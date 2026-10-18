//
//  ContentView.swift
//  Echo
//
//  The HUD. Wires the perception manager to the audio engine and narrator, derives
//  one `ProximityState` from them, and lays it out over the camera in two layers
//  (HIG › Materials): the AR view is content; a handful of elements float above it.
//
//  One layout, built for low vision: big and simple, nothing in the way.
//
//    Edge      A coloured frame around the screen that grows as the way ahead closes.
//    Top       The map (leading) and, only when something is wrong, one status line.
//    Bottom    The distance and state in giant type, the prominent Describe button,
//              and one group of three glass buttons: Repeat, Mute Beeps, Settings.
//              All in the bottom third, within thumb reach.
//
//  Settings and the full map are sheets; the tutorial is a full-screen cover. Only
//  one is shown at a time (HIG › Sheets): a request made from inside Settings is
//  carried out after that sheet has gone.
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
    @State private var afterSettings: FollowUp?

    private enum FollowUp { case map, tutorial }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ARWireframeView(manager: manager)
            .ignoresSafeArea()
            .overlay { ProximityEdge(state: state) }
            .overlay(alignment: .top) { topBar }
            .overlay(alignment: .bottom) { bottomColumn }
            .sheet(isPresented: $showSettings, onDismiss: runFollowUp) {
                SettingsView(audio: audio, narrator: narrator, prefs: prefs, manager: manager,
                             onReplayTutorial: { afterSettings = .tutorial },
                             onShowMap: { afterSettings = .map })
            }
            .sheet(isPresented: $showMap) {
                MapView(manager: manager, audio: audio)
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView {
                    prefs.hasSeenOnboarding = true
                    showOnboarding = false
                }
            }
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
            .onChange(of: audio.hapticsOnly) { prefs.hapticsOnly = audio.hapticsOnly }
            .onChange(of: narrator.isEnabled) { prefs.voice = narrator.isEnabled }
            .onChange(of: prefs.cameraFeed) { manager.setCameraFeed(prefs.cameraFeed.mode) }
    }

    // MARK: Lifecycle

    private func startUp() {
        manager.onSnapshot = { [audio, narrator, manager] snapshot in
            audio.update(snapshot: snapshot)
            audio.ducked = narrator.isSpeaking
            narrator.update(snapshot: snapshot, vision: manager.visionReport,
                            closeness: audio.closeness, targetDistance: audio.targetDistance)
        }
        narrator.audio = audio
        audio.isMuted = !prefs.beeps
        audio.masterVolume = prefs.volume
        audio.hapticsEnabled = prefs.haptics
        audio.hapticsOnly = prefs.hapticsOnly
        narrator.isEnabled = prefs.voice
        manager.setCameraFeed(prefs.cameraFeed.mode)
        manager.start()
        audio.start()
        if !prefs.hasSeenOnboarding { showOnboarding = true }
    }

    /// Presents whatever Settings asked for, now that its sheet is gone.
    private func runFollowUp() {
        guard let followUp = afterSettings else { return }
        afterSettings = nil
        switch followUp {
        case .map: showMap = true
        case .tutorial: showOnboarding = true
        }
    }

    // MARK: Derived state

    private var snapshot: SceneSnapshot? { manager.snapshot }
    private var running: Bool { manager.status == .running }
    private var floorFound: Bool { snapshot.map { $0.groundSource != .assumed } ?? false }

    private var state: ProximityState {
        ProximityState.make(running: running, hazard: manager.tripHazards.first,
                            closeness: audio.closeness, distance: audio.targetDistance)
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

    /// Only problems earn a line at the top; when all is well there is nothing to read.
    private var statusLine: (symbol: String, text: String)? {
        if let statusMessage { return ("exclamationmark.circle", statusMessage) }
        if !manager.capabilities.hasLiDAR { return ("sensor.fill", "No LiDAR on this device") }
        if !audio.headphonesConnected { return ("headphones", "No headphones") }
        if running, !floorFound { return ("square.stack.3d.down.right", "Finding the floor") }
        return nil
    }

    // MARK: Top

    @ViewBuilder private var topBar: some View {
        HStack(alignment: .top, spacing: HUDMetrics.spacing) {
            MinimapButton(snapshot: snapshot, radius: manager.config.mapRadius,
                          coneHalfAngle: audio.coneHalfAngle, alertRange: audio.alertRange) {
                showMap = true
            }
            if let line = statusLine {
                StatusLine(symbol: line.symbol, text: line.text)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HUDMetrics.margin)
        .padding(.top, HUDMetrics.spacingSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: statusLine?.text)
        // The HUD sits over camera content, so it keeps a dark appearance; the sheets
        // follow the system. Colours stay semantic so the swap is just the scheme.
        .environment(\.colorScheme, .dark)
        .accessibilitySortPriority(0)
    }

    // MARK: Bottom

    @ViewBuilder private var bottomColumn: some View {
        VStack(spacing: HUDMetrics.spacingLarge) {
            ProximityDisplay(state: state)
                .accessibilitySortPriority(3)
            DescribeButton(enabled: running) {
                narrator.describe(snapshot: snapshot, vision: manager.visionReport)
            }
            .accessibilitySortPriority(2)
            HUDControlBar(audio: audio, onRepeat: { narrator.repeatLast() }, onSettings: { showSettings = true })
                .accessibilitySortPriority(1)
        }
        .frame(maxWidth: HUDMetrics.maxColumnWidth)
        .padding(.horizontal, HUDMetrics.margin)
        .padding(.top, HUDMetrics.spacingLarge * 2)
        .padding(.bottom, HUDMetrics.spacingSmall)
        .frame(maxWidth: .infinity)
        // A standard scrim behind text over media, as Photos and video players do; it
        // dims only the bottom of the camera, never the room ahead.
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
        .environment(\.colorScheme, .dark)
        .accessibilitySortPriority(1)
    }
}

#Preview {
    ContentView()
}
