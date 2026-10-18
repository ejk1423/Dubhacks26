//
//  SpatialAudioEngine.swift
//  Echo
//
//  Makes the walls audible. Driven by `SceneSnapshot`s, up to three nearby surfaces
//  (the nearest on the left, ahead, and on the right, within `wallRange`) each become a
//  continuous sound source that sits at the surface's bearing. Each source pulses, and
//  as the user closes in the pulses get faster, louder and brighter (the low-pass
//  opens up), so a wall sounds like a Geiger counter that you are walking toward.
//  Silence means nothing is within range. Trip hazards add a low rising chirp.
//
//  Rendering is done by `AmbientSynth` on the audio thread, in stereo, with the cues
//  the ear uses to lateralise a sound pushed well past natural strength:
//    - interaural level difference (far ear up to `maxILD` quieter),
//    - interaural time difference (far ear up to `maxITD` later),
//    - head shadow (far ear low-passed).
//  Bearings are multiplied by `azimuthGain` and clamped to the sides. The pulsed,
//  broadband (noise + hum) texture is chosen because onsets and wideband energy are
//  what the ear localises best; pure tones are nearly impossible to place.
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

// MARK: - Real-time synth

/// Parameters of one wall source, as the audio thread sees them.
nonisolated struct AmbientSource: Sendable {
    /// -1 (hard left) ... 1 (hard right), already exaggerated and clamped.
    var lateral: Float = 0
    var gain: Float = 0
    var cutoff: Float = 800      // Hz, low-pass on the noise
    var pulseRate: Float = 1     // pulses per second
}

/// Lock-free-enough stereo renderer: the main thread sets targets, the audio thread
/// smooths toward them per sample. All DSP state lives here and is touched only by
/// the audio thread.
nonisolated final class AmbientSynth: @unchecked Sendable {
    static let sourceCount = 3
    private static let delayLength = 128

    private struct Targets {
        var sources = [AmbientSource](repeating: AmbientSource(), count: AmbientSynth.sourceCount)
        var master: Float = 0
    }

    private let targets = OSAllocatedUnfairLock(initialState: Targets())
    private let rate: Float
    private let maxILD: Float
    private let maxITD: Float
    private let shadowCutoff: Float
    private let smoothing: Float          // per-sample parameter smoothing coefficient

    // Audio-thread state, one entry per source.
    private var current = [AmbientSource](repeating: AmbientSource(), count: sourceCount)
    private var master: Float = 0
    private var seeds: [UInt32] = [0x9E3779B9, 0x7F4A7C15, 0x2545F491]
    private var noiseLP = [Float](repeating: 0, count: sourceCount)
    private var farLP = [Float](repeating: 0, count: sourceCount)
    private var pulsePhase = [Float](repeating: 0, count: sourceCount)
    private var humPhase = [Float](repeating: 0, count: sourceCount)
    private var delay = [[Float]](repeating: [Float](repeating: 0, count: delayLength), count: sourceCount)
    private var delayPos = [Int](repeating: 0, count: sourceCount)

    init(sampleRate: Double, maxILD: Float, maxITD: Float, shadowCutoff: Float) {
        rate = Float(sampleRate)
        self.maxILD = maxILD
        self.maxITD = maxITD
        self.shadowCutoff = shadowCutoff
        smoothing = 1 - exp(-1 / (0.04 * rate))   // ~40 ms
    }

    func set(sources: [AmbientSource], master: Float) {
        targets.withLock {
            for i in 0..<Self.sourceCount { $0.sources[i] = i < sources.count ? sources[i] : AmbientSource() }
            $0.master = master
        }
    }

    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let target = targets.withLock { $0 }
        for i in 0..<frames {
            left[i] = 0
            right[i] = 0
        }
        master += (target.master - master) * min(1, smoothing * Float(frames))
        let twoPi = 2 * Float.pi

        for s in 0..<Self.sourceCount {
            let tgt = target.sources[s]
            var cur = current[s]
            if cur.gain < 0.0005, tgt.gain < 0.0005 { current[s] = tgt; continue }

            var seed = seeds[s]
            var lp = noiseLP[s]
            var far = farLP[s]
            var pulse = pulsePhase[s]
            var hum = humPhase[s]
            var pos = delayPos[s]

            for i in 0..<frames {
                cur.lateral += (tgt.lateral - cur.lateral) * smoothing
                cur.gain += (tgt.gain - cur.gain) * smoothing
                cur.cutoff += (tgt.cutoff - cur.cutoff) * smoothing
                cur.pulseRate += (tgt.pulseRate - cur.pulseRate) * smoothing

                // Source signal: low-passed noise plus a low hum, gated by the pulse.
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let white = Float(seed >> 8) / Float(1 << 24) * 2 - 1
                lp += (1 - exp(-twoPi * cur.cutoff / rate)) * (white - lp)
                hum += twoPi * 165 / rate
                if hum > twoPi { hum -= twoPi }
                pulse += cur.pulseRate / rate
                if pulse >= 1 { pulse -= 1 }
                let gate = max(0, sin(twoPi * pulse))          // half-duty, soft edges
                let env = gate * gate
                let mono = (lp * 1.6 + sin(hum) * 0.35) * env * cur.gain * master

                // Stereo: near ear direct; far ear quieter, later and darker.
                let side = abs(cur.lateral)
                let farGain = pow(10, -maxILD * side / 20)
                let farDelay = Int(maxITD * side * rate)
                let farCutoff = 20_000 - (20_000 - shadowCutoff) * side
                delay[s][pos] = mono
                let delayed = delay[s][(pos - farDelay + Self.delayLength) % Self.delayLength]
                pos = (pos + 1) % Self.delayLength
                far += (1 - exp(-twoPi * farCutoff / rate)) * (delayed - far)
                let farSample = far * farGain

                if cur.lateral < 0 {
                    left[i] += mono
                    right[i] += farSample
                } else {
                    right[i] += mono
                    left[i] += farSample
                }
            }

            current[s] = cur
            seeds[s] = seed
            noiseLP[s] = lp
            farLP[s] = far
            pulsePhase[s] = pulse
            humPhase[s] = hum
            delayPos[s] = pos
        }

        for i in 0..<frames {
            left[i] = max(-1, min(1, left[i]))
            right[i] = max(-1, min(1, right[i]))
        }
    }
}

// MARK: - Engine

@Observable
final class SpatialAudioEngine {

    // MARK: Observable state (read by the HUD)

    var isMuted = false
    var masterVolume: Float = 0.8
    var hapticsEnabled = true
    private(set) var isRunning = false
    private(set) var headphonesConnected = false
    /// Bearing of the loudest wall source in radians (right positive), for the HUD. Nil when quiet.
    private(set) var loudestAzimuth: Float?
    /// Closeness (0 far ... 1 touching) of the loudest wall source.
    private(set) var loudestCloseness: Float = 0

    // MARK: Tuning

    @ObservationIgnored let wallRange: Float = 1.6            // metres; silent beyond
    @ObservationIgnored let touchDistance: Float = 0.25       // metres; loudest / fastest at or inside
    @ObservationIgnored let sideBoundary: Float = 12 * .pi / 180   // |bearing| above this is a side source
    @ObservationIgnored let hazardRange: Float = 1.5          // metres ahead
    @ObservationIgnored let hazardRepeat: TimeInterval = 2.0

    @ObservationIgnored let azimuthGain: Float = 1.6          // ~55 degrees off-centre renders fully to the side
    @ObservationIgnored let maxILD: Float = 24                // dB quieter in the far ear at full side
    @ObservationIgnored let maxITD: Float = 0.0008            // seconds later in the far ear at full side
    @ObservationIgnored let shadowCutoff: Float = 1_000       // Hz low-pass on the far ear at full side

    // MARK: Audio graph

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let stereo: AVAudioFormat
    @ObservationIgnored private let synth: AmbientSynth
    @ObservationIgnored private let ambientNode: AVAudioSourceNode
    @ObservationIgnored private let hazardPlayer = AVAudioPlayerNode()
    @ObservationIgnored private let hazardTone: [Float]
    @ObservationIgnored private let haptic = UIImpactFeedbackGenerator(style: .rigid)
    @ObservationIgnored private let logger = Logger(subsystem: "echo.audio", category: "SpatialAudioEngine")

    // MARK: Scheduling

    @ObservationIgnored private var snapshot: SceneSnapshot?
    @ObservationIgnored private var snapshotTime: TimeInterval = 0
    @ObservationIgnored private var lastHazardTone: TimeInterval = 0
    @ObservationIgnored private var lastHaptic: TimeInterval = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    // MARK: Init

    init() {
        stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let rate = stereo.sampleRate
        hazardTone = Self.chirp(rate: rate, from: 380, to: 620, duration: 0.09, decay: 0.08)
            + [Float](repeating: 0, count: Int(0.07 * rate))
            + Self.chirp(rate: rate, from: 380, to: 620, duration: 0.09, decay: 0.08)

        let synth = AmbientSynth(sampleRate: rate, maxILD: maxILD, maxITD: maxITD, shadowCutoff: shadowCutoff)
        self.synth = synth
        // `@Sendable` keeps the render block nonisolated: it runs on the audio thread, and a
        // main-actor-inferred closure there trips the runtime's executor check.
        ambientNode = AVAudioSourceNode(format: stereo) { @Sendable _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            synth.render(frames: Int(frameCount), left: left, right: right)
            return noErr
        }

        engine.attach(ambientNode)
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
        synth.set(sources: [], master: 0)
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

            engine.connect(ambientNode, to: engine.mainMixerNode, format: stereo)
            engine.connect(hazardPlayer, to: engine.mainMixerNode, format: stereo)
            engine.prepare()
            try engine.start()
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
        // Stale snapshot means the AR session stopped: go quiet rather than repeat old news.
        guard !isMuted, engine.isRunning, let snap = snapshot, now - snapshotTime < 0.5 else {
            synth.set(sources: [], master: 0)
            loudestAzimuth = nil
            loudestCloseness = 0
            return
        }

        // Nearest surface on the left, ahead, and on the right.
        var nearest: [ObstacleHit?] = [nil, nil, nil]
        var bearings: [Float] = [0, 0, 0]
        func consider(_ hit: ObstacleHit?) {
            guard let hit, hit.horizontalDistance <= wallRange else { return }
            let bearing = self.bearing(of: hit.point, in: snap)
            guard abs(bearing) <= .pi / 2 + 0.2 else { return }       // ignore things behind
            let slot = bearing < -sideBoundary ? 0 : (bearing > sideBoundary ? 2 : 1)
            if hit.horizontalDistance < (nearest[slot]?.horizontalDistance ?? .infinity) {
                nearest[slot] = hit
                bearings[slot] = bearing
            }
        }
        for hit in snap.fineSectorHits { consider(hit) }
        consider(snap.nearestForwardObstacle)

        var sources: [AmbientSource] = []
        var loudest: (closeness: Float, bearing: Float)?
        for slot in 0..<3 {
            guard let hit = nearest[slot] else { sources.append(AmbientSource()); continue }
            let closeness = min(1, max(0, (wallRange - hit.horizontalDistance) / (wallRange - touchDistance)))
            let steep = closeness * closeness                       // quiet and slow until it is really close
            let lateral = sin(max(-.pi / 2, min(.pi / 2, bearings[slot] * azimuthGain)))
            sources.append(AmbientSource(
                lateral: lateral,
                gain: 0.08 + 0.92 * steep,
                cutoff: 500 + 6_000 * closeness,
                pulseRate: 0.8 + 9 * steep
            ))
            if closeness > (loudest?.closeness ?? -1) { loudest = (closeness, bearings[slot]) }
        }
        synth.set(sources: sources, master: masterVolume)

        loudestAzimuth = loudest?.bearing
        loudestCloseness = loudest?.closeness ?? 0
        if hapticsEnabled, let loudest, loudest.closeness > 0.5 {
            let interval = 1.0 / Double(0.8 + 9 * loudest.closeness * loudest.closeness)
            if now - lastHaptic >= interval {
                haptic.impactOccurred(intensity: CGFloat(0.3 + 0.7 * loudest.closeness))
                lastHaptic = now
            }
        }

        // Trip hazards: a rising double chirp from the hazard's bearing.
        if let hazard = snap.tripHazards.first(where: { $0.distanceAhead > 0 && $0.distanceAhead <= hazardRange }),
           now - lastHazardTone >= hazardRepeat {
            let azimuth = bearing(of: hazard.position, in: snap)
            hazardPlayer.scheduleBuffer(render(hazardTone, azimuth: azimuth, gain: 0.9 * masterVolume), completionHandler: nil)
            lastHazardTone = now
            if hapticsEnabled { haptic.impactOccurred(intensity: 1) }
        }
    }

    /// Horizontal bearing of `point` from the walking heading, radians, right positive.
    private func bearing(of point: SIMD3<Float>, in snap: SceneSnapshot) -> Float {
        let heading = snap.heading
        let right = simd_normalize(simd_cross(heading, SIMD3(0, 1, 0)))
        let d = point - snap.cameraPosition
        return atan2(d.x * right.x + d.z * right.z, d.x * heading.x + d.z * heading.z)
    }

    // MARK: One-shot stereo rendering (hazard chirp)

    private func render(_ mono: [Float], azimuth: Float, gain: Float) -> AVAudioPCMBuffer {
        let rate = Float(stereo.sampleRate)
        let lateral = sin(max(-.pi / 2, min(.pi / 2, azimuth * azimuthGain)))
        let side = abs(lateral)
        let farGain = pow(10, -maxILD * side / 20)
        let farDelay = Int(maxITD * side * rate)
        let alpha = 1 - exp(-2 * .pi * (20_000 - (20_000 - shadowCutoff) * side) / rate)

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

    /// A sine sweep from `from` to `to` Hz with a 2 ms attack and exponential decay.
    private static func chirp(rate: Double, from: Double, to: Double, duration: Double, decay: Double) -> [Float] {
        let n = Int(duration * rate)
        let attack = Int(0.002 * rate)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let u = Double(i) / Double(n)
            phase += 2 * .pi * (from + (to - from) * u) / rate
            var env = exp(-Double(i) / (decay * rate))
            if i < attack { env *= Double(i) / Double(attack) }
            out[i] = Float(env * sin(phase))
        }
        return out
    }
}
