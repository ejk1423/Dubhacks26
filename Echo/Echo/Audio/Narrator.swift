//
//  Narrator.swift
//  Echo
//
//  Speaks the things a beep cannot, and only when they are about to matter. Timing is
//  by time-to-reach (distance over the user's walking speed), so a step 2 m away is
//  silent while the user stands still and "Step up" lands about a second and a half
//  before the foot gets there. Each kind of line has its own repeat limit, hazards
//  interrupt everything else, and `describe()` speaks a summary of the surroundings on
//  demand: scene, what is ahead and how far, which sides are open, people, hazards, signs.
//

import AVFAudio
import Foundation
import Observation
import simd

/// Relays synthesizer callbacks (which arrive off the main actor) back to the narrator.
nonisolated private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let onFinished: @MainActor @Sendable () -> Void
    init(onFinished: @escaping @MainActor @Sendable () -> Void) { self.onFinished = onFinished }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let onFinished = onFinished
        Task { @MainActor in onFinished() }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let onFinished = onFinished
        Task { @MainActor in onFinished() }
    }
}

@Observable
final class Narrator {

    var isEnabled = true
    /// The last thing said, for the HUD.
    private(set) var lastLine: String?
    private(set) var lastLineTime: TimeInterval = 0
    private(set) var isSpeaking = false

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let voice = AVSpeechSynthesisVoice(language: "en-US")
    @ObservationIgnored private var lastSpoken: [String: TimeInterval] = [:]
    @ObservationIgnored private var delegate: SpeechDelegate?

    // Tuning
    @ObservationIgnored let hazardLeadTime: Float = 1.5        // seconds before reaching a step
    @ObservationIgnored let hazardMinDistance: Float = 0.5     // or this close, even when still
    @ObservationIgnored let objectLeadTime: Float = 2.0
    @ObservationIgnored let objectMinDistance: Float = 0.7
    @ObservationIgnored let personLeadTime: Float = 2.5
    @ObservationIgnored let personMinDistance: Float = 1.0
    @ObservationIgnored let pathHalfWidth: Float = 0.6         // metres either side of the walking line
    @ObservationIgnored let movingSpeed: Float = 0.15          // m/s; below this the user is standing

    init() {
        delegate = SpeechDelegate { [weak self] in self?.isSpeaking = false }
        synthesizer.delegate = delegate
    }

    // MARK: Per-snapshot narration

    func update(snapshot: SceneSnapshot, vision: VisionReport?, closeness: Float, targetDistance: Float?) {
        let now = ProcessInfo.processInfo.systemUptime
        if lastLine != nil, now - lastLineTime > 4 { lastLine = nil }
        guard isEnabled else { return }

        let speed = snapshot.walkingSpeed
        func secondsTo(_ distance: Float) -> Float { speed >= movingSpeed ? distance / speed : .infinity }

        // 1. Trip hazards in the walking line, about to be reached.
        if let hazard = snapshot.tripHazards.first(where: {
            $0.distanceAhead > 0 && abs($0.lateralOffset) <= pathHalfWidth
                && ($0.distanceAhead <= hazardMinDistance || secondsTo($0.distanceAhead) <= hazardLeadTime)
        }) {
            let line: String
            switch hazard.kind {
            case .drop: line = "Step down"
            case .bump: line = "Step up"
            case .unknownSurface: line = "Careful, uneven ground"
            }
            if say(line, key: "hazard", every: 4, interrupt: true, now: now) { return }
        }

        let fresh = vision.flatMap { now - $0.timestamp < 1.0 ? $0 : nil }

        // 2. People and animals in the walking line.
        if let fresh {
            let inPath = fresh.detections
                .filter { detection in
                    guard let distance = detection.distance, let lateral = detection.lateralOffset else { return false }
                    return abs(lateral) <= pathHalfWidth + 0.2
                        && (distance <= personMinDistance || secondsTo(distance) <= personLeadTime)
                }
                .sorted { ($0.distance ?? 99) < ($1.distance ?? 99) }
            if let nearest = inPath.first, let lateral = nearest.lateralOffset {
                var line = "\(nearest.label) ahead"
                if abs(lateral) > 0.3 { line += lateral < 0 ? ", slightly left" : ", slightly right" }
                if say(line, key: "person", every: 6, now: now) { return }
            }
        }

        // 3. Blocked and standing: say where it is open.
        if let targetDistance, targetDistance <= 0.6, speed < movingSpeed {
            if let line = openings(in: snapshot) {
                if say("Blocked. \(line)", key: "blocked", every: 8, now: now) { return }
            }
        }

        // 4. What the obstacle ahead is, as it is about to be reached.
        if let fresh, closeness > 0.3, let label = fresh.labelAhead, fresh.labelConfidence >= 0.3, label != "Person",
           let targetDistance, targetDistance <= objectMinDistance || secondsTo(targetDistance) <= objectLeadTime {
            if say("\(label) ahead", key: "object:\(label)", every: 10, now: now) { return }
        }

        // 5. Signs.
        if let fresh, let sign = fresh.signs.first {
            _ = say("Sign: \(sign.capitalized)", key: "sign:\(sign)", every: 20, now: now)
        }
    }

    // MARK: On-demand summary

    func describe(snapshot: SceneSnapshot?, vision: VisionReport?) {
        guard let snapshot else {
            speak("Not ready yet.", interrupt: true)
            return
        }
        var parts: [String] = []
        if let scene = vision?.scene { parts.append(scene + ".") }

        if let ahead = snapshot.nearestForwardObstacle {
            var what = "Something"
            if let label = vision?.labelAhead, (vision?.labelConfidence ?? 0) >= 0.3 { what = label }
            parts.append("\(what) \(Self.spoken(ahead.horizontalDistance)) ahead.")
        } else {
            parts.append("Clear ahead.")
        }

        if let openings = openings(in: snapshot) { parts.append(openings + ".") }

        let people = (vision?.detections ?? []).filter { $0.distance != nil && abs($0.bearing) <= 1.2 }
            .sorted { ($0.distance ?? 99) < ($1.distance ?? 99) }
        if let nearest = people.first, let distance = nearest.distance {
            let side = abs(nearest.bearing) > 0.35 ? (nearest.bearing < 0 ? " on your left" : " on your right") : " ahead"
            parts.append("\(nearest.label) \(Self.spoken(distance))\(side).")
            if people.count > 1 { parts.append("\(people.count) people in view.") }
        }

        if let hazard = snapshot.tripHazards.first {
            let name: String
            switch hazard.kind {
            case .drop: name = "Step down"
            case .bump: name = "Step up"
            case .unknownSurface: name = "Uneven ground"
            }
            parts.append("\(name) \(Self.spoken(hazard.distanceAhead)) ahead.")
        }

        if let signs = vision?.signs, !signs.isEmpty {
            parts.append("Sign: " + signs.prefix(2).map { $0.capitalized }.joined(separator: ", ") + ".")
        }

        speak(parts.joined(separator: " "), interrupt: true)
    }

    /// "Open on your left" / "Open on both sides" / "Turn around", from the coarse sectors.
    private func openings(in snapshot: SceneSnapshot) -> String? {
        let sectors = snapshot.sectorDistances
        guard sectors.count == 8 else { return nil }
        let left = min(sectors[6], sectors[7])
        let right = min(sectors[1], sectors[2])
        let behind = min(sectors[3], sectors[4], sectors[5])
        let open: Float = 1.5
        switch (left > open, right > open) {
        case (true, true): return "Open on both sides"
        case (true, false): return "Open on your left"
        case (false, true): return "Open on your right"
        case (false, false): return behind > open ? "Turn around" : nil
        }
    }

    // MARK: Speech

    @discardableResult
    private func say(_ text: String, key: String, every interval: TimeInterval, interrupt: Bool = false,
                     now: TimeInterval) -> Bool {
        if let last = lastSpoken[key], now - last < interval { return false }
        if synthesizer.isSpeaking && !interrupt { return false }
        speak(text, interrupt: interrupt)
        lastSpoken[key] = now
        return true
    }

    private func speak(_ text: String, interrupt: Bool) {
        if interrupt, synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = 0.52
        utterance.volume = 1
        synthesizer.speak(utterance)
        lastLine = text
        lastLineTime = ProcessInfo.processInfo.systemUptime
        isSpeaking = true
    }

    private static func spoken(_ metres: Float) -> String {
        metres < 0.95 ? "\(Int((metres * 10).rounded() * 10)) centimetres" : String(format: "%.1f metres", metres)
    }
}
