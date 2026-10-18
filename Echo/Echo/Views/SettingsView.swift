//
//  SettingsView.swift
//  Echo
//
//  Grouped settings: Sound, Display, Map, Help, About. Sound toggles write through to
//  the audio engine and narrator; the HUD mirrors them into HUDPreferences.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var audio: SpatialAudioEngine
    @Bindable var narrator: Narrator
    @Bindable var prefs: HUDPreferences
    let manager: ARLiDARManager
    let onReplayTutorial: () -> Void
    let onShowMap: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                soundSection
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
                        .font(Theme.font(17, .bold))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Sound

    private var soundSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.1.fill").foregroundStyle(.secondary)
                Slider(value: $audio.masterVolume, in: 0...1)
                    .accessibilityLabel("Beep volume")
                    .accessibilityValue("\(Int((audio.masterVolume * 100).rounded())) percent")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(get: { !audio.isMuted }, set: { audio.isMuted = !$0 })) {
                Label("Beeps", systemImage: "dot.radiowaves.left.and.right")
            }
            Toggle(isOn: $narrator.isEnabled) {
                Label("Voice", systemImage: "waveform")
            }
            Toggle(isOn: $audio.hapticsEnabled) {
                Label("Haptic ticks", systemImage: "iphone.radiowaves.left.and.right")
            }
        } header: {
            Text("Sound")
        } footer: {
            Text("Beeps warn about whatever is in the cone ahead, earlier when you walk faster. The voice names people, steps, objects and signs as you are about to reach them. Haptic ticks mirror the beeps in your hand.")
        }
        .onChange(of: audio.isMuted) { Haptics.select() }
        .onChange(of: narrator.isEnabled) { Haptics.select() }
        .onChange(of: audio.hapticsEnabled) { Haptics.select() }
    }

    // MARK: Display

    private var displaySection: some View {
        Section {
            Toggle(isOn: $prefs.simpleMode) {
                Label("Simple mode", systemImage: "circle.grid.cross.fill")
            }
            .onChange(of: prefs.simpleMode) { Haptics.select() }
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
            // (SurfaceRenderer is private). Expose one and add a "Show surfaces" toggle here.
        } header: {
            Text("Display")
        } footer: {
            Text("Simple mode shows only the way ahead in giant type and the Describe button. Detail mode adds the map, camera readings and status, for sighted testers. Dim or switch off the camera to see the LiDAR surfaces on black.")
        }
    }

    // MARK: Map

    private var mapSection: some View {
        Section("Map") {
            Button {
                dismiss()
                onShowMap()
            } label: {
                Label("Show full map", systemImage: "map.fill")
            }
            Button(role: .destructive) {
                Haptics.toggled(on: false)
                manager.reset()
            } label: {
                Label("Reset map", systemImage: "arrow.counterclockwise")
            }
            .accessibilityHint("Forgets every scanned surface and starts tracking again")
        }
    }

    // MARK: Help

    private var helpSection: some View {
        Section {
            Button {
                dismiss()
                onReplayTutorial()
            } label: {
                Label("Replay tutorial", systemImage: "play.circle.fill")
            }
            VStack(alignment: .leading, spacing: 8) {
                helpRow("checkmark.circle.fill", Theme.clear, "Green and silence: the way ahead is clear.")
                helpRow("exclamationmark.circle.fill", Theme.caution, "Amber and slow beeps: something is in your path. Slow down.")
                helpRow("octagon.fill", Theme.danger, "Red and a solid tone: stop, you are about to touch it.")
                helpRow("figure.stairs", Theme.danger, "\"Step up\" / \"Step down\" is spoken about a second and a half before your foot gets there.")
            }
            .padding(.vertical, 4)
        } header: {
            Text("Help")
        }
    }

    private func helpRow(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.version)
            LabeledContent("LiDAR", value: manager.capabilities.hasLiDAR ? "Ready" : "Not available")
            LabeledContent("Headphones", value: audio.headphonesConnected ? "Connected" : "Not connected")
            LabeledContent("Mesh chunks", value: "\(manager.meshAnchorCount)")
            LabeledContent("Walking speed", value: String(format: "%.1f m/s", manager.snapshot?.walkingSpeed ?? 0))
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
