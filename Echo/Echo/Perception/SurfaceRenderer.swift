//
//  SurfaceRenderer.swift
//  Echo
//
//  Turns `WireframeMeshData` into RealityKit entities: one `ModelEntity` per
//  ARMeshAnchor drawn as translucent, class-tinted surfaces with a world-space grid
//  that fade in as the user approaches (see `EchoSurface.metal`), plus a red overlay
//  entity for the current trip hazards.
//
//  The surface shader reads the camera position and time from RealityKit's uniforms,
//  so the look updates every frame with no CPU work here. If the shader cannot be
//  loaded, plain translucent unlit fills are used instead.
//

import Foundation
import Metal
import RealityKit
import UIKit
import simd
import os

@MainActor
final class SurfaceRenderer {

    // MARK: Palette

    enum Palette {
        static let floor     = UIColor(red: 0.10, green: 0.45, blue: 0.28, alpha: 1)   // dim green: walkable, recedes
        static let wall      = UIColor(red: 0.00, green: 0.90, blue: 1.00, alpha: 1)   // cyan
        static let ceiling   = UIColor(red: 0.35, green: 0.45, blue: 1.00, alpha: 1)   // (not drawn)
        static let furniture = UIColor(red: 1.00, green: 0.68, blue: 0.20, alpha: 1)   // amber: obstacles
        static let unknown   = UIColor(red: 0.45, green: 0.50, blue: 0.60, alpha: 1)   // grey
        static let hazard    = UIColor(red: 1.00, green: 0.16, blue: 0.16, alpha: 1)   // red

        static func color(for bucket: SurfaceBucket) -> UIColor {
            switch bucket {
            case .floor:     return floor
            case .wall:      return wall
            case .ceiling:   return ceiling
            case .furniture: return furniture
            case .unknown:   return unknown
            }
        }
    }

    // MARK: State

    /// World-locked root for every mesh entity. Add it to `arView.scene`.
    let root: AnchorEntity

    private let config: PerceptionConfig
    private let logger = Logger(subsystem: "echo.perception", category: "SurfaceRenderer")

    private var meshEntities: [UUID: ModelEntity] = [:]
    private var sequences: [UUID: UInt64] = [:]
    private var centers: [UUID: SIMD3<Float>] = [:]
    private var bucketMaterials: [SurfaceBucket: any Material] = [:]
    private var bucketsByEntity: [UUID: [SurfaceBucket]] = [:]
    private var highlightTarget: SIMD4<Float> = .zero

    private let hazardFill: ModelEntity
    private let hazardFillMaterial: UnlitMaterial

    // MARK: Init

    init(config: PerceptionConfig) {
        self.config = config

        root = AnchorEntity(world: matrix_identity_float4x4)
        root.name = "echo.surface.root"

        let shader = Self.loadSurfaceShader(logger: logger)
        for bucket in SurfaceBucket.allCases {
            bucketMaterials[bucket] = Self.makeSurfaceMaterial(Palette.color(for: bucket), shader: shader)
        }

        hazardFillMaterial = Self.makeFlatMaterial(Palette.hazard, opacity: 0.35)
        hazardFill = ModelEntity()
        hazardFill.name = "echo.hazard.fill"
        hazardFill.isEnabled = false
        root.addChild(hazardFill)
    }

    func attach(to arView: ARView) {
        if root.scene == nil {
            arView.scene.addAnchor(root)
        }
    }

    // MARK: Mesh chunks

    /// Builds or replaces the entity for one mesh anchor. Out-of-order results
    /// (an older `sequence` arriving after a newer one) are ignored.
    func apply(_ data: WireframeMeshData) {
        if let last = sequences[data.anchorID], last > data.sequence { return }
        sequences[data.anchorID] = data.sequence
        centers[data.anchorID] = data.center

        guard !data.positions.isEmpty, data.indices.count >= 3, !data.buckets.isEmpty else {
            remove(anchorID: data.anchorID)
            return
        }

        var descriptor = MeshDescriptor(name: "mesh-\(data.anchorID.uuidString)")
        descriptor.positions = MeshBuffers.Positions(data.positions)
        descriptor.primitives = .triangles(data.indices)
        descriptor.materials = .perFace(data.faceMaterials)

        let mesh: MeshResource
        do {
            mesh = try MeshResource.generate(from: [descriptor])
        } catch {
            logger.error("Mesh generation failed for \(data.anchorID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        let materials: [any Material] = data.buckets.compactMap { bucketMaterials[$0] }

        let entity: ModelEntity
        if let existing = meshEntities[data.anchorID] {
            entity = existing
        } else {
            entity = ModelEntity()
            entity.name = "echo.mesh.\(data.anchorID.uuidString)"
            root.addChild(entity)
            meshEntities[data.anchorID] = entity
        }
        entity.model = ModelComponent(mesh: mesh, materials: materials)
        bucketsByEntity[data.anchorID] = data.buckets
        entity.transform = Transform(matrix: data.transform)
    }

    func remove(anchorID: UUID) {
        if let entity = meshEntities.removeValue(forKey: anchorID) {
            entity.removeFromParent()
        }
        sequences[anchorID] = nil
        centers[anchorID] = nil
        bucketsByEntity[anchorID] = nil
    }

    func removeAll() {
        for entity in meshEntities.values { entity.removeFromParent() }
        meshEntities.removeAll()
        sequences.removeAll()
        centers.removeAll()
        bucketsByEntity.removeAll()
        hazardFill.isEnabled = false
    }

    /// Hides chunks far from the user so a long walk does not accumulate draw calls.
    /// (The shader has already faded them out by then.)
    /// Lights up the surface around `point` (world space) in red: the obstacle the beeps
    /// are about. `radius` 0 or nil clears it. Materials are shared per bucket, so one
    /// parameter change and a re-assignment per entity updates the whole scene.
    func highlight(point: SIMD3<Float>?, radius: Float) {
        let target = point.map { SIMD4($0.x, $0.y, $0.z, radius) } ?? .zero
        guard target != highlightTarget else { return }
        highlightTarget = target
        for bucket in SurfaceBucket.allCases {
            guard var material = bucketMaterials[bucket] as? CustomMaterial else { continue }
            material.custom.value = target
            bucketMaterials[bucket] = material
        }
        for (id, entity) in meshEntities {
            guard let buckets = bucketsByEntity[id] else { continue }
            entity.model?.materials = buckets.compactMap { bucketMaterials[$0] }
        }
    }

    func cull(around cameraPosition: SIMD3<Float>, radius: Float) {
        let limit = radius + 2.0   // chunks are ~1-2 m wide
        for (id, entity) in meshEntities {
            let center = centers[id] ?? entity.transform.translation
            let shouldShow = simd_distance(center, cameraPosition) <= limit
            if entity.isEnabled != shouldShow { entity.isEnabled = shouldShow }
        }
    }

    // MARK: Hazard overlay

    /// Replaces the red overlay with the current hazard triangles (world space).
    func updateHazardOverlay(_ overlay: HazardOverlayData) {
        guard !overlay.isEmpty, overlay.positions.count >= 3 else {
            hazardFill.isEnabled = false
            return
        }

        var descriptor = MeshDescriptor(name: "hazard-overlay")
        descriptor.positions = MeshBuffers.Positions(overlay.positions)
        descriptor.primitives = .triangles(overlay.indices)
        descriptor.materials = .allFaces(0)

        do {
            let mesh = try MeshResource.generate(from: [descriptor])
            hazardFill.model = ModelComponent(mesh: mesh, materials: [hazardFillMaterial])
            hazardFill.isEnabled = true
        } catch {
            logger.error("Hazard overlay generation failed: \(error.localizedDescription, privacy: .public)")
            hazardFill.isEnabled = false
        }
    }

    // MARK: Materials

    private static func loadSurfaceShader(logger: Logger) -> CustomMaterial.SurfaceShader? {
        guard let device = MTLCreateSystemDefaultDevice(), let library = device.makeDefaultLibrary() else {
            logger.error("No Metal default library; falling back to flat surfaces")
            return nil
        }
        return CustomMaterial.SurfaceShader(named: "echoSurface", in: library)
    }

    private static func makeSurfaceMaterial(_ color: UIColor, shader: CustomMaterial.SurfaceShader?) -> any Material {
        if let shader {
            do {
                var material = try CustomMaterial(surfaceShader: shader, lightingModel: .unlit)
                material.baseColor = .init(tint: color)
                material.blending = .transparent(opacity: 1.0)   // the shader sets the real opacity
                material.faceCulling = .none
                return material
            } catch {
                // Fall through to the flat material.
            }
        }
        return makeFlatMaterial(color, opacity: 0.6)
    }

    private static func makeFlatMaterial(_ color: UIColor, opacity: Float) -> UnlitMaterial {
        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        material.faceCulling = .none
        return material
    }
}
