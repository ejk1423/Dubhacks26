//
//  PerceptionModels.swift
//  Echo
//
//  Sendable value types shared between the ARKit session (main actor), the
//  `MeshGeometryStore` actor (background geometry math) and the SwiftUI HUD.
//  Nothing in this file imports ARKit or RealityKit on purpose: everything here
//  can cross an isolation boundary under Swift 6 strict concurrency.
//

import Foundation
import simd

// MARK: - Configuration

/// Tunable thresholds for the perception pipeline. Distances are metres, times are seconds.
struct PerceptionConfig: Sendable {

    // Walking-path corridor analysed for trip hazards, expressed relative to the
    // camera position along the horizontal heading (`t` = ahead, `s` = right).
    var pathNear: Float = 1.0
    var pathFar: Float = 3.0
    var pathHalfWidth: Float = 0.5
    var cellSize: Float = 0.2

    // Elevation thresholds relative to the locally estimated ground plane.
    var dropThreshold: Float = 0.08        // pothole / step down (negative elevation)
    var bumpThreshold: Float = 0.05        // curb / rock / cable (positive elevation)
    var maxTripHeight: Float = 0.35        // taller than this is an obstacle (sonar), not a trip hazard
    var minHazardVertices: Int = 4         // per-cell noise rejection
    var unknownSurfaceMaxDistance: Float = 2.0

    // Ground estimation.
    var groundSampleRadius: Float = 3.0
    var minGroundSamples: Int = 50
    var maxGroundSamples: Int = 8_192
    var planeMeshAgreement: Float = 0.25   // plane vs mesh-median disagreement that flips trust to the mesh
    var assumedCameraHeight: Float = 1.3   // fallback when no floor has been seen yet

    // Obstacle sonar ("parking sensor").
    var obstacleMinHeight: Float = 0.25    // ignore floor clutter below shin height
    var obstacleMaxHeight: Float = 2.0     // ignore ceilings / lamps above head height
    var obstacleMaxRange: Float = 4.0
    var forwardConeHalfAngle: Float = .pi / 4

    // Scheduling and rendering.
    var analysisInterval: TimeInterval = 0.1   // 10 Hz hazard + sonar analysis
    var maxAnchorUpdatesPerFrame: Int = 3      // mesh anchors converted per ARFrame (60 Hz)
    var renderRadius: Float = 8.0              // wireframe chunks farther than this are hidden
    var hazardOverlayLift: Float = 0.015       // lift the red overlay above the mesh to avoid z-fighting
    var maxOverlayTriangles: Int = 20_000
}

// MARK: - Surface classification

/// Raw `ARMeshClassification` values, kept as `UInt8` so chunks stay cheap and `Sendable`.
enum MeshClass {
    static let none: UInt8 = 0
    static let wall: UInt8 = 1
    static let floor: UInt8 = 2
    static let ceiling: UInt8 = 3
    static let table: UInt8 = 4
    static let seat: UInt8 = 5
    static let window: UInt8 = 6
    static let door: UInt8 = 7
}

/// Rendering palette bucket. The raw value is the natural material ordering.
enum SurfaceBucket: UInt32, CaseIterable, Sendable {
    case floor = 0      // walkable – neon green
    case wall           // walls, doors, windows – cyan
    case ceiling        // dim indigo
    case furniture      // tables, seats – amber (sonar obstacles)
    case unknown        // unclassified – grey

    init(meshClass: UInt8) {
        switch meshClass {
        case MeshClass.floor:                                   self = .floor
        case MeshClass.wall, MeshClass.window, MeshClass.door:  self = .wall
        case MeshClass.ceiling:                                 self = .ceiling
        case MeshClass.table, MeshClass.seat:                   self = .furniture
        default:                                                self = .unknown
        }
    }
}

// MARK: - Geometry transfer objects (main actor -> MeshGeometryStore)

/// One ARMeshAnchor geometry copied out of its Metal buffers.
struct MeshChunk: Sendable {
    let anchorID: UUID
    /// Monotonic per-manager counter so stale async results can be discarded.
    let sequence: UInt64
    /// Anchor-to-world transform.
    let transform: simd_float4x4
    /// Vertex positions in anchor-local space.
    let localPositions: [SIMD3<Float>]
    /// Triangle list, three indices per face.
    let indices: [UInt32]
    /// One `MeshClass` value per face (`indices.count / 3`).
    let faceClasses: [UInt8]
    let timestamp: TimeInterval
}

/// Horizontal ARPlaneAnchor summary used as the "established" ground plane.
struct PlaneInfo: Sendable {
    let anchorID: UUID
    let transform: simd_float4x4
    let center: SIMD3<Float>
    let width: Float
    let height: Float
    let isFloor: Bool

    var worldCenter: SIMD3<Float> { transform.transformPoint(center) }
    var area: Float { width * height }
}

// MARK: - Render transfer objects (MeshGeometryStore -> WireframeRenderer)

/// Everything the renderer needs to (re)build one wireframe chunk.
struct WireframeMeshData: Sendable {
    let anchorID: UUID
    let sequence: UInt64
    let transform: simd_float4x4
    let positions: [SIMD3<Float>]
    let indices: [UInt32]
    /// Dense material index per face (0..<buckets.count).
    let faceMaterials: [UInt32]
    /// Buckets actually used by this chunk, in ascending raw-value order.
    let buckets: [SurfaceBucket]
}

/// World-space triangles of every face currently flagged as a trip hazard.
struct HazardOverlayData: Sendable {
    var positions: [SIMD3<Float>] = []
    var indices: [UInt32] = []
    var timestamp: TimeInterval = 0
    var isEmpty: Bool { indices.isEmpty }
}

// MARK: - Analysis results (MeshGeometryStore -> HUD / audio)

/// Nearest solid surface point, used by the wall-sonar audio source.
struct ObstacleHit: Sendable, Equatable {
    let point: SIMD3<Float>
    /// Horizontal (XZ) distance from the camera, which is what matters for a walking body.
    let horizontalDistance: Float
    let bucket: SurfaceBucket
}

enum TripHazardKind: Int, Sendable {
    case drop            // pothole, step down, open stairwell
    case bump            // curb, rock, cable, threshold
    case unknownSurface  // no LiDAR return where floor is expected (low confidence)
}

struct TripHazard: Sendable, Identifiable, Equatable {
    /// Stable across frames while the hazard stays roughly in place (rounded world XZ + kind).
    let id: Int
    let kind: TripHazardKind
    /// World-space centroid on the hazard surface (where the audio alert is placed).
    let position: SIMD3<Float>
    let distanceAhead: Float
    let lateralOffset: Float
    /// Signed height relative to ground: negative for drops, positive for bumps.
    let elevation: Float
    let confidence: Float
    let vertexCount: Int
}

enum GroundSource: Sendable, Equatable {
    case planeAnchor
    case meshMedian
    case assumed
}

/// Snapshot of the scene published every `PerceptionConfig.analysisInterval`.
struct SceneSnapshot: Sendable {
    let timestamp: TimeInterval
    let cameraTransform: simd_float4x4
    let cameraPosition: SIMD3<Float>
    /// Unit horizontal walking direction (XZ plane).
    let heading: SIMD3<Float>
    let groundHeight: Float
    let groundSource: GroundSource
    let nearestObstacle: ObstacleHit?
    let nearestForwardObstacle: ObstacleHit?
    /// Nearest obstacle distance in 8 yaw sectors of 45 degrees: index 0 = ahead, 2 = right,
    /// 4 = behind, 6 = left. `.infinity` when the sector is clear.
    let sectorDistances: [Float]
    let tripHazards: [TripHazard]
    let meshAnchorCount: Int
    let vertexCount: Int
}

// MARK: - Session state

enum PerceptionStatus: Sendable, Equatable {
    case idle
    case starting
    case running
    case limited(String)
    case interrupted
    case failed(String)
    case unsupported(String)
}

struct DeviceCapabilities: Sendable, Equatable {
    var worldTracking = false
    var meshReconstruction = false
    var meshClassification = false
    var sceneDepth = false
    var planeClassification = false

    var hasLiDAR: Bool { meshReconstruction }
}

enum CameraFeedMode: Sendable, Equatable {
    /// Pure black background: the Tesla FSD look.
    case hidden
    /// Camera feed darkened by `ev` stops (negative values dim). -2.5 reads as a night-vision feed.
    case dimmed(ev: Float)
    case full
}

// MARK: - simd helpers

extension simd_float4x4 {
    var translation: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }

    func transformPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = self * SIMD4(p.x, p.y, p.z, 1)
        return SIMD3(v.x, v.y, v.z)
    }
}

extension SIMD3 where Scalar == Float {
    /// Projection onto the horizontal plane.
    var xz: SIMD3<Float> { SIMD3(x, 0, z) }
}
