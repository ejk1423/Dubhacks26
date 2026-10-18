//
//  ARLiDARManager.swift
//  Echo
//
//  Owns the ARView + ARSession, configures LiDAR scene reconstruction, copies
//  mesh anchors into Sendable chunks, and schedules the background analysis
//  (`MeshGeometryStore`) and wireframe rendering (`WireframeRenderer`).
//
//  Threading model (Swift 6, default MainActor isolation):
//    * ARKit delivers delegate callbacks on the main queue (`delegateQueue = .main`),
//      so this class and the renderer are main-actor isolated.
//    * Only cheap buffer copies happen on the main thread; all geometry math runs
//      inside the `MeshGeometryStore` actor.
//    * Consumers (spatial audio, vision) subscribe through `onFrame` / `onSnapshot`,
//      both invoked on the main actor.
//

import ARKit
import RealityKit
import Observation
import UIKit
import os

@Observable
final class ARLiDARManager: NSObject {

    // MARK: Observable state (read by the HUD)

    private(set) var status: PerceptionStatus = .idle
    private(set) var capabilities = DeviceCapabilities()
    private(set) var snapshot: SceneSnapshot?
    private(set) var meshAnchorCount = 0
    private(set) var cameraFeedMode: CameraFeedMode = .full

    /// Convenience accessors for the HUD.
    var nearestObstacleDistance: Float? { snapshot?.nearestObstacle?.horizontalDistance }
    var tripHazards: [TripHazard] { snapshot?.tripHazards ?? [] }

    // MARK: Dependencies (not observed)

    @ObservationIgnored let arView: ARView
    @ObservationIgnored let config: PerceptionConfig
    @ObservationIgnored private let store: MeshGeometryStore
    @ObservationIgnored private let renderer: WireframeRenderer
    @ObservationIgnored private let logger = Logger(subsystem: "echo.perception", category: "ARLiDARManager")

    // MARK: Hooks for other subsystems (invoked on the main actor)

    /// Every ARFrame (60 Hz). The vision tracker samples `capturedImage` / `sceneDepth` here.
    @ObservationIgnored var onFrame: ((ARFrame) -> Void)?
    /// Every `config.analysisInterval` (10 Hz). The spatial audio engine places its sources here.
    @ObservationIgnored var onSnapshot: ((SceneSnapshot) -> Void)?

    // MARK: Scheduling

    @ObservationIgnored private var pendingAnchors: [UUID: ARMeshAnchor] = [:]
    @ObservationIgnored private var pendingOrder: [UUID] = []
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var lastAnalysisTime: TimeInterval = 0
    @ObservationIgnored private var analysisInFlight = false
    @ObservationIgnored private var upsertsInFlight = 0
    @ObservationIgnored private var isRunning = false

    // MARK: Init

    init(config: PerceptionConfig = PerceptionConfig()) {
        self.config = config
        self.arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        self.store = MeshGeometryStore(config: config)
        self.renderer = WireframeRenderer(config: config)
        super.init()

        capabilities = Self.probeCapabilities()
        configureView()
    }

    // MARK: Lifecycle

    /// Starts (or restarts) world tracking with LiDAR mesh reconstruction.
    func start() {
        guard !isRunning else { return }   // a repeated onAppear must not wipe the map
        guard capabilities.worldTracking else {
            status = .unsupported("ARKit world tracking is not available on this device.")
            return
        }
        status = .starting
        run(options: [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction])
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true   // safety aid: never let the screen sleep mid-walk
        status = capabilities.hasLiDAR
            ? .running
            : .limited("No LiDAR scanner: wireframe and hazard detection are unavailable.")
    }

    func pause() {
        arView.session.pause()
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        status = .idle
    }

    /// Drops every cached mesh and restarts tracking from a fresh origin.
    func reset() {
        clearScene()
        if isRunning {
            run(options: [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction])
        }
    }

    func setCameraFeed(_ mode: CameraFeedMode) {
        cameraFeedMode = mode
        applyBackground()
    }

    // MARK: Configuration

    private func configureView() {
        arView.automaticallyConfigureSession = false
        // Everything that costs GPU time and adds nothing to a wireframe.
        arView.renderOptions = [
            .disableMotionBlur, .disableDepthOfField, .disableHDR, .disableCameraGrain,
            .disableFaceMesh, .disablePersonOcclusion, .disableGroundingShadows,
            .disableAREnvironmentLighting,
        ]
        // We draw the mesh ourselves; RealityKit's own occlusion would z-fight with it.
        arView.environment.sceneUnderstanding.options = []
        arView.session.delegateQueue = .main
        arView.session.delegate = self
        renderer.attach(to: arView)
        applyBackground()
    }

    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity           // +Y is up, so mesh Y == height
        configuration.planeDetection = [.horizontal]      // floor planes = established ground
        configuration.environmentTexturing = .none
        configuration.isLightEstimationEnabled = false

        if capabilities.meshClassification {
            configuration.sceneReconstruction = .meshWithClassification
        } else if capabilities.meshReconstruction {
            configuration.sceneReconstruction = .mesh
        }

        // No `.sceneDepth` frame semantics until something consumes the depth map: it costs
        // GPU time and heat, and thermal pressure interrupts the session.
        return configuration
    }

    private func run(options: ARSession.RunOptions) {
        arView.session.run(makeConfiguration(), options: options)
    }

    private func applyBackground() {
        switch cameraFeedMode {
        case .hidden:
            arView.environment.background = .color(.black)
        case .dimmed(let ev):
            arView.environment.background = .cameraFeed(exposureCompensation: ev)
        case .full:
            arView.environment.background = .cameraFeed()
        }
    }

    private static func probeCapabilities() -> DeviceCapabilities {
        var caps = DeviceCapabilities()
        caps.worldTracking = ARWorldTrackingConfiguration.isSupported
        caps.meshReconstruction = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        caps.meshClassification = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
        caps.sceneDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        caps.planeClassification = ARPlaneAnchor.isClassificationSupported
        return caps
    }

    private func clearScene() {
        pendingAnchors.removeAll()
        pendingOrder.removeAll()
        renderer.removeAll()
        snapshot = nil
        meshAnchorCount = 0
        analysisInFlight = false
        Task { await store.removeAll() }
    }

    // MARK: Anchor ingestion

    private func ingest(_ anchors: [ARAnchor]) {
        for anchor in anchors {
            if let mesh = anchor as? ARMeshAnchor {
                // Coalesce: keep only the newest version of each anchor until it is drained.
                if pendingAnchors.updateValue(mesh, forKey: mesh.identifier) == nil {
                    pendingOrder.append(mesh.identifier)
                }
            } else if let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal {
                let info = PlaneInfo(
                    anchorID: plane.identifier,
                    transform: plane.transform,
                    center: plane.center,
                    width: plane.planeExtent.width,
                    height: plane.planeExtent.height,
                    isFloor: Self.isFloor(plane)
                )
                Task { await store.upsertPlane(info) }
            }
        }
    }

    private func dequeue(_ anchorID: UUID) {
        if pendingAnchors.removeValue(forKey: anchorID) != nil {
            pendingOrder.removeAll { $0 == anchorID }
        }
    }

    /// Converts at most `config.maxAnchorUpdatesPerFrame` queued anchors per frame so a
    /// burst of mesh refinements never stalls the render loop. Anchors stay coalesced in
    /// `pendingAnchors` while `config.maxUpsertsInFlight` chunks are already with the store,
    /// so a slow store applies backpressure instead of piling up chunk copies in memory.
    private func drainPendingAnchors(timestamp: TimeInterval) {
        var processed = 0
        while processed < config.maxAnchorUpdatesPerFrame,
              upsertsInFlight < config.maxUpsertsInFlight,
              !pendingOrder.isEmpty {
            let id = pendingOrder.removeFirst()
            guard let anchor = pendingAnchors.removeValue(forKey: id) else { continue }
            sequence += 1
            guard let chunk = Self.makeChunk(from: anchor, sequence: sequence, timestamp: timestamp) else { continue }
            processed += 1
            upsertsInFlight += 1
            Task {
                let data = await store.upsert(chunk)
                upsertsInFlight -= 1
                renderer.apply(data)
            }
        }
    }

    private func scheduleAnalysisIfNeeded(frame: ARFrame) {
        guard !analysisInFlight,
              frame.timestamp - lastAnalysisTime >= config.analysisInterval else { return }
        analysisInFlight = true
        lastAnalysisTime = frame.timestamp
        let transform = frame.camera.transform
        let timestamp = frame.timestamp
        Task {
            let result = await store.analyze(cameraTransform: transform, timestamp: timestamp)
            snapshot = result.snapshot
            meshAnchorCount = result.snapshot.meshAnchorCount
            for id in result.evicted { renderer.remove(anchorID: id) }
            renderer.updateHazardOverlay(result.overlay)
            renderer.cull(around: result.snapshot.cameraPosition, radius: config.renderRadius)
            onSnapshot?(result.snapshot)
            analysisInFlight = false
        }
    }

    // MARK: Geometry extraction

    /// Copies an ARMeshAnchor out of its Metal buffers into a `Sendable` chunk.
    /// Vertices are packed `float3` (12-byte stride), faces are 32- or 16-bit triangle
    /// indices, classification is one `UInt8` per face.
    private static func makeChunk(from anchor: ARMeshAnchor, sequence: UInt64, timestamp: TimeInterval) -> MeshChunk? {
        let geometry = anchor.geometry
        let vertexSource = geometry.vertices
        let faces = geometry.faces
        let vertexCount = vertexSource.count
        let faceCount = faces.count
        guard vertexCount > 0, faceCount > 0, faces.indexCountPerPrimitive == 3 else { return nil }

        var positions = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        let vertexBase = vertexSource.buffer.contents().advanced(by: vertexSource.offset)
        let vertexStride = vertexSource.stride
        positions.withUnsafeMutableBufferPointer { out in
            for i in 0..<vertexCount {
                let p = vertexBase.advanced(by: i * vertexStride).assumingMemoryBound(to: Float.self)
                out[i] = SIMD3(p[0], p[1], p[2])
            }
        }

        let indexCount = faceCount * 3
        var indices = [UInt32](repeating: 0, count: indexCount)
        let faceBase = faces.buffer.contents()
        switch faces.bytesPerIndex {
        case 4:
            indices.withUnsafeMutableBytes { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: faceBase, count: indexCount * 4))
            }
        case 2:
            let src = faceBase.assumingMemoryBound(to: UInt16.self)
            for i in 0..<indexCount { indices[i] = UInt32(src[i]) }
        default:
            return nil
        }

        var classes = [UInt8](repeating: MeshClass.none, count: faceCount)
        if let classification = geometry.classification, classification.count == faceCount {
            let classBase = classification.buffer.contents().advanced(by: classification.offset)
            let classStride = classification.stride
            for i in 0..<faceCount {
                classes[i] = classBase.advanced(by: i * classStride).load(as: UInt8.self)
            }
        }

        return MeshChunk(
            anchorID: anchor.identifier,
            sequence: sequence,
            transform: anchor.transform,
            localPositions: positions,
            indices: indices,
            faceClasses: classes,
            timestamp: timestamp
        )
    }

    private static func isFloor(_ plane: ARPlaneAnchor) -> Bool {
        if case .floor = plane.classification { return true }
        return false
    }

    private static func describe(_ reason: ARCamera.TrackingState.Reason) -> String {
        switch reason {
        case .initializing:         return "Initializing tracking. Hold still for a moment."
        case .excessiveMotion:      return "Moving too fast. Slow down."
        case .insufficientFeatures: return "Not enough visual detail. Point the phone at textured surfaces."
        case .relocalizing:         return "Relocalizing."
        @unknown default:           return "Tracking limited."
        }
    }
}

// MARK: - ARSessionDelegate

// `@preconcurrency`: ARKit calls these on `delegateQueue` (= main), so the main-actor
// isolation is enforced at runtime rather than by the type checker.
extension ARLiDARManager: @preconcurrency ARSessionDelegate {

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        ingest(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        ingest(anchors)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            let id = anchor.identifier
            if anchor is ARMeshAnchor {
                dequeue(id)
                renderer.remove(anchorID: id)
                Task { await store.remove(anchorID: id) }
            } else if anchor is ARPlaneAnchor {
                Task { await store.removePlane(anchorID: id) }
            }
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        drainPendingAnchors(timestamp: frame.timestamp)
        onFrame?(frame)
        scheduleAnalysisIfNeeded(frame: frame)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            status = capabilities.hasLiDAR
                ? .running
                : .limited("No LiDAR scanner: wireframe and hazard detection are unavailable.")
        case .notAvailable:
            status = .limited("Tracking unavailable.")
        case .limited(let reason):
            status = .limited(Self.describe(reason))
        }
    }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        logger.error("AR session failed: \(error.localizedDescription, privacy: .public)")
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        status = .failed(error.localizedDescription)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        status = .interrupted
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        // Keep the map: ARKit relocalizes against it, and tracking state updates `status`.
        // Wiping it here made the whole scene vanish after every notification banner.
        status = .starting
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
    }
}
