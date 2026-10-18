//
//  SpatialAudioEngine.swift
//  Echo
//
//  Binaural "parking sensor" for headphones, driven by `SceneSnapshot`s. Deliberately
//  sparse: silence is the normal state, and a sound always means something is close.
//
//    * Wall ticks: a short broadband click from the direction of the nearest obstacle
//      in front (or anything at all within `proximityRange`), in three distance zones
//      (slow / medium / fast) rather than a continuous rate, so the zone is easy to hear.
//    * Hazard buzz: a low triple buzz from the direction of a trip hazard ahead,
//      repeated every `hazardRepeat` while it is still there.
//
//  Rendering goes through `AVAudioEnvironmentNode`, i.e. Apple's AUSpatialMixer, set up
//  for headphones with the system's personalized HRTF profile when the user has one and
//  the AirPods' own head tracking (`isListenerHeadTrackingEnabled`), so a sound stays on
//  the wall while the head turns. Sources are placed relative to the phone's walking
//  heading, which on iPhone is also the system head-tracking anchor. Azimuths are
//  exaggerated by `azimuthGain` so small offsets are still clearly left or right.
//
//  The sounds are broadband on purpose: the ear localises clicks and buzzes far better
//  than pure tones, whose HRTF cues are almost absent.
//
//  The session is `.playback` on purpose: `.playAndRecord` would drop AirPods to the
//  mono hands-free profile and destroy the stereo cues. Bluetooth route changes stop
//  `AVAudioEngine`, so configuration-change, route-change and interruption
//  notifications all rebuild the graph and restart it.
//

import AVFAudio
import Foundation
import Observation
import simd
import os

@Observable
final class SpatialAudioEngine {

    // MARK: Observable state (read by the HUD)

    var isMuted = false
    private(set) var isRunning = false
    private(set) var headphonesConnected = false

    // MARK: Tuning

    /// Tick zones for the obstacle ahead: (max distance in metres, seconds between ticks).
    @ObservationIgnored let wallZones: [(distance: Float, interval: TimeInterval)] = [
        (0.6, 0.25),
        (1.0, 0.7),
        (1.5, 1.8),
    ]
    var wallRange: Float { wallZones.last!.distance }
    @ObservationIgnored let proximityRange: Float = 0.5     // anything this close ticks, even beside or behind you
    @ObservationIgnored let hazardRange: Float = 1.5        // metres ahead
    @ObservationIgnored let hazardRepeat: TimeInterval = 2.0
    @ObservationIgnored let azimuthGain: Float = 1.5        // 60 degrees off-centre renders at 90
    @ObservationIgnored let hazardElevation: Float = -0.5   // metres below ear level at 1 m

    // MARK: Audio graph

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let environment = AVAudioEnvironmentNode()
    @ObservationIgnored private let wallPlayer = AVAudioPlayerNode()
    @ObservationIgnored private let hazardPlayer = AVAudioPlayerNode()
    @ObservationIgnored private let format: AVAudioFormat
    @ObservationIgnored private let wallTick: AVAudioPCMBuffer
    @ObservationIgnored private let hazardBuzz: AVAudioPCMBuffer
    @ObservationIgnored private let logger = Logger(subsystem: "echo.audio", category: "SpatialAudioEngine")

    // MARK: Scheduling

    @ObservationIgnored private var snapshot: SceneSnapshot?
    @ObservationIgnored private var snapshotTime: TimeInterval = 0
    @ObservationIgnored private var lastWallTick: TimeInterval = 0
    @ObservationIgnored private var lastHazardBuzz: TimeInterval = 0
    @ObservationIgnored private var hazardPlayingUntil: TimeInterval = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    // MARK: Init

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!   // mono: required for 3D
        wallTick = Self.makeClick(format: format)
        hazardBuzz = Self.makeBuzz(format: format, frequency: 440, beepDuration: 0.06, beeps: 3, gap: 0.04)

        engine.attach(environment)
        engine.attach(wallPlayer)
        engine.attach(hazardPlayer)

        // Headphone binaural rendering with the AirPods' head tracking. Loudness is set
        // here, so distance attenuation and reverb are off; they would only blur the cue.
        environment.outputType = .headphones
        environment.isListenerHeadTrackingEnabled = true
        environment.distanceAttenuationParameters.rolloffFactor = 0
        environment.reverbParameters.enable = false
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
        for player in [wallPlayer, hazardPlayer] {
            player.renderingAlgorithm = .auto      // "use output type": best HRTF for headphones
            player.sourceMode = .pointSource
            player.reverbBlend = 0
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observeSystemEvents()
        restartEngine()
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

            engine.connect(environment, to: engine.mainMixerNode, format: nil)
            engine.connect(wallPlayer, to: environment, format: format)
            engine.connect(hazardPlayer, to: environment, format: format)
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
        // Stale snapshot means the AR session stopped: stay silent rather than repeat old news.
        guard !isMuted, engine.isRunning, let snap = snapshot, now - snapshotTime < 0.5 else { return }

        // Trip hazards take priority.
        if let hazard = snap.tripHazards.first(where: { $0.distanceAhead > 0 && $0.distanceAhead <= hazardRange }) {
            if now - lastHazardBuzz >= hazardRepeat {
                place(hazardPlayer, toward: hazard.position, in: snap, elevation: hazardElevation)
                hazardPlayer.scheduleBuffer(hazardBuzz, completionHandler: nil)
                lastHazardBuzz = now
                hazardPlayingUntil = now + Double(hazardBuzz.frameLength) / format.sampleRate + 0.1
            }
        }
        guard now >= hazardPlayingUntil else { return }   // don't talk over the hazard alert

        // Whatever is closest in front of us: the corridor straight ahead, or the nearest
        // thing in the forward half-plane. Behind or beside only counts when very close.
        var target: ObstacleHit?
        func consider(_ hit: ObstacleHit?, within range: Float) {
            guard let hit, hit.horizontalDistance <= range,
                  hit.horizontalDistance < (target?.horizontalDistance ?? .infinity) else { return }
            target = hit
        }
        consider(snap.nearestForwardObstacle, within: wallRange)
        if let near = snap.nearestObstacle {
            consider(near, within: Self.isInFront(near.point, in: snap) ? wallRange : proximityRange)
        }
        guard let wall = target,
              let zone = wallZones.first(where: { wall.horizontalDistance <= $0.distance }),
              now - lastWallTick >= zone.interval else { return }

        place(wallPlayer, toward: wall.point, in: snap, elevation: 0)
        wallPlayer.scheduleBuffer(wallTick, completionHandler: nil)
        lastWallTick = now
    }

    private static func isInFront(_ point: SIMD3<Float>, in snap: SceneSnapshot) -> Bool {
        let d = point - snap.cameraPosition
        return d.x * snap.heading.x + d.z * snap.heading.z > 0
    }

    /// Places `player` 1 m from the listener toward `point`, with the azimuth exaggerated
    /// by `azimuthGain` and clamped to the sides (never behind, which the ear confuses
    /// with ahead).
    private func place(_ player: AVAudioPlayerNode, toward point: SIMD3<Float>, in snap: SceneSnapshot,
                       elevation: Float) {
        let heading = snap.heading
        let right = simd_normalize(simd_cross(heading, SIMD3(0, 1, 0)))
        let d = point - snap.cameraPosition
        let ahead = d.x * heading.x + d.z * heading.z
        let side = d.x * right.x + d.z * right.z

        var azimuth = atan2(side, ahead) * azimuthGain          // right positive
        azimuth = max(-.pi / 2, min(.pi / 2, azimuth))
        // Listener faces -Z; +X is right.
        player.position = AVAudio3DPoint(x: sin(azimuth), y: elevation, z: -cos(azimuth))
        player.volume = 1
    }

    // MARK: Sounds

    /// A 2-pulse broadband click (noise bursts with a sharp attack and ~4 ms decay).
    /// Clicks carry the interaural time and spectral cues that make a sound easy to place.
    private static func makeClick(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let pulse = Int(0.012 * rate)
        let gap = Int(0.03 * rate)
        let total = 2 * pulse + gap
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let samples = buffer.floatChannelData![0]
        for i in 0..<total { samples[i] = 0 }
        var seed: UInt32 = 0x9E3779B9
        for start in [0, pulse + gap] {
            for i in 0..<pulse {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = Float(seed >> 8) / Float(1 << 24) * 2 - 1
                let decay = exp(-Double(i) / (0.004 * rate))
                // Blend in a 3 kHz tone so the click has a clear pitch on top of the noise.
                let tone = sin(2 * .pi * 3_000 * Double(i) / rate)
                samples[start + i] = Float(0.9 * decay) * (0.6 * noise + Float(0.4 * tone))
            }
        }
        return buffer
    }

    /// Sawtooth-like buzz (harmonics 1-8) with 5 ms raised-cosine edges so it doesn't click.
    private static func makeBuzz(format: AVAudioFormat, frequency: Double, beepDuration: Double,
                                 beeps: Int, gap: Double) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let beepFrames = Int(beepDuration * rate)
        let gapFrames = Int(gap * rate)
        let total = beeps * beepFrames + (beeps - 1) * gapFrames
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let samples = buffer.floatChannelData![0]
        let edge = Int(0.005 * rate)
        for i in 0..<total { samples[i] = 0 }
        for b in 0..<beeps {
            let start = b * (beepFrames + gapFrames)
            for i in 0..<beepFrames {
                var envelope: Double = 1
                if i < edge { envelope = 0.5 - 0.5 * cos(.pi * Double(i) / Double(edge)) }
                if i > beepFrames - edge { envelope = 0.5 - 0.5 * cos(.pi * Double(beepFrames - i) / Double(edge)) }
                var value = 0.0
                for h in 1...8 { value += sin(2 * .pi * frequency * Double(h) * Double(i) / rate) / Double(h) }
                samples[start + i] = Float(0.5 * envelope * value)
            }
        }
        return buffer
    }
}
