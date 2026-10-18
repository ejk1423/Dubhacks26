//
//  Narrator.swift
//  Echo
//
//  Speaks the things a beep cannot: "Step up", "Person ahead on your left", "Stairs
//  ahead". Driven by `SceneSnapshot` (trip hazards), `VisionReport` (people, animals,
//  what the obstacle ahead is) and the sonar closeness. Each kind of line has its own
//  repeat interval so nothing is nagged, and a hazard interrupts whatever is playing.
//

import AVFAudio
import Foundation
import Observation

@Observable
final class Narrator {

    var isEnabled = true
    /// The last thing said, for the HUD.
    private(set) var lastLine: String?
    private(set) var lastLineTime: TimeInterval = 0

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let voice = AVSpeechSynthesisVoice(language: "en-US")
    @ObservationIgnored private var lastSpoken: [String: TimeInterval] = [:]

    // Tuning
    @ObservationIgnored let hazardRepeat: TimeInterval = 4
    @ObservationIgnored let personRepeat: TimeInterval = 6
    @ObservationIgnored let objectRepeat: TimeInterval = 10
    @ObservationIgnored let personRange: Float = 2.5
    @ObservationIgnored let hazardRange: Float = 2.0

    func update(snapshot: SceneSnapshot, vision: VisionReport?, closeness: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        if lastLine != nil, now - lastLineTime > 4 { lastLine = nil }
        guard isEnabled else { return }

        // 1. Trip hazards: the most important thing, and they interrupt.
        if let hazard = snapshot.tripHazards.first(where: { $0.distanceAhead > 0 && $0.distanceAhead <= hazardRange }) {
            let line: String
            switch hazard.kind {
            case .drop: line = "Step down"
            case .bump: line = "Step up"
            case .unknownSurface: line = "Uneven ground"
            }
            if say(line, key: "hazard", every: hazardRepeat, interrupt: true, now: now) { return }
        }

        // 2. People and animals in front.
        if let vision, now - vision.timestamp < 1.0 {
            let ahead = vision.detections
                .filter { abs($0.bearing) <= 0.8 && ($0.distance ?? 0) <= personRange }
                .sorted { ($0.distance ?? 99) < ($1.distance ?? 99) }
            if let nearest = ahead.first {
                var line = "\(nearest.label) ahead"
                if abs(nearest.bearing) > 0.25 { line += nearest.bearing < 0 ? " on your left" : " on your right" }
                if say(line, key: "person", every: personRepeat, now: now) { return }
            }

            // 3. What the obstacle ahead is, once it is close enough to matter.
            if closeness > 0.3, let label = vision.labelAhead, vision.labelConfidence >= 0.3, label != "Person" {
                _ = say("\(label) ahead", key: "object:\(label)", every: objectRepeat, now: now)
            }
        }
    }

    @discardableResult
    private func say(_ text: String, key: String, every interval: TimeInterval, interrupt: Bool = false,
                     now: TimeInterval) -> Bool {
        if let last = lastSpoken[key], now - last < interval { return false }
        if synthesizer.isSpeaking {
            guard interrupt else { return false }
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = 0.52
        utterance.volume = 1
        synthesizer.speak(utterance)
        lastSpoken[key] = now
        lastLine = text
        lastLineTime = now
        return true
    }
}
