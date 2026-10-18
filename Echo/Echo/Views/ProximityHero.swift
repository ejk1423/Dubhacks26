//
//  ProximityHero.swift
//  Echo
//
//  The one dominant element of the HUD: a ring that fills as the thing ahead gets
//  closer, the distance in giant type in the middle, and the state word under it.
//  `large` is the simple-mode size for low-vision use; the compact size sits in the
//  detail layout. VoiceOver reads it as one element: "Obstacle 0.8 metres ahead".
//

import SwiftUI

struct ProximityHero: View {
    let state: ProximityState
    /// Second line: the last spoken line, or what the camera thinks is ahead.
    let detail: String?
    var large = false

    private var ring: CGFloat { large ? 250 : 176 }
    private var stroke: CGFloat { large ? 18 : 12 }

    var body: some View {
        VStack(spacing: large ? 14 : 8) {
            gauge
                .frame(width: ring, height: ring)

            Text(state.title)
                .font(Theme.font(large ? 44 : 28, .heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.interpolate)

            Text(detail ?? " ")
                .font(Theme.font(large ? 21 : 15, .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(minHeight: large ? 26 : 18)
                .contentTransition(.interpolate)
        }
        .padding(.horizontal, Theme.gutter)
        .animation(.easeOut(duration: 0.2), value: state.kind)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityValue(detail ?? "")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var gauge: some View {
        ZStack {
            // Soft halo in the state colour, stronger as the target gets closer.
            Circle()
                .fill(state.color.opacity(0.10 + 0.30 * Double(state.closeness)))
                .blur(radius: large ? 26 : 18)
                .padding(-10)
            Circle()
                .stroke(.white.opacity(0.12), lineWidth: stroke)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.02, state.closeness)))
                .stroke(state.color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(state.distance == nil || state.level == .inactive ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: state.closeness)
            Circle()
                .fill(.black.opacity(0.4))
                .padding(stroke + 4)
            centre
        }
        .animation(.easeOut(duration: 0.25), value: state.level)
    }

    @ViewBuilder private var centre: some View {
        switch state.kind {
        case .starting:
            Image(systemName: "ellipsis")
                .font(.system(size: large ? 64 : 40, weight: .heavy))
                .foregroundStyle(Theme.inactive)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .clear:
            Image(systemName: "checkmark")
                .font(.system(size: large ? 92 : 54, weight: .heavy))
                .foregroundStyle(Theme.clear)
        case .hazard, .edge, .floorObject:
            VStack(spacing: 2) {
                Image(systemName: state.symbol ?? "exclamationmark")
                    .font(.system(size: large ? 64 : 40, weight: .heavy))
                    .foregroundStyle(state.color)
                if let distance = state.distance {
                    distanceText(distance, size: large ? 40 : 24, unitSize: large ? 18 : 12)
                }
            }
        case .ahead, .slow, .stop:
            if let distance = state.distance {
                distanceText(distance, size: large ? 96 : 56, unitSize: large ? 30 : 18)
            }
        }
    }

    private func distanceText(_ distance: Float, size: CGFloat, unitSize: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(String(format: "%.1f", distance))
                .font(Theme.font(size, .heavy))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("m")
                .font(Theme.font(unitSize, .bold))
                .foregroundStyle(.white.opacity(0.65))
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, stroke + 10)
    }
}

/// Soft glow along the screen edge in the state colour; red closing in from the
/// periphery reads even when the user is not looking at the centre.
struct EdgeGlow: View {
    let color: Color
    let strength: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 56, style: .continuous)
            .strokeBorder(color, lineWidth: 28)
            .blur(radius: 30)
            .opacity(strength)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(.easeOut(duration: 0.2), value: strength)
    }
}
