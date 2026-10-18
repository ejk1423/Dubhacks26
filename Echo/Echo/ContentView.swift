import SwiftUI
import Playgrounds
import simd

struct ContentView: View {
    @State private var manager = ARLiDARManager()
    @State private var audio = SpatialAudioEngine()

    var body: some View {
        ARWireframeView(manager: manager)
            .ignoresSafeArea()
            .overlay { edgeGlow }
            .overlay(alignment: .top) { statusBar }
            .overlay(alignment: .bottom) { panel }
            .onAppear {
                manager.onSnapshot = { [audio] in audio.update(snapshot: $0) }
                manager.start()
                audio.start()
            }
            .onDisappear {
                manager.pause()
                audio.stop()
            }
    }

    // MARK: Derived state

    private var snapshot: SceneSnapshot? { manager.snapshot }
    private var forward: ObstacleHit? { snapshot?.nearestForwardObstacle }
    private var hazard: TripHazard? { manager.tripHazards.first }
    private var floorFound: Bool { snapshot.map { $0.groundSource != .assumed } ?? false }

    /// Bearing of the corridor obstacle from the walking heading, radians, right positive.
    private var forwardBearing: Float? {
        guard let snap = snapshot, let hit = forward else { return nil }
        let right = simd_normalize(simd_cross(snap.heading, SIMD3(0, 1, 0)))
        let d = hit.point - snap.cameraPosition
        return atan2(d.x * right.x + d.z * right.z, d.x * snap.heading.x + d.z * snap.heading.z)
    }

    private enum Zone { case clear, far, near, imminent }

    private var zone: Zone {
        guard let d = forward?.horizontalDistance, d <= audio.alertRange else { return .clear }
        if d <= 0.3 { return .imminent }
        if d <= 0.45 { return .near }
        return .far
    }

    private var zoneColor: Color {
        switch zone {
        case .clear: return Color(red: 0.3, green: 0.95, blue: 0.55)
        case .far: return .yellow
        case .near: return .orange
        case .imminent: return Color(red: 1, green: 0.25, blue: 0.25)
        }
    }

    private var headline: String {
        guard manager.status == .running else { return "—" }
        if let hazard { return hazardName(hazard.kind) }
        switch zone {
        case .clear: return "Clear"
        case .far: return "Ahead"
        case .near: return "Close"
        case .imminent: return "Stop"
        }
    }

    private var detail: String? {
        if let hazard { return String(format: "%.1f m ahead", hazard.distanceAhead) }
        guard let d = forward?.horizontalDistance else { return nil }
        let side: String
        if let b = forwardBearing, abs(b) > 0.12 { side = b < 0 ? " · left" : " · right" } else { side = "" }
        return String(format: "%.1f m%@", d, side)
    }

    // MARK: Edge glow (direction of the last cue)

    private var edgeGlow: some View {
        GeometryReader { geo in
            if let azimuth = audio.lastCueAzimuth, abs(azimuth) > 0.1 {
                let onRight = azimuth > 0
                LinearGradient(
                    colors: [zoneColor.opacity(0.75), .clear],
                    startPoint: onRight ? .trailing : .leading,
                    endPoint: onRight ? .leading : .trailing
                )
                .frame(width: geo.size.width * 0.35)
                .frame(maxWidth: .infinity, alignment: onRight ? .trailing : .leading)
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.3), value: audio.lastCueAzimuth == nil)
    }

    // MARK: Top status bar

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                RadarView(
                    sectorDistances: snapshot?.sectorDistances ?? [],
                    forwardDistance: forward?.horizontalDistance,
                    forwardBearing: forwardBearing,
                    maxRange: manager.config.obstacleMaxRange,
                    alertRange: audio.alertRange,
                    zoneColor: zoneColor
                )
                .frame(width: 150, height: 84)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    chip("sensor.fill", manager.capabilities.hasLiDAR ? "LiDAR" : "No LiDAR", ok: manager.capabilities.hasLiDAR)
                    chip("headphones", audio.headphonesConnected ? "Headphones" : "No headphones", ok: audio.headphonesConnected)
                    chip("square.stack.3d.down.right.fill", floorFound ? "Floor" : "Finding floor", ok: floorFound)
                }
                Spacer(minLength: 0)
            }
            if let message = statusMessage {
                Text(message)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ symbol: String, _ text: String, ok: Bool) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(ok ? .white : .orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    /// Only shown when something needs attention.
    private var statusMessage: String? {
        switch manager.status {
        case .running: return nil
        case .idle: return "Idle"
        case .starting: return "Starting…"
        case .limited(let reason): return reason
        case .interrupted: return "Interrupted"
        case .failed(let msg): return "Failed: \(msg)"
        case .unsupported(let msg): return msg
        }
    }

    // MARK: Bottom panel: radar + readout + controls

    private var panel: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                    Text(headline)
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .foregroundStyle(hazard == nil ? zoneColor : .red)
                        .contentTransition(.interpolate)
                    if let detail {
                        Text(detail)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .contentTransition(.numericText())
                    }
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 10) {
                control(audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        audio.isMuted ? "Unmute" : "Mute") { audio.isMuted.toggle() }
                control(audio.hapticsEnabled ? "iphone.radiowaves.left.and.right" : "iphone.slash",
                        "Haptics") { audio.hapticsEnabled.toggle() }
                control("arrow.counterclockwise", "Reset map") { manager.reset() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func control(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func hazardName(_ kind: TripHazardKind) -> String {
        switch kind {
        case .drop: return "Step down"
        case .bump: return "Step up"
        case .unknownSurface: return "Uneven"
        }
    }
}

// MARK: - Radar

/// Half-circle sonar display: the user is at the bottom centre, walking up. Each of the
/// five forward sectors draws an arc at its obstacle distance; the corridor obstacle is
/// a dot at its true bearing.
private struct RadarView: View {
    let sectorDistances: [Float]
    let forwardDistance: Float?
    let forwardBearing: Float?
    let maxRange: Float
    let alertRange: Float
    let zoneColor: Color

    var body: some View {
        Canvas { context, size in
            let origin = CGPoint(x: size.width / 2, y: size.height - 6)
            let radius = min(size.width / 2, size.height) - 8
            func r(_ distance: Float) -> CGFloat { radius * CGFloat(min(distance / maxRange, 1)) }

            // Range rings + alert radius.
            for metres in stride(from: 1, through: Int(maxRange), by: 1) {
                let path = Path { p in
                    p.addArc(center: origin, radius: r(Float(metres)), startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                }
                context.stroke(path, with: .color(.white.opacity(0.18)), lineWidth: 1)
            }
            let alert = Path { p in
                p.addArc(center: origin, radius: r(alertRange), startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            }
            context.stroke(alert, with: .color(zoneColor.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

            // Forward sectors: 6 = left, 7, 0 = ahead, 1, 2 = right (45 degrees each).
            if sectorDistances.count == 8 {
                for (k, offset) in [(6, -90.0), (7, -45.0), (0, 0.0), (1, 45.0), (2, 90.0)] {
                    let d = sectorDistances[k]
                    guard d.isFinite else { continue }
                    let centre = Angle.degrees(270 + offset)
                    let path = Path { p in
                        p.addArc(center: origin, radius: r(d), startAngle: centre - .degrees(20), endAngle: centre + .degrees(20), clockwise: false)
                    }
                    let color: Color = d <= alertRange ? zoneColor : .white
                    context.stroke(path, with: .color(color.opacity(d <= alertRange ? 0.9 : 0.5)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }
            }

            // Corridor obstacle at its exact bearing.
            if let d = forwardDistance, let bearing = forwardBearing {
                let angle = CGFloat(bearing) - .pi / 2
                let point = CGPoint(x: origin.x + r(d) * cos(angle), y: origin.y + r(d) * sin(angle))
                context.fill(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)), with: .color(zoneColor))
                context.stroke(Path(ellipseIn: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)), with: .color(zoneColor.opacity(0.5)), lineWidth: 2)
            }

            // The user.
            let user = Path { p in
                p.move(to: CGPoint(x: origin.x, y: origin.y - 10))
                p.addLine(to: CGPoint(x: origin.x - 7, y: origin.y + 2))
                p.addLine(to: CGPoint(x: origin.x + 7, y: origin.y + 2))
                p.closeSubpath()
            }
            context.fill(user, with: .color(.white))
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    ContentView()
}

#Playground {
    _ = 1 + 2
}
