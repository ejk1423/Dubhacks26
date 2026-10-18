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
//    Scene     The obstacle the beeps are about is lit red on the LiDAR surfaces.
//    Top       The map, fading into the top-right corner. Nothing else.
//    Bottom    The distance and state in giant type, a small line only when something
//              is wrong (no headphones, finding the floor), then one row: the prominent
//              Describe button with Mute Beeps and Settings. All in the bottom third,
//              within thumb reach.
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
            .overlay(alignment: .topTrailing) { mapPanel }
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

    /// The hazard worth showing: in the walking line and close, the same bar the voice uses.
    private var hazardAhead: TripHazard? {
        manager.tripHazards.first { $0.distanceAhead > 0 && $0.distanceAhead <= 1.2 && abs($0.lateralOffset) <= 0.6 }
    }

    private var state: ProximityState {
        ProximityState.make(running: running, hazard: hazardAhead,
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

    @ViewBuilder private var mapPanel: some View {
        MapPanel(snapshot: snapshot, vision: manager.visionReport, radius: manager.config.mapRadius,
                 coneHalfAngle: audio.coneHalfAngle, alertRange: audio.alertRange) {
            showMap = true
        }
        // Pushed into the corner so the fade runs off the screen edge, as a car's inset does.
        .padding(.trailing, -72)
        .padding(.top, -64)
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
            // Problems (no headphones, finding the floor) as one small line; nothing else
            // ever appears here, so the top of the screen stays clear.
            if let line = statusLine {
                Label(line.text, systemImage: line.symbol)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .fontDesign(.rounded)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, -HUDMetrics.spacingSmall)
                    .transition(.opacity)
                    .accessibilitySortPriority(2)
            }
            HUDControlBar(audio: audio, describeEnabled: running,
                          onDescribe: { narrator.describe(snapshot: snapshot, vision: manager.visionReport) },
                          onSettings: { showSettings = true })
                .accessibilitySortPriority(2)
        }
        .frame(maxWidth: HUDMetrics.maxColumnWidth)
        .padding(.horizontal, HUDMetrics.margin)
        .padding(.top, HUDMetrics.spacingLarge * 2)
        .padding(.bottom, HUDMetrics.spacingSmall)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: statusLine?.text)
        // A standard scrim behind text over media, as Photos and video players do; it
        // dims only the bottom of the camera, never the room ahead.
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.45), .black.opacity(0.82)],
                           startPoint: .top, endPoint: .bottom)
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
