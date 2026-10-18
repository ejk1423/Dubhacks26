//
//  VisionObserver.swift
//  Echo
//
//  Semantic layer on top of the geometry: Apple's on-device Vision networks run on the
//  camera image a few times a second and the results are fused with the LiDAR depth map.
//
//    * People and animals: `VNDetectHumanRectanglesRequest` / `VNRecognizeAnimalsRequest`
//      give boxes; the depth map inside each box gives a distance, the camera intrinsics
//      give a bearing and a world position. Detections are matched to short-lived tracks
//      across passes, so each person has a stable `trackID`, a smoothed distance, a
//      closing speed and a flag for "walking toward you" (their own motion in the world
//      frame, independent of the user's walking).
//    * What is ahead: when the sonar has a target, `VNClassifyImageRequest` classifies the
//      image region around it. Candidate names accumulate confidence-weighted scores that
//      decay pass by pass, so a name is only reported once it has been seen consistently,
//      and names that contradict the surroundings (a car in a hallway, a bed on a street)
//      are suppressed. A person box over the region names it "Person" directly.
//    * Where you are: the whole image is classified for a scene word (hallway, kitchen,
//      street, ...) and an indoors/outdoors judgement used by the "describe" summary.
//    * Signs: every few passes `VNRecognizeTextRequest` reads the image and wayfinding
//      words (EXIT, RESTROOM, STAIRS, PUSH, ...) and room numbers are reported, each with
//      an estimated world position so the narrator can later say "Exit sign was on your
//      right" relative to wherever the user is now facing.
//
//  Work happens on a serial background queue; at most one frame is in flight. Results
//  come back on the main actor through `onReport`. No face detection is used.
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
    /// Horizontal distance in metres (smoothed over the track), nil when the depth map had
    /// nothing usable in the box.
    let distance: Float?
    let confidence: Float
    /// Stable while the same person or animal is seen pass after pass.
    let trackID: Int?
    /// Rate at which the gap is closing, m/s, positive when getting closer. Relative to the
    /// user, so it includes the user's own walking. nil until the track has enough history.
    let approachingSpeed: Float?
    /// The detection's own motion in the world is toward the user (they are walking at you,
    /// not just you walking at them).
    let movingTowardYou: Bool
    /// Seconds this track has been seen.
    let trackAge: Float

    init(label: String, bearing: Float, distance: Float?, confidence: Float,
         trackID: Int? = nil, approachingSpeed: Float? = nil, movingTowardYou: Bool = false, trackAge: Float = 0) {
        self.label = label
        self.bearing = bearing
        self.distance = distance
        self.confidence = confidence
        self.trackID = trackID
        self.approachingSpeed = approachingSpeed
        self.movingTowardYou = movingTowardYou
        self.trackAge = trackAge
    }

    /// Sideways offset from the walking line in metres (right positive), when distance is known.
    var lateralOffset: Float? { distance.map { $0 * sin(bearing) } }

    /// Seconds until the gap closes at the current closing speed, nil when not closing.
    var timeToReach: Float? {
        guard let distance, let speed = approachingSpeed, speed > 0.05 else { return nil }
        return distance / speed
    }

    var isPerson: Bool { label == "Person" }
}

/// A wayfinding sign that was read at some point, with where it was.
nonisolated struct SignSighting: Sendable, Equatable {
    /// Spoken form: "Exit", "Restroom", "Room 204".
    let text: String
    /// Estimated world position of the sign (depth-map distance, or 3 m when unknown).
    let worldPosition: SIMD3<Float>
    /// Bearing from the walking heading when it was read, radians, right positive.
    let bearingAtSighting: Float
    let distanceAtSighting: Float?
    let timestamp: TimeInterval

    /// Bearing of the sign from where the user is now, radians, right positive.
    func bearing(from position: SIMD3<Float>, heading: SIMD3<Float>) -> Float {
        let right = simd_normalize(simd_cross(heading, SIMD3(0, 1, 0)))
        let d = worldPosition - position
        return atan2(d.x * right.x + d.z * right.z, d.x * heading.x + d.z * heading.z)
    }

    func distance(from position: SIMD3<Float>) -> Float {
        simd_length((worldPosition - position).xz)
    }

    /// Safety-relevant signs are spoken even in quiet mode.
    var isSafety: Bool {
        ["Exit", "Emergency exit", "Emergency", "Caution", "Wet floor", "No entry", "Do not enter", "Stop", "Danger"]
            .contains(text)
    }
}

/// A LiDAR object the camera has put a name on.
nonisolated struct NamedObject: Sendable, Identifiable, Equatable {
    let id: Int
    let name: String
    let confidence: Float
}

/// What the camera thinks the floor patch at a trip hazard is.
nonisolated enum GroundKind: Sendable, Equatable {
    case step, object, flat
}

nonisolated struct VisionReport: Sendable {
    let timestamp: TimeInterval
    let detections: [VisionDetection]
    /// Spoken name of the thing at the sonar target, after scoring across passes.
    let labelAhead: String?
    let labelConfidence: Float
    /// Spoken name of the surroundings ("Hallway", "Street"), if confident.
    let scene: String?
    /// Wayfinding words read from signs in view, most recent reading pass only.
    let signs: [String]
    /// Indoors / outdoors judgement from the scene classifier, nil when unsure.
    let isIndoors: Bool?
    /// The most recently read sign, kept for a minute after it left the view.
    let lastSign: SignSighting?
    /// Signs read in the last minute, newest first, one per text.
    let recentSigns: [SignSighting]
    /// The floor patch at the nearest trip hazard, after voting: a step, an object, or flat.
    var groundKind: GroundKind? = nil
    var groundLabel: String? = nil
    var groundConfidence: Float = 0
    /// Names for LiDAR objects (`SceneObject.id`), voted across passes.
    var objects: [NamedObject] = []

    func name(for objectID: Int) -> NamedObject? { objects.first { $0.id == objectID } }

    /// People in the report, nearest first.
    var people: [VisionDetection] {
        detections.filter(\.isPerson).sorted { ($0.distance ?? 99) < ($1.distance ?? 99) }
    }
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
        /// Region around the nearest trip hazard on the floor, if any.
        var regionGround: CGRect? = nil
        /// Image regions of the nearest LiDAR objects (`SceneObject.id` -> Vision rect).
        var objectRegions: [ObjectRegion] = []
    }

    nonisolated struct ObjectRegion: Sendable {
        let id: Int
        let rect: CGRect
    }

    private let queue = DispatchQueue(label: "echo.vision", qos: .userInitiated)
    private let busy = OSAllocatedUnfairLock(initialState: false)
    private let onReport: @MainActor @Sendable (VisionReport) -> Void
    private let logger = Logger(subsystem: "echo.perception", category: "VisionObserver")

    // Worker-queue state.
    private var passCounter = 0
    private var groundVotes: [(kind: GroundKind, name: String, confidence: Float)?] = []
    /// Per LiDAR object: decayed scores per name, and the pass it was last seen.
    private var objectScores: [Int: [String: Float]] = [:]
    private var objectLastSeen: [Int: Int] = [:]
    private var labelScores: [String: Float] = [:]
    private var labelLastSeenPass: [String: Int] = [:]
    private var sceneVotes: [String?] = []
    private var lastSigns: [String] = []
    private var recentSigns: [SignSighting] = []
    private var tracks: [Track] = []
    private var nextTrackID = 1

    // Tuning
    private let trackTimeout: TimeInterval = 1.5         // seconds unseen before a track is dropped
    private let trackMatchBearing: Float = 0.35          // radians
    private let trackMatchDistance: Float = 1.2          // metres
    private let speedWindow: TimeInterval = 1.4          // seconds of history for closing speed
    private let speedMinSpan: TimeInterval = 0.7         // seconds of history before a speed is trusted
    private let towardYouSpeed: Float = 0.35             // m/s of the person's own motion toward the user
    private let labelDecay: Float = 0.65                 // per pass with a region ahead
    private let labelDecayNoTarget: Float = 0.4          // per pass without one
    private let signMemory: TimeInterval = 60

    private struct Track {
        let id: Int
        let label: String
        var bearing: Float
        var distance: Float?
        var world: SIMD3<Float>?
        var confidence: Float
        let firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var samples: [(time: TimeInterval, distance: Float, world: SIMD3<Float>)] = []
        var matched = false
    }

    private struct RawDetection {
        let label: String
        let bearing: Float
        let distance: Float?
        let world: SIMD3<Float>?
        let confidence: Float
        let box: CGRect
    }

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
        passCounter += 1
        let readsText = passCounter % 3 == 0

        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = true
        let animals = VNRecognizeAnimalsRequest()
        let scene = VNClassifyImageRequest()
        var requests: [VNRequest] = [people, animals, scene]

        var classify: VNClassifyImageRequest?
        if let region = input.regionAhead {
            let request = VNClassifyImageRequest()
            request.regionOfInterest = region
            classify = request
            requests.append(request)
        }
        var classifyGround: VNClassifyImageRequest?
        if let region = input.regionGround {
            let request = VNClassifyImageRequest()
            request.regionOfInterest = region
            classifyGround = request
            requests.append(request)
        }
        var objectRequests: [(id: Int, request: VNClassifyImageRequest)] = []
        for region in input.objectRegions.prefix(3) {
            let request = VNClassifyImageRequest()
            request.regionOfInterest = region.rect
            objectRequests.append((region.id, request))
            requests.append(request)
        }
        var text: VNRecognizeTextRequest?
        if readsText {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.03
            text = request
            requests.append(request)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: input.image, orientation: .right, options: [:])
        do {
            try handler.perform(requests)
        } catch {
            logger.error("Vision failed: \(error.localizedDescription, privacy: .public)")
            return VisionReport(timestamp: input.timestamp, detections: [], labelAhead: nil, labelConfidence: 0,
                                scene: nil, signs: [], isIndoors: nil, lastSign: recentSigns.first, recentSigns: recentSigns)
        }

        // People and animals, fused with depth and matched to tracks.
        var raw: [RawDetection] = []
        for observation in people.results ?? [] where observation.confidence >= 0.5 {
            raw.append(rawDetection("Person", box: observation.boundingBox, confidence: observation.confidence, input: input))
        }
        for observation in animals.results ?? [] where observation.confidence >= 0.5 {
            let name = observation.labels.first?.identifier.capitalized ?? "Animal"
            raw.append(rawDetection(name, box: observation.boundingBox, confidence: observation.confidence, input: input))
        }
        let detections = track(raw, input: input)

        // Scene: vote over the last five passes.
        sceneVotes.append(scene.results.flatMap { Self.bestName(in: $0, table: Self.sceneNames, minimum: 0.15) }?.name)
        if sceneVotes.count > 5 { sceneVotes.removeFirst() }
        let sceneName = Dictionary(grouping: sceneVotes.compactMap { $0 }, by: { $0 })
            .max { $0.value.count < $1.value.count }
            .flatMap { $0.value.count >= 3 ? $0.key : nil }
        let indoors = sceneName.flatMap { Self.indoorScenes.contains($0) ? true : (Self.outdoorScenes.contains($0) ? false : nil) }

        // Object ahead: confidence-weighted scores decaying over passes.
        let personAhead = input.regionAhead.flatMap { region in
            raw.filter { $0.label == "Person" && Self.overlap($0.box, region) > 0.3 }.map(\.confidence).max()
        }
        let (labelAhead, labelConfidence) = scoreLabels(classify?.results, hasRegion: input.regionAhead != nil,
                                                        personAhead: personAhead, indoors: indoors)

        // Signs.
        if let text {
            lastSigns = readSigns(text.results ?? [], input: input)
        }
        recentSigns.removeAll { input.timestamp - $0.timestamp > signMemory }

        // What is on the floor at the hazard: vote over the last three passes so a single
        // confused frame never turns a rug into a step.
        groundVotes.append(classifyGround?.results.flatMap { Self.groundGuess(in: $0) })
        if groundVotes.count > 3 { groundVotes.removeFirst() }
        var groundKind: GroundKind?
        var groundLabel: String?
        var groundConfidence: Float = 0
        if let latest = groundVotes.last ?? nil {
            let agreeing = groundVotes.compactMap { $0 }.filter { $0.kind == latest.kind }
            if agreeing.count >= 2 {
                groundKind = latest.kind
                groundLabel = latest.name
                groundConfidence = agreeing.map(\.confidence).max() ?? latest.confidence
            }
        }

        // Named LiDAR objects: scores accumulate per object across passes and decay, so a
        // name needs to be seen repeatedly, and a bad frame cannot rename a chair a bin.
        for (id, request) in objectRequests {
            var scores = objectScores[id] ?? [:]
            for key in scores.keys { scores[key]! *= 0.7 }
            if let results = request.results {
                for observation in results.prefix(10) where observation.confidence >= 0.12 {
                    guard let name = Self.bestName(in: [observation], table: Self.objectNames, minimum: 0.12)?.name else { continue }
                    if indoors == true, Self.outdoorOnly.contains(name) { continue }
                    if indoors == false, Self.indoorOnly.contains(name) { continue }
                    scores[name, default: 0] += observation.confidence
                }
            }
            objectScores[id] = scores
            objectLastSeen[id] = passCounter
        }
        for (id, seen) in objectLastSeen where passCounter - seen > 30 {
            objectScores[id] = nil
            objectLastSeen[id] = nil
        }
        var named: [NamedObject] = []
        for (id, scores) in objectScores {
            guard let best = scores.max(by: { $0.value < $1.value }), best.value >= 0.35 else { continue }
            named.append(NamedObject(id: id, name: best.key, confidence: min(1, best.value / 1.5)))
        }

        return VisionReport(timestamp: input.timestamp, detections: detections,
                            labelAhead: labelAhead, labelConfidence: labelConfidence,
                            scene: sceneName, signs: lastSigns, isIndoors: indoors,
                            lastSign: recentSigns.first, recentSigns: recentSigns,
                            groundKind: groundKind, groundLabel: groundLabel, groundConfidence: groundConfidence,
                            objects: named)
    }

    // MARK: Tracking

    /// Matches this pass's detections to existing tracks by bearing and distance, smooths
    /// their positions and estimates closing speed and the person's own motion.
    private func track(_ raw: [RawDetection], input: Input) -> [VisionDetection] {
        let now = input.timestamp
        tracks.removeAll { now - $0.lastSeen > trackTimeout }
        for i in tracks.indices { tracks[i].matched = false }

        // Greedy assignment, best matches first.
        var pairs: [(cost: Float, detection: Int, track: Int)] = []
        for (d, detection) in raw.enumerated() {
            for (t, track) in tracks.enumerated() where track.label == detection.label {
                var cost = abs(Self.wrap(detection.bearing - track.bearing)) / trackMatchBearing
                if let a = detection.distance, let b = track.distance {
                    cost += abs(a - b) / trackMatchDistance
                } else {
                    cost += 0.4
                }
                if cost < 1 { pairs.append((cost, d, t)) }
            }
        }
        pairs.sort { $0.cost < $1.cost }
        var assignment = [Int?](repeating: nil, count: raw.count)
        for pair in pairs where assignment[pair.detection] == nil && !tracks[pair.track].matched {
            assignment[pair.detection] = pair.track
            tracks[pair.track].matched = true
        }

        let camera = input.cameraTransform.translation
        var result: [VisionDetection] = []
        for (d, detection) in raw.enumerated() {
            let index: Int
            if let t = assignment[d] {
                index = t
                var track = tracks[t]
                track.bearing = detection.bearing
                track.confidence = max(track.confidence * 0.8, detection.confidence)
                track.lastSeen = now
                if let distance = detection.distance, let world = detection.world {
                    track.distance = track.distance.map { $0 * 0.5 + distance * 0.5 } ?? distance
                    track.world = track.world.map { $0 * 0.5 + world * 0.5 } ?? world
                    track.samples.append((now, track.distance ?? distance, track.world ?? world))
                    track.samples.removeAll { now - $0.time > speedWindow }
                } else {
                    track.distance = nil
                    track.world = nil
                    track.samples.removeAll()
                }
                tracks[t] = track
            } else {
                var track = Track(id: nextTrackID, label: detection.label, bearing: detection.bearing,
                                  distance: detection.distance, world: detection.world,
                                  confidence: detection.confidence, firstSeen: now, lastSeen: now)
                if let distance = detection.distance, let world = detection.world {
                    track.samples = [(now, distance, world)]
                }
                track.matched = true
                nextTrackID += 1
                tracks.append(track)
                index = tracks.count - 1
            }

            let track = tracks[index]
            var approaching: Float?
            var toward = false
            if let first = track.samples.first, let last = track.samples.last, track.samples.count >= 4,
               last.time - first.time >= speedMinSpan {
                let fit = Self.fit(track.samples)
                approaching = -fit.distanceRate
                let gap = (camera - last.world).xz
                if simd_length(gap) > 0.2, simd_length(fit.velocity) >= towardYouSpeed {
                    toward = simd_dot(fit.velocity, simd_normalize(gap)) >= towardYouSpeed
                }
            }
            result.append(VisionDetection(label: track.label, bearing: track.bearing, distance: track.distance,
                                          confidence: track.confidence, trackID: track.id,
                                          approachingSpeed: approaching, movingTowardYou: toward,
                                          trackAge: Float(now - track.firstSeen)))
        }
        return result
    }

    // MARK: Object naming

    /// Confidence-weighted, decaying scores per candidate name. A person box over the region
    /// wins outright; names that contradict the scene are dropped.
    private func scoreLabels(_ observations: [VNClassificationObservation]?, hasRegion: Bool,
                             personAhead: Float?, indoors: Bool?) -> (String?, Float) {
        let decay = hasRegion ? labelDecay : labelDecayNoTarget
        labelScores = labelScores.mapValues { $0 * decay }.filter { $0.value >= 0.03 }
        guard hasRegion else { return (nil, 0) }

        if let personAhead {
            return ("Person", personAhead)
        }
        if let observations {
            var seen: [String: Float] = [:]
            for observation in observations.prefix(25) where observation.confidence >= 0.08 {
                let id = observation.identifier.lowercased()
                guard let entry = Self.objectNames.first(where: { Self.matches(id, key: $0.key) }) else { continue }
                seen[entry.name] = max(seen[entry.name] ?? 0, observation.confidence)
            }
            for (name, confidence) in seen {
                labelScores[name, default: 0] += confidence
                labelLastSeenPass[name] = passCounter
            }
        }

        let plausible = labelScores.filter { name, _ in
            // The dedicated detector did not see a person, so the classifier's one is noise.
            if name == "Person" || name == "People" { return false }
            if indoors == true, Self.outdoorOnly.contains(name) { return false }
            if indoors == false, Self.indoorOnly.contains(name) { return false }
            // Must have been seen in this pass or the one before.
            return (labelLastSeenPass[name] ?? 0) >= passCounter - 1
        }
        guard let best = plausible.max(by: { $0.value < $1.value }), best.value >= 0.35 else { return (nil, 0) }
        return (best.key, min(1, best.value * 0.5))
    }

    // MARK: Signs

    private func readSigns(_ observations: [VNRecognizedTextObservation], input: Input) -> [String] {
        var found: [String] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.4 else { continue }
            let words = candidate.string.uppercased()
            var names: [String] = []
            for entry in Self.signWords where words.contains(entry.key) && !names.contains(entry.name) {
                names.append(entry.name)
            }
            // Keep the more specific reading when a word is part of a longer one.
            if names.contains("Emergency exit") { names.removeAll { $0 == "Exit" || $0 == "Emergency" } }
            if words.contains("WOMEN") || words.contains("LADIES") { names.removeAll { $0 == "Men's restroom" } }
            if names.contains("Do not enter") || names.contains("No entry") { names.removeAll { $0 == "Entrance" } }
            if words.contains("BUS STOP") { names.removeAll { $0 == "Stop" } }
            if let room = Self.roomNumber(in: words) { names.append(room) }
            guard !names.isEmpty else { continue }

            let placed = place(box: observation.boundingBox, input: input, fallbackDepth: 3)
            for name in names {
                if !found.contains(name) { found.append(name) }
                let sighting = SignSighting(text: name, worldPosition: placed.world, bearingAtSighting: placed.bearing,
                                            distanceAtSighting: placed.distance, timestamp: input.timestamp)
                recentSigns.removeAll { $0.text == name }
                recentSigns.insert(sighting, at: 0)
            }
        }
        return found
    }

    /// "ROOM 204", "RM 12B", or a bare short number on its own line ("204", "B117").
    private static func roomNumber(in text: String) -> String? {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard !tokens.isEmpty, tokens.count <= 3 else { return nil }
        func isNumber(_ token: String) -> Bool {
            let digits = token.filter(\.isNumber)
            return digits.count >= 2 && digits.count <= 4 && token.count <= 5
                && token.allSatisfy { $0.isNumber || $0.isLetter } && token.first.map { $0.isNumber || token.count > 1 } == true
        }
        if let i = tokens.firstIndex(where: { $0 == "ROOM" || $0 == "RM" || $0 == "SUITE" }), i + 1 < tokens.count,
           isNumber(tokens[i + 1]) {
            return (tokens[i] == "SUITE" ? "Suite " : "Room ") + tokens[i + 1]
        }
        if tokens.count == 1, isNumber(tokens[0]), tokens[0].filter(\.isNumber).count >= 3 {
            return "Room " + tokens[0]
        }
        return nil
    }

    // MARK: Geometry

    private func rawDetection(_ label: String, box: CGRect, confidence: Float, input: Input) -> RawDetection {
        let distance = sampleDepth(in: box, input: input)
        let placed = place(box: box, input: input, fallbackDepth: 1, depth: distance)
        return RawDetection(label: label, bearing: placed.bearing, distance: distance == nil ? nil : placed.distance,
                            world: distance == nil ? nil : placed.world, confidence: confidence, box: box)
    }

    /// World position, horizontal distance and bearing of a Vision box centre, using the
    /// depth map inside the box (or `fallbackDepth` when it has nothing usable).
    private func place(box: CGRect, input: Input, fallbackDepth: Float, depth: Float?? = nil)
        -> (world: SIMD3<Float>, distance: Float, bearing: Float) {
        let sampled: Float? = depth ?? sampleDepth(in: box, input: input)
        let z = sampled ?? fallbackDepth
        let centre = Self.bufferPoint(visionX: Float(box.midX), visionY: Float(box.midY))
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
        return (world, simd_length(d.xz), bearing)
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

    /// Least-squares rates over a track's samples: distance change (m/s, negative when
    /// closing) and horizontal world velocity. Far less jittery than first-to-last.
    private static func fit(_ samples: [(time: TimeInterval, distance: Float, world: SIMD3<Float>)])
        -> (distanceRate: Float, velocity: SIMD3<Float>) {
        let t0 = samples[0].time
        let n = Float(samples.count)
        let ts = samples.map { Float($0.time - t0) }
        let meanT = ts.reduce(0, +) / n
        let varT = ts.reduce(0) { $0 + ($1 - meanT) * ($1 - meanT) }
        guard varT > 1e-4 else { return (0, .zero) }
        func slope(_ values: [Float]) -> Float {
            let mean = values.reduce(0, +) / n
            var cov: Float = 0
            for i in 0..<samples.count { cov += (ts[i] - meanT) * (values[i] - mean) }
            return cov / varT
        }
        let vx = slope(samples.map { $0.world.x })
        let vz = slope(samples.map { $0.world.z })
        return (slope(samples.map(\.distance)), SIMD3(vx, 0, vz))
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> Float {
        let i = a.intersection(b)
        guard !i.isNull, a.width > 0, a.height > 0 else { return 0 }
        return Float(i.width * i.height / (a.width * a.height))
    }

    private static func wrap(_ angle: Float) -> Float {
        var a = angle
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }

    // MARK: Vocabulary

    /// Classifier identifiers worth saying out loud as the thing ahead, and how to say them.
    /// More specific keys come first so "glass door" wins over "door".
    /// What the floor patch at a trip hazard can be: a real step, an object lying there,
    /// or something flat that the mesh raised a little (a rug, a cable, a threshold strip).
    private static let groundNames: [(key: String, name: String, kind: GroundKind)] = [
        ("staircase", "Stairs", .step), ("stairs", "Stairs", .step), ("stairway", "Stairs", .step), ("step", "Step", .step),
        ("curb", "Curb", .step), ("kerb", "Curb", .step), ("doorstep", "Step", .step), ("ramp", "Ramp", .step),
        ("ledge", "Ledge", .step), ("platform", "Platform edge", .step), ("escalator", "Escalator", .step),
        ("doormat", "Mat", .flat), ("mat", "Mat", .flat), ("rug", "Rug", .flat), ("carpet", "Carpet", .flat),
        ("threshold", "Threshold", .flat), ("cable", "Cable", .flat), ("cord", "Cable", .flat), ("wire", "Cable", .flat),
        ("tile", "Floor", .flat), ("floor", "Floor", .flat), ("grass", "Grass", .flat), ("manhole", "Manhole", .flat),
        ("drain", "Drain", .flat), ("puddle", "Puddle", .flat), ("shadow", "Floor", .flat), ("sidewalk", "Floor", .flat),
        ("pavement", "Floor", .flat), ("road", "Floor", .flat), ("hardwood", "Floor", .flat), ("concrete", "Floor", .flat),
        ("backpack", "Bag", .object), ("bag", "Bag", .object), ("suitcase", "Suitcase", .object), ("box", "Box", .object),
        ("shoe", "Shoes", .object), ("sneaker", "Shoes", .object), ("boot", "Boots", .object), ("bottle", "Bottle", .object),
        ("bucket", "Bucket", .object), ("basket", "Basket", .object), ("toy", "Toy", .object), ("ball", "Ball", .object),
        ("skateboard", "Skateboard", .object), ("flowerpot", "Plant pot", .object), ("pot", "Pot", .object),
        ("plant", "Plant", .object), ("rock", "Rock", .object), ("stone", "Rock", .object), ("brick", "Brick", .object),
        ("trash", "Trash", .object), ("litter", "Litter", .object), ("cone", "Cone", .object), ("chair", "Chair", .object),
        ("stool", "Stool", .object), ("dog", "Dog", .object), ("cat", "Cat", .object), ("package", "Package", .object),
        ("umbrella", "Umbrella", .object), ("helmet", "Helmet", .object), ("book", "Book", .object),
        ("beanbag", "Bean bag", .object), ("bean bag", "Bean bag", .object), ("cushion", "Cushion", .object),
        ("pillow", "Pillow", .object), ("blanket", "Blanket", .object), ("laundry", "Laundry", .object),
        ("clothes", "Clothes", .object), ("clothing", "Clothes", .object), ("towel", "Towel", .object),
        ("sofa", "Couch", .object), ("couch", "Couch", .object), ("ottoman", "Ottoman", .object),
        ("laptop", "Laptop", .object), ("speaker", "Speaker", .object), ("fan", "Fan", .object),
        ("luggage", "Luggage", .object), ("crate", "Crate", .object), ("pet bed", "Pet bed", .object),
    ]

    private static func groundGuess(in observations: [VNClassificationObservation]) -> (kind: GroundKind, name: String, confidence: Float)? {
        for observation in observations.prefix(15) where observation.confidence >= 0.18 {
            let id = observation.identifier.lowercased()
            if let entry = groundNames.first(where: {
                id == $0.key || id.hasPrefix($0.key + " ") || id.hasSuffix(" " + $0.key)
                    || id.contains("_" + $0.key) || id.contains($0.key + "_") || id.contains(" " + $0.key + " ")
            }) {
                return (entry.kind, entry.name, observation.confidence)
            }
        }
        return nil
    }

    private static let objectNames: [(key: String, name: String)] = [
        // Ways through
        ("revolving door", "Revolving door"), ("sliding door", "Sliding door"), ("glass door", "Glass door"),
        ("doorway", "Doorway"), ("door", "Door"), ("entrance", "Entrance"), ("gate", "Gate"), ("turnstile", "Turnstile"),
        ("staircase", "Stairs"), ("stairway", "Stairs"), ("stairs", "Stairs"), ("step", "Steps"), ("escalator", "Escalator"),
        ("elevator", "Elevator"), ("lift", "Elevator"), ("ramp", "Ramp"), ("handrail", "Railing"), ("banister", "Railing"),
        ("railing", "Railing"), ("fence", "Fence"), ("wall", "Wall"), ("window", "Window"), ("curtain", "Curtain"),
        ("mirror", "Mirror"), ("partition", "Partition"),
        // Posts and street furniture
        ("pillar", "Pillar"), ("column", "Pillar"), ("lamppost", "Lamp post"), ("streetlight", "Lamp post"),
        ("street light", "Lamp post"), ("bollard", "Bollard"), ("pole", "Pole"), ("post", "Post"), ("hydrant", "Fire hydrant"),
        ("mailbox", "Mailbox"), ("parking meter", "Parking meter"), ("traffic light", "Traffic light"), ("sign", "Sign"),
        ("cone", "Cone"), ("barrier", "Barrier"), ("bus stop", "Bus stop"), ("tree", "Tree"), ("bush", "Bush"),
        ("hedge", "Hedge"), ("plant", "Plant"), ("flower", "Plants"), ("rock", "Rock"), ("boulder", "Rock"),
        ("fountain", "Fountain"), ("statue", "Statue"),
        // Bins and clutter
        ("dumpster", "Dumpster"), ("trash", "Trash can"), ("garbage", "Trash can"), ("rubbish", "Trash can"),
        ("recycling", "Recycling bin"), ("bin", "Bin"), ("box", "Box"), ("crate", "Crate"), ("basket", "Basket"),
        ("suitcase", "Suitcase"), ("luggage", "Suitcase"), ("backpack", "Bag"), ("bag", "Bag"), ("ladder", "Ladder"),
        ("shopping cart", "Shopping cart"), ("cart", "Cart"), ("trolley", "Cart"),
        // Wheels
        ("bicycle", "Bicycle"), ("bike", "Bicycle"), ("motorcycle", "Motorcycle"), ("scooter", "Scooter"),
        ("stroller", "Stroller"), ("pram", "Stroller"), ("baby carriage", "Stroller"), ("wheelchair", "Wheelchair"),
        ("automobile", "Car"), ("car", "Car"), ("taxi", "Car"), ("van", "Van"), ("truck", "Truck"), ("bus", "Bus"),
        ("train", "Train"), ("tram", "Tram"),
        // Furniture
        ("chair", "Chair"), ("armchair", "Chair"), ("stool", "Stool"), ("bench", "Bench"), ("sofa", "Couch"),
        ("couch", "Couch"), ("dining table", "Table"), ("table", "Table"), ("desk", "Desk"), ("countertop", "Counter"),
        ("counter", "Counter"), ("bar", "Counter"), ("kiosk", "Kiosk"), ("vending machine", "Vending machine"),
        ("bed", "Bed"), ("cabinet", "Cabinet"), ("cupboard", "Cabinet"), ("wardrobe", "Wardrobe"), ("locker", "Lockers"),
        ("bookcase", "Shelf"), ("shelving", "Shelf"), ("shelf", "Shelf"), ("rack", "Rack"), ("refrigerator", "Fridge"),
        ("fridge", "Fridge"), ("oven", "Oven"), ("stove", "Stove"), ("sink", "Sink"), ("toilet", "Toilet"),
        ("bathtub", "Bathtub"), ("washing machine", "Washing machine"), ("piano", "Piano"), ("television", "Television"),
        ("monitor", "Monitor"), ("computer", "Computer"), ("printer", "Printer"), ("whiteboard", "Whiteboard"),
        ("lamp", "Lamp"), ("radiator", "Radiator"),
        // Living things
        ("dog", "Dog"), ("puppy", "Dog"), ("cat", "Cat"), ("kitten", "Cat"), ("bird", "Bird"), ("horse", "Horse"),
        ("person", "Person"), ("people", "Person"), ("crowd", "People"),
    ]

    /// Names that only make sense outdoors / indoors; suppressed when the scene says otherwise.
    private static let outdoorOnly: Set<String> = [
        "Car", "Van", "Truck", "Bus", "Train", "Tram", "Motorcycle", "Lamp post", "Fire hydrant", "Parking meter",
        "Traffic light", "Bus stop", "Tree", "Hedge", "Bush", "Dumpster", "Fountain", "Horse", "Rock",
    ]
    private static let indoorOnly: Set<String> = [
        "Bed", "Toilet", "Bathtub", "Fridge", "Oven", "Stove", "Washing machine", "Couch", "Wardrobe", "Lockers",
        "Piano", "Television", "Monitor", "Computer", "Printer", "Whiteboard", "Radiator", "Elevator", "Escalator",
    ]

    /// Scene words for the "describe" summary.
    private static let sceneNames: [(key: String, name: String)] = [
        ("hallway", "Hallway"), ("corridor", "Hallway"), ("staircase", "Stairwell"), ("stairwell", "Stairwell"),
        ("elevator", "Elevator"), ("kitchen", "Kitchen"), ("bathroom", "Bathroom"), ("restroom", "Bathroom"),
        ("bedroom", "Bedroom"), ("living room", "Living room"), ("dining room", "Dining room"), ("office", "Office"),
        ("classroom", "Classroom"), ("lecture", "Lecture hall"), ("library", "Library"), ("lobby", "Lobby"),
        ("store", "Store"), ("shop", "Store"), ("supermarket", "Supermarket"), ("mall", "Mall"), ("restaurant", "Restaurant"),
        ("cafe", "Cafe"), ("gym", "Gym"), ("garage", "Garage"), ("parking", "Parking lot"), ("street", "Street"),
        ("sidewalk", "Sidewalk"), ("road", "Road"), ("crosswalk", "Crosswalk"), ("park", "Park"), ("garden", "Garden"),
        ("beach", "Beach"), ("forest", "Woods"), ("bridge", "Bridge"), ("platform", "Platform"), ("station", "Station"),
        ("airport", "Airport"), ("bus", "Bus"), ("train", "Train"), ("outdoor", "Outdoors"), ("indoor", "Indoors"),
    ]
    private static let indoorScenes: Set<String> = [
        "Hallway", "Stairwell", "Elevator", "Kitchen", "Bathroom", "Bedroom", "Living room", "Dining room", "Office",
        "Classroom", "Lecture hall", "Library", "Lobby", "Store", "Supermarket", "Mall", "Restaurant", "Cafe", "Gym",
        "Airport", "Bus", "Train", "Indoors",
    ]
    private static let outdoorScenes: Set<String> = [
        "Parking lot", "Street", "Sidewalk", "Road", "Crosswalk", "Park", "Garden", "Beach", "Woods", "Bridge", "Outdoors",
    ]

    /// Wayfinding words worth reading off a sign, and how to say them.
    private static let signWords: [(key: String, name: String)] = [
        ("EMERGENCY EXIT", "Emergency exit"), ("FIRE EXIT", "Emergency exit"), ("EXIT", "Exit"), ("ENTRANCE", "Entrance"),
        ("ENTER", "Entrance"), ("WAY OUT", "Exit"), ("RESTROOM", "Restroom"), ("WASHROOM", "Restroom"), ("TOILET", "Restroom"),
        ("WOMEN", "Women's restroom"), ("LADIES", "Women's restroom"), ("MEN", "Men's restroom"), ("STAIRS", "Stairs"),
        ("STAIRWAY", "Stairs"), ("ELEVATOR", "Elevator"), ("LIFT", "Elevator"), ("ESCALATOR", "Escalator"), ("PUSH", "Push"),
        ("PULL", "Pull"), ("EMERGENCY", "Emergency"), ("CAUTION", "Caution"), ("WET FLOOR", "Wet floor"), ("DANGER", "Danger"),
        ("NO ENTRY", "No entry"), ("DO NOT ENTER", "Do not enter"), ("STOP", "Stop"), ("OPEN", "Open"), ("CLOSED", "Closed"),
        ("RECEPTION", "Reception"), ("INFORMATION", "Information"), ("LOBBY", "Lobby"), ("PARKING", "Parking"),
        ("PLATFORM", "Platform"), ("TICKETS", "Tickets"), ("CHECKOUT", "Checkout"), ("CASHIER", "Checkout"),
        ("ACCESSIBLE", "Accessible"),
    ]

    private static func matches(_ id: String, key: String) -> Bool {
        id == key || id.hasPrefix(key + " ") || id.hasSuffix(" " + key) || id.hasPrefix(key + "_") || id.hasSuffix("_" + key)
            || id.contains(" " + key + " ") || id.contains("_" + key + "_")
    }

    private static func bestName(in observations: [VNClassificationObservation],
                                 table: [(key: String, name: String)],
                                 minimum: Float = 0.2) -> (name: String, confidence: Float)? {
        for observation in observations.prefix(15) where observation.confidence >= minimum {
            let id = observation.identifier.lowercased()
            if let entry = table.first(where: { matches(id, key: $0.key) }) {
                return (entry.name, observation.confidence)
            }
        }
        return nil
    }
}
