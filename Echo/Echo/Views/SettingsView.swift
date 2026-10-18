//
//  SettingsView.swift
//  Echo
//
//  Grouped settings in a system sheet: Sound, Voice, Display, Map, Help, About.
//  Sound toggles write through to the audio engine and narrator; the HUD mirrors them
//  into HUDPreferences.
//
//  HIG › Sheets: medium and large detents, a grabber, Done on the trailing edge, swipe
//  to dismiss. HIG › Toggles: switches only inside list rows, so every on/off here is
//  a plain `Toggle` in a `Form`. Every row is a system control at its default size.
//

import AVFAudio
import SwiftUI

struct SettingsView: View {
    @Bindable var audio: SpatialAudioEngine
    @Bindable var narrator: Narrator
    @Bindable var prefs: HUDPreferences
    let manager: ARLiDARManager
    /// Called before the sheet dismisses; the HUD presents the follow-up once it has gone.
    let onReplayTutorial: () -> Void
    let onShowMap: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                soundSection
                voiceSection
                displaySection
                mapSection
                helpSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Sound

    private var soundSection: some View {
        Section {
            HStack(spacing: HUDMetrics.spacing) {
                Image(systemName: "speaker.wave.1.fill").foregroundStyle(.secondary)
                Slider(value: $audio.masterVolume, in: 0...1)
                    .accessibilityLabel("Beep volume")
                    .accessibilityValue("\(Int((audio.masterVolume * 100).rounded())) percent")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            Picker(selection: Binding(
                get: { audio.isMuted ? 2 : (audio.hapticsOnly ? 1 : 0) },
                set: { choice in
                    audio.isMuted = choice == 2
                    audio.hapticsOnly = choice == 1
                    if choice == 1 { audio.hapticsEnabled = true }
                    Haptics.select()
                })) {
                Text("Beeps").tag(0)
                Text("Haptics Only").tag(1)
                Text("Off").tag(2)
            } label: {
                Label("Collision Warning", systemImage: "dot.radiowaves.left.and.right")
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $narrator.isEnabled) {
                Label("Voice", systemImage: "waveform")
            }
            Toggle(isOn: $audio.hapticsEnabled) {
                Label("Haptic Ticks", systemImage: "iphone.radiowaves.left.and.right")
            }
            HStack(spacing: 12) {
                Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary)
                Slider(value: $audio.stereoWidth, in: 0.5...1.5)
                    .accessibilityLabel("Stereo width")
                    .accessibilityValue("\(Int((audio.stereoWidth * 100).rounded())) percent")
                Image(systemName: "arrow.left.and.right.square.fill").foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(get: { narrator.earconsEnabled }, set: { narrator.earconsEnabled = $0; audio.earconsEnabled = $0 })) {
                Label("Chimes Before Warnings", systemImage: "bell.badge.waveform")
            }
        } header: {
            Text("Sound")
        } footer: {
            Text("Warnings only come when you are about 1.3 seconds from hitting what is ahead, or already within arm's reach. Standing still or walking past is silent. Haptics Only keeps the ticks in your hand and drops the sound.")
        }
        .onChange(of: narrator.isEnabled) { Haptics.select() }
        .onChange(of: audio.hapticsEnabled) { Haptics.select() }
    }

    // MARK: Voice

    private var voiceSection: some View {
        Section {
            Picker(selection: $narrator.verbosity) {
                ForEach(NarrationVerbosity.allCases) { level in
                    Text(level.title).tag(level)
                }
            } label: {
                Label("Talkativeness", systemImage: "text.bubble")
            }
            .pickerStyle(.segmented)
            .onChange(of: narrator.verbosity) { Haptics.select() }
            Picker(selection: Binding(get: { narrator.preferredVoiceIdentifier ?? "" },
                                      set: { narrator.preferredVoiceIdentifier = $0.isEmpty ? nil : $0 })) {
                Text("Best Available").tag("")
                ForEach(Narrator.englishVoices(), id: \.identifier) { voice in
                    Text("\(voice.name) · \(voice.language)").tag(voice.identifier)
                }
            } label: {
                Label("Voice", systemImage: "person.wave.2")
            }
            LabeledContent("In Use", value: narrator.voiceDescription)
            HStack(spacing: HUDMetrics.spacing) {
                Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                Slider(value: $narrator.speechRate, in: 0.4...0.65)
                    .accessibilityLabel("Speaking rate")
                Image(systemName: "hare.fill").foregroundStyle(.secondary)
            }
            Button {
                narrator.announce("This is how I sound.")
            } label: {
                Label("Test Voice", systemImage: "play.fill")
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("Normal: steps, people in your path, which side is open when you are blocked, and safety signs. More: also what is ahead by name, doorways and path changes. Everything: all of it, more often. Premium voices download from Settings › Accessibility › Spoken Content.")
        }
    }

    // MARK: Display

    private var displaySection: some View {
        Section {
            Picker(selection: $prefs.cameraFeed) {
                ForEach(CameraFeedPreference.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            } label: {
                Label("Camera", systemImage: "camera.fill")
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Camera feed")
            // TODO: `ARLiDARManager` has no public switch for the surface rendering
            // (SurfaceRenderer is private). Expose one and add a "Show Surfaces" toggle here.
        } header: {
            Text("Display")
        } footer: {
            Text("Dim or switch off the camera to see the LiDAR surfaces on black.")
        }
    }

    // MARK: Map

    private var mapSection: some View {
        Section("Map") {
            Button {
                onShowMap()
                dismiss()
            } label: {
                Label("Show Full Map", systemImage: "map")
            }
            Button(role: .destructive) {
                Haptics.toggled(on: false)
                manager.reset()
            } label: {
                Label("Reset Map", systemImage: "arrow.counterclockwise")
            }
            .accessibilityHint("Forgets every scanned surface and starts tracking again")
        }
    }

    // MARK: Help

    private var helpSection: some View {
        Section {
            Button {
                onReplayTutorial()
                dismiss()
            } label: {
                Label("Replay Tutorial", systemImage: "play.circle")
            }
            // The legend for the proximity state: the one place the three state colours are
            // explained, each paired with its symbol and words.
            helpRow("checkmark", .green, "Green and silence: the way ahead is clear.")
            helpRow("exclamationmark.triangle.fill", .orange, "Orange and slow beeps: something is in your path. Slow down.")
            helpRow("hand.raised.fill", .red, "Red and a solid tone: stop, you are about to touch it.")
            helpRow("figure.stairs", .red, "\"Step up\" and \"Step down\" are spoken about a second and a half before your foot gets there.")
        } header: {
            Text("Help")
        }
    }

    private func helpRow(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.version)
            LabeledContent("LiDAR", value: manager.capabilities.hasLiDAR ? "Ready" : "Not available")
            LabeledContent("Headphones", value: audio.headphonesConnected ? "Connected" : "Not connected")
            LabeledContent("Mesh Chunks", value: "\(manager.meshAnchorCount)")
            LabeledContent("Walking Speed", value: String(format: "%.1f m/s", manager.snapshot?.walkingSpeed ?? 0))
        } header: {
            Text("About")
        } footer: {
            Text("Echo runs entirely on this phone: LiDAR mesh, depth and camera vision never leave the device. Built at DubHacks 2026.")
        }
    }

    private static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}
