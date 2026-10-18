//
//  SpatialAudioEngine.swift
//  Echo
//
//  Collision warning for headphones, driven by `SceneSnapshot`s. Silence is the normal
//  state: a sound only plays for something in the walking corridor that the user is
//  actually closing in on (or that is already within arm's reach).
//
//    * Wall ping: a descending sonar chirp from the bearing of the obstacle in the
//      corridor, in three distance zones (slow / medium / fast). Also a haptic tick.
//    * Hazard: a low rising double-tone from the bearing of a trip hazard ahead,
//      repeated every `hazardRepeat` while it is still there.
//
//  Direction is rendered here, not by the system spatialiser: each cue is mixed to
//  stereo with the three cues the ear actually uses to lateralise a sound, pushed well
//  past natural strength so small bearings are still obvious:
//    - interaural level difference (the far ear is up to `maxILD` quieter),
//    - interaural time difference (the far ear is up to `maxITD` later),
//    - head shadow (the far ear is low-passed).
//  Bearings are multiplied by `azimuthGain` and clamped to the sides, so 45 degrees
//  already sounds fully to one side. Generic HRTF rendering was tried twice and was
//  too smeared to place; this is crisper and does not depend on a personalised profile.
//
//  The session is `.playback` on purpose: `.playAndRecord` would drop AirPods to the
//  mono hands-free profile and destroy the stereo cues. Bluetooth route changes stop
//  `AVAudioEngine`, so configuration-change, route-change and interruption
//  notifications all rebuild the graph and restart it.
//

import AVFAudio
import Foundation
import Observation
import UIKit
import simd
import os

@Observable
final class SpatialAudioEngine {

    // MARK: Observable state (read by the HUD)

    var isMuted = false
    var hapticsEnabled = true
    private(set) var isRunning = false
    private(set) var headphonesConnected = false
    /// Bearing of the last cue in radians (right positive), for the HUD. Nil when quiet.
    private(set) var lastCueAzimuth: Float?
    private(set) var lastCueTime: TimeInterval = 0

    // MARK: Tuning

    /// Ping zones for the obstacle in the corridor: (max distance in metres, seconds between pings).
    @ObservationIgnored let wallZones: [(distance: Float, interval: TimeInterval)] = [
        (0.3, 0.2),
        (0.45, 0.5),
        (0.7, 1.2),
    ]
    var alertRange: Float { wallZones.last!.distance }
    @ObservationIgnored let imminentRange: Float = 0.3          // always ping inside this, moving or not
    @ObservationIgnored let closingSpeedThreshold: Float = 0.15 // m/s toward the obstacle before pinging
    @ObservationIgnored let hazardRange: Float = 1.5            // metres ahead
    @ObservationIgnored let hazardRepeat: TimeInterval = 2.0

    @ObservationIgnored let azimuthGain: Float = 2.0            // 45 degrees off-centre renders fully to the side
    @ObservationIgnored let maxILD: Float = 20                  // dB quieter in the far ear at full side
    @ObservationIgnored let maxITD: Double = 0.0007             // seconds later in the far ear at full side
    @ObservationIgnored let shadowCutoff: Double = 1_200        // Hz low-pass on the far ear at full side

    // MARK: Audio graph

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let wallPlayer = AVAudioPlayerNode()
    @ObservationIgnored private let hazardPlayer = AVAudioPlayerNode()
    @ObservationIgnored private let stereo: AVAudioFormat
    @ObservationIgnored private let wallPing: [Float]
    @ObservationIgnored private let hazardTone: [Float]
    @ObservationIgnored private let haptic = UIImpactFeedbackGenerator(style: .rigid)
    @ObservationIgnored private let logger = Logger(subsystem: "echo.audio", category: "SpatialAudioEngine")

    // MARK: Scheduling

    @ObservationIgnored private var snapshot: SceneSnapshot?
    @ObservationIgnored private var snapshotTime: TimeInterval = 0
    @ObservationIgnored private var lastWallPing: TimeInterval = 0
    @ObservationIgnored private var lastHazardTone: TimeInterval = 0
    @ObservationIgnored private var hazardPlayingUntil: TimeInterval = 0
    @ObservationIgnored private var forwardHistory: [(time: TimeInterval, distance: Float)] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    // MARK: Init

    init() {
        stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let rate = stereo.sampleRate
        wallPing = Self.chirp(rate: rate, from: 2_400, to: 900, duration: 0.07, decay: 0.025)
        hazardTone = Self.chirp(rate: rate, from: 380, to: 620, duration: 0.09, decay: 0.08)
            + [Float](repeating: 0, count: Int(0.07 * rate))
            + Self.chirp(rate: rate, from: 380, to: 620, duration: 0.09, decay: 0.08)

        engine.attach(wallPlayer)
        engine.attach(hazardPlayer)
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observeSystemEvents()
        restartEngine()
        haptic.prepare()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        wallPlayer.stop()
        hazardPlayer.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Feed every analysis result here (`ARLiDARManager.onSnapshot`).
    func update(snapshot: SceneSnapshot) {
        self.snapshot = snapshot
        snapshotTime = ProcessInfo.processInfo.systemUptime

        // Closing speed on the corridor obstacle, from the last ~0.6 s of readings.
        if let d = snapshot.nearestForwardObstacle?.horizontalDistance {
            forwardHistory.append((snapshot.timestamp, d))
            forwardHistory.removeAll { snapshot.timestamp - $0.time > 0.6 }
        } else {
            forwardHistory.removeAll()
        }
    }

    /// Metres per second toward the corridor obstacle (negative when backing away).
    var closingSpeed: Float {
        guard let first = forwardHistory.first, let last = forwardHistory.last,
              last.time - first.time >= 0.25 else { return 0 }
        return (first.distance - last.distance) / Float(last.time - first.time)
    }

    // MARK: Engine

    private func restartEngine() {
        guard isRunning else { return }
        engine.stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            updateRoute()

            engine.connect(wallPlayer, to: engine.mainMixerNode, format: stereo)
            engine.connect(hazardPlayer, to: engine.mainMixerNode, format: stereo)
            engine.prepare()
            try engine.start()
            wallPlayer.play()
            hazardPlayer.play()
            logger.info("Audio engine running on \(session.currentRoute.outputs.map(\.portName).joined(separator: ", "), privacy: .public)")
        } catch {
            logger.error("Audio engine failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateRoute() {
        let headphonePorts: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .usbAudio]
        let connected = AVAudioSession.sharedInstance().currentRoute.outputs.contains { headphonePorts.contains($0.portType) }
        if headphonesConnected != connected { headphonesConnected = connected }
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        // AirPods connecting/disconnecting changes the hardware format and stops the engine.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngine() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateRoute()
                if !self.engine.isRunning { self.restartEngine() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended else { return }
            MainActor.assumeIsolated { self?.restartEngine() }
        })
    }

    // MARK: Cues

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if lastCueAzimuth != nil, now - lastCueTime > 1.0 { lastCueAzimuth = nil }
        // Stale snapshot means the AR session stopped: stay silent rather than repeat old news.
        guard !isMuted, engine.isRunning, let snap = snapshot, now - snapshotTime < 0.5 else { return }

        // Trip hazards take priority.
        if let hazard = snap.tripHazards.first(where: { $0.distanceAhead > 0 && $0.distanceAhead <= hazardRange }),
           now - lastHazardTone >= hazardRepeat {
            let azimuth = bearing(of: hazard.position, in: snap)
            hazardPlayer.scheduleBuffer(render(hazardTone, azimuth: azimuth, gain: 0.9), completionHandler: nil)
            lastHazardTone = now
            hazardPlayingUntil = now + Double(hazardTone.count) / stereo.sampleRate + 0.1
            noteCue(azimuth, at: now, hapticIntensity: 1)
        }
        guard now >= hazardPlayingUntil else { return }   // don't talk over the hazard alert

        // Only the obstacle in the walking corridor, and only when we are actually heading
        // into it: closing on it, or already inside arm's reach.
        guard let wall = snap.nearestForwardObstacle, wall.horizontalDistance <= alertRange,
              wall.horizontalDistance <= imminentRange || closingSpeed >= closingSpeedThreshold,
              let zone = wallZones.first(where: { wall.horizontalDistance <= $0.distance }),
              now - lastWallPing >= zone.interval else { return }

        let azimuth = bearing(of: wall.point, in: snap)
        let closeness = 1 - wall.horizontalDistance / alertRange
        wallPlayer.scheduleBuffer(render(wallPing, azimuth: azimuth, gain: 0.5 + 0.5 * closeness), completionHandler: nil)
        lastWallPing = now
        noteCue(azimuth, at: now, hapticIntensity: 0.4 + 0.6 * closeness)
    }

    private func noteCue(_ azimuth: Float, at time: TimeInterval, hapticIntensity: Float) {
        lastCueAzimuth = azimuth
        lastCueTime = time
        if hapticsEnabled { haptic.impactOccurred(intensity: CGFloat(hapticIntensity)) }
    }

    /// Horizontal bearing of `point` from the walking heading, radians, right positive.
    private func bearing(of point: SIMD3<Float>, in snap: SceneSnapshot) -> Float {
        let heading = snap.heading
        let right = simd_normalize(simd_cross(heading, SIMD3(0, 1, 0)))
        let d = point - snap.cameraPosition
        return atan2(d.x * right.x + d.z * right.z, d.x * heading.x + d.z * heading.z)
    }

    // MARK: Stereo rendering

    /// Mixes a mono cue to stereo at `azimuth` using exaggerated level, time and
    /// head-shadow differences between the ears.
    private func render(_ mono: [Float], azimuth: Float, gain: Float) -> AVAudioPCMBuffer {
        let rate = stereo.sampleRate
        let lateral = sin(max(-.pi / 2, min(.pi / 2, azimuth * azimuthGain)))   // -1 (left) ... 1 (right)
        let side = abs(lateral)

        let farGain = pow(10, -maxILD * side / 20)
        let farDelay = Int(maxITD * Double(side) * rate)
        let cutoff = 20_000 - (20_000 - shadowCutoff) * Double(side)
        let alpha = Float(1 - exp(-2 * .pi * cutoff / rate))

        let frames = mono.count + farDelay
        let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let near = buffer.floatChannelData![lateral < 0 ? 0 : 1]
        let far = buffer.floatChannelData![lateral < 0 ? 1 : 0]

        var shadowed: Float = 0
        for i in 0..<frames {
            near[i] = i < mono.count ? mono[i] * gain : 0
            let delayed = i - farDelay
            let x = delayed >= 0 && delayed < mono.count ? mono[delayed] : 0
            shadowed += alpha * (x - shadowed)
            far[i] = shadowed * farGain * gain
        }
        return buffer
    }

    // MARK: Sounds

    /// A sine sweep from `from` to `to` Hz with a 2 ms attack and exponential decay.
    private static func chirp(rate: Double, from: Double, to: Double, duration: Double, decay: Double) -> [Float] {
        let n = Int(duration * rate)
        let attack = Int(0.002 * rate)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let u = Double(i) / Double(n)
            let f = from + (to - from) * u
            phase += 2 * .pi * f / rate
            var env = exp(-Double(i) / (decay * rate))
            if i < attack { env *= Double(i) / Double(attack) }
            out[i] = Float(env * sin(phase))
        }
        return out
    }
}
