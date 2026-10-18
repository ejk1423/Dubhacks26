//
//  ProximityDisplay.swift
//  Echo
//
//  The way ahead, as big as the screen allows and with nothing in the way: the
//  distance in giant type, the state as a word with a symbol, and a coloured frame
//  around the screen edge that thickens as the thing ahead gets closer, so low-vision
//  users read it peripherally without looking at any one spot.
//
//  No card, no ring, no morphing text: values swap instantly, only the frame's opacity
//  eases (and not under Reduce Motion). Colour is never the only carrier: every state
//  has its word and its symbol (HIG › Accessibility).
//

import SwiftUI

struct ProximityDisplay: View {
    let state: ProximityState

    // The number is the one permitted custom size; it scales with Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 104
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 72

    var body: some View {
        VStack(spacing: HUDMetrics.spacingSmall) {
            if let distance = state.distance, state.level != .inactive {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(distance, format: .number.precision(.fractionLength(1)))
                        .font(.system(size: numberSize, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("m")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .fontDesign(.rounded)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            } else {
                Image(systemName: state.symbol)
                    .font(.system(size: symbolSize, weight: .heavy))
                    .foregroundStyle(state.color)
                    .frame(height: numberSize * 1.1)
            }

            HStack(spacing: HUDMetrics.spacingSmall) {
                if state.distance != nil {
                    Image(systemName: state.symbol)
                }
                Text(state.title)
            }
            .font(.largeTitle)
            .fontWeight(.bold)
            .fontDesign(.rounded)
            .foregroundStyle(state.color)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        // Text over camera, with no panel: a soft shadow keeps it legible on any background.
        .shadow(color: .black.opacity(0.8), radius: 10, y: 2)
        .shadow(color: .black.opacity(0.5), radius: 2)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Coloured frame along the screen edge: invisible when clear, thickening and
/// brightening in the state colour as the way ahead closes. Peripheral, not obstructive.
struct ProximityEdge: View {
    let state: ProximityState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var strength: Double {
        switch state.kind {
        case .starting, .clear: return 0
        case .hazard, .edge: return 0.9
        case .floorObject: return 0.6
        case .ahead, .slow, .stop: return 0.25 + 0.7 * Double(state.closeness)
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 58, style: .continuous)
            .strokeBorder(state.color, lineWidth: reduceTransparency ? 10 : 22 + 26 * strength)
            .blur(radius: reduceTransparency ? 0 : 18)
            .opacity(strength)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: strength)
    }
}
