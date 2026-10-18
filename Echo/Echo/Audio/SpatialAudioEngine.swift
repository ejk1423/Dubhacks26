//
//  SpatialAudioEngine.swift
//  Echo
//
//  Directional "parking sensor" for AirPods, driven by `SceneSnapshot`s. Deliberately
//  sparse: silence is the normal state, and a beep always means something is close.
//
//    * Wall pings: a short 1 kHz ping when an obstacle ahead is within `wallRange`
//      (or anything at all is within `proximityRange`), in three distance zones
//      (slow / medium / fast) rather than a continuous rate, so the zone is easy to hear.
//    * Hazard beeps: a high triple-beep when a trip hazard ahead is within
//      `hazardRange`, repeated every `hazardRepeat` while it is still there.
//
//  Direction is hard stereo panning, not HRTF: HRTF cues were too subtle to locate a
//  wall. The azimuth (walking heading, corrected by the AirPods head yaw from
//  `HeadTracker`) maps to pan on a steep curve: dead ahead is centred, and anything
//  past `fullPanAngle` is entirely in one ear.
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
    private(set) var headTrackingActive = false

    // MARK: Tuning

    /// Ping zones for the obstacle ahead: (max distance in metres, seconds between pings).
    @ObservationIgnored let wallZones: [(distance: Float, interval: TimeInterval)] = [
        (0.6, 0.25),
        (1.0, 0.7),
        (1.5, 1.8),
    ]
    var wallRange: Float { wallZones.last!.distance }
    @ObservationIgnored let proximityRange: Float = 0.5     // anything this close pings, even beside you
    @ObservationIgnored let hazardRange: Float = 1.5        // metres ahead
    @ObservationIgnored let hazardRepeat: TimeInterval = 2.0
    @ObservationIgnored let fullPanAngle: Float = .pi / 4   // 45 degrees off-centre = one ear only
    @ObservationIgnored let centreDeadZone: Float = 0.08    // ~5 degrees counts as dead ahead

    // MARK: Audio graph

    @ObservationIgnored let headTracker = HeadTracker()
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let wallPlayer = AVAudioPlayerNode()
    @ObservationIgnored private let hazardPlayer = AVAudioPlayerNode()
    @ObservationIgnored private let format: AVAudioFormat
    @ObservationIgnored private let wallPing: AVAudioPCMBuffer
    @ObservationIgnored private let hazardBeeps: AVAudioPCMBuffer
    @ObservationIgnored private let logger = Logger(subsystem: "echo.audio", category: "SpatialAudioEngine")

    // MARK: Scheduling

    @ObservationIgnored private var snapshot: SceneSnapshot?
    @ObservationIgnored private var snapshotTime: TimeInterval = 0
    @ObservationIgnored private var lastWallPing: TimeInterval = 0
    @ObservationIgnored private var lastHazardBeep: TimeInterval = 0
    @ObservationIgnored private var hazardPlayingUntil: TimeInterval = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    // MARK: Init

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!   // mono, panned by the mixer
        wallPing = Self.makeTone(format: format, frequency: 1_000, beepDuration: 0.04, beeps: 1, gap: 0)
        hazardBeeps = Self.makeTone(format: format, frequency: 2_200, beepDuration: 0.03, beeps: 3, gap: 0.03)

        engine.attach(wallPlayer)
        engine.attach(hazardPlayer)
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observeSystemEvents()
        restartEngine()
        headTracker.start()
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
        headTracker.stop()
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

            engine.connect(wallPlayer, to: engine.mainMixerNode, format: format)
            engine.connect(hazardPlayer, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            wallPlayer.play()
            hazardPlayer.play()
            logger.info("Audio engine running on \(session.currentRoute.outputs.map(\.portName).joined(separator: ", "), privacy: .public)")
        } catch {
            logger.error("Audio engine failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        // AirPods connecting/disconnecting changes the hardware format and stops the engine.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngine() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.engine.isRunning else { return }
                self.restartEngine()
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
        let headYaw = snapshot.flatMap { headTracker.relativeYaw(phoneYaw: Self.yaw(of: $0.heading)) }
        if headTrackingActive != (headYaw != nil) { headTrackingActive = headYaw != nil }

        // Stale snapshot means the AR session stopped: stay silent rather than repeat old news.
        guard !isMuted, engine.isRunning, let snap = snapshot, now - snapshotTime < 0.5 else { return }

        // Trip hazards take priority.
        if let hazard = snap.tripHazards.first(where: { $0.distanceAhead > 0 && $0.distanceAhead <= hazardRange }) {
            if now - lastHazardBeep >= hazardRepeat {
                pan(hazardPlayer, toward: hazard.position, in: snap, headYaw: headYaw)
                hazardPlayer.scheduleBuffer(hazardBeeps, completionHandler: nil)
                lastHazardBeep = now
                hazardPlayingUntil = now + Double(hazardBeeps.frameLength) / format.sampleRate + 0.1
            }
        }
        guard now >= hazardPlayingUntil else { return }   // don't talk over the hazard alert

        // The obstacle ahead, or anything (beside or behind too) that is very close.
        var target = snap.nearestForwardObstacle.flatMap { $0.horizontalDistance <= wallRange ? $0 : nil }
        if target == nil, let near = snap.nearestObstacle, near.horizontalDistance <= proximityRange {
            target = near
        }
        guard let wall = target,
              let zone = wallZones.first(where: { wall.horizontalDistance <= $0.distance }),
              now - lastWallPing >= zone.interval else { return }

        pan(wallPlayer, toward: wall.point, in: snap, headYaw: headYaw)
        wallPlayer.scheduleBuffer(wallPing, completionHandler: nil)
        lastWallPing = now
    }

    /// Pans `player` toward the horizontal direction of `point`, hard-left/right past `fullPanAngle`.
    private func pan(_ player: AVAudioPlayerNode, toward point: SIMD3<Float>, in snap: SceneSnapshot,
                     headYaw: Float?) {
        let heading = snap.heading
        let right = simd_normalize(simd_cross(heading, SIMD3(0, 1, 0)))
        let d = point - snap.cameraPosition
        let ahead = d.x * heading.x + d.z * heading.z
        let side = d.x * right.x + d.z * right.z

        // Azimuth relative to where the head points: right positive. Turning the head left
        // (positive yaw) moves everything to the right.
        var azimuth = atan2(side, ahead)
        if let yaw = headYaw { azimuth += yaw }
        azimuth = atan2(sin(azimuth), cos(azimuth))

        let magnitude = abs(azimuth) <= centreDeadZone ? 0 : min(abs(azimuth) / fullPanAngle, 1)
        // Square-root curve: small angles already move the sound clearly to one side.
        player.pan = (azimuth < 0 ? -1 : 1) * magnitude.squareRoot()
        player.volume = 1
    }

    // MARK: Helpers

    /// Yaw of a horizontal heading, counter-clockwise positive, 0 = -Z (matches CoreMotion's sense).
    private static func yaw(of heading: SIMD3<Float>) -> Float {
        atan2(-heading.x, -heading.z)
    }

    /// Mono sine beeps with 5 ms raised-cosine edges so they don't click.
    private static func makeTone(format: AVAudioFormat, frequency: Double, beepDuration: Double,
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
                samples[start + i] = Float(0.8 * envelope * sin(2 * .pi * frequency * Double(i) / rate))
            }
        }
        return buffer
    }
}
