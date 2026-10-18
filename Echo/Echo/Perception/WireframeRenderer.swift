//
//  WireframeRenderer.swift
//  Echo
//
//  Turns `WireframeMeshData` into RealityKit entities drawn as glowing wireframes
//  (drawn as sparse dots): one `ModelEntity` per ARMeshAnchor with per-face material
//  buckets, plus a translucent red overlay entity for the current trip hazards.
//
//  Line rendering uses `UnlitMaterial.triangleFillMode = .lines`, so the colours are
//  independent of scene lighting and stay bright over a dimmed camera feed.
//

import Foundation
import RealityKit
import UIKit
import simd
import os

@MainActor
final class WireframeRenderer {

    // MARK: Palette

    enum Palette {
        static let floor     = UIColor(red: 0.20, green: 1.00, blue: 0.50, alpha: 1)   // neon green
        static let wall      = UIColor(red: 0.00, green: 0.92, blue: 1.00, alpha: 1)   // cyan
        static let ceiling   = UIColor(red: 0.35, green: 0.45, blue: 1.00, alpha: 1)   // indigo
        static let furniture = UIColor(red: 1.00, green: 0.72, blue: 0.20, alpha: 1)   // amber
        static let unknown   = UIColor(red: 0.70, green: 0.75, blue: 0.82, alpha: 1)   // grey
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

        static func opacity(for bucket: SurfaceBucket) -> Float {
            switch bucket {
            case .floor:                    return 0.4    // walkable; recede so obstacles stand out
            case .wall, .furniture:         return 0.95
            case .ceiling:                  return 0.45
            case .unknown:                  return 0.55
            }
        }
    }

    // MARK: State

    /// World-locked root for every wireframe entity. Add it to `arView.scene`.
    let root: AnchorEntity

    private let config: PerceptionConfig
    private let logger = Logger(subsystem: "echo.perception", category: "WireframeRenderer")

    private var meshEntities: [UUID: ModelEntity] = [:]
    private var sequences: [UUID: UInt64] = [:]
    private var centers: [UUID: SIMD3<Float>] = [:]
    private var bucketMaterials: [SurfaceBucket: UnlitMaterial] = [:]

    private let hazardFill: ModelEntity
    private let hazardFillMaterial: UnlitMaterial

    // MARK: Init

    init(config: PerceptionConfig) {
        self.config = config

        root = AnchorEntity(world: matrix_identity_float4x4)
        root.name = "echo.wireframe.root"

        for bucket in SurfaceBucket.allCases {
            bucketMaterials[bucket] = Self.makeMaterial(
                Palette.color(for: bucket),
                opacity: Palette.opacity(for: bucket),
                lines: false
            )
        }

        hazardFillMaterial = Self.makeMaterial(Palette.hazard, opacity: 0.25, lines: false)

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

    /// Builds or replaces the wireframe entity for one mesh anchor. Out-of-order results
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
        entity.transform = Transform(matrix: data.transform)
    }

    func remove(anchorID: UUID) {
        if let entity = meshEntities.removeValue(forKey: anchorID) {
            entity.removeFromParent()
        }
        sequences[anchorID] = nil
        centers[anchorID] = nil
    }

    func removeAll() {
        for entity in meshEntities.values { entity.removeFromParent() }
        meshEntities.removeAll()
        sequences.removeAll()
        centers.removeAll()
        hazardFill.isEnabled = false
    }

    /// Hides chunks far from the user so a long walk does not accumulate draw calls.
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

    private static func makeMaterial(_ color: UIColor, opacity: Float, lines: Bool) -> UnlitMaterial {
        var material = UnlitMaterial(color: color)
        material.triangleFillMode = lines ? .lines : .fill
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        material.faceCulling = .none
        return material
    }
}
