//
//  ContentView.swift
//  Echo
//
//  The HUD. Wires the perception manager to the audio engine and narrator, derives
//  one `ProximityState` from them, and lays it out over the camera in two layers
//  (HIG › Materials): the AR view is content; a handful of Liquid Glass elements
//  float above it.
//
//    Top       Detail mode: the small map (leading) and one status line (trailing).
//              Simple mode: the status line only, and only when there is a problem.
//    Bottom    The proximity gauge (the single focal point), the prominent Describe
//              button, and one group of three glass buttons: Repeat, Mute Beeps,
//              Settings. All in the bottom third, within thumb reach.
//
//  Settings and the full map are sheets; the tutorial is a full-screen cover. Only
//  one is shown at a time (HIG › Sheets): a request made from inside Settings is
//  carried out after that sheet has gone.
//
//  Pieces live under Views/: HUDStyle, ProximityState, ProximityGauge, HUDBar,
//  MinimapView (+ MapView), OnboardingView, SettingsView, HUDPreferences.
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
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: prefs.simpleMode)
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

    /// Second line under the state (Detail mode): the last spoken line for a few
    /// seconds, else what is ahead by name.
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

    /// The one thing worth a line at the top right now, most important first. Problems
    /// in both modes; what the camera sees only in Detail mode (HIG › Designing for iOS:
    /// "limiting the number of onscreen controls while making secondary details ...
    /// discoverable").
    private var statusLine: (symbol: String, text: String)? {
        if let statusMessage { return ("exclamationmark.circle", statusMessage) }
        if !manager.capabilities.hasLiDAR { return ("sensor.fill", "No LiDAR on this device") }
        if !audio.headphonesConnected { return ("headphones", "No headphones") }
        if running, !floorFound { return ("square.stack.3d.down.right", "Finding the floor") }
        guard !prefs.simpleMode else { return nil }
        if let person = peopleAhead.first(where: \.movingTowardYou) {
            return ("figure.walk.motion", person.distance.map { String(format: "%@ coming · %.1f m", person.label, $0) } ?? "\(person.label) coming")
        }
        if let person = peopleAhead.first {
            return ("figure.stand", person.distance.map { String(format: "%@ · %.1f m", person.label, $0) } ?? person.label)
        }
        if let overhead = snapshot?.nearestOverheadObstacle, overhead.horizontalDistance < 1.5 {
            return ("arrow.down.to.line", String(format: "Low overhead · %.1f m", overhead.horizontalDistance))
        }
        if let door = snapshot?.openings.first(where: \.isDoorway) {
            let side = door.bearing < -0.4 ? "left" : (door.bearing > 0.4 ? "right" : "ahead")
            return ("door.left.hand.open", String(format: "Doorway %@ · %.1f m", side, door.distance))
        }
        if let scene = freshVision?.scene { return ("eye", scene) }
        return nil
    }

    // MARK: Top

    @ViewBuilder private var topBar: some View {
        // Side by side when the status fits; stacked at large text sizes
        // (HIG › Typography: "consider using a stacked layout").
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: HUDMetrics.spacing) {
                minimap
                Spacer(minLength: 0)
                status
            }
            // No Spacer here: in an overlay it would stretch to the full height.
            VStack(alignment: .leading, spacing: HUDMetrics.spacingSmall) {
                minimap
                status
            }
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

    @ViewBuilder private var minimap: some View {
        if !prefs.simpleMode {
            MinimapButton(snapshot: snapshot, radius: manager.config.mapRadius,
                          coneHalfAngle: audio.coneHalfAngle, alertRange: audio.alertRange) {
                showMap = true
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let line = statusLine {
            StatusLine(symbol: line.symbol, text: line.text)
                .transition(.opacity)
        }
    }

    // MARK: Bottom

    @ViewBuilder private var bottomColumn: some View {
        VStack(spacing: HUDMetrics.spacing) {
            ProximityGauge(state: state, detail: prefs.simpleMode ? nil : detailLine, large: prefs.simpleMode)
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
        .padding(.bottom, HUDMetrics.spacingSmall)
        .environment(\.colorScheme, .dark)
        .accessibilitySortPriority(1)
    }
}

#Preview {
    ContentView()
}
