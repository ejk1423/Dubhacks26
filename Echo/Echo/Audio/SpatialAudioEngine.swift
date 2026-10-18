//
//  SpatialAudioEngine.swift
//  Echo
//
//  Parking-sensor style collision warning, driven by `SceneSnapshot`s. One target: the
//  nearest surface inside a forward cone (`coneHalfAngle`) within the alert range. The
//  range grows with walking speed (`leadTime` seconds of travel, at least `alertRange`),
//  so a brisk walker is warned earlier than someone shuffling. Beyond `imminentRange` it
//  only beeps while the user is actually closing in on the target; inside, always.
//  Beeps duck while the narrator is speaking. Beeps are soft and low until the last stretch, where they get faster,
//  louder and higher, going solid near contact. Nothing beside or behind the user makes
//  a sound, and silence means the way ahead is clear. Trip hazards are spoken by
//  `Narrator`, not beeped.
//
//  Direction is a gentle nuance, not the message: the beep is mixed to stereo with a
//  small level and time difference toward the target's bearing (capped at
//  `maxLateral`), so a post slightly to the left reads as slightly left while the beep
//  stays clearly "in front".
//
//  The session is `.playback` on purpose: `.playAndRecord` would drop AirPods to the
//  mono hands-free profile. Bluetooth route changes stop `AVAudioEngine`, so
//  configuration-change, route-change and interruption notifications restart it.
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
    var masterVolume: Float = 0.8
    var hapticsEnabled = true
    /// Set while speech is playing so beeps drop under it.
    var ducked = false
    private(set) var isRunning = false
    private(set) var headphonesConnected = false
    /// 0 (nothing in range) ... 1 (at contact) for the current target.
    private(set) var closeness: Float = 0
    /// Distance to the current target in metres, nil when the cone is clear.
    private(set) var targetDistance: Float?

    // MARK: Tuning

    @ObservationIgnored let alertRange: Float = 1.0             // metres; minimum range
    @ObservationIgnored let leadTime: Float = 1.6               // seconds of travel the range covers when walking
    @ObservationIgnored let maxRange: Float = 2.2
    @ObservationIgnored let imminentRange: Float = 0.45         // metres; inside this beep even when standing still
    @ObservationIgnored let closingSpeedThreshold: Float = 0.1  // m/s toward the target before beeping
    @ObservationIgnored let touchDistance: Float = 0.3          // metres; solid tone at or inside
    @ObservationIgnored let coneHalfAngle: Float = 40 * .pi / 180
    @ObservationIgnored let slowestInterval: TimeInterval = 1.2
    @ObservationIgnored let fastestInterval: TimeInterval = 0.09

    @ObservationIgnored let maxLateral: Float = 0.5             // sin(bearing) cap: never more than mildly off-centre
    @ObservationIgnored let maxILD: Float = 7                   // dB quieter in the far ear at maxLateral
    @ObservationIgnored let maxITD: Float = 0.0003              // seconds later in the far ear at maxLateral

    // MARK: Audio graph

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let stereo: AVAudioFormat
    @ObservationIgnored private let beepPlayer = AVAudioPlayerNode()
    @ObservationIgnored private let haptic = UIImpactFeedbackGenerator(style: .rigid)
    @ObservationIgnored private let logger = Logger(subsystem: "echo.audio", category: "SpatialAudioEngine")

    // MARK: Scheduling

    @ObservationIgnored private var snapshot: SceneSnapshot?
    @ObservationIgnored private var snapshotTime: TimeInterval = 0
    @ObservationIgnored private var lastBeep: TimeInterval = 0
    @ObservationIgnored private var targetHistory: [(time: TimeInterval, distance: Float)] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    // MARK: Init

    init() {
        stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.attach(beepPlayer)
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observeSystemEvents()
        restartEngine()
        haptic.prepare()
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
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
        beepPlayer.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Feed every analysis result here (`ARLiDARManager.onSnapshot`).
    func update(snapshot: SceneSnapshot) {
        self.snapshot = snapshot
        snapshotTime = ProcessInfo.processInfo.systemUptime
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

            engine.connect(beepPlayer, to: engine.mainMixerNode, format: stereo)
            engine.prepare()
            try engine.start()
            beepPlayer.play()
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
        // Stale snapshot means the AR session stopped: go quiet rather than repeat old news.
        guard engine.isRunning, let snap = snapshot, now - snapshotTime < 0.5 else {
            closeness = 0
            targetDistance = nil
            return
        }

        // Nearest surface in the forward cone.
        var target: (hit: ObstacleHit, bearing: Float)?
        func consider(_ hit: ObstacleHit?) {
            guard let hit, hit.horizontalDistance <= maxRange else { return }
            let bearing = self.bearing(of: hit.point, in: snap)
            guard abs(bearing) <= coneHalfAngle,
                  hit.horizontalDistance < (target?.hit.horizontalDistance ?? .infinity) else { return }
            target = (hit, bearing)
        }
        consider(snap.nearestForwardObstacle)
        for hit in snap.fineSectorHits { consider(hit) }

        guard let target else {
            closeness = 0
            targetDistance = nil
            targetHistory.removeAll()
            return
        }
        let distance = target.hit.horizontalDistance
        let range = min(maxRange, max(alertRange, snap.walkingSpeed * leadTime))
        let c = min(1, max(0, (range - distance) / (range - touchDistance)))
        closeness = c
        targetDistance = distance

        // Closing speed over the last ~0.6 s of readings.
        targetHistory.append((snap.timestamp, distance))
        targetHistory.removeAll { snap.timestamp - $0.time > 0.6 }
        var closingSpeed: Float = 0
        if let first = targetHistory.first, let last = targetHistory.last, last.time - first.time >= 0.25 {
            closingSpeed = (first.distance - last.distance) / Float(last.time - first.time)
        }
        guard distance <= imminentRange || closingSpeed >= closingSpeedThreshold else { return }

        // Beep rate and loudness rise steeply near the end; solid near contact.
        let far = 1 - c
        let interval = fastestInterval + (slowestInterval - fastestInterval) * Double(far * far)
        guard now - lastBeep >= interval else { return }
        lastBeep = now
        guard !isMuted else { return }

        // Low and soft until the last stretch: pitch only climbs in the final 30 cm or so.
        let urgency = c * c * c
        let beep = Self.beep(rate: stereo.sampleRate, frequency: 620 + 680 * Double(urgency),
                             duration: c > 0.95 ? 0.10 : 0.05)
        let gain = (0.18 + 0.72 * c * c) * (ducked ? 0.4 : 1)
        beepPlayer.scheduleBuffer(render(beep, azimuth: target.bearing, gain: gain), completionHandler: nil)
        if hapticsEnabled { haptic.impactOccurred(intensity: CGFloat(0.3 + 0.7 * c)) }
    }

    /// Horizontal bearing of `point` from the walking heading, radians, right positive.
    private func bearing(of point: SIMD3<Float>, in snap: SceneSnapshot) -> Float {
        let heading = snap.heading
        let right = simd_normalize(simd_cross(heading, SIMD3(0, 1, 0)))
        let d = point - snap.cameraPosition
        return atan2(d.x * right.x + d.z * right.z, d.x * heading.x + d.z * heading.z)
    }

    // MARK: Stereo rendering

    /// Mixes a mono cue to stereo, nudged toward `azimuth` with a small level and time
    /// difference. Capped so the cue always reads as "ahead".
    private func render(_ mono: [Float], azimuth: Float, gain: Float) -> AVAudioPCMBuffer {
        let rate = Float(stereo.sampleRate)
        let lateral = max(-maxLateral, min(maxLateral, sin(azimuth)))
        let side = abs(lateral) / maxLateral
        let farGain = pow(10, -maxILD * side / 20)
        let farDelay = Int(maxITD * side * rate)
        let volume = gain * masterVolume

        let frames = mono.count + farDelay
        let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let near = buffer.floatChannelData![lateral < 0 ? 0 : 1]
        let far = buffer.floatChannelData![lateral < 0 ? 1 : 0]
        for i in 0..<frames {
            near[i] = i < mono.count ? mono[i] * volume : 0
            let delayed = i - farDelay
            far[i] = delayed >= 0 && delayed < mono.count ? mono[delayed] * farGain * volume : 0
        }
        return buffer
    }

    // MARK: Sounds

    /// A clean beep: sine with a faint second harmonic, 3 ms attack, 15 ms release.
    private static func beep(rate: Double, frequency: Double, duration: Double) -> [Float] {
        let n = Int(duration * rate)
        let attack = Int(0.003 * rate)
        let release = Int(0.015 * rate)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rate
            var env = 1.0
            if i < attack { env = Double(i) / Double(attack) }
            if i > n - release { env = Double(n - i) / Double(release) }
            let value = sin(2 * .pi * frequency * t) + 0.12 * sin(4 * .pi * frequency * t)
            out[i] = Float(0.7 * env * value)
        }
        return out
    }
}
