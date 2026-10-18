//
//  Theme.swift
//  Echo
//
//  The HUD's visual language. Three colours say everything about the way ahead
//  (clear / caution / danger); everything else is white type in SF Rounded on dark
//  glass, so the camera feed stays readable underneath.
//

import SwiftUI
import UIKit

nonisolated enum Theme {

    // Proximity semantics. Every element that talks about the way ahead uses these.
    static let clear = Color(red: 0.30, green: 0.87, blue: 0.60)
    static let caution = Color(red: 1.00, green: 0.74, blue: 0.22)
    static let danger = Color(red: 1.00, green: 0.30, blue: 0.32)
    static let inactive = Color(white: 0.62)

    // Map palette.
    static let live = Color(red: 0.42, green: 0.84, blue: 1.00)
    static let wall = Color.white
    static let furniture = caution

    // Layout.
    static let gutter: CGFloat = 16
    static let radius: CGFloat = 24
    static let chipRadius: CGFloat = 14
    static let controlHeight: CGFloat = 64

    static func font(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Blend across the three state colours for a 0 (far) ... 1 (contact) closeness.
    static func proximityColor(closeness: Float) -> Color {
        let c = Double(min(1, max(0, closeness)))
        if c < 0.5 { return clear.mix(with: caution, by: c * 2) }
        return caution.mix(with: danger, by: (c - 0.5) * 2)
    }
}

// MARK: - Glass panels

struct Glass: ViewModifier {
    var cornerRadius: CGFloat = Theme.radius
    var tint: Color = .clear
    var tintOpacity: Double = 0

    func body(content: Content) -> some View {
        content
            .background(tint.opacity(tintOpacity))
            .background(.black.opacity(0.32))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
    }
}

extension View {
    func glass(cornerRadius: CGFloat = Theme.radius, tint: Color = .clear, tintOpacity: Double = 0) -> some View {
        modifier(Glass(cornerRadius: cornerRadius, tint: tint, tintOpacity: tintOpacity))
    }
}

// MARK: - Haptics for controls

/// Every control answers with a tap, so toggles can be worked without looking.
enum Haptics {
    private static let impact = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()
    private static let selection = UISelectionFeedbackGenerator()

    static func tap() { impact.impactOccurred() }
    static func toggled(on: Bool) {
        if on { notification.notificationOccurred(.success) } else { impact.impactOccurred(intensity: 0.55) }
    }
    static func select() { selection.selectionChanged() }
}
