//
//  SpatialAudioEngine.swift
//  Echo
//
//  Parking-sensor style collision warning, driven by `SceneSnapshot`s. One target: the
//  nearest surface inside a forward cone (`coneHalfAngle`) within the alert range. The
//  warning is timed by time-to-collision: it beeps only when the target is within
//  `leadTime` seconds at the current closing speed, or already within `imminentRange`.
//  Standing in front of something, or walking past it, is silent. Far beeps are quiet
//  and slow; they only get insistent in the last half metre. `hapticsOnly` keeps the
//  ticks in the hand and drops the sound altogether.
//  Beeps duck while the narrator is speaking. Beeps are soft and low until the last
//  stretch, where they get faster, louder and higher, going solid near contact. Nothing
//  beside or behind the user makes a sound, and silence means the way ahead is clear.
//  Trip hazards are spoken by `Narrator`, not beeped.
//
//  Sound vocabulary, so each sound means one thing:
//    * Beep (620 Hz rising): something in the way ahead, closer as it quickens.
//    * Tick (one soft high click): the way ahead just became clear after being blocked.
//    * Two-tone chime (rising): a spoken warning is about to follow; listen.
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

    /// The engine most recently started, so `Narrator` can play earcons without wiring.
    static weak var current: SpatialAudioEngine?

    // MARK: Observable state (read by the HUD)

    var isMuted = false
    var masterVolume: Float = 0.8
    var hapticsEnabled = true
    /// Haptic ticks only, no beeps (a quieter way to use Echo).
    var hapticsOnly = false
    /// Set while speech is playing so beeps drop under it.
    var ducked = false
    /// Earcons (clear tick, pre-speech chime) can be switched off independently of beeps.
    var earconsEnabled = true
    private(set) var isRunning = false
    private(set) var headphonesConnected = false
    /// 0 (nothing in range) ... 1 (at contact) for the current target.
    private(set) var closeness: Float = 0
    /// Distance to the current target in metres, nil when the cone is clear.
    private(set) var targetDistance: Float?
    /// Bearing of the current target, radians, right positive; nil when clear.
    private(set) var targetBearing: Float?
    /// Uptime when the path last went from blocked to clear (the tick), for the HUD.
    private(set) var lastClearedTime: TimeInterval = 0

    // MARK: Tuning

    @ObservationIgnored let alertRange: Float = 0.8             // metres; range shown on the map / minimum
    @ObservationIgnored let leadTime: Float = 1.3               // seconds to collision at which beeps start
    @ObservationIgnored let maxRange: Float = 1.6
    @ObservationIgnored let imminentRange: Float = 0.35         // metres; inside this beep even when standing still
    @ObservationIgnored let closingSpeedThreshold: Float = 0.15 // m/s toward the target before beeping
    @ObservationIgnored let touchDistance: Float = 0.3          // metres; solid tone at or inside
    @ObservationIgnored let coneHalfAngle: Float = 40 * .pi / 180
    @ObservationIgnored let slowestInterval: TimeInterval = 1.4
    @ObservationIgnored let fastestInterval: TimeInterval = 0.09

    @ObservationIgnored let blockedCloseness: Float = 0.35      // closeness that counts as "blocked" for the clear tick
    @ObservationIgnored let blockedHold: TimeInterval = 0.4     // seconds blocked before clearing earns a tick
    @ObservationIgnored let clearHold: TimeInterval = 0.45      // seconds clear before the tick plays

    @ObservationIgnored let maxLateral: Float = 0.5             // sin(bearing) cap: never more than mildly off-centre
    @ObservationIgnored let maxILD: Float = 6                   // dB quieter in the far ear at maxLateral
    @ObservationIgnored let maxITD: Float = 0.0003              // seconds later in the far ear at maxLateral

    // MARK: Audio graph

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let stereo: AVAudioFormat
    @ObservationIgnored private let beepPlayer = AVAudioPlayerNode()
    @ObservationIgnored private let cuePlayer = AVAudioPlayerNode()
    @ObservationIgnored private let haptic = UIImpactFeedbackGenerator(style: .rigid)
    @ObservationIgnored private let softHaptic = UIImpactFeedbackGenerator(style: .soft)
    @ObservationIgnored private let logger = Logger(subsystem: "echo.audio", category: "SpatialAudioEngine")

    // MARK: Scheduling

    @ObservationIgnored private var snapshot: SceneSnapshot?
    @ObservationIgnored private var snapshotTime: TimeInterval = 0
    @ObservationIgnored private var lastBeep: TimeInterval = 0
    @ObservationIgnored private var beepsHeldUntil: TimeInterval = 0
    @ObservationIgnored private var targetHistory: [(time: TimeInterval, distance: Float)] = []
    @ObservationIgnored private var blockedSince: TimeInterval?
    @ObservationIgnored private var wasBlocked = false
    @ObservationIgnored private var clearSince: TimeInterval?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    // Pre-rendered cues (mono samples at the stereo format's rate).
    @ObservationIgnored private let clearTick: [Float]
    @ObservationIgnored private let alertChime: [Float]

    // MARK: Init

    init() {
        stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        clearTick = Self.tick(rate: stereo.sampleRate)
        alertChime = Self.chime(rate: stereo.sampleRate)
        engine.attach(beepPlayer)
        engine.attach(cuePlayer)
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Self.current = self
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
        if Self.current === self { Self.current = nil }
        timer?.invalidate()
        timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        beepPlayer.stop()
        cuePlayer.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Feed every analysis result here (`ARLiDARManager.onSnapshot`).
    func update(snapshot: SceneSnapshot) {
        self.snapshot = snapshot
        snapshotTime = ProcessInfo.processInfo.systemUptime
    }

    // MARK: Earcons

    /// Rising two-tone chime: a spoken warning follows. Returns its duration so the caller
    /// can delay the utterance. Beeps are held for the chime so it is heard on its own.
    @discardableResult
    func playAlertEarcon() -> TimeInterval {
        let duration = Double(alertChime.count) / stereo.sampleRate
        guard engine.isRunning, earconsEnabled, !isMuted else { return 0 }
        beepsHeldUntil = ProcessInfo.processInfo.systemUptime + duration + 0.1
        cuePlayer.scheduleBuffer(render(alertChime, azimuth: 0, gain: 0.55), completionHandler: nil)
        if hapticsEnabled { softHaptic.impactOccurred(intensity: 0.6) }
        return duration
    }

    /// One soft click: the way ahead is clear again.
    func playClearTick() {
        guard engine.isRunning, earconsEnabled, !isMuted else { return }
        cuePlayer.scheduleBuffer(render(clearTick, azimuth: 0, gain: 0.35), completionHandler: nil)
        if hapticsEnabled { softHaptic.impactOccurred(intensity: 0.4) }
    }

    /// Quiet acknowledgement click for button presses (describe, where am I).
    func playAcknowledge() {
        guard engine.isRunning, earconsEnabled, !isMuted else { return }
        cuePlayer.scheduleBuffer(render(clearTick, azimuth: 0, gain: 0.2), completionHandler: nil)
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
            engine.connect(cuePlayer, to: engine.mainMixerNode, format: stereo)
            engine.prepare()
            try engine.start()
            beepPlayer.play()
            cuePlayer.play()
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
            targetBearing = nil
            blockedSince = nil
            wasBlocked = false
            clearSince = nil
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
            targetBearing = nil
            targetHistory.removeAll()
            trackClearing(closeness: 0, now: now)
            return
        }
        let distance = target.hit.horizontalDistance

        // Closing speed over the last ~0.6 s of readings.
        targetHistory.append((snap.timestamp, distance))
        targetHistory.removeAll { snap.timestamp - $0.time > 0.6 }
        var closingSpeed: Float = 0
        if let first = targetHistory.first, let last = targetHistory.last, last.time - first.time >= 0.25 {
            closingSpeed = (first.distance - last.distance) / Float(last.time - first.time)
        }

        // The range that matters is how far we travel in `leadTime` at the current closing
        // speed; the HUD's closeness is measured against that, so "ahead" means "about to
        // reach", not "somewhere in view".
        let range = min(maxRange, max(alertRange, closingSpeed * leadTime))
        let c = min(1, max(0, (range - distance) / (range - touchDistance)))
        closeness = c
        targetDistance = distance
        targetBearing = target.bearing
        trackClearing(closeness: c, now: now)

        let imminent = distance <= imminentRange
        let closingIn = closingSpeed >= closingSpeedThreshold && distance / closingSpeed <= leadTime
        guard imminent || closingIn else { return }

        // Beep rate and loudness rise steeply near the end; solid near contact.
        let far = 1 - c
        let interval = fastestInterval + (slowestInterval - fastestInterval) * Double(far * far)
        guard now - lastBeep >= interval, now >= beepsHeldUntil else { return }
        lastBeep = now
        if hapticsEnabled { haptic.impactOccurred(intensity: CGFloat(0.3 + 0.7 * c)) }
        guard !isMuted, !hapticsOnly else { return }

        // Low and soft until the last stretch: pitch only climbs in the final 30 cm or so.
        let urgency = c * c * c
        let beep = Self.beep(rate: stereo.sampleRate, frequency: 520 + 600 * Double(urgency),
                             duration: c > 0.95 ? 0.09 : 0.04)
        let gain = (0.10 + 0.6 * c * c) * (ducked ? 0.4 : 1)
        beepPlayer.scheduleBuffer(render(beep, azimuth: target.bearing, gain: gain), completionHandler: nil)
    }

    /// Blocked-then-clear detection for the clear tick: the user must have been properly
    /// blocked for a moment, and the cone must stay clear for a moment, so a doorframe
    /// brushing the edge of the cone does not click.
    private func trackClearing(closeness c: Float, now: TimeInterval) {
        if c >= blockedCloseness {
            if blockedSince == nil { blockedSince = now }
            if now - blockedSince! >= blockedHold { wasBlocked = true }
            clearSince = nil
            return
        }
        blockedSince = nil
        guard wasBlocked else { clearSince = nil; return }
        guard c < 0.1 else { clearSince = nil; return }   // in between: wait and see
        if clearSince == nil { clearSince = now }
        if now - clearSince! >= clearHold {
            wasBlocked = false
            clearSince = nil
            lastClearedTime = now
            playClearTick()
        }
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
        let attack = Int(0.004 * rate)
        let release = Int(0.02 * rate)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rate
            var env = 1.0
            if i < attack { env = Double(i) / Double(attack) }
            if i > n - release { env = Double(n - i) / Double(release) }
            let value = sin(2 * .pi * frequency * t) + 0.05 * sin(4 * .pi * frequency * t)
            out[i] = Float(0.7 * env * value)
        }
        return out
    }

    /// A short wooden click: high sine with a fast exponential decay, nothing like the beep.
    private static func tick(rate: Double) -> [Float] {
        let n = Int(0.045 * rate)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rate
            let env = exp(-t * 110) * min(1, Double(i) / (0.001 * rate))
            out[i] = Float(0.8 * env * (sin(2 * .pi * 2200 * t) + 0.3 * sin(2 * .pi * 3300 * t)))
        }
        return out
    }

    /// Two rising tones (G5 then C6), 90 ms each with a short gap: "a voice line is coming".
    private static func chime(rate: Double) -> [Float] {
        let first = beep(rate: rate, frequency: 784, duration: 0.09)
        let gap = [Float](repeating: 0, count: Int(0.03 * rate))
        let second = beep(rate: rate, frequency: 1047, duration: 0.12)
        return first + gap + second
    }
}
