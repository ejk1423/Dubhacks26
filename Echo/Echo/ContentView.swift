import SwiftUI
import Playgrounds
import simd

struct ContentView: View {
    @State private var manager = ARLiDARManager()
    @State private var audio = SpatialAudioEngine()

    var body: some View {
        ARWireframeView(manager: manager)
            .ignoresSafeArea()
            .overlay(alignment: .top) { header }
            .overlay(alignment: .bottom) { footer }
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
    private var hazard: TripHazard? { manager.tripHazards.first }
    private var floorFound: Bool { snapshot.map { $0.groundSource != .assumed } ?? false }
    private var running: Bool { manager.status == .running }

    /// Green when clear, through amber, to red at contact.
    private var zoneColor: Color {
        guard audio.targetDistance != nil else { return Theme.clear }
        let c = Double(audio.closeness)
        if c < 0.5 { return Theme.clear.mix(with: Theme.caution, by: c * 2) }
        return Theme.caution.mix(with: Theme.danger, by: (c - 0.5) * 2)
    }

    private var statusWord: String {
        guard running else { return "Starting" }
        if let hazard { return hazardName(hazard.kind) }
        guard audio.targetDistance != nil else { return "Clear ahead" }
        switch audio.closeness {
        case ..<0.4: return "Obstacle ahead"
        case ..<0.85: return "Slow down"
        default: return "Stop"
        }
    }

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

    // MARK: Header: minimap + status

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                MinimapView(
                    snapshot: snapshot,
                    radius: manager.config.mapRadius,
                    coneHalfAngle: audio.coneHalfAngle,
                    alertRange: audio.alertRange,
                    accent: zoneColor
                )
                .frame(width: 168, height: 168)
                .glass(cornerRadius: 20)

                VStack(alignment: .leading, spacing: 6) {
                    StatusRow(symbol: "sensor.fill", text: "LiDAR", ok: manager.capabilities.hasLiDAR)
                    StatusRow(symbol: "headphones", text: "Headphones", ok: audio.headphonesConnected)
                    StatusRow(symbol: "square.stack.3d.down.right.fill", text: "Floor", ok: floorFound)
                }
                .padding(12)
                .glass(cornerRadius: 16)

                Spacer(minLength: 0)
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glass(cornerRadius: 20)
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Footer: proximity gauge + controls

    private var footer: some View {
        VStack(spacing: 18) {
            ProximityGauge(closeness: audio.closeness, distance: audio.targetDistance,
                           active: running, color: hazard == nil ? zoneColor : Theme.danger)
                .frame(width: 168, height: 168)

            Text(statusWord)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .contentTransition(.interpolate)

            HStack(spacing: 22) {
                IconToggle(symbol: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                           active: !audio.isMuted) { audio.isMuted.toggle() }
                IconToggle(symbol: "iphone.radiowaves.left.and.right",
                           active: audio.hapticsEnabled) { audio.hapticsEnabled.toggle() }
                IconToggle(symbol: "arrow.counterclockwise", active: true) { manager.reset() }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glass(cornerRadius: 30)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    private func hazardName(_ kind: TripHazardKind) -> String {
        switch kind {
        case .drop: return "Step down ahead"
        case .bump: return "Step up ahead"
        case .unknownSurface: return "Uneven ground"
        }
    }
}

// MARK: - Theme

private enum Theme {
    static let clear = Color(red: 0.36, green: 0.86, blue: 0.62)
    static let caution = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let danger = Color(red: 1.0, green: 0.33, blue: 0.33)
    static let wall = Color.white
    static let furniture = caution
    static let live = Color(red: 0.45, green: 0.85, blue: 1.0)
}

private struct Glass: ViewModifier {
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(.black.opacity(0.35))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

private extension View {
    func glass(cornerRadius: CGFloat) -> some View { modifier(Glass(cornerRadius: cornerRadius)) }
}

// MARK: - Components

private struct StatusRow: View {
    let symbol: String
    let text: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .frame(width: 16)
            Text(text)
                .font(.caption.weight(.semibold))
            Spacer(minLength: 6)
            Circle()
                .fill(ok ? Theme.clear : Theme.caution)
                .frame(width: 7, height: 7)
        }
        .foregroundStyle(.white.opacity(ok ? 0.95 : 0.6))
        .frame(width: 118)
    }
}

private struct IconToggle: View {
    let symbol: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(active ? .white : .white.opacity(0.4))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(active ? 0.14 : 0.06)))
        }
        .buttonStyle(.plain)
    }
}

/// Ring that fills as the obstacle ahead gets closer, with the distance in the middle.
private struct ProximityGauge: View {
    let closeness: Float
    let distance: Float?
    let active: Bool
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.12), lineWidth: 12)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.02, closeness)))
                .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(distance == nil ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: closeness)
            Circle()
                .fill(color.opacity(0.12 + 0.25 * Double(closeness)))
                .padding(14)

            VStack(spacing: 0) {
                if !active {
                    Text("—").font(.system(size: 40, weight: .bold, design: .rounded))
                } else if let distance {
                    Text(String(format: "%.1f", distance))
                        .font(.system(size: 48, weight: .heavy, design: .rounded))
                        .contentTransition(.numericText())
                    Text("metres")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 40, weight: .bold))
                }
            }
            .foregroundStyle(.white)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(distance.map { String(format: "Obstacle %.1f metres ahead", $0) } ?? "Clear ahead")
    }
}

/// Top-down blueprint of the room, heading-up, user at the centre.
private struct MinimapView: View {
    let snapshot: SceneSnapshot?
    let radius: Float
    let coneHalfAngle: Float
    let alertRange: Float
    let accent: Color

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let scale = CGFloat(min(size.width, size.height) / 2 - 8) / CGFloat(radius)
            let r = CGFloat(radius) * scale
            context.clip(to: Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)))

            guard let snap = snapshot else { return }
            let p0 = snap.cameraPosition
            var world = context
            world.translateBy(x: centre.x, y: centre.y)
            world.rotate(by: Angle(radians: -.pi / 2 - atan2(CGFloat(snap.heading.z), CGFloat(snap.heading.x))))
            func point(_ x: Float, _ z: Float) -> CGPoint {
                CGPoint(x: CGFloat(x - p0.x) * scale, y: CGFloat(z - p0.z) * scale)
            }

            let map = snap.map
            let cell = CGFloat(map.cellSize) * scale + 0.3
            var floor = Path(), walls = Path(), furniture = Path(), obstacles = Path(), live = Path()
            for row in 0..<map.size {
                for column in 0..<map.size {
                    let kind = map.cell(column, row)
                    guard kind != .empty else { continue }
                    let origin = point(map.origin.x + Float(column) * map.cellSize, map.origin.y + Float(row) * map.cellSize)
                    let rect = CGRect(origin: origin, size: CGSize(width: cell, height: cell))
                    if map.isLive(column, row) { live.addRect(rect); continue }
                    switch kind {
                    case .floor: floor.addRect(rect)
                    case .wall: walls.addRect(rect)
                    case .furniture: furniture.addRect(rect)
                    case .obstacle: obstacles.addRect(rect)
                    case .empty: break
                    }
                }
            }
            world.fill(floor, with: .color(.white.opacity(0.07)))
            world.fill(obstacles, with: .color(.white.opacity(0.55)))
            world.fill(furniture, with: .color(Theme.furniture.opacity(0.9)))
            world.fill(walls, with: .color(Theme.wall.opacity(0.9)))
            world.fill(live, with: .color(Theme.live))

            // Alert cone.
            let coneR = CGFloat(alertRange) * scale
            let cone = Path { p in
                p.move(to: .zero)
                p.addArc(center: .zero, radius: coneR,
                         startAngle: .radians(-.pi / 2 - Double(coneHalfAngle)),
                         endAngle: .radians(-.pi / 2 + Double(coneHalfAngle)), clockwise: false)
                p.closeSubpath()
            }
            world.fill(cone, with: .color(accent.opacity(0.18)))
            world.stroke(cone, with: .color(accent.opacity(0.6)), lineWidth: 1)

            // Target.
            if let hit = snap.nearestForwardObstacle {
                let p = point(hit.point.x, hit.point.z)
                world.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(accent))
            }

            // Rings and the user, unrotated.
            for metres in stride(from: 1, through: Int(radius), by: 1) {
                let rr = CGFloat(metres) * scale
                context.stroke(Path(ellipseIn: CGRect(x: centre.x - rr, y: centre.y - rr, width: 2 * rr, height: 2 * rr)),
                               with: .color(.white.opacity(0.1)), lineWidth: 1)
            }
            let user = Path { p in
                p.move(to: CGPoint(x: centre.x, y: centre.y - 8))
                p.addLine(to: CGPoint(x: centre.x - 5.5, y: centre.y + 5))
                p.addLine(to: CGPoint(x: centre.x, y: centre.y + 2.5))
                p.addLine(to: CGPoint(x: centre.x + 5.5, y: centre.y + 5))
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
