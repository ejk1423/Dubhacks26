//
//  Narrator.swift
//  Echo
//
//  Speaks the things a beep cannot, and only when they are about to matter. Timing is
//  by time-to-reach (distance over the user's walking speed), so a step 2 m away is
//  silent while the user stands still and "Step up" lands about a second and a half
//  before the foot gets there.
//
//  Policy, in order of priority each snapshot:
//    1. Trip hazards in the walking line (always; a two-tone chime precedes the line).
//    2. People or animals walking toward the user (chime), then people in the path.
//    3. Blocked and standing: which side is open.
//    4. Changes: "Path clear" once after an obstacle is passed, "Narrowing" / "Opening up"
//       as the clearance between walls shrinks or grows, "Opening on your left" as a
//       side opens while walking.
//    5. The object about to be reached, by name, and signs with their side.
//  Nothing is repeated while it stays true: every kind of line has its own repeat limit,
//  people are keyed by track so each is announced once, and `verbosity` decides which
//  categories speak and how often. `describe()` and `whereAmI()` speak summaries on
//  demand, ordered by importance, with natural distances ("about a metre", not "110
//  centimetres").
//

import AVFAudio
import Foundation
import Observation
import simd

/// How much the narrator says. Hazards and people walking at the user are always spoken.
enum NarrationVerbosity: String, CaseIterable, Identifiable, Sendable {
    /// Hazards, people in the path, safety signs. Nothing about objects, widths or openings.
    case quiet
    /// Also: the object ahead, blocked-side guidance, path clear, narrowing, signs with side.
    case normal
    /// Also: opening up, side openings while walking, all people nearby, more frequent repeats.
    case verbose

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Multiplier on every repeat interval.
    var repeatScale: Double {
        switch self {
        case .quiet: return 2
        case .normal: return 1
        case .verbose: return 0.7
        }
    }
}

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
    var verbosity: NarrationVerbosity = .normal
    /// Play the two-tone chime before hazard lines (needs a running `SpatialAudioEngine`).
    var earconsEnabled = true
    /// Words per minute-ish: `AVSpeechUtterance.rate`, 0...1.
    var speechRate: Float = 0.52
    /// A specific `AVSpeechSynthesisVoice.identifier`; nil picks the best English voice installed.
    var preferredVoiceIdentifier: String? {
        didSet { voice = Self.bestVoice(identifier: preferredVoiceIdentifier) }
    }
    /// Name and quality of the voice in use, for the settings sheet.
    var voiceDescription: String { Self.describe(voice) }

    /// The last thing said, for the HUD.
    private(set) var lastLine: String?
    private(set) var lastLineTime: TimeInterval = 0
    private(set) var isSpeaking = false
    /// Clearance between the nearest things on the left and right ahead, metres; nil when open.
    private(set) var pathWidth: Float?
    /// True while the clearance ahead is narrow (under `narrowWidth`).
    private(set) var isNarrow = false

    /// The engine used for earcons; `SpatialAudioEngine.current` when not set.
    @ObservationIgnored weak var audio: SpatialAudioEngine?

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var voice: AVSpeechSynthesisVoice?
    @ObservationIgnored private var lastSpoken: [String: TimeInterval] = [:]
    @ObservationIgnored private var delegate: SpeechDelegate?

    // Context state
    @ObservationIgnored private var blockedSince: TimeInterval?
    @ObservationIgnored private var blockedLongEnough = false
    @ObservationIgnored private var clearSince: TimeInterval?
    @ObservationIgnored private var smoothedWidth: Float?
    @ObservationIgnored private var sideOpen: [Bool?] = [nil, nil]          // left, right
    @ObservationIgnored private var sideOpenSince: [TimeInterval?] = [nil, nil]
    @ObservationIgnored private var lastPrune: TimeInterval = 0

    // Tuning
    @ObservationIgnored let hazardLeadTime: Float = 1.5        // seconds before reaching a step
    @ObservationIgnored let hazardMinDistance: Float = 0.5     // or this close, even when still
    @ObservationIgnored let objectLeadTime: Float = 2.0
    @ObservationIgnored let objectMinDistance: Float = 0.7
    @ObservationIgnored let personLeadTime: Float = 2.5
    @ObservationIgnored let personMinDistance: Float = 1.0
    @ObservationIgnored let approachRange: Float = 4.5         // metres; someone walking at you is called this early
    @ObservationIgnored let pathHalfWidth: Float = 0.6         // metres either side of the walking line
    @ObservationIgnored let movingSpeed: Float = 0.15          // m/s; below this the user is standing
    @ObservationIgnored let blockedCloseness: Float = 0.4
    @ObservationIgnored let blockedHold: TimeInterval = 1.2    // seconds blocked before "Path clear" is worth saying
    @ObservationIgnored let narrowWidth: Float = 1.1           // metres between the walls: "Narrowing"
    @ObservationIgnored let wideWidth: Float = 1.7             // and back out: "Opening up"
    @ObservationIgnored let openSide: Float = 2.3              // metres: a side counts as open
    @ObservationIgnored let closedSide: Float = 1.3            // metres: a side counts as closed

    init() {
        voice = Self.bestVoice(identifier: nil)
        delegate = SpeechDelegate { [weak self] in self?.isSpeaking = false }
        synthesizer.delegate = delegate
    }

    // MARK: Per-snapshot narration

    func update(snapshot: SceneSnapshot, vision: VisionReport?, closeness: Float, targetDistance: Float?) {
        let now = ProcessInfo.processInfo.systemUptime
        if lastLine != nil, now - lastLineTime > 4 { lastLine = nil }
        if now - lastPrune > 30 {
            lastPrune = now
            lastSpoken = lastSpoken.filter { now - $0.value < 120 }
        }
        updateWidth(snapshot)
        guard isEnabled else { return }

        let speed = snapshot.walkingSpeed
        let walking = speed >= movingSpeed
        func secondsTo(_ distance: Float) -> Float { walking ? distance / speed : .infinity }
        let fresh = vision.flatMap { now - $0.timestamp < 1.0 ? $0 : nil }
        // State machines run every snapshot; their lines wait their turn below.
        let pathLine = pathChange(closeness: closeness, targetDistance: targetDistance, walking: walking, now: now)
        let sideLine = sideChange(snapshot, now: now)

        // 1. Trip hazards in the walking line, about to be reached.
        if let hazard = snapshot.tripHazards.first(where: {
            $0.distanceAhead > 0 && abs($0.lateralOffset) <= pathHalfWidth
                && ($0.distanceAhead <= hazardMinDistance || secondsTo($0.distanceAhead) <= hazardLeadTime)
        }) {
            // Once per hazard (ids are stable while it stays put), and never two in quick succession.
            if lastSpoken["hazard"].map({ now - $0 >= 3 }) ?? true,
               say(Self.name(hazard.kind), key: "hazard:\(hazard.id)", every: 12, interrupt: true, alert: true, now: now) {
                lastSpoken["hazard"] = now
                return
            }
        }

        // 2. Someone walking toward the user: early, with a chime.
        if let fresh {
            let approaching = fresh.detections
                .filter { $0.movingTowardYou && ($0.distance ?? 99) <= approachRange && abs($0.bearing) <= 0.8 }
                .sorted { ($0.distance ?? 99) < ($1.distance ?? 99) }
            if let who = approaching.first, let id = who.trackID {
                let lateral = who.lateralOffset ?? 0
                let inPath = abs(lateral) <= pathHalfWidth + 0.3
                if inPath || verbosity != .quiet {
                    var line = "\(who.label) coming toward you"
                    if !inPath { line += lateral < 0 ? ", on your left" : ", on your right" }
                    if say(line, key: "approach:\(id)", every: 15, interrupt: true, alert: true, now: now) {
                        lastSpoken["person"] = now
                        return
                    }
                }
            }

            // 3. People and animals in the walking line, about to be reached.
            let inPath = fresh.detections
                .filter { detection in
                    guard let distance = detection.distance, let lateral = detection.lateralOffset else { return false }
                    return abs(lateral) <= pathHalfWidth + 0.2
                        && (distance <= personMinDistance || secondsTo(distance) <= personLeadTime)
                }
                .sorted { ($0.distance ?? 99) < ($1.distance ?? 99) }
            if let nearest = inPath.first, let lateral = nearest.lateralOffset, let distance = nearest.distance,
               lastSpoken["person"].map({ now - $0 >= 4 }) ?? true {
                let key = nearest.trackID.map { "person:\($0)" } ?? "person:\(nearest.label)"
                let justCalled = nearest.trackID.flatMap { lastSpoken["approach:\($0)"] }.map { now - $0 < 8 } ?? false
                if !justCalled {
                    var line = distance < 0.6 ? "\(nearest.label) right in front of you" : "\(nearest.label) ahead"
                    if distance >= 0.6, abs(lateral) > 0.3 { line += lateral < 0 ? ", slightly left" : ", slightly right" }
                    if say(line, key: key, every: 8, now: now) {
                        lastSpoken["person"] = now
                        return
                    }
                }
            }
        }

        // 4. Blocked and standing: say where it is open.
        if let targetDistance, targetDistance <= 0.6, !walking, verbosity != .quiet || closeness > 0.9 {
            if let line = openings(in: snapshot) {
                if say("Blocked. \(line)", key: "blocked", every: 8, now: now) { return }
            }
        }

        // 5. Changes in the path: cleared, narrowing, opening.
        if let change = pathLine {
            if say(change.line, key: change.key, every: change.every, now: now) { return }
        }
        if walking, verbosity != .quiet, let side = sideLine {
            if say(side.line, key: side.key, every: 6, now: now) { return }
        }

        // 6. What the obstacle ahead is, as it is about to be reached.
        if let fresh, closeness > 0.3, let label = fresh.labelAhead, fresh.labelConfidence >= 0.3, label != "Person",
           let targetDistance, targetDistance <= objectMinDistance || secondsTo(targetDistance) <= objectLeadTime,
           verbosity != .quiet || targetDistance <= 0.5,
           lastSpoken["object"].map({ now - $0 >= 5 }) ?? true {
            let line = targetDistance < 0.45 ? "\(label), right in front of you" : "\(label) ahead"
            if say(line, key: "object:\(label)", every: 12, now: now) {
                lastSpoken["object"] = now
                return
            }
        }

        // 7. Signs, with the side they are on.
        if let fresh, let name = fresh.signs.first {
            let sighting = fresh.recentSigns.first { $0.text == name }
            if verbosity != .quiet || sighting?.isSafety == true {
                var line = Self.signPhrase(name)
                if let sighting { line += " " + Self.sideWords(bearing: sighting.bearingAtSighting) }
                _ = say(line, key: "sign:\(name)", every: 25, now: now)
            }
        }
    }

    // MARK: Context tracking

    /// Clearance between the nearest things front-left and front-right, from the fine sectors.
    private func updateWidth(_ snapshot: SceneSnapshot) {
        let clearance = Self.clearance(snapshot)
        let width: Float?
        switch (clearance.left, clearance.right) {
        case (nil, nil): width = nil
        case let (l?, r?): width = l + r
        case let (l?, nil): width = l + 3
        case let (nil, r?): width = 3 + r
        }
        if let width {
            smoothedWidth = smoothedWidth.map { $0 * 0.7 + width * 0.3 } ?? width
        } else {
            smoothedWidth = nil
        }
        pathWidth = smoothedWidth
    }

    /// "Path clear" after an obstacle is passed, "Narrowing" / "Opening up" from the clearance.
    private func pathChange(closeness: Float, targetDistance: Float?, walking: Bool, now: TimeInterval)
        -> (line: String, key: String, every: TimeInterval)? {
        // Blocked -> clear.
        if closeness >= blockedCloseness {
            if blockedSince == nil { blockedSince = now }
            if now - blockedSince! >= blockedHold { blockedLongEnough = true }
            clearSince = nil
        } else {
            blockedSince = nil
            if blockedLongEnough, targetDistance == nil || closeness < 0.1 {
                if clearSince == nil { clearSince = now }
                if now - clearSince! >= 0.5 {
                    blockedLongEnough = false
                    clearSince = nil
                    if verbosity != .quiet { return ("Path clear", "clear", 4) }
                }
            } else {
                clearSince = nil
            }
        }

        // Wide <-> narrow, with hysteresis, only while walking (standing and turning is not a change).
        if let width = smoothedWidth {
            if !isNarrow, width < narrowWidth {
                isNarrow = true
                if walking, verbosity != .quiet { return ("Narrowing", "narrow", 6) }
            } else if isNarrow, width > wideWidth {
                isNarrow = false
                if walking, verbosity == .verbose { return ("Opening up", "wide", 6) }
            }
        } else if isNarrow {
            isNarrow = false
            if walking, verbosity == .verbose { return ("Opening up", "wide", 6) }
        }
        return nil
    }

    /// "Opening on your left" when a side goes from closed to open and stays so for a moment.
    private func sideChange(_ snapshot: SceneSnapshot, now: TimeInterval) -> (line: String, key: String)? {
        let hits = snapshot.fineSectorHits
        guard hits.count == 24 else { return nil }
        func nearest(_ range: ClosedRange<Int>) -> Float {
            range.compactMap { hits[$0]?.horizontalDistance }.min() ?? .infinity
        }
        let sides = [nearest(16...20), nearest(4...8)]   // left, right (90 degrees, give or take 30)
        var result: (String, String)?
        for i in 0..<2 {
            let distance = sides[i]
            if distance >= openSide {
                if sideOpen[i] == false {
                    if sideOpenSince[i] == nil { sideOpenSince[i] = now }
                    if now - sideOpenSince[i]! >= 0.4 {
                        sideOpen[i] = true
                        sideOpenSince[i] = nil
                        if result == nil { result = ("Opening on your \(i == 0 ? "left" : "right")", "open:\(i)") }
                    }
                } else if sideOpen[i] == nil {
                    sideOpen[i] = true
                }
            } else {
                sideOpenSince[i] = nil
                if distance <= closedSide { sideOpen[i] = false }
            }
        }
        return result
    }

    // MARK: On-demand summaries

    /// What matters right now, most important first: hazards, people, what is ahead, open
    /// sides, signs, and the kind of place.
    func describe(snapshot: SceneSnapshot?, vision: VisionReport?) {
        guard let snapshot else {
            speak("Not ready yet.", interrupt: true)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let fresh = vision.flatMap { now - $0.timestamp < 1.5 ? $0 : nil }
        var urgent: [String] = []
        var parts: [String] = []

        if let hazard = snapshot.tripHazards.first(where: { $0.distanceAhead > 0 && $0.distanceAhead <= 3 }) {
            let side = abs(hazard.lateralOffset) > 0.5 ? (hazard.lateralOffset < 0 ? " on your left" : " on your right") : ""
            urgent.append(Self.phrase(Self.name(hazard.kind), at: hazard.distanceAhead, side: side.isEmpty ? " ahead" : side))
        }

        let people = (fresh?.detections ?? []).filter { $0.distance != nil && abs($0.bearing) <= 1.3 }
            .sorted { ($0.distance ?? 99) < ($1.distance ?? 99) }
        if let nearest = people.first, let distance = nearest.distance {
            let what = nearest.movingTowardYou ? "\(nearest.label) coming toward you" : nearest.label
            let line = Self.phrase(what, at: distance, side: " " + Self.sideWords(bearing: nearest.bearing))
            if nearest.movingTowardYou || distance < 1.5 { urgent.append(line) } else { parts.append(line) }
            let others = people.count - 1
            if others > 0 { parts.append(others == 1 ? "One more person nearby." : "\(others) more people nearby.") }
        }

        if let ahead = snapshot.nearestForwardObstacle {
            var what = "Something"
            if let label = fresh?.labelAhead, (fresh?.labelConfidence ?? 0) >= 0.3, label != "Person" { what = label }
            else if ahead.bucket == .wall { what = "Wall" }
            parts.append(Self.phrase(what, at: ahead.horizontalDistance, side: " ahead"))
        } else if snapshot.sectorDistances.count == 8, snapshot.sectorDistances[0].isFinite,
                  let distance = Self.spoken(snapshot.sectorDistances[0]) {
            parts.append("Clear ahead for \(distance).")
        } else {
            parts.append("Clear ahead.")
        }

        if let openings = openings(in: snapshot) { parts.append(openings + ".") }
        if let width = smoothedWidth, width < 2.5 { parts.append("About \(Self.spokenWidth(width)) wide.") }

        if let sign = fresh?.lastSign ?? vision?.lastSign, now - sign.timestamp < 60 {
            parts.append(Self.signSummary(sign, snapshot: snapshot, now: now))
        }

        var scene: String?
        if let name = fresh?.scene ?? vision?.scene { scene = Self.scenePhrase(name) }
        var all = urgent + parts
        if let scene {
            if urgent.isEmpty { all.insert(scene, at: 0) } else { all.append(scene) }
        }
        speak(all.joined(separator: " "), interrupt: true)
    }

    /// The kind of place, how wide it is, which sides are open, and the last sign seen.
    func whereAmI(snapshot: SceneSnapshot?, vision: VisionReport?) {
        guard let snapshot else {
            speak("Not ready yet.", interrupt: true)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        var parts: [String] = []

        if let name = vision?.scene {
            var line = Self.scenePhrase(name)
            if let width = smoothedWidth, width < 4 {
                line.removeLast()
                line += ", about \(Self.spokenWidth(width)) wide."
            }
            parts.append(line)
        } else if let indoors = vision?.isIndoors {
            parts.append(indoors ? "Indoors." : "Outdoors.")
        } else if let width = smoothedWidth, width < 4 {
            parts.append("A space about \(Self.spokenWidth(width)) wide.")
        }

        // Which sides are open, and what is on the closed ones.
        let sectors = snapshot.sectorDistances
        if sectors.count == 8 {
            let sides: [(name: String, distance: Float, range: ClosedRange<Int>)] = [
                ("ahead", sectors[0], 22...25),           // fine sectors wrap: 22, 23, 0, 1
                ("on your right", min(sectors[1], sectors[2]), 4...8),
                ("on your left", min(sectors[6], sectors[7]), 16...20),
                ("behind you", min(sectors[3], sectors[4], sectors[5]), 10...14),
            ]
            let open = sides.filter { $0.distance > openSide }.map(\.name)
            if !open.isEmpty {
                parts.append("Open " + Self.list(open) + ".")
            }
            for side in sides where side.distance <= openSide {
                let what = Self.thing(in: side.range, of: snapshot) ?? "Something"
                parts.append(Self.phrase(what, at: side.distance, side: " " + side.name))
            }
        }

        let people = (vision?.detections ?? []).filter { $0.distance != nil }
        if !people.isEmpty {
            parts.append(people.count == 1 ? "One person nearby." : "\(people.count) people nearby.")
        }

        if let sign = vision?.lastSign, now - sign.timestamp < 90 {
            parts.append(Self.signSummary(sign, snapshot: snapshot, now: now))
        }

        if parts.isEmpty { parts.append("Not sure yet. Look around a little.") }
        speak(parts.joined(separator: " "), interrupt: true)
    }

    /// Speak a line now (HUD confirmations and the like).
    func announce(_ text: String) {
        speak(text, interrupt: true)
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    // MARK: Geometry helpers

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

    /// Lateral distance to the nearest thing on each side of the walking line, from the
    /// fine sectors between 15 and 90 degrees. nil when that side is open.
    private static func clearance(_ snapshot: SceneSnapshot) -> (left: Float?, right: Float?) {
        let hits = snapshot.fineSectorHits
        guard hits.count == 24 else { return (nil, nil) }
        var left: Float?, right: Float?
        for i in 1...6 {
            let angle = Float(i) * 15 * .pi / 180
            if let hit = hits[i] { right = min(right ?? .infinity, hit.horizontalDistance * sin(angle)) }
            if let hit = hits[24 - i] { left = min(left ?? .infinity, hit.horizontalDistance * sin(angle)) }
        }
        return (left, right)
    }

    /// "Wall", "Furniture" or nil for the nearest fine-sector hit in `range` (indices wrap past 23).
    private static func thing(in range: ClosedRange<Int>, of snapshot: SceneSnapshot) -> String? {
        let hits = snapshot.fineSectorHits
        guard hits.count == 24 else { return nil }
        let nearest = range.compactMap { hits[$0 % 24] }.min { $0.horizontalDistance < $1.horizontalDistance }
        switch nearest?.bucket {
        case .wall: return "Wall"
        case .furniture: return "Furniture"
        default: return nil
        }
    }

    // MARK: Phrasing

    private static func name(_ kind: TripHazardKind) -> String {
        switch kind {
        case .drop: return "Step down"
        case .bump: return "Step up"
        case .unknownSurface: return "Uneven ground"
        }
    }

    /// Natural distance words, nil inside arm's reach (say "right in front of you" instead).
    static func spoken(_ metres: Float) -> String? {
        switch metres {
        case ..<0.45: return nil
        case ..<0.8: return "half a metre"
        case ..<1.3: return "about a metre"
        case ..<1.8: return "a metre and a half"
        case ..<2.6: return "two metres"
        case ..<3.6: return "three metres"
        case ..<4.6: return "four metres"
        case ..<5.6: return "five metres"
        default: return "\(Int(metres.rounded())) metres"
        }
    }

    private static func spokenWidth(_ metres: Float) -> String {
        switch metres {
        case ..<0.8: return "half a metre"
        case ..<1.3: return "a metre"
        case ..<1.8: return "a metre and a half"
        case ..<2.6: return "two metres"
        case ..<3.6: return "three metres"
        default: return "\(Int(metres.rounded())) metres"
        }
    }

    /// "Chair about a metre ahead." / "Chair right in front of you." / "Wall half a metre on your left."
    private static func phrase(_ what: String, at metres: Float, side: String) -> String {
        guard let distance = spoken(metres) else {
            return side.hasSuffix("ahead") ? "\(what) right in front of you." : "\(what) right beside you\(side)."
        }
        return "\(what) \(distance)\(side)."
    }

    /// "ahead", "ahead, slightly left", "on your right", "behind you, to the left".
    static func sideWords(bearing: Float) -> String {
        let side = bearing < 0 ? "left" : "right"
        switch abs(bearing) {
        case ..<0.25: return "ahead"
        case ..<0.6: return "ahead, slightly \(side)"
        case ..<1.25: return "on your \(side)"
        case ..<2.4: return "behind you, to the \(side)"
        default: return "behind you"
        }
    }

    private static func signPhrase(_ name: String) -> String {
        name.hasPrefix("Room") || name.hasPrefix("Suite") ? name : "\(name) sign"
    }

    /// "Exit sign on your right." / "Exit sign was on your left, a moment ago."
    private static func signSummary(_ sign: SignSighting, snapshot: SceneSnapshot, now: TimeInterval) -> String {
        let bearing = sign.bearing(from: snapshot.cameraPosition, heading: snapshot.heading)
        let age = now - sign.timestamp
        let place = sideWords(bearing: bearing)
        if age < 3 { return "\(signPhrase(sign.text)) \(place)." }
        let ago: String
        switch age {
        case ..<12: ago = "a moment ago"
        case ..<40: ago = "about \(Int((age / 5).rounded() * 5)) seconds ago"
        default: ago = "a while ago"
        }
        return "\(signPhrase(sign.text)) was \(place), \(ago)."
    }

    private static func scenePhrase(_ scene: String) -> String {
        switch scene {
        case "Outdoors", "Indoors": return "\(scene)."
        case "Street", "Sidewalk", "Road", "Crosswalk", "Bridge", "Platform", "Beach", "Woods": return "On a \(scene.lowercased())."
        case "Bus", "Train": return "On a \(scene.lowercased())."
        default:
            let article = "AEIOU".contains(scene.first!) ? "an" : "a"
            return "You're in \(article) \(scene.lowercased())."
        }
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }

    // MARK: Speech

    @discardableResult
    private func say(_ text: String, key: String, every interval: TimeInterval, interrupt: Bool = false,
                     alert: Bool = false, now: TimeInterval) -> Bool {
        if let last = lastSpoken[key], now - last < interval * verbosity.repeatScale { return false }
        if synthesizer.isSpeaking && !interrupt { return false }
        speak(text, interrupt: interrupt, alert: alert)
        lastSpoken[key] = now
        return true
    }

    private func speak(_ text: String, interrupt: Bool, alert: Bool = false) {
        if interrupt, synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = speechRate
        utterance.volume = 1
        if alert, earconsEnabled, let engine = audio ?? SpatialAudioEngine.current {
            utterance.preUtteranceDelay = engine.playAlertEarcon() + 0.05
        }
        synthesizer.speak(utterance)
        lastLine = text
        lastLineTime = ProcessInfo.processInfo.systemUptime
        isSpeaking = true
    }

    // MARK: Voice

    /// English voices installed, best first (premium, then enhanced, then compact; en-US first).
    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { rank($0) > rank($1) }
    }

    private static func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        var score = 0
        switch voice.quality {
        case .premium: score += 300
        case .enhanced: score += 200
        default: score += 100
        }
        if voice.language == "en-US" { score += 30 }
        else if voice.language == "en-GB" || voice.language == "en-AU" { score += 20 }
        // Novelty voices (Bells, Bubbles, ...) and the old screen-reader compact voices read badly.
        if voice.identifier.contains("synthesis.voice") || voice.identifier.contains("eloquence") { score -= 150 }
        return score
    }

    private static func bestVoice(identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let chosen = AVSpeechSynthesisVoice(identifier: identifier) { return chosen }
        return englishVoices().first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private static func describe(_ voice: AVSpeechSynthesisVoice?) -> String {
        guard let voice else { return "System voice" }
        let quality: String
        switch voice.quality {
        case .premium: quality = "premium"
        case .enhanced: quality = "enhanced"
        default: quality = "compact"
        }
        return "\(voice.name) (\(quality))"
    }
}
