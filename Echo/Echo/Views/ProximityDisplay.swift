//
//  ProximityDisplay.swift
//  Echo
//
//  The way ahead, as big as the screen allows and with nothing in the way: the
//  distance in giant type and the state as a word with a symbol. The obstacle itself
//  is lit red in the scene (SurfaceRenderer.highlight), so the eye is drawn to the
//  thing, not to a gauge.
//
//  No card, no ring, no morphing text: values swap instantly. Colour is never the only
//  carrier: every state has its word and its symbol (HIG › Accessibility).
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
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
