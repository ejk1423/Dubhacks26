//
//  HUDBar.swift
//  Echo
//
//  The controls that float over the camera, all system components so they pick up
//  Liquid Glass, press states, Dynamic Type and accessibility on their own
//  (HIG › Buttons: "System buttons offer ... built-in interaction states,
//  accessibility support, and appearance adaptation").
//
//    * DescribeButton   the one prominent action (HIG: "Keep the number of prominent
//                       buttons to one or two per view").
//    * HUDControlBar    Repeat, Mute Beeps and Settings in one glass group, like a
//                       bottom toolbar (HIG › Toolbars: one group, symbols, no borders).
//    * MinimapButton    the small map that opens the full one.
//

import SwiftUI

// MARK: - Describe

struct DescribeButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Label("Describe", systemImage: "text.bubble.fill")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .frame(minWidth: 120)
        }
        // The accent-tinted glass marks this as the primary action (HIG › Color, Liquid
        // Glass: "apply color to the background rather than to symbols or text").
        .hudButtonStyle(prominent: true)
        .controlSize(.extraLarge)
        .disabled(!enabled)
        .accessibilityLabel("Describe surroundings")
        .accessibilityHint("Speaks what is around you: the room, what is ahead, which sides are open, people and steps.")
    }
}

// MARK: - Bottom control group

struct HUDControlBar: View {
    @Bindable var audio: SpatialAudioEngine
    let describeEnabled: Bool
    let onDescribe: () -> Void
    let onSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Haptic on the tap itself, not on every change (the persisted value is applied at launch).
    private var muted: Binding<Bool> {
        Binding(get: { audio.isMuted }, set: { audio.isMuted = $0; Haptics.toggled(on: !$0) })
    }

    var body: some View {
        // One container so the three glass circles read as a single group.
        HUDGlassGroup {
            HStack(spacing: HUDMetrics.spacingSmall) {
                DescribeButton(enabled: describeEnabled, action: onDescribe)
                    .layoutPriority(1)

                // HIG › Toggles: "Outside of a list, use a button that behaves like a toggle,
                // not a switch", and show state by more than colour: the slash does that.
                Toggle(isOn: muted) {
                    Label("Mute Beeps", systemImage: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .hudButtonStyle()
                .buttonBorderShape(.circle)
                .accessibilityHint("Silences the collision beeps")

                Button {
                    Haptics.tap()
                    onSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .labelStyle(.iconOnly)
                .hudButtonStyle()
                .buttonBorderShape(.circle)
                .accessibilityHint("Sound, voice, display, map and help")
            }
            .fontWeight(.semibold)
            .controlSize(.extraLarge)
        }
    }
}

// MARK: - Map panel

/// The map floating in the top-right corner with no frame: a soft dark cloud fades into
/// the camera at the edges (as a car's navigation inset does), and the drawing sits on
/// it. Tapping opens the full map.
struct MapPanel: View {
    let snapshot: SceneSnapshot?
    let vision: VisionReport?
    let radius: Float
    let coneHalfAngle: Float
    let alertRange: Float
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 272

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            MinimapView(snapshot: snapshot, vision: vision, radius: radius,
                        coneHalfAngle: coneHalfAngle, alertRange: alertRange)
                .frame(width: min(size, 320), height: min(size, 320))
                // Both the dark backing and the mask reach full transparency inside the
                // inscribed circle, so no corner of the square ever shows.
                .background(
                    RadialGradient(colors: [.black.opacity(0.7), .black.opacity(0.62), .clear],
                                   center: .center, startRadius: 0, endRadius: min(size, 320) * 0.5)
                )
                .mask(
                    RadialGradient(colors: [.black, .black, .clear],
                                   center: .center, startRadius: 0, endRadius: min(size, 320) * 0.5)
                )
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map of the room")
        .accessibilityHint("Opens the full map with distances in every direction")
    }
}
