//
//  HUDControls.swift
//  Echo
//
//  Buttons, toggles and chips shared by both HUD layouts. Everything is at least
//  60 pt tall, answers with a haptic, and carries a VoiceOver label and value.
//

import SwiftUI

// MARK: - Toggle with icon + label, used for Beeps / Voice / Haptics

struct HUDToggleStyle: ToggleStyle {
    let onSymbol: String
    let offSymbol: String

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
            Haptics.toggled(on: configuration.isOn)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: configuration.isOn ? onSymbol : offSymbol)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(height: 24)
                configuration.label
                    .font(Theme.font(12, .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: Theme.controlHeight)
            .foregroundStyle(configuration.isOn ? .white : .white.opacity(0.42))
            .background(
                RoundedRectangle(cornerRadius: Theme.chipRadius + 4, style: .continuous)
                    .fill(.white.opacity(configuration.isOn ? 0.16 : 0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.chipRadius + 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

// MARK: - Plain icon + label button (Settings, Map)

struct HUDButton: View {
    let title: String
    let symbol: String
    var hint: String? = nil
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(height: 24)
                Text(title)
                    .font(Theme.font(12, .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: Theme.controlHeight)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: Theme.chipRadius + 4, style: .continuous)
                    .fill(.white.opacity(0.10))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.chipRadius + 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(hint ?? "")
    }
}

// MARK: - Compact icon-only button (Where am I, mute, settings)

struct IconButton: View {
    let symbol: String
    let label: String
    var hint: String? = nil
    var dimmed = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(dimmed ? .white.opacity(0.4) : .white)
                .frame(width: 52, height: Theme.controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: Theme.chipRadius + 4, style: .continuous)
                        .fill(.white.opacity(dimmed ? 0.05 : 0.12))
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.chipRadius + 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
    }
}

// MARK: - Describe

struct DescribeButton: View {
    let enabled: Bool
    var large = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: large ? 26 : 18, weight: .bold))
                Text("Describe")
                    .font(Theme.font(large ? 28 : 18, .heavy))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: large ? 84 : Theme.controlHeight)
            .background(Capsule().fill(.white))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityLabel("Describe surroundings")
        .accessibilityHint("Speaks what is around you: the room, what is ahead, which sides are open, people and steps.")
    }
}

// MARK: - Small status chips (LiDAR, Headphones, Floor, scene, people)

struct StatusChip: View {
    let symbol: String
    let text: String
    var tint: Color = .white
    var ok: Bool? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
            Text(text)
                .font(Theme.font(12, .bold))
                .lineLimit(1)
            if let ok {
                Circle()
                    .fill(ok ? Theme.clear : Theme.caution)
                    .frame(width: 7, height: 7)
            }
        }
        .foregroundStyle(tint.opacity(ok == false ? 0.6 : 0.95))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .glass(cornerRadius: 15)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ok.map { "\(text): \($0 ? "ready" : "not ready")" } ?? text)
    }
}

/// Session status line at the top ("Initializing tracking. Hold still.").
struct StatusBanner: View {
    let text: String
    var tint: Color = Theme.caution

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(tint)
            Text(text)
                .font(Theme.font(14, .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glass(cornerRadius: 18)
        .accessibilityElement(children: .combine)
    }
}
