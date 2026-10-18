//
//  ProximityGauge.swift
//  Echo
//
//  The HUD's single focal point (HIG › Layout, "Visual hierarchy"): one glass card
//  holding a ring that fills as the thing ahead gets closer, the distance in large
//  type, and the state as a word with a symbol. `large` is the Simple-mode size.
//  VoiceOver reads the whole card as one element: "Obstacle 0.8 metres ahead".
//

import SwiftUI

struct ProximityGauge: View {
    let state: ProximityState
    /// Optional second line: the last spoken line, or what the camera thinks is ahead.
    let detail: String?
    var large = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Every custom dimension scales with Dynamic Type (HIG › Typography, "Supporting
    // Dynamic Type"). The number is the one permitted custom size.
    @ScaledMetric(relativeTo: .largeTitle) private var compactRing: CGFloat = 160
    @ScaledMetric(relativeTo: .largeTitle) private var largeRing: CGFloat = 224
    @ScaledMetric(relativeTo: .largeTitle) private var compactNumber: CGFloat = 52
    @ScaledMetric(relativeTo: .largeTitle) private var largeNumber: CGFloat = 76
    @ScaledMetric(relativeTo: .largeTitle) private var compactSymbol: CGFloat = 44
    @ScaledMetric(relativeTo: .largeTitle) private var largeSymbol: CGFloat = 64

    /// Capped so the ring never outgrows a phone at accessibility text sizes.
    private var ring: CGFloat { min(large ? largeRing : compactRing, 280) }
    private var stroke: CGFloat { ring * 0.06 }
    private var numberSize: CGFloat { large ? largeNumber : compactNumber }
    private var symbolSize: CGFloat { large ? largeSymbol : compactSymbol }
    private var cornerRadius: CGFloat { HUDMetrics.spacingLarge + HUDMetrics.spacingSmall }

    var body: some View {
        VStack(spacing: HUDMetrics.spacing) {
            dial
                .frame(width: ring, height: ring)

            VStack(spacing: HUDMetrics.spacingSmall) {
                // Word + symbol: colour is never the only carrier (HIG › Accessibility,
                // "Convey information with more than color alone").
                HStack(alignment: .firstTextBaseline, spacing: HUDMetrics.spacingSmall) {
                    Image(systemName: state.symbol)
                        .foregroundStyle(state.color)
                        .symbolRenderingMode(.monochrome)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    Text(state.title)
                        .contentTransition(reduceMotion ? .identity : .interpolate)
                }
                .font(large ? .largeTitle : .title)
                .fontWeight(.bold)
                .fontDesign(.rounded)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)

                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .contentTransition(reduceMotion ? .identity : .interpolate)
                }
            }
            .multilineTextAlignment(.center)
        }
        .padding(.vertical, HUDMetrics.spacingLarge)
        .padding(.horizontal, HUDMetrics.spacingLarge)
        .frame(maxWidth: .infinity)
        .hudSurface(.clear, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.kind)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityValue(detail ?? "")
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: Dial

    private var dial: some View {
        ZStack {
            Circle()
                .stroke(.tertiary, lineWidth: stroke)
            if let fill = state.ringFill {
                Circle()
                    .trim(from: 0, to: CGFloat(fill))
                    .stroke(state.color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: fill)
                    .transition(.opacity)
            }
            centre
                .padding(stroke + HUDMetrics.spacingSmall)
        }
    }

    @ViewBuilder private var centre: some View {
        if let distance = state.distance, state.level != .inactive {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(distance, format: .number.precision(.fractionLength(1)))
                    .font(.system(size: numberSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                Text("m")
                    .font(large ? .title2 : .title3)
                    .fontWeight(.semibold)
                    .fontDesign(.rounded)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
        } else {
            Image(systemName: state.symbol)
                .font(.system(size: symbolSize, weight: .bold))
                .foregroundStyle(state.color)
                // The only running symbol animation, and only while starting up; it stops
                // under Reduce Motion (HIG › Accessibility, "Be cautious with ... animations").
                .symbolEffect(.variableColor.iterative, options: .repeating,
                              isActive: state.kind == .starting && !reduceMotion)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
    }
}
