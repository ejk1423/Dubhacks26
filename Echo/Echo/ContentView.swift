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

    private enum Zone { case clear, far, near, imminent }

    private var zone: Zone {
        guard let d = forward?.horizontalDistance, d <= audio.wallRange else { return .clear }
        if d <= 0.4 { return .imminent }
        if d <= 0.8 { return .near }
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
        return String(format: "%.1f m", d)
    }

    // MARK: Edge glow (direction of the loudest wall)

    private var edgeGlow: some View {
        GeometryReader { geo in
            if let azimuth = audio.loudestAzimuth, abs(azimuth) > 0.1, audio.loudestCloseness > 0.15 {
                let onRight = azimuth > 0
                LinearGradient(
                    colors: [zoneColor.opacity(0.2 + 0.6 * Double(audio.loudestCloseness)), .clear],
                    startPoint: onRight ? .trailing : .leading,
                    endPoint: onRight ? .leading : .trailing
                )
                .frame(width: geo.size.width * 0.35)
                .frame(maxWidth: .infinity, alignment: onRight ? .trailing : .leading)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: audio.loudestAzimuth == nil)
    }

    // MARK: Top: minimap + status chips

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                MinimapView(
                    snapshot: snapshot,
                    radius: manager.config.mapRadius,
                    corridorHalfWidth: manager.config.forwardHalfWidth,
                    wallRange: audio.wallRange,
                    zoneColor: zoneColor
                )
                .frame(width: 176, height: 176)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.15)))

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

    // MARK: Bottom panel: readout + controls

    private var panel: some View {
        @Bindable var audio = audio
        return VStack(spacing: 12) {
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
                Image(systemName: "speaker.wave.1.fill").foregroundStyle(.white.opacity(0.7))
                Slider(value: $audio.masterVolume, in: 0...1)
                    .tint(.white)
                    .disabled(audio.isMuted)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 4)

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
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
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

// MARK: - Minimap

/// Top-down blueprint of the room, heading-up, user at the centre. Walls are cyan,
/// furniture amber, other obstacles grey, floor a faint green; cells the depth map saw
/// this frame are drawn bright. The walking corridor and 1 m rings are overlaid, and the
/// corridor obstacle is marked at its true position.
private struct MinimapView: View {
    let snapshot: SceneSnapshot?
    let radius: Float
    let corridorHalfWidth: Float
    let wallRange: Float
    let zoneColor: Color

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let scale = CGFloat(min(size.width, size.height) / 2 - 6) / CGFloat(radius)   // points per metre
            context.clip(to: Path(ellipseIn: CGRect(x: centre.x - CGFloat(radius) * scale, y: centre.y - CGFloat(radius) * scale,
                                                    width: 2 * CGFloat(radius) * scale, height: 2 * CGFloat(radius) * scale)))

            guard let snap = snapshot else { return }
            let p0 = snap.cameraPosition
            // Rotate the world so the walking heading points up the screen.
            let headingAngle = atan2(CGFloat(snap.heading.z), CGFloat(snap.heading.x))
            var world = context
            world.translateBy(x: centre.x, y: centre.y)
            world.rotate(by: Angle(radians: -.pi / 2 - headingAngle))
            func point(_ x: Float, _ z: Float) -> CGPoint {
                CGPoint(x: CGFloat(x - p0.x) * scale, y: CGFloat(z - p0.z) * scale)
            }

            // Occupancy cells, batched by class.
            let map = snap.map
            let cell = CGFloat(map.cellSize) * scale + 0.5
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
            world.fill(floor, with: .color(Color(red: 0.1, green: 0.6, blue: 0.35).opacity(0.28)))
            world.fill(obstacles, with: .color(Color(white: 0.7).opacity(0.85)))
            world.fill(furniture, with: .color(Color(red: 1, green: 0.68, blue: 0.2).opacity(0.95)))
            world.fill(walls, with: .color(Color(red: 0, green: 0.9, blue: 1).opacity(0.95)))
            world.fill(live, with: .color(.white))

            // Walking corridor and audible range.
            let corridor = Path(CGRect(x: -CGFloat(corridorHalfWidth) * scale, y: -CGFloat(wallRange) * scale,
                                       width: 2 * CGFloat(corridorHalfWidth) * scale, height: CGFloat(wallRange) * scale))
            world.fill(corridor, with: .color(zoneColor.opacity(0.12)))
            world.stroke(corridor, with: .color(zoneColor.opacity(0.5)), lineWidth: 1)

            // Corridor obstacle.
            if let hit = snap.nearestForwardObstacle {
                let p = point(hit.point.x, hit.point.z)
                world.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(zoneColor))
            }

            // Range rings (drawn unrotated so the ticks stay put) and the user.
            for metres in stride(from: 1, through: Int(radius), by: 1) {
                let r = CGFloat(metres) * scale
                context.stroke(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(.white.opacity(0.14)), lineWidth: 1)
            }
            let user = Path { p in
                p.move(to: CGPoint(x: centre.x, y: centre.y - 9))
                p.addLine(to: CGPoint(x: centre.x - 6, y: centre.y + 5))
                p.addLine(to: CGPoint(x: centre.x, y: centre.y + 2))
                p.addLine(to: CGPoint(x: centre.x + 6, y: centre.y + 5))
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
