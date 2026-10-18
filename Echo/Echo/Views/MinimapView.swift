//
//  MinimapView.swift
//  Echo
//
//  Heading-up blueprint of the room. Layers, back to front:
//    1. the occupancy map, rasterised once per snapshot into a crisp CGImage
//       (floor faint, walls bright, furniture warm, obstacles grey, cells the depth
//       camera sees right now in the accent colour),
//    2. doorways as short bright chords,
//    4. trip hazards as warning triangles, people from the camera as teal dots (filled
//       when they are walking toward the user),
//    5. the current target and the user's arrow; the full-screen map adds metre rings
//       and the alert cone.
//  The map stays put (world-fixed, so it never spins); the user's arrow and the camera's
//  detections turn with the heading instead. No frame: the panel fades into the camera.
//

import SwiftUI
import CoreGraphics

struct MinimapView: View {
    let snapshot: SceneSnapshot?
    var vision: VisionReport? = nil
    let radius: Float
    let coneHalfAngle: Float
    let alertRange: Float
    /// Bigger marks, thicker arcs and more labels for the full-screen map.
    var detailed = false

    @State private var cache = MinimapImageCache()

    private var people: Color { .teal }
    private var hazard: Color { .orange }

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let inset: CGFloat = detailed ? 24 : 8
            let r = min(size.width, size.height) / 2 - inset
            let scale = r / CGFloat(max(radius, 0.1))
            let s: CGFloat = detailed ? 1.8 : 1

            guard let snap = snapshot else { return }
            // Screen angle of the heading (world x -> screen x, world z -> screen y).
            let headingAngle = atan2(Double(snap.heading.z), Double(snap.heading.x))

            // World layer: fixed.
            drawWorld(snap, in: context, centre: centre, scale: scale, mark: s)

            // Metre rings and the cone only on the full map; the HUD map stays clean.
            if detailed {
                for metres in stride(from: 1, through: Int(radius), by: 1) {
                    let rr = CGFloat(metres) * scale
                    context.stroke(Path(ellipseIn: CGRect(x: centre.x - rr, y: centre.y - rr, width: 2 * rr, height: 2 * rr)),
                                   with: .color(.white.opacity(0.16)), lineWidth: 1)
                    context.draw(Text("\(metres) m").font(.caption).foregroundStyle(.white.opacity(0.6)),
                                 at: CGPoint(x: centre.x + rr - 3, y: centre.y + 3), anchor: .topTrailing)
                }
            }

            // User layer: turns with the heading. Drawn with "up" = heading, then rotated.
            var user = context
            user.translateBy(x: centre.x, y: centre.y)
            user.rotate(by: Angle(radians: headingAngle + .pi / 2))
            if detailed { drawCone(in: user, scale: scale) }
            drawPeople(in: user, scale: scale, mark: s)

            // The user: a filled arrow, as on a car's navigation display.
            let arrow = Path { p in
                p.move(to: CGPoint(x: 0, y: -11 * s))
                p.addLine(to: CGPoint(x: -7 * s, y: 7 * s))
                p.addLine(to: CGPoint(x: 0, y: 3.5 * s))
                p.addLine(to: CGPoint(x: 7 * s, y: 7 * s))
                p.closeSubpath()
            }
            user.fill(arrow, with: .color(.red))
        }
        .accessibilityHidden(true)
    }

    /// The alert cone in the user frame (up = heading).
    private func drawCone(in context: GraphicsContext, scale: CGFloat) {
        let coneR = CGFloat(alertRange) * scale
        let cone = Path { p in
            p.move(to: .zero)
            p.addArc(center: .zero, radius: coneR,
                     startAngle: .radians(-.pi / 2 - Double(coneHalfAngle)),
                     endAngle: .radians(-.pi / 2 + Double(coneHalfAngle)), clockwise: false)
            p.closeSubpath()
        }
        context.fill(cone, with: .color(.accentColor.opacity(0.16)))
        context.stroke(cone, with: .color(.accentColor.opacity(0.6)), lineWidth: 1)
    }

    // MARK: World layer (fixed)

    private func drawWorld(_ snap: SceneSnapshot, in context: GraphicsContext, centre: CGPoint, scale: CGFloat, mark s: CGFloat) {
        let p0 = snap.cameraPosition
        var world = context
        world.translateBy(x: centre.x, y: centre.y)
        func point(_ x: Float, _ z: Float) -> CGPoint {
            CGPoint(x: CGFloat(x - p0.x) * scale, y: CGFloat(z - p0.z) * scale)
        }

        // 1. Occupancy map, crisp.
        let map = snap.map
        if let image = cache.image(for: map, timestamp: snap.timestamp, palette: .dark) {
            let side = CGFloat(map.size) * CGFloat(map.cellSize) * scale
            world.draw(image.interpolation(.none),
                       in: CGRect(origin: point(map.origin.x, map.origin.y), size: CGSize(width: side, height: side)))
        }

        // 3. Doorways: a bright chord across the gap, perpendicular to the line of sight.
        for opening in snap.openings where opening.isDoorway {
            let p = point(opening.position.x, opening.position.z)
            let length = hypot(p.x, p.y)
            guard length > 1 else { continue }
            let across = CGPoint(x: -p.y / length, y: p.x / length)
            let half = CGFloat(opening.width) * scale / 2
            let chord = Path { path in
                path.move(to: CGPoint(x: p.x - across.x * half, y: p.y - across.y * half))
                path.addLine(to: CGPoint(x: p.x + across.x * half, y: p.y + across.y * half))
            }
            world.stroke(chord, with: .color(.white), style: StrokeStyle(lineWidth: 3 * s, lineCap: .round))
        }

        // 4. Trip hazards: warning triangles at their world position.
        for hazard in snap.tripHazards {
            let p = point(hazard.position.x, hazard.position.z)
            let d: CGFloat = 6 * s
            let triangle = Path { path in
                path.move(to: CGPoint(x: p.x, y: p.y - d))
                path.addLine(to: CGPoint(x: p.x - d, y: p.y + d * 0.8))
                path.addLine(to: CGPoint(x: p.x + d, y: p.y + d * 0.8))
                path.closeSubpath()
            }
            world.fill(triangle, with: .color(self.hazard))
            world.stroke(triangle, with: .color(.black.opacity(0.6)), lineWidth: 1)
        }

        // 5. The current target.
        if let hit = snap.nearestForwardObstacle {
            let p = point(hit.point.x, hit.point.z)
            let d: CGFloat = detailed ? 7 : 5
            world.fill(Path(ellipseIn: CGRect(x: p.x - d, y: p.y - d, width: 2 * d, height: 2 * d)), with: .color(.accentColor))
            world.stroke(Path(ellipseIn: CGRect(x: p.x - d - 3, y: p.y - d - 3, width: 2 * d + 6, height: 2 * d + 6)),
                         with: .color(.accentColor.opacity(0.6)), lineWidth: 1.5)
        }
    }

    /// People and animals from the camera, placed by bearing and distance in the user
    /// frame (up = heading). Filled when walking toward the user.
    private func drawPeople(in context: GraphicsContext, scale: CGFloat, mark s: CGFloat) {
        guard let vision, ProcessInfo.processInfo.systemUptime - vision.timestamp < 1.5 else { return }
        for detection in vision.detections {
            guard let distance = detection.distance, distance <= radius else { continue }
            let p = CGPoint(x: CGFloat(distance * sin(detection.bearing)) * scale,
                            y: -CGFloat(distance * cos(detection.bearing)) * scale)
            let d: CGFloat = 6 * s
            let dot = Path(ellipseIn: CGRect(x: p.x - d, y: p.y - d, width: 2 * d, height: 2 * d))
            if detection.movingTowardYou {
                context.fill(dot, with: .color(people))
            } else {
                context.fill(dot, with: .color(people.opacity(0.35)))
                context.stroke(dot, with: .color(people), lineWidth: 2)
            }
            if detailed {
                context.draw(Text(detection.label).font(.caption2.weight(.semibold)).foregroundStyle(people),
                             at: CGPoint(x: p.x, y: p.y - d - 2), anchor: .bottom)
            }
        }
    }
}

// MARK: - Occupancy map raster

/// Premultiplied RGBA for each cell kind. The map always sits on a dark disc, so one
/// palette: floor faint, walls bright, furniture warm, obstacles grey, live accent.
nonisolated struct MinimapPalette: Equatable, Sendable {
    var floor: SIMD4<UInt8>
    var wall: SIMD4<UInt8>
    var furniture: SIMD4<UInt8>
    var obstacle: SIMD4<UInt8>
    var live: SIMD4<UInt8>

    static let dark = MinimapPalette(
        floor: [70, 70, 70, 70], wall: [250, 250, 250, 250], furniture: [235, 185, 110, 235],
        obstacle: [185, 185, 185, 185], live: [10, 132, 255, 255])
}

/// Rasterises the occupancy grid into one small RGBA image per snapshot.
final class MinimapImageCache {
    private var timestamp: TimeInterval = -1
    private var palette: MinimapPalette?
    private var image: Image?

    func image(for map: OccupancyMap, timestamp: TimeInterval, palette: MinimapPalette) -> Image? {
        if timestamp == self.timestamp, palette == self.palette { return image }
        self.timestamp = timestamp
        self.palette = palette
        image = Self.render(map, palette: palette).map { Image(decorative: $0, scale: 1) }
        return image
    }

    private static func render(_ map: OccupancyMap, palette: MinimapPalette) -> CGImage? {
        let n = map.size
        guard n > 0, map.cells.count >= n * n else { return nil }
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        for i in 0..<(n * n) {
            let raw = map.cells[i]
            let live = raw & OccupancyMap.liveFlag != 0
            let kind = OccupancyMap.Cell(rawValue: raw & ~OccupancyMap.liveFlag) ?? .empty
            let px: SIMD4<UInt8>
            if live {
                px = palette.live
            } else {
                switch kind {
                case .empty: continue
                case .floor: px = palette.floor
                case .wall: px = palette.wall
                case .furniture: px = palette.furniture
                case .obstacle: px = palette.obstacle
                }
            }
            let o = i * 4
            pixels[o] = px.x; pixels[o + 1] = px.y; pixels[o + 2] = px.z; pixels[o + 3] = px.w
        }
        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return context.makeImage()
        }
    }
}

// MARK: - Full map sheet

/// The expanded map as a system sheet (HIG › Sheets). Content, so a standard
/// background, not glass; the map itself keeps its dark disc.
struct MapView: View {
    let manager: ARLiDARManager
    let audio: SpatialAudioEngine

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HUDMetrics.spacingLarge) {
                    MinimapView(snapshot: manager.snapshot, vision: manager.visionReport,
                                radius: manager.config.mapRadius, coneHalfAngle: audio.coneHalfAngle,
                                alertRange: audio.alertRange, detailed: true)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 420)
                        .background(Color.black.opacity(0.85), in: .rect(cornerRadius: HUDMetrics.spacingLarge, style: .continuous))
                        .environment(\.colorScheme, .dark)

                    MinimapLegend()

                    readings

                    Text("The map stays put and your arrow turns. White bars are doorways, triangles are steps, teal dots are people, and the blue cone is where the beeps listen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(HUDMetrics.margin)
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var cardinal: [(name: String, distance: Float)] {
        guard let s = manager.snapshot?.sectorDistances, s.count == 8 else { return [] }
        return [("Ahead", s[0]), ("Right", min(s[1], s[2])), ("Behind", min(s[3], s[4], s[5])), ("Left", min(s[6], s[7]))]
    }

    private func words(_ distance: Float) -> String {
        guard distance.isFinite, distance <= manager.config.mapRadius else { return "Clear" }
        return String(format: "%.1f m", distance)
    }

    /// Four distances in words. A row at normal text sizes, a 2 × 2 grid when the text
    /// no longer fits (HIG › Typography: "Consider adjusting your layout at large font sizes").
    private var readings: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: HUDMetrics.spacingSmall) {
                ForEach(cardinal, id: \.name) { reading in readingCell(reading) }
            }
            Grid(horizontalSpacing: HUDMetrics.spacingSmall, verticalSpacing: HUDMetrics.spacingSmall) {
                GridRow {
                    ForEach(cardinal.prefix(2), id: \.name) { reading in readingCell(reading) }
                }
                GridRow {
                    ForEach(cardinal.dropFirst(2), id: \.name) { reading in readingCell(reading) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cardinal.map { "\($0.name) \(words($0.distance))" }.joined(separator: ", "))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func readingCell(_ reading: (name: String, distance: Float)) -> some View {
        VStack(spacing: 4) {
            Text(reading.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(words(reading.distance))
                .font(.title3)
                .fontWeight(.semibold)
                .fontDesign(.rounded)
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity)
        .padding(.vertical, HUDMetrics.spacing)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: HUDMetrics.spacing, style: .continuous))
    }
}

// MARK: - Legend

struct MinimapLegend: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: HUDMetrics.spacing) { items }
            VStack(alignment: .leading, spacing: HUDMetrics.spacingSmall) { items }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var items: some View {
        item(.primary, "Wall")
        item(.orange, "Furniture / step")
        item(.tint, "Seen now")
        item(.teal, "Person")
    }

    private func item(_ style: some ShapeStyle, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(style).frame(width: 8, height: 8)
            Text(label)
        }
    }
}
