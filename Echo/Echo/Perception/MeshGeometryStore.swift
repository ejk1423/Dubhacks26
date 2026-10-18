//
//  MeshGeometryStore.swift
//  Echo
//
//  Actor that owns a copy of every LiDAR mesh chunk and does all of the heavy
//  geometry math off the main thread:
//
//    * builds render data (triangles with per-face material buckets) for each chunk,
//    * estimates the local ground plane (ARPlaneAnchor floor, cross-checked
//      against the median height of floor-classified mesh vertices, with a
//      classification-free height-mode fallback for sidewalks and fresh scans),
//    * finds the nearest obstacle for the wall sonar per 15-degree sector (published
//      as 8 coarse sectors) and in a narrow corridor straight ahead, split into a
//      body band and a head band, using distance histograms (a bin needs several
//      vertices, so one stray vertex is not a wall) smoothed over time (approach is
//      instant, recession is rate-limited),
//    * tracks the corridor target over time to tell a person walking at the user
//      from a wall the user is walking at,
//    * measures the clear width either side of the walking line,
//    * builds a top-down occupancy map (mesh plus this frame's depth map) for the HUD
//      and casts rays through it to find doorways and gaps wide enough to walk through,
//    * scans a 0.3-2.5 m corridor along the walking direction for negative drops
//      (potholes, stairs) and positive spikes (curbs, rocks) relative to ground, and
//      for edges where well-observed floor simply ends inside the camera's view,
//      clusters them into `TripHazard`s, reports only those that persist over several
//      analyses, and emits the red overlay triangles.
//
//  The sonar fuses two sources: the accumulated mesh (full 360 degrees, but smoothed
//  and a second or so behind reality) and the live LiDAR depth map (camera field of
//  view only, but dense and instantaneous). Inside the depth map's cone the corridor
//  trusts the depth map, and any mesh the camera can currently see past (checked per
//  line of sight through a coarse camera-space z-buffer of this frame's depth) is
//  treated as stale, so a person stepping in front is seen on the next analysis and
//  stops counting the moment they walk on, while a table below the camera's view is
//  never mistaken for a ghost.
//
//  Only `Sendable` value types cross into or out of this actor.
//

import Foundation
import simd

actor MeshGeometryStore {

    // MARK: Types

    private struct StoredChunk {
        let chunk: MeshChunk
        /// Vertex positions in world space (anchor transform baked in).
        let world: [SIMD3<Float>]
        /// Classification per vertex, derived from the faces that touch it.
        let vertexClasses: [UInt8]
        let aabbMin: SIMD3<Float>
        let aabbMax: SIMD3<Float>
    }

    /// Accumulator for one corridor grid cell.
    private struct Cell {
        var count = 0            // mesh floor-ish vertices inside the trip band (drops and bumps included)
        var obstacleCount = 0    // mesh vertices above `maxTripHeight`
        var dropCount = 0
        var bumpCount = 0
        var dropSum = SIMD3<Float>(repeating: 0)
        var bumpSum = SIMD3<Float>(repeating: 0)
        var minDy: Float = .infinity
        var maxDy: Float = -.infinity
        // This frame's depth map, by height band.
        var liveFloor = 0        // returns between a drop and `maxTripHeight`: the floor is there right now
        var liveBelow = 0        // returns below the drop threshold: a lower floor is visible
        var liveAbove = 0        // returns above `maxTripHeight`: something stands here
        var liveMinDy: Float = .infinity

        /// Mesh vertices at about ground level (neither drop nor bump).
        var meshNearGround: Int { count - dropCount - bumpCount }
    }

    private struct Candidate {
        let chunkIndex: Int
        let vertex: Int
        let cell: Int
    }

    private enum CellKind: UInt8 {
        case none = 0, drop, bump, unknown
    }

    /// Sonar histograms: fine yaw sectors x distance bins, plus the forward corridor
    /// (one histogram for the mesh, one for the live depth map, each with a separate
    /// head-band copy so overhead things can be told apart from body-height things).
    private struct SonarBins {
        let nSectors: Int
        let nBins: Int
        let sectorWidth: Float
        let binSize: Float
        let maxRange: Float
        let forwardHalfWidth: Float
        var count: [Int]
        var sum: [SIMD3<Float>]
        var cls: [UInt8]
        var fwdCount: [Int]
        var fwdSum: [SIMD3<Float>]
        var fwdClass: [UInt8]
        var headCount: [Int]
        var headSum: [SIMD3<Float>]
        var headClass: [UInt8]
        var depthFwdCount: [Int]
        var depthFwdSum: [SIMD3<Float>]
        var depthHeadCount: [Int]
        var depthHeadSum: [SIMD3<Float>]

        init(nSectors: Int, nBins: Int, config cfg: PerceptionConfig) {
            self.nSectors = nSectors
            self.nBins = nBins
            sectorWidth = 2 * .pi / Float(nSectors)
            binSize = cfg.obstacleBinSize
            maxRange = cfg.obstacleMaxRange
            forwardHalfWidth = cfg.forwardHalfWidth
            count = [Int](repeating: 0, count: nSectors * nBins)
            sum = [SIMD3<Float>](repeating: .zero, count: nSectors * nBins)
            cls = [UInt8](repeating: MeshClass.none, count: nSectors * nBins)
            fwdCount = [Int](repeating: 0, count: nBins)
            fwdSum = [SIMD3<Float>](repeating: .zero, count: nBins)
            fwdClass = [UInt8](repeating: MeshClass.none, count: nBins)
            headCount = [Int](repeating: 0, count: nBins)
            headSum = [SIMD3<Float>](repeating: .zero, count: nBins)
            headClass = [UInt8](repeating: MeshClass.none, count: nBins)
            depthFwdCount = [Int](repeating: 0, count: nBins)
            depthFwdSum = [SIMD3<Float>](repeating: .zero, count: nBins)
            depthHeadCount = [Int](repeating: 0, count: nBins)
            depthHeadSum = [SIMD3<Float>](repeating: .zero, count: nBins)
        }

        /// Drops one solid point into the sector histogram and, if it is in the walking
        /// corridor, into the forward histogram (`fromDepth` selects which one; `head`
        /// additionally files it in the head band).
        mutating func accumulate(_ v: SIMD3<Float>, _ c: UInt8, t: Float, s: Float, fromDepth: Bool, head: Bool) {
            let dist = (t * t + s * s).squareRoot()
            guard dist < maxRange, dist > 0.05 else { return }
            let angle = atan2(s, t)                                   // 0 = ahead, +pi/2 = right
            var k = Int(((angle + sectorWidth / 2) / sectorWidth).rounded(.down))
            k = ((k % nSectors) + nSectors) % nSectors
            let b = min(Int(dist / binSize), nBins - 1)
            let bin = k * nBins + b
            count[bin] += 1
            sum[bin] += v
            if c != MeshClass.none { cls[bin] = c }
            guard t > 0.05, abs(s) <= forwardHalfWidth else { return }
            let fb = min(Int(t / binSize), nBins - 1)
            if fromDepth {
                depthFwdCount[fb] += 1
                depthFwdSum[fb] += v
                if head {
                    depthHeadCount[fb] += 1
                    depthHeadSum[fb] += v
                }
            } else {
                fwdCount[fb] += 1
                fwdSum[fb] += v
                if c != MeshClass.none { fwdClass[fb] = c }
                if head {
                    headCount[fb] += 1
                    headSum[fb] += v
                    if c != MeshClass.none { headClass[fb] = c }
                }
            }
        }
    }

    /// Coarse camera-space z-buffer of this frame's depth map: the nearest depth seen in
    /// each ~2-degree cell of the view. Answers "can the camera currently see past this
    /// mesh point?" along the actual line of sight, so mesh above or below the depth
    /// map's vertical field of view is never vetoed by what is seen behind it.
    private struct DepthView {
        static let nx = 48
        static let ny = 36
        static let halfTan: Float = 0.75      // grid extent; the live field of view is measured from the points
        let inverse: simd_float4x4
        var minZ = [Float](repeating: .infinity, count: Self.nx * Self.ny)
        var maxTanX: Float = 0
        var maxTanY: Float = 0
        var pointCount = 0

        init(cameraTransform: simd_float4x4) {
            inverse = cameraTransform.inverse
        }

        /// Camera-space (tan x, tan y, depth) for a world point in front of the camera.
        @inline(__always)
        func project(_ v: SIMD3<Float>) -> (tx: Float, ty: Float, z: Float)? {
            let p = inverse.transformPoint(v)
            let z = -p.z
            guard z > 0.05 else { return nil }
            return (p.x / z, p.y / z, z)
        }

        @inline(__always)
        static func cellIndex(tx: Float, ty: Float) -> Int? {
            guard abs(tx) < halfTan, abs(ty) < halfTan else { return nil }
            let cx = min(nx - 1, Int((tx + halfTan) / (2 * halfTan) * Float(nx)))
            let cy = min(ny - 1, Int((ty + halfTan) / (2 * halfTan) * Float(ny)))
            return cy * nx + cx
        }

        mutating func insert(_ v: SIMD3<Float>) {
            guard let p = project(v), let idx = Self.cellIndex(tx: p.tx, ty: p.ty) else { return }
            pointCount += 1
            if abs(p.tx) > maxTanX { maxTanX = abs(p.tx) }
            if abs(p.ty) > maxTanY { maxTanY = abs(p.ty) }
            if p.z < minZ[idx] { minZ[idx] = p.z }
        }

        /// The camera currently sees something at least `margin` farther than `v` along
        /// the same line of sight: `v` is stale mesh.
        func seesPast(_ v: SIMD3<Float>, margin: Float) -> Bool {
            guard pointCount > 0, let p = project(v),
                  abs(p.tx) <= maxTanX * 0.95, abs(p.ty) <= maxTanY * 0.95,
                  let idx = Self.cellIndex(tx: p.tx, ty: p.ty) else { return false }
            let seen = minZ[idx]
            return seen.isFinite && p.z < seen - margin
        }

        /// `v` lies well inside the part of the view the depth map is returning from.
        func inView(_ v: SIMD3<Float>, inset: Float = 0.85) -> Bool {
            guard pointCount > 0, let p = project(v) else { return false }
            return abs(p.tx) <= maxTanX * inset && abs(p.ty) <= maxTanY * inset
        }
    }

    private struct TrackedHazard {
        var hazard: TripHazard
        var streak: Int
        var cells: [Int]
        /// Where the hazard and the user were when the streak started (edge drag check).
        var origin: SIMD3<Float>
        var originUser: SIMD3<Float>
    }

    private struct TrackedOpening {
        var opening: Opening
        var streak: Int
        var misses: Int
    }

    private struct TargetSample {
        let time: TimeInterval
        /// Target position along the heading in a frame fixed to the world (user motion removed).
        let along: Float
        /// Raw measured distance.
        let distance: Float
    }

    struct AnalysisResult: Sendable {
        let snapshot: SceneSnapshot
        let overlay: HazardOverlayData
        /// Chunks dropped for being far away; the renderer should remove them too.
        let evicted: [UUID]
    }

    // MARK: State

    private let config: PerceptionConfig
    private var chunks: [UUID: StoredChunk] = [:]
    private var planes: [UUID: PlaneInfo] = [:]
    private var totalVertices = 0
    private var lastGround: Float?
    private var lastAnalysisTime: TimeInterval?
    private var lastHeading: SIMD3<Float>?
    private var lastPosition: SIMD3<Float>?
    private var walkingSpeed: Float = 0
    /// Fine sonar sectors (15 degrees each, index 0 centred dead ahead, clockwise).
    private static let sectorCount = 24
    private var smoothedSectors = [Float](repeating: .infinity, count: sectorCount)
    private var sectorHits = [ObstacleHit?](repeating: nil, count: sectorCount)
    private var sectorStreaks = [Int](repeating: 0, count: sectorCount)
    /// Narrow corridor straight ahead ("is there something in my path?"), all heights.
    private var smoothedForward: Float = .infinity
    private var forwardHit: ObstacleHit?
    private var forwardStreak = 0
    /// The same corridor split into a body band (shin to `headBandMin`) and a head band.
    private var smoothedBody: Float = .infinity
    private var bodyHit: ObstacleHit?
    private var bodyStreak = 0
    private var smoothedHead: Float = .infinity
    private var headHit: ObstacleHit?
    private var headStreak = 0
    private var trackedHazards: [TrackedHazard] = []
    private var trackedOpenings: [TrackedOpening] = []
    /// Forward-target motion.
    private var targetHistory: [TargetSample] = []
    private var userAlong: Float = 0
    private var lastTargetDistance: Float?
    private var targetHeadingRef: SIMD3<Float>?
    private var approachStreak = 0
    /// Path clearance, smoothed (narrowing is instant, widening is rate-limited).
    private var clearLeft: Float
    private var clearRight: Float

    init(config: PerceptionConfig) {
        self.config = config
        clearLeft = config.clearanceMaxLateral
        clearRight = config.clearanceMaxLateral
    }

    // MARK: Chunk / plane bookkeeping

    /// Stores (or replaces) a chunk and returns the wireframe data for the renderer.
    func upsert(_ chunk: MeshChunk) -> WireframeMeshData {
        let n = chunk.localPositions.count
        let faceCount = chunk.faceClasses.count

        // World-space positions + bounding box.
        var world = [SIMD3<Float>](repeating: .zero, count: n)
        var aabbMin = SIMD3<Float>(repeating: .infinity)
        var aabbMax = SIMD3<Float>(repeating: -.infinity)
        for i in 0..<n {
            let w = chunk.transform.transformPoint(chunk.localPositions[i])
            world[i] = w
            aabbMin = simd_min(aabbMin, w)
            aabbMax = simd_max(aabbMax, w)
        }

        // Per-vertex class (a classified face wins over `none`).
        var vertexClasses = [UInt8](repeating: MeshClass.none, count: n)
        chunk.indices.withUnsafeBufferPointer { idx in
            for f in 0..<faceCount {
                let base = f * 3
                guard base + 2 < idx.count else { break }
                let c = chunk.faceClasses[f]
                if c != MeshClass.none {
                    for k in 0..<3 {
                        let vi = Int(idx[base + k])
                        if vi < n { vertexClasses[vi] = c }
                    }
                }
            }
        }

        // Render geometry: the real triangles, bucketed per face by class. Ceilings are
        // dropped (nothing to walk into, and they fill the view); everything else is drawn
        // and the surface shader decides how visible it is from its distance to the user.
        var keptIndices: [UInt32] = []
        keptIndices.reserveCapacity(chunk.indices.count)
        var rawMaterials: [UInt32] = []
        rawMaterials.reserveCapacity(faceCount)
        var usedBuckets = [Bool](repeating: false, count: SurfaceBucket.allCases.count)
        chunk.indices.withUnsafeBufferPointer { idx in
            for f in 0..<faceCount {
                let base = f * 3
                guard base + 2 < idx.count else { break }
                let bucket = SurfaceBucket(meshClass: chunk.faceClasses[f])
                guard bucket != .ceiling else { continue }
                keptIndices.append(idx[base])
                keptIndices.append(idx[base + 1])
                keptIndices.append(idx[base + 2])
                rawMaterials.append(bucket.rawValue)
                usedBuckets[Int(bucket.rawValue)] = true
            }
        }

        // Dense material indices so the renderer only allocates the materials this chunk uses.
        var remap = [UInt32](repeating: 0, count: usedBuckets.count)
        var buckets: [SurfaceBucket] = []
        for bucket in SurfaceBucket.allCases where usedBuckets[Int(bucket.rawValue)] {
            remap[Int(bucket.rawValue)] = UInt32(buckets.count)
            buckets.append(bucket)
        }
        let faceMaterials = rawMaterials.map { remap[Int($0)] }

        if let old = chunks[chunk.anchorID] { totalVertices -= old.world.count }
        totalVertices += n
        chunks[chunk.anchorID] = StoredChunk(
            chunk: chunk,
            world: world,
            vertexClasses: vertexClasses,
            aabbMin: aabbMin,
            aabbMax: aabbMax
        )

        return WireframeMeshData(
            anchorID: chunk.anchorID,
            sequence: chunk.sequence,
            transform: chunk.transform,
            center: (aabbMin + aabbMax) / 2,
            positions: chunk.localPositions,
            indices: keptIndices,
            faceMaterials: faceMaterials,
            buckets: buckets
        )
    }

    func remove(anchorID: UUID) {
        if let old = chunks.removeValue(forKey: anchorID) {
            totalVertices -= old.world.count
        }
    }

    func upsertPlane(_ plane: PlaneInfo) {
        planes[plane.anchorID] = plane
    }

    func removePlane(anchorID: UUID) {
        planes[anchorID] = nil
    }

    func removeAll() {
        chunks.removeAll()
        planes.removeAll()
        totalVertices = 0
        lastGround = nil
        resetTracking()
    }

    private func resetTracking() {
        lastAnalysisTime = nil
        lastHeading = nil
        lastPosition = nil
        walkingSpeed = 0
        smoothedSectors = [Float](repeating: .infinity, count: Self.sectorCount)
        sectorHits = [ObstacleHit?](repeating: nil, count: Self.sectorCount)
        sectorStreaks = [Int](repeating: 0, count: Self.sectorCount)
        smoothedForward = .infinity
        forwardHit = nil
        forwardStreak = 0
        smoothedBody = .infinity
        bodyHit = nil
        bodyStreak = 0
        smoothedHead = .infinity
        headHit = nil
        headStreak = 0
        trackedHazards.removeAll()
        trackedOpenings.removeAll()
        resetTargetHistory()
        clearLeft = config.clearanceMaxLateral
        clearRight = config.clearanceMaxLateral
    }

    private func resetTargetHistory() {
        targetHistory.removeAll(keepingCapacity: true)
        userAlong = 0
        lastTargetDistance = nil
        targetHeadingRef = nil
        approachStreak = 0
    }

    // MARK: Analysis

    /// Runs the ground estimate, obstacle sonar and trip-hazard scan for the given camera pose.
    /// `depthPoints` are world-space samples of this frame's LiDAR depth map (may be empty).
    func analyze(cameraTransform: simd_float4x4, timestamp: TimeInterval,
                 depthPoints: [SIMD3<Float>]) -> AnalysisResult {
        let cfg = config
        let p0 = cameraTransform.translation

        // Walking direction: the camera's view direction (-Z) projected onto the floor.
        // Nothing else is mixed in: adding the phone's long axis made the heading swing
        // sideways with every roll of the hand, which made every bearing wander. When the
        // phone is pointed almost straight down the projection is meaningless, so the
        // previous heading is kept.
        let camZ = SIMD3(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        var heading = (-camZ).xz
        if simd_length(heading) >= 0.3 {
            heading = simd_normalize(heading)
        } else {
            heading = lastHeading ?? SIMD3(0, 0, -1)
        }
        lastHeading = heading
        let right = simd_normalize(simd_cross(heading, SIMD3(0, 1, 0)))

        // ---- 0. Forget mesh far behind us so memory stays bounded --------------
        var evicted: [UUID] = []
        for (id, sc) in chunks
        where Self.horizontalDistance(from: p0, toBox: sc.aabbMin, sc.aabbMax) > cfg.chunkEvictionRadius {
            evicted.append(id)
        }
        for id in evicted { remove(anchorID: id) }

        // ---- 1. Ground plane -------------------------------------------------
        let (ground, groundSource) = estimateGround(cameraPosition: p0)
        if groundSource != .assumed { lastGround = ground }

        let dt = Float(min(max(timestamp - (lastAnalysisTime ?? timestamp), 0), 0.5))
        lastAnalysisTime = timestamp

        // Walking speed (horizontal), exponentially smoothed over ~0.4 s, and the user's
        // displacement along the heading (for the target-motion estimate).
        if let last = lastPosition, dt > 0.01 {
            let step = (p0 - last).xz
            let instantaneous = simd_length(step) / dt
            let blend = min(1, dt / 0.4)
            walkingSpeed += (instantaneous - walkingSpeed) * blend
            userAlong += simd_dot(step, heading)
        }
        lastPosition = p0

        // The sonar works off an assumed floor height (walls span floor to ceiling), but
        // trip hazards are height differences, so they wait for a real floor.
        let hazardsEnabled = groundSource != .assumed
        if !hazardsEnabled { trackedHazards.removeAll() }

        // ---- 2. Single pass: sonar + corridor accumulation --------------------
        let chunkList = Array(chunks.values)

        let nT = max(1, Int(((cfg.pathFar - cfg.pathNear) / cfg.cellSize).rounded(.up)))
        let nS = max(1, Int(((2 * cfg.pathHalfWidth) / cfg.cellSize).rounded(.up)))
        var cells = [Cell](repeating: Cell(), count: nT * nS)
        var candidates: [Candidate] = []

        // Corridor AABB in world space, used to skip irrelevant chunks early.
        let cornerA = p0 + heading * cfg.pathNear - right * cfg.pathHalfWidth
        let cornerB = p0 + heading * cfg.pathNear + right * cfg.pathHalfWidth
        let cornerC = p0 + heading * cfg.pathFar - right * cfg.pathHalfWidth
        let cornerD = p0 + heading * cfg.pathFar + right * cfg.pathHalfWidth
        var corridorMin = simd_min(simd_min(cornerA, cornerB), simd_min(cornerC, cornerD))
        var corridorMax = simd_max(simd_max(cornerA, cornerB), simd_max(cornerC, cornerD))
        corridorMin.y = ground - 1.5                       // deep enough to see a stairwell
        corridorMax.y = ground + cfg.maxTripHeight + 0.1

        let sonarYMin = ground + cfg.obstacleMinHeight
        let sonarYMax = ground + cfg.obstacleMaxHeight
        let headYMin = ground + cfg.headBandMin

        let nSectors = Self.sectorCount
        let nBins = max(1, Int((cfg.obstacleMaxRange / cfg.obstacleBinSize).rounded(.up)))
        var bins = SonarBins(nSectors: nSectors, nBins: nBins, config: cfg)

        // Path clearance: a lateral histogram of solid points in a band ahead. The band
        // stops short of the forward target (last analysis) so the wall ahead does not
        // read as "no clearance" while the passage leading to it is wide open.
        let clearFar = min(cfg.clearanceFar, max(cfg.clearanceNear + 0.4, smoothedForward - 0.15))
        let nLateral = max(2, Int((2 * cfg.clearanceMaxLateral / cfg.clearanceBinSize).rounded(.up)))
        var lateral = [Int](repeating: 0, count: nLateral)
        func lateralBin(_ s: Float) -> Int? {
            let b = Int((s + cfg.clearanceMaxLateral) / cfg.clearanceBinSize)
            return b >= 0 && b < nLateral ? b : nil
        }

        // Top-down occupancy map (world-aligned grid centred on the user).
        let mapSize = Int((2 * cfg.mapRadius / cfg.mapCellSize).rounded(.up))
        let mapOrigin = SIMD2<Float>(
            ((p0.x - cfg.mapRadius) / cfg.mapCellSize).rounded(.down) * cfg.mapCellSize,
            ((p0.z - cfg.mapRadius) / cfg.mapCellSize).rounded(.down) * cfg.mapCellSize
        )
        var mapObstacle = [UInt16](repeating: 0, count: mapSize * mapSize)
        var mapObstacleClass = [UInt8](repeating: MeshClass.none, count: mapSize * mapSize)
        var mapFloor = [UInt16](repeating: 0, count: mapSize * mapSize)
        var mapLive = [UInt16](repeating: 0, count: mapSize * mapSize)
        var mapLiveFloor = [UInt16](repeating: 0, count: mapSize * mapSize)
        func mapIndex(_ v: SIMD3<Float>) -> Int? {
            let column = Int((v.x - mapOrigin.x) / cfg.mapCellSize)
            let row = Int((v.z - mapOrigin.y) / cfg.mapCellSize)
            guard column >= 0, column < mapSize, row >= 0, row < mapSize else { return nil }
            return row * mapSize + column
        }
        func corridorIndex(t: Float, s: Float) -> Int? {
            guard t >= cfg.pathNear, t <= cfg.pathFar, abs(s) <= cfg.pathHalfWidth else { return nil }
            let ti = min(Int((t - cfg.pathNear) / cfg.cellSize), nT - 1)
            let si = min(Int((s + cfg.pathHalfWidth) / cfg.cellSize), nS - 1)
            return ti * nS + si
        }

        // Live depth map, one pass: no classes, but every point is a real surface seen this
        // frame. Feeds the sonar, the forward corridor, the clearance profile, the map (solid
        // and floor) and the corridor cells (floor seen / lower floor seen / something standing),
        // plus the camera-space z-buffer used to veto stale mesh.
        var depthView = DepthView(cameraTransform: cameraTransform)
        for v in depthPoints {
            depthView.insert(v)
            let dy = v.y - ground
            let d = v - p0
            let t = d.x * heading.x + d.z * heading.z
            let s = d.x * right.x + d.z * right.z
            if dy >= cfg.obstacleMinHeight, dy <= cfg.obstacleMaxHeight {
                bins.accumulate(v, MeshClass.none, t: t, s: s, fromDepth: true, head: dy >= cfg.headBandMin)
                if let idx = mapIndex(v) { mapLive[idx] += 1 }
                if t >= cfg.clearanceNear, t <= clearFar, let lb = lateralBin(s) { lateral[lb] += 1 }
            } else if abs(dy) < 0.15, let idx = mapIndex(v) {
                mapLiveFloor[idx] += 1
            }
            if hazardsEnabled, dy <= cfg.obstacleMaxHeight, let idx = corridorIndex(t: t, s: s) {
                if dy > cfg.maxTripHeight {
                    cells[idx].liveAbove += 1
                } else if dy <= -cfg.dropThreshold {
                    cells[idx].liveBelow += 1
                    if dy < cells[idx].liveMinDy { cells[idx].liveMinDy = dy }
                } else {
                    cells[idx].liveFloor += 1
                }
            }
        }
        let ghostMargin = cfg.ghostMargin

        for (ci, sc) in chunkList.enumerated() {
            let horizontal = Self.horizontalDistance(from: p0, toBox: sc.aabbMin, sc.aabbMax)
            let sonarRelevant =
                horizontal <= cfg.obstacleMaxRange
                && sc.aabbMax.y >= sonarYMin && sc.aabbMin.y <= sonarYMax
            let corridorRelevant = hazardsEnabled && Self.overlaps(sc.aabbMin, sc.aabbMax, corridorMin, corridorMax)
            let mapRelevant = horizontal <= cfg.mapRadius
            if !sonarRelevant && !corridorRelevant && !mapRelevant { continue }

            sc.world.withUnsafeBufferPointer { w in
                sc.vertexClasses.withUnsafeBufferPointer { cls in
                    for i in 0..<w.count {
                        let v = w[i]
                        let c = cls[i]
                        let dy = v.y - ground
                        let d = v - p0
                        let t = d.x * heading.x + d.z * heading.z   // ahead
                        let s = d.x * right.x + d.z * right.z       // right

                        // -- Wall sonar: anything solid between shin and head height.
                        let solid = dy >= cfg.obstacleMinHeight && dy <= cfg.obstacleMaxHeight
                            && c != MeshClass.floor && c != MeshClass.ceiling
                        let stale = solid && depthView.seesPast(v, margin: ghostMargin)
                        if sonarRelevant, solid, !stale {
                            bins.accumulate(v, c, t: t, s: s, fromDepth: false, head: v.y >= headYMin)
                            if t >= cfg.clearanceNear, t <= clearFar, let lb = lateralBin(s) { lateral[lb] += 1 }
                        }

                        // -- Occupancy map: solid things at body height, and the floor.
                        if mapRelevant, !stale, let idx = mapIndex(v) {
                            if solid {
                                mapObstacle[idx] += 1
                                if c != MeshClass.none { mapObstacleClass[idx] = c }
                            } else if c == MeshClass.floor || abs(dy) < 0.15 {
                                mapFloor[idx] += 1
                            }
                        }

                        // -- Trip-hazard corridor: floor-ish surfaces only.
                        if corridorRelevant,
                           c != MeshClass.wall, c != MeshClass.ceiling,
                           c != MeshClass.window, c != MeshClass.door,
                           let idx = corridorIndex(t: t, s: s) {
                            if dy > cfg.maxTripHeight {
                                cells[idx].obstacleCount += 1
                            } else {
                                cells[idx].count += 1
                                if dy < cells[idx].minDy { cells[idx].minDy = dy }
                                if dy > cells[idx].maxDy { cells[idx].maxDy = dy }
                                if dy <= -cfg.dropThreshold {
                                    cells[idx].dropCount += 1
                                    cells[idx].dropSum += v
                                    candidates.append(Candidate(chunkIndex: ci, vertex: i, cell: idx))
                                } else if dy >= cfg.bumpThreshold {
                                    cells[idx].bumpCount += 1
                                    cells[idx].bumpSum += v
                                    candidates.append(Candidate(chunkIndex: ci, vertex: i, cell: idx))
                                }
                            }
                        }
                    }
                }
            }
        }

        // ---- 2b. Resolve sonar sectors + temporal smoothing ---------------------
        func firstSolidBin(_ counts: ArraySlice<Int>, _ sums: ArraySlice<SIMD3<Float>>,
                           _ classes: ArraySlice<UInt8>?) -> ObstacleHit? {
            for (bin, count) in zip(counts.indices, counts) where count >= cfg.minObstacleVertices {
                let centroid = sums[bin] / Float(count)
                return ObstacleHit(
                    point: centroid,
                    horizontalDistance: simd_length((centroid - p0).xz),
                    bucket: SurfaceBucket(meshClass: classes?[bin] ?? MeshClass.none)
                )
            }
            return nil
        }
        for k in 0..<nSectors {
            let range = (k * nBins)..<((k + 1) * nBins)
            smooth(raw: firstSolidBin(bins.count[range], bins.sum[range], bins.cls[range]),
                   distance: &smoothedSectors[k], hit: &sectorHits[k], streak: &sectorStreaks[k], dt: dt)
        }

        // Corridor: the depth map is the authority inside its cone; the mesh fills in the
        // corridor's edges that the camera cannot see.
        func resolveForward(meshCount: [Int], meshSum: [SIMD3<Float>], meshClass: [UInt8],
                            depthCount: [Int], depthSum: [SIMD3<Float>]) -> ObstacleHit? {
            let mesh = firstSolidBin(meshCount[...], meshSum[...], meshClass[...])
            var raw = depthPoints.isEmpty ? mesh : firstSolidBin(depthCount[...], depthSum[...], nil)
            if let m = mesh, m.horizontalDistance < (raw?.horizontalDistance ?? .infinity) {
                let d = m.point - p0
                let bearing = atan2(d.x * right.x + d.z * right.z, d.x * heading.x + d.z * heading.z)
                if depthPoints.isEmpty || abs(bearing) > cfg.depthFOVHalfAngle { raw = m }
            }
            return raw
        }
        let rawForward = resolveForward(meshCount: bins.fwdCount, meshSum: bins.fwdSum, meshClass: bins.fwdClass,
                                        depthCount: bins.depthFwdCount, depthSum: bins.depthFwdSum)
        smooth(raw: rawForward, distance: &smoothedForward, hit: &forwardHit, streak: &forwardStreak, dt: dt)

        // Body band = everything minus the head band (exact: the head band is a subset).
        var bodyCount = bins.fwdCount, bodySum = bins.fwdSum, depthBodyCount = bins.depthFwdCount, depthBodySum = bins.depthFwdSum
        for b in 0..<nBins {
            bodyCount[b] -= bins.headCount[b]
            bodySum[b] -= bins.headSum[b]
            depthBodyCount[b] -= bins.depthHeadCount[b]
            depthBodySum[b] -= bins.depthHeadSum[b]
        }
        let rawBody = resolveForward(meshCount: bodyCount, meshSum: bodySum, meshClass: bins.fwdClass,
                                     depthCount: depthBodyCount, depthSum: depthBodySum)
        smooth(raw: rawBody, distance: &smoothedBody, hit: &bodyHit, streak: &bodyStreak, dt: dt)
        let rawHead = resolveForward(meshCount: bins.headCount, meshSum: bins.headSum, meshClass: bins.headClass,
                                     depthCount: bins.depthHeadCount, depthSum: bins.depthHeadSum)
        smooth(raw: rawHead, distance: &smoothedHead, hit: &headHit, streak: &headStreak, dt: dt)

        let nearestSector = (0..<nSectors).min { smoothedSectors[$0] < smoothedSectors[$1] }!
        let best = sectorHits[nearestSector]
        let bestFwd = forwardHit

        // Publish 8 coarse sectors (45 degrees each) as the minimum of their 3 fine sectors.
        var coarseSectors = [Float](repeating: .infinity, count: 8)
        for k in 0..<nSectors {
            let coarse = ((k + 1) / 3) % 8
            coarseSectors[coarse] = min(coarseSectors[coarse], smoothedSectors[k])
        }

        // ---- 2c. Forward-target motion ------------------------------------------
        let motion = updateTargetMotion(raw: rawForward, heading: heading, timestamp: timestamp)

        // ---- 2d. Path clearance ---------------------------------------------------
        let centre = nLateral / 2                      // s = 0 is the boundary between centre-1 and centre
        var rawRight = cfg.clearanceMaxLateral
        for b in centre..<nLateral where lateral[b] >= cfg.clearanceMinVertices {
            rawRight = Float(b - centre) * cfg.clearanceBinSize
            break
        }
        var rawLeft = cfg.clearanceMaxLateral
        for b in stride(from: centre - 1, through: 0, by: -1) where lateral[b] >= cfg.clearanceMinVertices {
            rawLeft = Float(centre - 1 - b) * cfg.clearanceBinSize
            break
        }
        clearLeft = min(rawLeft, clearLeft + cfg.clearanceReleaseRate * dt)
        clearRight = min(rawRight, clearRight + cfg.clearanceReleaseRate * dt)

        // ---- 3. Classify cells ------------------------------------------------
        var kinds = [CellKind](repeating: .none, count: cells.count)
        for idx in 0..<cells.count where hazardsEnabled {
            let cell = cells[idx]
            let minShare = cfg.minHazardFraction * Float(cell.count)
            if cell.dropCount >= cfg.minHazardVertices, Float(cell.dropCount) >= minShare,
               cell.dropCount >= cell.bumpCount {
                kinds[idx] = .drop
            } else if cell.bumpCount >= cfg.minHazardVertices, Float(cell.bumpCount) >= minShare {
                kinds[idx] = .bump
            }
        }
        if cfg.reportUnknownSurfaces, hazardsEnabled {
            // A cell with no LiDAR returns at all, surrounded by scanned floor and within
            // close range, usually means the floor is not there (edge of a platform,
            // glass, or a very deep hole). Reported at low confidence.
            for ti in 0..<nT {
                let tCenter = cfg.pathNear + (Float(ti) + 0.5) * cfg.cellSize
                guard tCenter <= cfg.unknownSurfaceMaxDistance else { continue }
                for si in 0..<nS {
                    let idx = ti * nS + si
                    guard cells[idx].count == 0, cells[idx].obstacleCount == 0 else { continue }
                    var populated = 0
                    if ti > 0, cells[idx - nS].count >= cfg.minHazardVertices { populated += 1 }
                    if ti < nT - 1, cells[idx + nS].count >= cfg.minHazardVertices { populated += 1 }
                    if si > 0, cells[idx - 1].count >= cfg.minHazardVertices { populated += 1 }
                    if si < nS - 1, cells[idx + 1].count >= cfg.minHazardVertices { populated += 1 }
                    if populated >= 2 { kinds[idx] = .unknown }
                }
            }
        }

        // ---- 4. Flood-fill cells into hazards ---------------------------------
        var found: [(hazard: TripHazard, cells: [Int])] = []
        var visited = [Bool](repeating: false, count: cells.count)
        for start in 0..<cells.count where kinds[start] != .none && !visited[start] {
            let kind = kinds[start]
            var stack = [start]
            var members: [Int] = []
            visited[start] = true
            while let idx = stack.popLast() {
                members.append(idx)
                let ti = idx / nS, si = idx % nS
                let neighbours = [
                    ti > 0 ? idx - nS : -1,
                    ti < nT - 1 ? idx + nS : -1,
                    si > 0 ? idx - 1 : -1,
                    si < nS - 1 ? idx + 1 : -1,
                ]
                for n in neighbours where n >= 0 && !visited[n] && kinds[n] == kind {
                    visited[n] = true
                    stack.append(n)
                }
            }

            // A step or curb spans the path and has nothing standing on it. A one-cell ridge
            // is clutter (a cable, a chair leg), and elevated floor with solid geometry above
            // it is the foot of a wall or a piece of furniture, not something to step onto.
            if kind != .unknown {
                let columns = Set(members.map { $0 % nS })
                let underSomething = members.contains { cells[$0].obstacleCount >= cfg.minHazardVertices }
                if columns.count < cfg.minHazardWidthCells || underSomething { continue }
            }

            var position = SIMD3<Float>(repeating: 0)
            var count = 0
            var elevation: Float = 0
            switch kind {
            case .drop:
                for idx in members {
                    position += cells[idx].dropSum
                    count += cells[idx].dropCount
                    elevation = min(elevation, cells[idx].minDy)
                }
                position /= Float(max(count, 1))
            case .bump:
                for idx in members {
                    position += cells[idx].bumpSum
                    count += cells[idx].bumpCount
                    elevation = max(elevation, cells[idx].maxDy)
                }
                position /= Float(max(count, 1))
            case .unknown:
                for idx in members {
                    let ti = idx / nS, si = idx % nS
                    let t = cfg.pathNear + (Float(ti) + 0.5) * cfg.cellSize
                    let s = -cfg.pathHalfWidth + (Float(si) + 0.5) * cfg.cellSize
                    position += p0 + heading * t + right * s
                }
                position /= Float(members.count)
                position.y = ground
                count = members.count
            case .none:
                continue
            }

            let rel = position - p0
            let hazardKind: TripHazardKind = kind == .drop ? .drop : (kind == .bump ? .bump : .unknownSurface)
            let confidence: Float = kind == .unknown
                ? 0.3
                : min(1, Float(count) / Float(cfg.minHazardVertices * 4))

            found.append((TripHazard(
                id: Self.hazardID(position: position, kind: hazardKind),
                kind: hazardKind,
                position: position,
                distanceAhead: rel.x * heading.x + rel.z * heading.z,
                lateralOffset: rel.x * right.x + rel.z * right.z,
                elevation: elevation,
                confidence: confidence,
                vertexCount: max(count, 1)
            ), members))
        }

        // ---- 4a. Edge: well-observed floor that ends inside the camera's view ------
        if hazardsEnabled, cfg.edgeDetectionEnabled, depthPoints.count >= cfg.edgeMinDepthPoints,
           let edge = detectEdge(cells: cells, nT: nT, nS: nS, p0: p0, heading: heading, right: right,
                                 ground: ground, depthView: depthView),
           !found.contains(where: { $0.hazard.kind == .drop && abs($0.hazard.distanceAhead - edge.distanceAhead) < 0.6 }) {
            found.append((edge, []))
        }

        // ---- 4b. Persistence: report a hazard only once it survives several scans --
        var next: [TrackedHazard] = []
        for (hazard, members) in found {
            let isEdge = hazard.vertexCount == 0
            var tracked = TrackedHazard(hazard: hazard, streak: 1, cells: members, origin: hazard.position, originUser: p0)
            if let m = trackedHazards.firstIndex(where: {
                $0.hazard.kind == hazard.kind && ($0.hazard.vertexCount == 0) == isEdge
                    && simd_length(($0.hazard.position - hazard.position).xz) <= cfg.hazardMatchRadius
            }) {
                let old = trackedHazards.remove(at: m)
                // An "edge" that walks along with the user is the depth map's range limit on a
                // dark floor, not a real edge: a real one stays put in the world.
                let userMoved = simd_length((p0 - old.originUser).xz)
                let edgeMoved = simd_length((hazard.position - old.origin).xz)
                let dragging = isEdge && userMoved >= 0.3 && edgeMoved > cfg.edgeDragTolerance * userMoved + 0.2
                if !dragging {
                    tracked.streak = old.streak + 1
                    tracked.hazard = hazard.withID(old.hazard.id)   // keep a stable id
                    tracked.origin = old.origin
                    tracked.originUser = old.originUser
                }
            }
            next.append(tracked)
        }
        trackedHazards = next
        let confirmed = next.filter {
            $0.streak >= ($0.hazard.vertexCount == 0 ? cfg.edgeConfirmFrames : cfg.hazardConfirmFrames)
        }
        let confirmedCells = Set(confirmed.flatMap(\.cells))
        let hazards = confirmed.map(\.hazard).sorted { $0.distanceAhead < $1.distanceAhead }

        // ---- 5. Red overlay triangles ----------------------------------------
        var overlay = HazardOverlayData()
        overlay.timestamp = timestamp
        if !candidates.isEmpty, !confirmedCells.isEmpty {
            var masks: [Int: [Bool]] = [:]
            for cand in candidates where confirmedCells.contains(cand.cell) {
                if masks[cand.chunkIndex] == nil {
                    masks[cand.chunkIndex] = [Bool](repeating: false, count: chunkList[cand.chunkIndex].world.count)
                }
                masks[cand.chunkIndex]![cand.vertex] = true
            }

            let lift = SIMD3<Float>(0, cfg.hazardOverlayLift, 0)
            var triangles = 0
            outer: for (ci, mask) in masks {
                let sc = chunkList[ci]
                let idx = sc.chunk.indices
                var remap = [Int32](repeating: -1, count: sc.world.count)
                var f = 0
                while f + 2 < idx.count {
                    defer { f += 3 }
                    let a = Int(idx[f]), b = Int(idx[f + 1]), c = Int(idx[f + 2])
                    guard a < mask.count, b < mask.count, c < mask.count else { continue }
                    let hits = (mask[a] ? 1 : 0) + (mask[b] ? 1 : 0) + (mask[c] ? 1 : 0)
                    if hits < 2 { continue }
                    for vi in [a, b, c] {
                        if remap[vi] < 0 {
                            remap[vi] = Int32(overlay.positions.count)
                            overlay.positions.append(sc.world[vi] + lift)
                        }
                        overlay.indices.append(UInt32(remap[vi]))
                    }
                    triangles += 1
                    if triangles >= cfg.maxOverlayTriangles { break outer }
                }
            }
        }

        // ---- 6. Occupancy map cells ---------------------------------------------
        var mapCells = [UInt8](repeating: 0, count: mapSize * mapSize)
        let minVertices = UInt16(cfg.mapMinVertices)
        for idx in 0..<mapCells.count {
            var cell = OccupancyMap.Cell.empty
            if mapObstacle[idx] >= minVertices {
                switch mapObstacleClass[idx] {
                case MeshClass.wall, MeshClass.door, MeshClass.window: cell = .wall
                case MeshClass.table, MeshClass.seat:                   cell = .furniture
                default:                                                cell = .obstacle
                }
            } else if mapFloor[idx] >= minVertices || mapLiveFloor[idx] >= minVertices {
                cell = .floor
            }
            var value = cell.rawValue
            if mapLive[idx] >= 2 {
                if cell == .empty || cell == .floor { value = OccupancyMap.Cell.obstacle.rawValue }
                value |= OccupancyMap.liveFlag
            }
            mapCells[idx] = value
        }
        let map = OccupancyMap(origin: mapOrigin, cellSize: cfg.mapCellSize, size: mapSize, cells: mapCells)

        // ---- 6b. Openings: doorways and gaps in the map ---------------------------
        let openings = detectOpenings(map: map, mapObstacleClass: mapObstacleClass, p0: p0,
                                      heading: heading, right: right, ground: ground)

        // ---- 7. Snapshot -------------------------------------------------------
        var snapshot = SceneSnapshot(
            timestamp: timestamp,
            cameraTransform: cameraTransform,
            cameraPosition: p0,
            heading: heading,
            groundHeight: ground,
            groundSource: groundSource,
            nearestObstacle: best,
            nearestForwardObstacle: bestFwd,
            sectorDistances: coarseSectors,
            fineSectorHits: sectorHits,
            map: map,
            tripHazards: hazards,
            walkingSpeed: walkingSpeed,
            meshAnchorCount: chunks.count,
            vertexCount: totalVertices
        )
        snapshot.openings = openings
        snapshot.nearestBodyObstacle = bodyHit
        snapshot.nearestOverheadObstacle = headHit
        snapshot.targetApproachSpeed = motion.approach
        snapshot.targetClosingSpeed = motion.closing
        snapshot.isTargetApproaching = motion.approaching
        snapshot.clearDistanceLeft = clearLeft
        snapshot.clearDistanceRight = clearRight
        snapshot.clearWidthAhead = clearLeft + clearRight
        snapshot.cameraHeight = p0.y - ground
        return AnalysisResult(snapshot: snapshot, overlay: overlay, evicted: evicted)
    }

    // MARK: Sonar smoothing

    /// Approaching readings take effect at once (a brand-new obstacle must be seen twice);
    /// receding or missing readings release at `obstacleReleaseRate` so one missed scan
    /// does not flicker.
    private func smooth(raw: ObstacleHit?, distance: inout Float, hit: inout ObstacleHit?,
                        streak: inout Int, dt: Float) {
        streak = raw == nil ? 0 : streak + 1
        if let raw, raw.horizontalDistance <= distance {
            if distance.isFinite || streak >= 2 {
                distance = raw.horizontalDistance
                hit = raw
            }
        } else if distance.isFinite {
            let receded = distance + config.obstacleReleaseRate * dt
            if let raw, raw.horizontalDistance <= receded {
                distance = raw.horizontalDistance
                hit = raw
            } else if receded >= config.obstacleMaxRange {
                distance = .infinity
                hit = nil
            } else {
                distance = receded
                if let old = hit {
                    hit = ObstacleHit(point: old.point, horizontalDistance: receded, bucket: old.bucket)
                }
            }
        }
    }

    // MARK: Forward-target motion

    /// Fits the target's position along the heading, in a frame that moves with the world
    /// rather than the user, over the last `targetHistoryWindow` seconds. The slope is the
    /// target's own velocity: a wall gives 0 however fast the user walks at it; a person
    /// walking at the user gives their walking speed.
    private func updateTargetMotion(raw: ObstacleHit?, heading: SIMD3<Float>, timestamp: TimeInterval)
        -> (approach: Float, closing: Float, approaching: Bool) {
        let cfg = config
        guard let raw else {
            resetTargetHistory()
            return (0, 0, false)
        }
        let distance = raw.horizontalDistance
        if let ref = targetHeadingRef, simd_dot(ref, heading) < cos(cfg.targetHeadingReset) {
            resetTargetHistory()
        }
        if let last = lastTargetDistance, abs(distance - last) > cfg.targetJumpReset {
            resetTargetHistory()
        }
        if targetHeadingRef == nil { targetHeadingRef = heading }
        lastTargetDistance = distance
        targetHistory.append(TargetSample(time: timestamp, along: distance + userAlong, distance: distance))
        targetHistory.removeAll { timestamp - $0.time > cfg.targetHistoryWindow }

        guard targetHistory.count >= cfg.targetMinSamples,
              let first = targetHistory.first, let last = targetHistory.last,
              last.time - first.time >= cfg.targetMinSpan else {
            approachStreak = 0
            return (0, 0, false)
        }

        // Least squares on (time, along) and (time, distance).
        let n = Float(targetHistory.count)
        var sumT: Float = 0, sumA: Float = 0, sumD: Float = 0, sumTT: Float = 0, sumTA: Float = 0, sumTD: Float = 0
        for s in targetHistory {
            let t = Float(s.time - first.time)
            sumT += t; sumA += s.along; sumD += s.distance
            sumTT += t * t; sumTA += t * s.along; sumTD += t * s.distance
        }
        let denom = n * sumTT - sumT * sumT
        guard denom > 1e-4 else { approachStreak = 0; return (0, 0, false) }
        let slopeAlong = (n * sumTA - sumT * sumA) / denom
        let slopeDistance = (n * sumTD - sumT * sumD) / denom
        let intercept = (sumA - slopeAlong * sumT) / n
        var worst: Float = 0
        for s in targetHistory {
            let t = Float(s.time - first.time)
            worst = max(worst, abs(s.along - (intercept + slopeAlong * t)))
        }
        guard worst <= cfg.targetMaxResidual else { approachStreak = 0; return (0, 0, false) }

        let approach = -slopeAlong
        let closing = -slopeDistance
        approachStreak = approach >= cfg.approachSpeedThreshold ? approachStreak + 1 : 0
        return (approach, closing, approachStreak >= 2)
    }

    // MARK: Edge detection

    /// A platform edge or stair-down where the floor simply ends: rows of the corridor hold
    /// well-observed floor (mesh or this frame's depth) right up to a line, and past that line,
    /// inside the part of the view the depth map is returning from, there is nothing at or
    /// near ground level and nothing standing there to hide it. Published as a `.drop` with
    /// `vertexCount == 0`; the lower floor's depth is used when the LiDAR sees it.
    private func detectEdge(cells: [Cell], nT: Int, nS: Int, p0: SIMD3<Float>, heading: SIMD3<Float>,
                            right: SIMD3<Float>, ground: Float, depthView: DepthView) -> TripHazard? {
        let cfg = config
        let needFloor = max(1, Int((cfg.edgeFloorFraction * Float(nS)).rounded(.up)))
        let needEmpty = max(1, Int((cfg.edgeEmptyFraction * Float(nS)).rounded(.up)))
        var floorRow = [Bool](repeating: false, count: nT)
        var emptyRow = [Bool](repeating: false, count: nT)
        var liveRow = [Int](repeating: 0, count: nT)
        for ti in 0..<nT {
            let t = cfg.pathNear + (Float(ti) + 0.5) * cfg.cellSize
            var floorCols = 0, emptyCols = 0
            for si in 0..<nS {
                let cell = cells[ti * nS + si]
                liveRow[ti] += cell.liveFloor
                if cell.meshNearGround >= cfg.minHazardVertices || cell.liveFloor >= cfg.edgeMinLiveFloor {
                    floorCols += 1
                    continue
                }
                guard cell.count - cell.dropCount == 0, cell.liveFloor == 0,
                      cell.obstacleCount == 0, cell.liveAbove == 0 else { continue }
                let s = -cfg.pathHalfWidth + (Float(si) + 0.5) * cfg.cellSize
                var centre = p0 + heading * t + right * s
                centre.y = ground
                if depthView.inView(centre) { emptyCols += 1 }
            }
            floorRow[ti] = floorCols >= needFloor
            emptyRow[ti] = emptyCols >= needEmpty
        }

        let minFloor = max(1, cfg.edgeMinFloorRows)
        let minEmpty = max(1, cfg.edgeMinEmptyRows)
        guard nT > minFloor + minEmpty - 1 else { return nil }
        for ti in (minFloor - 1)..<(nT - minEmpty) {
            let edgeT = cfg.pathNear + Float(ti + 1) * cfg.cellSize
            guard edgeT <= cfg.edgeMaxDistance else { break }
            var ok = liveRow[ti] >= cfg.edgeMinLiveFloor * max(1, nS / 2)   // the camera sees floor right up to the line
            for k in 0..<minFloor where !floorRow[ti - k] { ok = false }
            for k in 0..<minEmpty where !emptyRow[ti + 1 + k] { ok = false }
            guard ok else { continue }

            var seenBelow: Float = .infinity
            for row in (ti + 1)..<min(nT, ti + 1 + minEmpty) {
                for si in 0..<nS {
                    let cell = cells[row * nS + si]
                    if cell.liveBelow > 0 { seenBelow = min(seenBelow, cell.liveMinDy) }
                    if cell.dropCount > 0 { seenBelow = min(seenBelow, cell.minDy) }
                }
            }
            var position = p0 + heading * edgeT
            position.y = ground
            return TripHazard(
                id: Self.hazardID(position: position, kind: .drop),
                kind: .drop,
                position: position,
                distanceAhead: edgeT,
                lateralOffset: 0,
                elevation: seenBelow.isFinite ? seenBelow : -cfg.edgeAssumedDepth,
                confidence: seenBelow.isFinite ? 0.75 : 0.5,
                vertexCount: 0
            )
        }
        return nil
    }

    // MARK: Openings

    /// Casts rays through a coarsened copy of the occupancy map and looks for runs of rays
    /// that reach well past the surfaces on either side of them. The two flanking hits must
    /// be at about the same distance (the same wall), the chord between them between
    /// `openingMinWidth` and `openingMaxWidth`, and, by default, floor must have been seen
    /// through the gap so a patch of wall the scanner has not reached yet is not a door.
    private func detectOpenings(map: OccupancyMap, mapObstacleClass: [UInt8], p0: SIMD3<Float>,
                                heading: SIMD3<Float>, right: SIMD3<Float>, ground: Float) -> [Opening] {
        let cfg = config
        let cc = max(1, cfg.openingCoarseCells)
        let size = max(1, map.size / cc)
        let coarseCell = map.cellSize * Float(cc)
        var blocked = [Bool](repeating: false, count: size * size)
        var wallish = [Bool](repeating: false, count: size * size)
        var floorCells = [Bool](repeating: false, count: size * size)
        for row in 0..<(size * cc) {
            let cr = row / cc
            for column in 0..<(size * cc) {
                let fine = row * map.size + column
                let kind = OccupancyMap.Cell(rawValue: map.cells[fine] & ~OccupancyMap.liveFlag) ?? .empty
                let idx = cr * size + column / cc
                switch kind {
                case .wall:
                    blocked[idx] = true
                    wallish[idx] = true
                case .furniture, .obstacle:
                    blocked[idx] = true
                    switch mapObstacleClass[fine] {
                    case MeshClass.wall, MeshClass.door, MeshClass.window: wallish[idx] = true
                    default: break
                    }
                case .floor:
                    floorCells[idx] = true
                case .empty:
                    break
                }
            }
        }
        func coarseIndex(_ v: SIMD3<Float>) -> Int? {
            let column = Int((v.x - map.origin.x) / coarseCell)
            let row = Int((v.z - map.origin.y) / coarseCell)
            guard column >= 0, column < size, row >= 0, row < size else { return nil }
            return row * size + column
        }

        // Ray march.
        let step = max(0.5, cfg.openingRayStepDegrees) * .pi / 180
        let nRays = Int((2 * .pi / step).rounded())
        let maxR = cfg.mapRadius - coarseCell
        let march = coarseCell / 2
        var hitDist = [Float](repeating: .infinity, count: nRays)
        var hitWall = [Bool](repeating: false, count: nRays)
        var hitPoint = [SIMD3<Float>](repeating: .zero, count: nRays)
        var dirs = [SIMD3<Float>](repeating: .zero, count: nRays)
        for i in 0..<nRays {
            let a = Float(i) * step
            let dir = heading * cos(a) + right * sin(a)
            dirs[i] = dir
            var r: Float = 0.3
            while r <= maxR {
                let q = p0 + dir * r
                if let idx = coarseIndex(q), blocked[idx] {
                    hitDist[i] = r
                    hitWall[i] = wallish[idx]
                    hitPoint[i] = q
                    break
                }
                r += march
            }
        }
        func floorBeyond(ray i: Int, from: Float) -> Bool {
            var r = from + march
            while r <= min(maxR, from + cfg.openingDepth) {
                if let idx = coarseIndex(p0 + dirs[i] * r), floorCells[idx] { return true }
                r += march
            }
            return false
        }

        // Gap search: left flank L, deep rays, right flank R.
        var foundOpenings: [Opening] = []
        var i = 0
        var scanned = 0
        while scanned < nRays {
            defer { scanned += 1 }
            let L = i % nRays
            i += 1
            let dL = hitDist[L]
            guard dL.isFinite, dL >= cfg.openingMinDistance, dL <= cfg.openingMaxDistance else { continue }
            var k = (L + 1) % nRays
            var gapRays = 0
            while k != L, hitDist[k] >= dL + cfg.openingDepth {
                gapRays += 1
                k = (k + 1) % nRays
            }
            guard gapRays > 0, k != L else { continue }
            let R = k
            let dR = hitDist[R]
            guard dR.isFinite, dR <= cfg.openingMaxDistance, abs(dR - dL) <= cfg.openingFlankTolerance else { continue }
            let chord = (hitPoint[R] - hitPoint[L]).xz
            let width = simd_length(chord)
            guard width >= cfg.openingMinWidth, width <= cfg.openingMaxWidth else { continue }

            // Two walls running away from the user (a corridor) also leave a run of deep rays
            // between two flanks, but there the chord crosses both walls at a right angle,
            // whereas a doorway's jambs lie along the wall the chord runs parallel to.
            if cfg.openingRejectParallelWalls {
                let chordDir = chord / width
                func grazed(_ a: Int, _ b: Int) -> Bool {
                    guard hitDist[a].isFinite, hitDist[b].isFinite else { return false }
                    let wall = (hitPoint[a] - hitPoint[b]).xz
                    let len = simd_length(wall)
                    guard len > 0.05 else { return false }
                    return abs(simd_dot(wall / len, chordDir)) < 0.5
                }
                if grazed(L, (L + nRays - 2) % nRays), grazed((R + 2) % nRays, R) { continue }
            }

            var floorRays = 0
            let flank = min(dL, dR)
            var g = (L + 1) % nRays
            while g != R {
                if floorBeyond(ray: g, from: flank) { floorRays += 1 }
                g = (g + 1) % nRays
            }
            if cfg.openingNeedsFloorBeyond, floorRays * 2 < gapRays { i = R; scanned += gapRays; continue }

            var centre = (hitPoint[L] + hitPoint[R]) / 2
            centre.y = ground
            let rel = centre - p0
            let t = rel.x * heading.x + rel.z * heading.z
            let s = rel.x * right.x + rel.z * right.z
            let confidence = min(1, 0.4 + 0.15 * Float(gapRays)) * (floorRays * 2 >= gapRays ? 1 : 0.6)
            foundOpenings.append(Opening(
                id: Self.hazardID(position: centre, kind: nil),
                position: centre,
                bearing: atan2(s, t),
                distance: (t * t + s * s).squareRoot(),
                width: width,
                isDoorway: hitWall[L] && hitWall[R],
                confidence: confidence
            ))
            i = R                         // the right flank is the next left-flank candidate
            scanned += gapRays
        }

        // Persistence: match on world position, tolerate a few missed frames.
        var next: [TrackedOpening] = []
        var matched = [Bool](repeating: false, count: trackedOpenings.count)
        for opening in foundOpenings {
            var tracked = TrackedOpening(opening: opening, streak: 1, misses: 0)
            if let m = trackedOpenings.indices.first(where: {
                !matched[$0] && simd_length((trackedOpenings[$0].opening.position - opening.position).xz) <= cfg.openingMatchRadius
            }) {
                matched[m] = true
                let old = trackedOpenings[m]
                tracked.streak = old.streak + 1
                tracked.opening = Opening(id: old.opening.id, position: opening.position, bearing: opening.bearing,
                                          distance: opening.distance, width: opening.width,
                                          isDoorway: opening.isDoorway || old.opening.isDoorway,
                                          confidence: opening.confidence)
            }
            next.append(tracked)
        }
        for (m, old) in trackedOpenings.enumerated() where !matched[m] && old.misses < cfg.openingMissTolerance {
            var kept = old
            kept.misses += 1
            next.append(kept)
        }
        trackedOpenings = next
        return next
            .filter { $0.misses == 0 && $0.streak >= cfg.openingConfirmFrames }
            .map(\.opening)
            .sorted { $0.distance < $1.distance }
            .prefix(8)
            .map { $0 }
    }

    // MARK: Ground estimation

    /// Combines the largest floor `ARPlaneAnchor` under the user with the median height of
    /// nearby floor-classified mesh vertices. The plane is the "established" ground; the mesh
    /// median protects against a stale plane from another level (ramps, split levels). With
    /// no classified floor at all (outdoors, a fresh scan) it falls back to the dominant height
    /// of all mesh under the phone, cross-checked against any large unclassified plane.
    private func estimateGround(cameraPosition p0: SIMD3<Float>) -> (Float, GroundSource) {
        let cfg = config

        // (a) Plane anchors.
        var planeY: Float?
        var bestArea: Float = 0
        for plane in planes.values where plane.isFloor {
            let c = plane.worldCenter
            let reach = max(plane.width, plane.height) * 0.5 + 1.0
            if simd_length((c - p0).xz) <= reach, plane.area > bestArea {
                bestArea = plane.area
                planeY = c.y
            }
        }

        // (b) Mesh median of floor vertices within `groundSampleRadius`, well below the phone.
        var samples: [Float] = []
        samples.reserveCapacity(min(cfg.maxGroundSamples, 4096))
        let r2 = cfg.groundSampleRadius * cfg.groundSampleRadius
        let yLo = p0.y - 2.5
        let yHi = p0.y - 0.3
        sampling: for sc in chunks.values {
            if sc.aabbMax.y < yLo || sc.aabbMin.y > yHi { continue }
            if Self.horizontalDistance(from: p0, toBox: sc.aabbMin, sc.aabbMax) > cfg.groundSampleRadius { continue }
            for i in 0..<sc.world.count where sc.vertexClasses[i] == MeshClass.floor {
                let v = sc.world[i]
                if v.y < yLo || v.y > yHi { continue }
                let dx = v.x - p0.x, dz = v.z - p0.z
                if dx * dx + dz * dz > r2 { continue }
                samples.append(v.y)
                if samples.count >= cfg.maxGroundSamples { break sampling }
            }
        }
        var meshY: Float?
        if samples.count >= cfg.minGroundSamples {
            samples.sort()
            meshY = samples[samples.count / 2]
        }

        switch (planeY, meshY) {
        case let (p?, m?):
            return abs(p - m) <= cfg.planeMeshAgreement ? (p, .planeAnchor) : (m, .meshMedian)
        case let (p?, nil):
            return (p, .planeAnchor)
        case let (nil, m?):
            return (m, .meshMedian)
        case (nil, nil):
            if let fallback = fallbackGround(cameraPosition: p0) { return fallback }
            if let last = lastGround, abs(last - (p0.y - cfg.assumedCameraHeight)) < 1.0 {
                return (last, .meshMedian)
            }
            return (p0.y - cfg.assumedCameraHeight, .assumed)
        }
    }

    /// Classification-free ground: the most populated height band of all mesh vertices
    /// within `groundFallbackRadius`, 0.6-2.5 m below the phone (the surface under the user's
    /// feet dominates that volume), cross-checked against a large unclassified horizontal plane.
    private func fallbackGround(cameraPosition p0: SIMD3<Float>) -> (Float, GroundSource)? {
        let cfg = config

        // (c) Large unclassified horizontal plane well below the phone.
        var planeY: Float?
        var bestArea: Float = 0
        for plane in planes.values where !plane.isFloor {
            let c = plane.worldCenter
            let drop = p0.y - c.y
            guard drop >= cfg.unclassifiedPlaneMinDrop, drop <= cfg.groundFallbackMaxDrop,
                  plane.area >= cfg.unclassifiedPlaneMinArea else { continue }
            let reach = max(plane.width, plane.height) * 0.5 + 1.0
            if simd_length((c - p0).xz) <= reach, plane.area > bestArea {
                bestArea = plane.area
                planeY = c.y
            }
        }

        // (d) Height mode of every mesh vertex under the phone.
        let yLo = p0.y - cfg.groundFallbackMaxDrop
        let yHi = p0.y - cfg.groundFallbackMinDrop
        let bin = max(0.005, cfg.groundFallbackBin)
        let nBins = Int(((yHi - yLo) / bin).rounded(.up)) + 1
        var hist = [Int](repeating: 0, count: nBins)
        var total = 0
        let r2 = cfg.groundFallbackRadius * cfg.groundFallbackRadius
        for sc in chunks.values {
            if sc.aabbMax.y < yLo || sc.aabbMin.y > yHi { continue }
            if Self.horizontalDistance(from: p0, toBox: sc.aabbMin, sc.aabbMax) > cfg.groundFallbackRadius { continue }
            sc.world.withUnsafeBufferPointer { w in
                for v in w {
                    if v.y < yLo || v.y > yHi { continue }
                    let dx = v.x - p0.x, dz = v.z - p0.z
                    if dx * dx + dz * dz > r2 { continue }
                    hist[min(nBins - 1, Int((v.y - yLo) / bin))] += 1
                    total += 1
                }
            }
        }
        var modeY: Float?
        if total >= cfg.minGroundSamples {
            var bestCount = 0
            var bestBin = 0
            for b in 0..<nBins {
                var c = 0
                for k in max(0, b - 2)...min(nBins - 1, b + 2) { c += hist[k] }
                if c > bestCount { bestCount = c; bestBin = b }
            }
            if bestCount >= cfg.minGroundSamples, Float(bestCount) >= cfg.groundFallbackMinShare * Float(total) {
                var weighted: Float = 0
                for k in max(0, bestBin - 2)...min(nBins - 1, bestBin + 2) {
                    weighted += Float(hist[k]) * (yLo + (Float(k) + 0.5) * bin)
                }
                modeY = weighted / Float(bestCount)
            }
        }

        switch (planeY, modeY) {
        case let (p?, m?):
            return abs(p - m) <= cfg.planeMeshAgreement ? (p, .planeAnchor) : (m, .meshMedian)
        case let (p?, nil):
            return (p, .planeAnchor)
        case let (nil, m?):
            return (m, .meshMedian)
        case (nil, nil):
            return nil
        }
    }

    // MARK: Geometry helpers

    /// Stable id for something that stays put: rounded world XZ plus kind.
    private static func hazardID(position: SIMD3<Float>, kind: TripHazardKind?) -> Int {
        var hasher = Hasher()
        hasher.combine(Int((position.x / 0.25).rounded()))
        hasher.combine(Int((position.z / 0.25).rounded()))
        hasher.combine(kind?.rawValue ?? -1)
        return hasher.finalize()
    }

    private static func overlaps(_ aMin: SIMD3<Float>, _ aMax: SIMD3<Float>,
                                 _ bMin: SIMD3<Float>, _ bMax: SIMD3<Float>) -> Bool {
        aMin.x <= bMax.x && aMax.x >= bMin.x &&
        aMin.y <= bMax.y && aMax.y >= bMin.y &&
        aMin.z <= bMax.z && aMax.z >= bMin.z
    }

    /// Horizontal distance from a point to an axis-aligned box (0 when inside its XZ footprint).
    private static func horizontalDistance(from p: SIMD3<Float>, toBox bMin: SIMD3<Float>, _ bMax: SIMD3<Float>) -> Float {
        let dx = max(bMin.x - p.x, 0, p.x - bMax.x)
        let dz = max(bMin.z - p.z, 0, p.z - bMax.z)
        return (dx * dx + dz * dz).squareRoot()
    }
}
