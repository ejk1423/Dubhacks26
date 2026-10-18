//
//  HUDPreferences.swift
//  Echo
//
//  Everything the user can set from the HUD, persisted in UserDefaults so the app
//  comes back the way it was left: camera feed, sound toggles and
//  whether the tutorial has been seen.
//

import Foundation
import Observation

nonisolated enum CameraFeedPreference: String, CaseIterable, Hashable, Sendable {
    case full, dimmed, hidden

    var title: String {
        switch self {
        case .full: return "Full"
        case .dimmed: return "Dimmed"
        case .hidden: return "Off"
        }
    }

    var mode: CameraFeedMode {
        switch self {
        case .full: return .full
        case .dimmed: return .dimmed(ev: -2.5)
        case .hidden: return .hidden
        }
    }
}

@Observable
final class HUDPreferences {

    private enum Key {
        static let hasSeenOnboarding = "echo.hasSeenOnboarding"
        static let cameraFeed = "echo.cameraFeed"
        static let beeps = "echo.beeps"
        static let voice = "echo.voice"
        static let haptics = "echo.haptics"
        static let hapticsOnly = "echo.hapticsOnly"
        static let volume = "echo.volume"
    }

    var hasSeenOnboarding: Bool { didSet { defaults.set(hasSeenOnboarding, forKey: Key.hasSeenOnboarding) } }
    var cameraFeed: CameraFeedPreference { didSet { defaults.set(cameraFeed.rawValue, forKey: Key.cameraFeed) } }
    var beeps: Bool { didSet { defaults.set(beeps, forKey: Key.beeps) } }
    var voice: Bool { didSet { defaults.set(voice, forKey: Key.voice) } }
    var haptics: Bool { didSet { defaults.set(haptics, forKey: Key.haptics) } }
    /// Haptic ticks instead of beeps.
    var hapticsOnly: Bool { didSet { defaults.set(hapticsOnly, forKey: Key.hapticsOnly) } }
    var volume: Float { didSet { defaults.set(volume, forKey: Key.volume) } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasSeenOnboarding = defaults.bool(forKey: Key.hasSeenOnboarding)
        cameraFeed = CameraFeedPreference(rawValue: defaults.string(forKey: Key.cameraFeed) ?? "") ?? .full
        beeps = defaults.object(forKey: Key.beeps) as? Bool ?? true
        voice = defaults.object(forKey: Key.voice) as? Bool ?? true
        haptics = defaults.object(forKey: Key.haptics) as? Bool ?? true
        hapticsOnly = defaults.bool(forKey: Key.hapticsOnly)
        volume = defaults.object(forKey: Key.volume) as? Float ?? 0.8
    }
}
