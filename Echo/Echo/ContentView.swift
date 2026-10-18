import SwiftUI
import Playgrounds
import simd

struct ContentView: View {
    @State private var manager = ARLiDARManager()
    @State private var audio = SpatialAudioEngine()
    @State private var narrator = Narrator()
    @State private var showSettings = false

    var body: some View {
        ARWireframeView(manager: manager)
            .ignoresSafeArea()
            .overlay(alignment: .top) { header }
            .overlay(alignment: .bottom) { footer }
            .sheet(isPresented: $showSettings) { settings }
            .onAppear {
                manager.onSnapshot = { [audio, narrator, manager] snapshot in
                    audio.update(snapshot: snapshot)
                    audio.ducked = narrator.isSpeaking
                    narrator.update(snapshot: snapshot, vision: manager.visionReport,
                                    closeness: audio.closeness, targetDistance: audio.targetDistance)
                }
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

    private var freshVision: VisionReport? {
        guard let report = manager.visionReport, ProcessInfo.processInfo.systemUptime - report.timestamp < 1 else { return nil }
        return report
    }

    /// People / animals the camera sees in front, nearest first.
    private var peopleAhead: [VisionDetection] {
        (freshVision?.detections ?? []).filter { abs($0.bearing) <= 0.9 }.sorted { ($0.distance ?? 99) < ($1.distance ?? 99) }
    }

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

    /// Second line under the status: the last spoken line, or what is ahead by name.
    private var sceneLine: String? {
        if let spoken = narrator.lastLine { return spoken }
        if let person = peopleAhead.first {
            if let d = person.distance { return String(format: "%@ · %.1f m", person.label, d) }
            return person.label
        }
        if audio.closeness > 0.3, let report = freshVision, let label = report.labelAhead, report.labelConfidence >= 0.3 {
            return label
        }
        return nil
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

    // MARK: Header: minimap + status + what the camera sees

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
                .glass(cornerRadius: 22)

                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        StatusRow(symbol: "sensor.fill", text: "LiDAR", ok: manager.capabilities.hasLiDAR)
                        StatusRow(symbol: "headphones", text: "Headphones", ok: audio.headphonesConnected)
                        StatusRow(symbol: "square.stack.3d.down.right.fill", text: "Floor", ok: floorFound)
                    }
                    .padding(12)
                    .glass(cornerRadius: 16)

                    if let scene = freshVision?.scene {
                        Label(scene, systemImage: "eye")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .glass(cornerRadius: 12)
                    }
                    ForEach(Array(peopleAhead.prefix(2).enumerated()), id: \.offset) { _, person in
                        Label(person.distance.map { String(format: "%@ %.1f m", person.label, $0) } ?? person.label,
                              systemImage: "figure.stand")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.live)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .glass(cornerRadius: 12)
                    }
                }
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
        .animation(.easeOut(duration: 0.2), value: peopleAhead.count)
    }

    // MARK: Footer: proximity gauge + describe + controls

    private var footer: some View {
        VStack(spacing: 16) {
            ProximityGauge(closeness: audio.closeness, distance: audio.targetDistance,
                           active: running, color: hazard == nil ? zoneColor : Theme.danger)
                .frame(width: 172, height: 172)

            VStack(spacing: 4) {
                Text(statusWord)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .contentTransition(.interpolate)
                Text(sceneLine ?? " ")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .contentTransition(.interpolate)
            }
            .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button {
                    narrator.describe(snapshot: snapshot, vision: manager.visionReport)
                } label: {
                    Label("Describe", systemImage: "text.bubble.fill")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
                .disabled(!running)
                .opacity(running ? 1 : 0.5)

                HStack(spacing: 6) {
                    IconToggle(symbol: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                               active: !audio.isMuted) { audio.isMuted.toggle() }
                    IconToggle(symbol: narrator.isEnabled ? "waveform.and.mic" : "waveform.slash",
                               active: narrator.isEnabled) { narrator.isEnabled.toggle() }
                    IconToggle(symbol: "iphone.radiowaves.left.and.right",
                               active: audio.hapticsEnabled) { audio.hapticsEnabled.toggle() }
                    IconToggle(symbol: "slider.horizontal.3", active: true) { showSettings = true }
                }
                .padding(.horizontal, 8)
                .frame(height: 52)
                .glass(cornerRadius: 26)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    // MARK: Settings sheet

    private var settings: some View {
        @Bindable var audio = audio
        @Bindable var narrator = narrator
        return NavigationStack {
            Form {
                Section("Sound") {
                    HStack {
                        Image(systemName: "speaker.wave.1.fill")
                        Slider(value: $audio.masterVolume, in: 0...1)
                        Image(systemName: "speaker.wave.3.fill")
                    }
                    Toggle("Beeps", isOn: Binding(get: { !audio.isMuted }, set: { audio.isMuted = !$0 }))
                    Toggle("Voice", isOn: $narrator.isEnabled)
                    Toggle("Haptics", isOn: $audio.hapticsEnabled)
                }
                Section("Map") {
                    Button("Reset map", role: .destructive) { manager.reset() }
                }
                Section {
                    LabeledContent("Mesh chunks", value: "\(manager.meshAnchorCount)")
                    LabeledContent("Walking speed", value: String(format: "%.1f m/s", snapshot?.walkingSpeed ?? 0))
                    LabeledContent("Camera", value: "1× wide + LiDAR")
                } header: {
                    Text("Status")
                } footer: {
                    Text("Beeps warn about whatever is in the cone ahead, earlier when you walk faster. The voice names people, steps and objects as you are about to reach them. Describe speaks a summary of the room.")
                }
            }
            .navigationTitle("Echo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func hazardName(_ kind: TripHazardKind) -> String {
        switch kind {
        case .drop: return "Step down"
        case .bump: return "Step up"
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(active ? .white : .white.opacity(0.4))
                .frame(width: 38, height: 38)
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
                .fill(color.opacity(0.10 + 0.25 * Double(closeness)))
                .blur(radius: 18)
                .padding(-8)
            Circle()
                .stroke(.white.opacity(0.12), lineWidth: 12)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.02, closeness)))
                .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(distance == nil ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: closeness)
            Circle()
                .fill(.black.opacity(0.35))
                .padding(14)

            VStack(spacing: 0) {
                if !active {
                    Text("—").font(.system(size: 40, weight: .bold, design: .rounded))
                } else if let distance {
                    Text(String(format: "%.1f", distance))
                        .font(.system(size: 50, weight: .heavy, design: .rounded))
                        .contentTransition(.numericText())
                    Text("metres")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(Theme.clear)
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
