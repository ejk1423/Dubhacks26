//
//  HUDStyle.swift
//  Echo
//
//  The HUD's design system, kept deliberately small so the camera stays the subject.
//
//    * Two layers (HIG › Materials). The camera / LiDAR view is content. The few
//      controls above it are Liquid Glass: system buttons pick the material up on
//      their own, and the two custom surfaces (gauge, minimap) use `hudSurface`.
//    * One spacing scale (8 / 16 / 24) and the system text styles only. The single
//      custom size is the gauge number, which is a `@ScaledMetric`.
//    * Colour is semantic (HIG › Color). The app accent marks the one prominent
//      action; the three system state colours (green / orange / red) appear only on
//      the proximity state itself, never as decoration.
//

import SwiftUI
import UIKit

nonisolated enum HUDMetrics {
    static let spacingSmall: CGFloat = 8
    static let spacing: CGFloat = 16
    static let spacingLarge: CGFloat = 24
    /// Standard iPhone layout margin (HIG › Layout: respect system margins).
    static let margin: CGFloat = 16
    /// HIG › Materials: "If the underlying content is bright, consider adding a dark
    /// dimming layer of 35% opacity" behind clear Liquid Glass. The camera feed is bright.
    static let dimming: Double = 0.35
    /// Widest the floating column gets, so landscape and iPad do not stretch it.
    static let maxColumnWidth: CGFloat = 480
}

// MARK: - Liquid Glass for custom HUD surfaces

/// Which Liquid Glass variant a custom surface wants (HIG › Materials).
nonisolated enum HUDGlass {
    /// Highly translucent, for the gauge and minimap over the camera, with the 35% dimming
    /// layer the guidance recommends over bright content.
    case clear
    /// Blurs and adjusts luminosity for legibility; for the text-bearing status line.
    case regular
}

/// Glass for the custom HUD surfaces (proximity gauge, minimap, status line).
///
/// * The dimming layer sits *behind* clear glass, as the guidance describes.
/// * With Reduce Transparency or Increase Contrast on, the glass is replaced by a solid
///   system background so text keeps its contrast (HIG › Accessibility).
/// * Before iOS 26 the equivalent standard material is used.
struct HUDSurface<S: Shape>: ViewModifier {
    let glass: HUDGlass
    let shape: S
    var interactive = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(Color(.systemBackground).opacity(0.92), in: shape)
        } else if #available(iOS 26, *) {
            switch glass {
            case .clear:
                content
                    .glassEffect(.clear.interactive(interactive), in: shape)
                    .background(Color.black.opacity(HUDMetrics.dimming), in: shape)
            case .regular:
                content.glassEffect(.regular.interactive(interactive), in: shape)
            }
        } else {
            switch glass {
            case .clear:
                content
                    .background(.thinMaterial, in: shape)
                    .background(Color.black.opacity(HUDMetrics.dimming), in: shape)
            case .regular:
                content.background(.regularMaterial, in: shape)
            }
        }
    }
}

extension View {
    func hudSurface(_ glass: HUDGlass = .clear, in shape: some Shape, interactive: Bool = false) -> some View {
        modifier(HUDSurface(glass: glass, shape: shape, interactive: interactive))
    }
}

// MARK: - System glass buttons

/// `.glass` / `.glassProminent` on iOS 26, the bordered equivalents before it, so every
/// button stays a system button with its own press state and accessibility.
struct HUDButtonStyle: ViewModifier {
    var prominent = false

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        }
    }
}

extension View {
    func hudButtonStyle(prominent: Bool = false) -> some View {
        modifier(HUDButtonStyle(prominent: prominent))
    }
}

/// `GlassEffectContainer` on iOS 26 so neighbouring glass buttons read as one group.
struct HUDGlassGroup<Content: View>: View {
    var spacing: CGFloat = HUDMetrics.spacingSmall
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

// MARK: - Haptics for controls

/// Every control answers with a tap, so the HUD can be worked without looking.
/// HIG › Accessibility: "Use haptics in addition to audio cues."
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
