//
//  ContentView.swift
//  Echo
//
//  The HUD. Wires the perception manager to the audio engine and narrator, derives
//  one `ProximityState` from them, and lays it out in one of two ways:
//
//    * Simple mode: the giant proximity hero and the Describe button. For the actual
//      blind / low-vision user: nothing to read, everything to hear.
//    * Detail mode: adds the minimap, sensor status, what the camera sees and the
//      full control row. For sighted testers and demos.
//
//  Pieces live under Views/: Theme, ProximityState, ProximityHero, HUDControls,
//  MinimapView, OnboardingView, SettingsView, HUDPreferences.
//

import SwiftUI

struct ContentView: View {
    @State private var manager = ARLiDARManager()
    @State private var audio = SpatialAudioEngine()
    @State private var narrator = Narrator()
    @State private var prefs = HUDPreferences()
    @State private var announcer = StatusAnnouncer()

    @State private var showSettings = false
    @State private var showMap = false
    @State private var showOnboarding = false

    var body: some View {
        ARWireframeView(manager: manager)
            .ignoresSafeArea()
            .overlay { EdgeGlow(color: state.color, strength: state.glowStrength) }
            .overlay(alignment: .top) { top }
            .overlay(alignment: .bottom) { footer }
            .overlay {
                if showMap {
                    ExpandedMapView(manager: manager, audio: audio, accent: state.color) {
                        withAnimation(.easeOut(duration: 0.2)) { showMap = false }
                    }
                    .transition(.opacity)
                }
            }
            .overlay {
                if showOnboarding {
                    OnboardingView {
                        prefs.hasSeenOnboarding = true
                        withAnimation(.easeOut(duration: 0.25)) { showOnboarding = false }
                    }
                    .transition(.opacity)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(audio: audio, narrator: narrator, prefs: prefs, manager: manager,
                             onReplayTutorial: { withAnimation { showOnboarding = true } },
                             onShowMap: { withAnimation { showMap = true } })
            }
            .animation(.easeOut(duration: 0.25), value: prefs.simpleMode)
            .onAppear(perform: startUp)
            .onDisappear {
                manager.pause()
                audio.stop()
            }
            .onChange(of: state.kind) { announcer.consider(state) }
            .onChange(of: manager.status) { if let statusMessage { announcer.announce(statusMessage) } }
            // Mirror the live toggles into persisted preferences.
            .onChange(of: audio.isMuted) { prefs.beeps = !audio.isMuted }
            .onChange(of: audio.masterVolume) { prefs.volume = audio.masterVolume }
            .onChange(of: audio.hapticsEnabled) { prefs.haptics = audio.hapticsEnabled }
            .onChange(of: narrator.isEnabled) { prefs.voice = narrator.isEnabled }
            .onChange(of: prefs.cameraFeed) { manager.setCameraFeed(prefs.cameraFeed.mode) }
            .preferredColorScheme(.dark)
    }

    // MARK: Lifecycle

    private func startUp() {
        manager.onSnapshot = { [audio, narrator, manager] snapshot in
            audio.update(snapshot: snapshot)
            audio.ducked = narrator.isSpeaking
            narrator.update(snapshot: snapshot, vision: manager.visionReport,
                            closeness: audio.closeness, targetDistance: audio.targetDistance)
        }
        audio.isMuted = !prefs.beeps
        audio.masterVolume = prefs.volume
        audio.hapticsEnabled = prefs.haptics
        narrator.isEnabled = prefs.voice
        manager.setCameraFeed(prefs.cameraFeed.mode)
        manager.start()
        audio.start()
        if !prefs.hasSeenOnboarding { showOnboarding = true }
    }

    // MARK: Derived state

    private var snapshot: SceneSnapshot? { manager.snapshot }
    private var running: Bool { manager.status == .running }
    private var floorFound: Bool { snapshot.map { $0.groundSource != .assumed } ?? false }

    private var state: ProximityState {
        ProximityState.make(running: running, hazard: manager.tripHazards.first,
                            closeness: audio.closeness, distance: audio.targetDistance)
    }

    private var freshVision: VisionReport? {
        guard let report = manager.visionReport,
              ProcessInfo.processInfo.systemUptime - report.timestamp < 1 else { return nil }
        return report
    }

    /// People / animals the camera sees in front, nearest first.
    private var peopleAhead: [VisionDetection] {
        (freshVision?.detections ?? [])
            .filter { abs($0.bearing) <= 0.9 }
            .sorted { ($0.distance ?? 99) < ($1.distance ?? 99) }
    }

    /// Second line under the state: the last spoken line for a few seconds, else what is ahead by name.
    private var detailLine: String? {
        if let spoken = narrator.lastLine, ProcessInfo.processInfo.systemUptime - narrator.lastLineTime < 6 {
            return spoken
        }
        if let person = peopleAhead.first {
            if let d = person.distance { return String(format: "%@ · %.1f m", person.label, d) }
            return person.label
        }
        if audio.closeness > 0.3, let report = freshVision, let label = report.labelAhead, report.labelConfidence >= 0.3 {
            return label
        }
        if let sign = freshVision?.signs.first { return "Sign: \(sign)" }
        return nil
    }

    private var statusMessage: String? {
        switch manager.status {
        case .running: return nil
        case .idle: return "Paused"
        case .starting: return "Starting up…"
        case .limited(let reason): return reason
        case .interrupted: return "Interrupted. Waiting for the camera."
        case .failed(let message): return "Failed: \(message)"
        case .unsupported(let message): return message
        }
    }

    // MARK: Top

    @ViewBuilder private var top: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let statusMessage {
                StatusBanner(text: statusMessage, tint: running ? Theme.caution : Theme.danger)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if prefs.simpleMode {
                simpleTop
            } else {
                detailTop
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, Theme.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: statusMessage)
        .animation(.easeOut(duration: 0.2), value: peopleAhead.count)
    }

    private var simpleTop: some View {
        HStack {
            StatusChip(symbol: "headphones", text: audio.headphonesConnected ? "Headphones on" : "No headphones",
                       ok: audio.headphonesConnected)
            Spacer()
            StatusChip(symbol: "circle.grid.cross.fill", text: "Simple")
        }
    }

    private var detailTop: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                Haptics.tap()
                withAnimation(.easeOut(duration: 0.2)) { showMap = true }
            } label: {
                VStack(spacing: 4) {
                    MinimapView(snapshot: snapshot, radius: manager.config.mapRadius,
                                coneHalfAngle: audio.coneHalfAngle, alertRange: audio.alertRange,
                                accent: state.color)
                        .frame(width: 160, height: 160)
                    MinimapLegend()
                        .padding(.bottom, 6)
                }
                .padding(.horizontal, 4)
                .glass()
                .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Map of the room")
            .accessibilityHint("Double tap to open the full-screen map with distances in every direction")

            VStack(alignment: .leading, spacing: 6) {
                StatusChip(symbol: "sensor.fill", text: "LiDAR", ok: manager.capabilities.hasLiDAR)
                StatusChip(symbol: "headphones", text: "Headphones", ok: audio.headphonesConnected)
                StatusChip(symbol: "square.stack.3d.down.right.fill", text: "Floor", ok: floorFound)
                if let scene = freshVision?.scene {
                    StatusChip(symbol: "eye.fill", text: scene)
                }
                ForEach(Array(peopleAhead.prefix(2).enumerated()), id: \.offset) { _, person in
                    StatusChip(symbol: "figure.stand",
                               text: person.distance.map { String(format: "%@ %.1f m", person.label, $0) } ?? person.label,
                               tint: Theme.live)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Bottom

    @ViewBuilder private var footer: some View {
        VStack(spacing: 14) {
            if prefs.simpleMode {
                ProximityHero(state: state, detail: detailLine, large: true)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .glass(cornerRadius: 36, tint: state.color, tintOpacity: 0.16)
                DescribeButton(enabled: running, large: true) { describe() }
                controls(includeHaptics: false)
            } else {
                ProximityHero(state: state, detail: detailLine)
                DescribeButton(enabled: running) { describe() }
                controls(includeHaptics: true)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(prefs.simpleMode ? 0.85 : 0.72)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    private func controls(includeHaptics: Bool) -> some View {
        @Bindable var audio = audio
        @Bindable var narrator = narrator
        return HStack(spacing: 8) {
            Toggle("Beeps", isOn: Binding(get: { !audio.isMuted }, set: { audio.isMuted = !$0 }))
                .toggleStyle(HUDToggleStyle(onSymbol: "speaker.wave.2.fill", offSymbol: "speaker.slash.fill"))
                .accessibilityHint("Collision beeps for what is ahead")
            Toggle("Voice", isOn: $narrator.isEnabled)
                .toggleStyle(HUDToggleStyle(onSymbol: "waveform", offSymbol: "waveform.slash"))
                .accessibilityHint("Spoken names for steps, people, objects and signs")
            if includeHaptics {
                Toggle("Haptics", isOn: $audio.hapticsEnabled)
                    .toggleStyle(HUDToggleStyle(onSymbol: "iphone.radiowaves.left.and.right", offSymbol: "iphone.slash"))
                    .accessibilityHint("Ticks in your hand that mirror the beeps")
            }
            HUDButton(title: "Settings", symbol: "gearshape.fill", hint: "Sound, display, map and help") {
                showSettings = true
            }
        }
    }

    private func describe() {
        narrator.describe(snapshot: snapshot, vision: manager.visionReport)
    }
}

#Preview {
    ContentView()
}
