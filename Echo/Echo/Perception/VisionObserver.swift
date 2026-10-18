//
//  VisionObserver.swift
//  Echo
//
//  Semantic layer on top of the geometry: Apple's on-device Vision networks run on the
//  camera image a few times a second and the results are fused with the LiDAR depth map.
//
//    * People and animals: `VNDetectHumanRectanglesRequest` / `VNRecognizeAnimalsRequest`
//      give boxes; the depth map inside each box gives a distance, the camera intrinsics
//      give a bearing. A person is then "Person, 1.4 m, on your left" rather than an
//      anonymous blob of mesh.
//    * What is ahead: when the sonar has a target, `VNClassifyImageRequest` classifies the
//      image region around it (door, staircase, chair, car, ...) so the narrator can name it.
//
//  Work happens on a serial background queue; at most one frame is in flight. Results
//  come back on the main actor through `onReport`.
//
//  Image orientation: the captured buffer is in sensor (landscape) orientation; held in
//  portrait it must be rotated 90 degrees clockwise to be upright, which is
//  `CGImagePropertyOrientation.right`. Vision reports boxes in that upright frame with a
//  bottom-left origin; `bufferPoint` maps back to buffer coordinates for depth lookup.
//

import ARKit
import CoreVideo
import Foundation
import Vision
import os
import simd

nonisolated struct VisionDetection: Sendable {
    let label: String
    /// Horizontal bearing from the walking heading, radians, right positive.
    let bearing: Float
    /// Horizontal distance in metres, nil when the depth map had nothing usable in the box.
    let distance: Float?
    let confidence: Float
}

nonisolated struct VisionReport: Sendable {
    let timestamp: TimeInterval
    let detections: [VisionDetection]
    /// Spoken name of the thing at the sonar target, if the classifier was confident.
    let labelAhead: String?
    let labelConfidence: Float
}

nonisolated final class VisionObserver: @unchecked Sendable {

    /// Everything the worker needs, copied out of the ARFrame on the main thread.
    struct Input: @unchecked Sendable {
        let image: CVPixelBuffer
        let depth: CVPixelBuffer?
        let depthConfidence: CVPixelBuffer?
        let intrinsics: simd_float3x3
        let imageResolution: CGSize
        let cameraTransform: simd_float4x4
        /// Vision-normalised region (bottom-left origin) around the sonar target, if any.
        let regionAhead: CGRect?
        let timestamp: TimeInterval
    }

    private let queue = DispatchQueue(label: "echo.vision", qos: .userInitiated)
    private let busy = OSAllocatedUnfairLock(initialState: false)
    private let onReport: @MainActor @Sendable (VisionReport) -> Void
    private let logger = Logger(subsystem: "echo.perception", category: "VisionObserver")

    init(onReport: @escaping @MainActor @Sendable (VisionReport) -> Void) {
        self.onReport = onReport
    }

    /// Drops the frame if the previous one is still being analysed.
    func process(_ input: Input) {
        let accepted = busy.withLock { running -> Bool in
            if running { return false }
            running = true
            return true
        }
        guard accepted else { return }
        queue.async { [self] in
            let report = analyze(input)
            busy.withLock { $0 = false }
            let deliver = onReport
            Task { @MainActor in deliver(report) }
        }
    }

    // MARK: Analysis

    private func analyze(_ input: Input) -> VisionReport {
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = true
        let animals = VNRecognizeAnimalsRequest()
        var requests: [VNRequest] = [people, animals]
        var classify: VNClassifyImageRequest?
        if let region = input.regionAhead {
            let request = VNClassifyImageRequest()
            request.regionOfInterest = region
            classify = request
            requests.append(request)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: input.image, orientation: .right, options: [:])
        do {
            try handler.perform(requests)
        } catch {
            logger.error("Vision failed: \(error.localizedDescription, privacy: .public)")
            return VisionReport(timestamp: input.timestamp, detections: [], labelAhead: nil, labelConfidence: 0)
        }

        var detections: [VisionDetection] = []
        for observation in people.results ?? [] where observation.confidence >= 0.5 {
            detections.append(detection("Person", box: observation.boundingBox, confidence: observation.confidence, input: input))
        }
        for observation in animals.results ?? [] where observation.confidence >= 0.5 {
            let name = observation.labels.first?.identifier.capitalized ?? "Animal"
            detections.append(detection(name, box: observation.boundingBox, confidence: observation.confidence, input: input))
        }

        var labelAhead: String?
        var labelConfidence: Float = 0
        if let results = classify?.results {
            for observation in results.prefix(12) where observation.confidence >= 0.2 {
                if let name = Self.spokenName(for: observation.identifier) {
                    labelAhead = name
                    labelConfidence = observation.confidence
                    break
                }
            }
        }

        return VisionReport(timestamp: input.timestamp, detections: detections,
                            labelAhead: labelAhead, labelConfidence: labelConfidence)
    }

    /// Distance and bearing for a Vision box, from the depth map inside its central part.
    private func detection(_ label: String, box: CGRect, confidence: Float, input: Input) -> VisionDetection {
        let centre = Self.bufferPoint(visionX: Float(box.midX), visionY: Float(box.midY))
        let distance = sampleDepth(in: box, input: input)

        // Bearing: unproject the box centre at that depth (or 1 m if unknown) and compare
        // with the walking heading.
        let z = distance ?? 1
        let fx = input.intrinsics[0][0], fy = input.intrinsics[1][1]
        let cx = input.intrinsics[2][0], cy = input.intrinsics[2][1]
        let px = centre.u * Float(input.imageResolution.width)
        let py = centre.v * Float(input.imageResolution.height)
        let local = SIMD3((px - cx) * z / fx, -(py - cy) * z / fy, -z)
        let world = input.cameraTransform.transformPoint(local)
        let camera = input.cameraTransform.translation
        let camZ = SIMD3(input.cameraTransform.columns.2.x, input.cameraTransform.columns.2.y, input.cameraTransform.columns.2.z)
        var heading = (-camZ).xz
        heading = simd_length(heading) > 1e-3 ? simd_normalize(heading) : SIMD3(0, 0, -1)
        let right = simd_normalize(simd_cross(heading, SIMD3(0, 1, 0)))
        let d = world - camera
        let bearing = atan2(d.x * right.x + d.z * right.z, d.x * heading.x + d.z * heading.z)
        let horizontal = distance.map { _ in simd_length(d.xz) }
        return VisionDetection(label: label, bearing: bearing, distance: horizontal, confidence: confidence)
    }

    /// 30th percentile of the confident depths in the central half of the box: near the
    /// front of the body, robust to background pixels at the edges.
    private func sampleDepth(in box: CGRect, input: Input) -> Float? {
        guard let depth = input.depth else { return nil }
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let width = CVPixelBufferGetWidth(depth), height = CVPixelBufferGetHeight(depth)
        let stride = CVPixelBufferGetBytesPerRow(depth) / MemoryLayout<Float32>.size
        let depths = base.assumingMemoryBound(to: Float32.self)

        var confidences: UnsafeMutablePointer<UInt8>?
        var confidenceStride = 0
        if let confidence = input.depthConfidence {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            confidences = CVPixelBufferGetBaseAddress(confidence)?.assumingMemoryBound(to: UInt8.self)
            confidenceStride = CVPixelBufferGetBytesPerRow(confidence)
        }
        defer { if let confidence = input.depthConfidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }

        var samples: [Float] = []
        let steps = 10
        for i in 0..<steps {
            for j in 0..<steps {
                let vx = Float(box.minX) + Float(box.width) * (0.25 + 0.5 * Float(i) / Float(steps - 1))
                let vy = Float(box.minY) + Float(box.height) * (0.25 + 0.5 * Float(j) / Float(steps - 1))
                let p = Self.bufferPoint(visionX: vx, visionY: vy)
                let u = min(width - 1, max(0, Int(p.u * Float(width))))
                let v = min(height - 1, max(0, Int(p.v * Float(height))))
                if let confidences, confidences[v * confidenceStride + u] < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                let z = depths[v * stride + u]
                if z.isFinite, z > 0.1, z < 6 { samples.append(z) }
            }
        }
        guard samples.count >= 8 else { return nil }
        samples.sort()
        return samples[samples.count * 3 / 10]
    }

    /// Vision upright coordinates (bottom-left origin) -> buffer coordinates (top-left origin),
    /// for a sensor buffer that is rotated 90 degrees clockwise to stand upright.
    private static func bufferPoint(visionX: Float, visionY: Float) -> (u: Float, v: Float) {
        (u: 1 - visionY, v: 1 - visionX)
    }

    /// Classifier identifiers worth saying out loud, and how to say them.
    private static let spokenNames: [(key: String, name: String)] = [
        ("staircase", "Stairs"), ("stairs", "Stairs"), ("escalator", "Escalator"), ("elevator", "Elevator"),
        ("door", "Door"), ("gate", "Gate"), ("fence", "Fence"), ("railing", "Railing"), ("wall", "Wall"),
        ("pillar", "Pillar"), ("column", "Pillar"), ("pole", "Pole"), ("tree", "Tree"), ("plant", "Plant"),
        ("chair", "Chair"), ("stool", "Stool"), ("bench", "Bench"), ("sofa", "Couch"), ("couch", "Couch"),
        ("table", "Table"), ("desk", "Desk"), ("counter", "Counter"), ("bed", "Bed"), ("cabinet", "Cabinet"),
        ("shelf", "Shelf"), ("bookcase", "Shelf"), ("refrigerator", "Fridge"), ("sink", "Sink"), ("toilet", "Toilet"),
        ("automobile", "Car"), ("car", "Car"), ("truck", "Truck"), ("bus", "Bus"), ("bicycle", "Bicycle"),
        ("motorcycle", "Motorcycle"), ("scooter", "Scooter"), ("stroller", "Stroller"), ("shopping cart", "Cart"),
        ("trash", "Trash can"), ("garbage", "Trash can"), ("box", "Box"), ("suitcase", "Suitcase"), ("bag", "Bag"),
        ("cone", "Cone"), ("barrier", "Barrier"), ("sign", "Sign"), ("lamp", "Lamp"), ("window", "Window"),
        ("curtain", "Curtain"), ("mirror", "Mirror"), ("dog", "Dog"), ("cat", "Cat"), ("person", "Person"),
        ("people", "Person"), ("crowd", "People"),
    ]

    private static func spokenName(for identifier: String) -> String? {
        let id = identifier.lowercased()
        return spokenNames.first { id == $0.key || id.hasPrefix($0.key + " ") || id.hasSuffix(" " + $0.key) || id.contains("_" + $0.key) || id.contains($0.key + "_") }?.name
    }
}
