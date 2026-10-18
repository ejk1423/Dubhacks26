//
//  ProximityState.swift
//  Echo
//
//  One value that sums up the way ahead for the HUD: what to say, which of the three
//  colours to use, how far. Derived from the audio engine's target (the same thing
//  the beeps follow) and the first trip hazard, so the screen never disagrees with
//  the sound. `StatusAnnouncer` turns changes of it into VoiceOver announcements.
//

import SwiftUI
import UIKit

nonisolated enum ProximityLevel: Equatable, Sendable {
    case inactive, clear, caution, danger
}

nonisolated struct ProximityState: Equatable, Sendable {

    enum Kind: Equatable, Sendable {
        case starting
        case clear
        case ahead          // something in the cone, still far
        case slow           // closing in
        case stop           // at contact
        case hazard(TripHazardKind)
    }

    let kind: Kind
    /// Metres to the target or hazard, nil when the cone is clear.
    let distance: Float?
    /// 0 (nothing in range) ... 1 (at contact).
    let closeness: Float

    static func make(running: Bool, hazard: TripHazard?, closeness: Float, distance: Float?) -> ProximityState {
        guard running else { return ProximityState(kind: .starting, distance: nil, closeness: 0) }
        if let hazard {
            return ProximityState(kind: .hazard(hazard.kind), distance: hazard.distanceAhead, closeness: closeness)
        }
        guard let distance else { return ProximityState(kind: .clear, distance: nil, closeness: 0) }
        switch closeness {
        case ..<0.4: return ProximityState(kind: .ahead, distance: distance, closeness: closeness)
        case ..<0.85: return ProximityState(kind: .slow, distance: distance, closeness: closeness)
        default: return ProximityState(kind: .stop, distance: distance, closeness: closeness)
        }
    }

    var level: ProximityLevel {
        switch kind {
        case .starting: return .inactive
        case .clear: return .clear
        case .ahead, .slow: return .caution
        case .stop, .hazard: return .danger
        }
    }

    /// The one big word on screen.
    var title: String {
        switch kind {
        case .starting: return "Starting"
        case .clear: return "Clear ahead"
        case .ahead: return "Something ahead"
        case .slow: return "Slow down"
        case .stop: return "Stop"
        case .hazard(.bump): return "Step up"
        case .hazard(.drop): return "Step down"
        case .hazard(.unknownSurface): return "Uneven ground"
        }
    }

    /// Symbol shown in the gauge when there is no distance to show.
    var symbol: String? {
        switch kind {
        case .starting: return "ellipsis"
        case .clear: return "checkmark"
        case .hazard(.bump): return "arrow.up.to.line"
        case .hazard(.drop): return "arrow.down.to.line"
        case .hazard(.unknownSurface): return "questionmark"
        case .ahead, .slow, .stop: return nil
        }
    }

    /// Continuous colour: green far away, amber in the middle, red at contact.
    var color: Color {
        switch kind {
        case .starting: return Theme.inactive
        case .clear: return Theme.clear
        case .hazard: return Theme.danger
        case .ahead, .slow, .stop: return Theme.proximityColor(closeness: closeness)
        }
    }

    /// How strongly the screen edge glows in `color`.
    var glowStrength: Double {
        switch kind {
        case .starting, .clear: return 0
        case .hazard: return 0.55
        case .ahead, .slow, .stop: return Double(closeness * closeness) * 0.9
        }
    }

    var accessibilityLabel: String {
        switch kind {
        case .starting: return "Starting up"
        case .clear: return "Clear ahead"
        case .ahead: return "Obstacle \(Self.spoken(distance)) ahead"
        case .slow: return "Slow down. Obstacle \(Self.spoken(distance)) ahead"
        case .stop: return "Stop. Obstacle \(Self.spoken(distance)) ahead"
        case .hazard: return "\(title), \(Self.spoken(distance)) ahead"
        }
    }

    static func spoken(_ metres: Float?) -> String {
        guard let metres else { return "" }
        if metres < 0.95 { return "\(Int((metres * 10).rounded() * 10)) centimetres" }
        return String(format: "%.1f metres", metres)
    }
}

// MARK: - VoiceOver announcements

/// Posts the proximity state to VoiceOver when it changes in a way that matters,
/// never more often than every couple of seconds unless the news is urgent (stop,
/// step). Distances alone are not announced: the beeps and the gauge carry those.
final class StatusAnnouncer {
    private var lastKind: ProximityState.Kind?
    private var lastTime: TimeInterval = 0
    private let minimumInterval: TimeInterval = 2.5

    func consider(_ state: ProximityState) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        guard state.kind != lastKind else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let urgent: Bool
        switch state.kind {
        case .stop, .hazard: urgent = true
        default: urgent = false
        }
        // Clear <-> ahead flips every few hundred milliseconds while walking along a wall;
        // let those settle instead of reading each one out.
        if !urgent, now - lastTime < minimumInterval { return }
        lastKind = state.kind
        lastTime = now
        UIAccessibility.post(notification: .announcement, argument: state.accessibilityLabel)
    }

    func announce(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}
