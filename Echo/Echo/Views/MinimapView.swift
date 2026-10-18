//
//  MinimapView.swift
//  Echo
//
//  Heading-up blueprint of the room: the occupancy map rasterised once per snapshot
//  into a CGImage (one draw call instead of thousands of rects, drawn crisp), the nearest surface
//  per 15-degree sector as an arc, the alert cone, range rings and an "ahead" marker.
//
//  The drawing is monochrome plus the app accent (HIG › Color: the three state colours
//  stay on the proximity state; distance here is already encoded by radius). Label
//  colours resolve from the environment so the same view works on the dark HUD and in
//  the light or dark `MapView` sheet.
//

import SwiftUI
import CoreGraphics

struct MinimapView: View {
    let snapshot: SceneSnapshot?
    let radius: Float
    let coneHalfAngle: Float
    let alertRange: Float
    /// Ring labels, bigger marks and thicker arcs for the full-screen map.
    var detailed = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var cache = MinimapImageCache()

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let inset: CGFloat = detailed ? 24 : 12
            let r = min(size.width, size.height) / 2 - inset
            let scale = r / CGFloat(max(radius, 0.1))
            let disc = Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))

            var clipped = context
            clipped.clip(to: disc)

            if let snap = snapshot {
                drawWorld(snap, in: clipped, centre: centre, scale: scale)
                drawSonar(snap, in: clipped, centre: centre, scale: scale)
            }

            // Range rings, user chevron and the ahead marker stay unrotated: the map
            // turns with the user, these do not.
            for metres in stride(from: 1, through: Int(radius), by: 1) {
                let rr = CGFloat(metres) * scale
                context.stroke(Path(ellipseIn: CGRect(x: centre.x - rr, y: centre.y - rr, width: 2 * rr, height: 2 * rr)),
                               with: .color(.primary.opacity(0.12)), lineWidth: 1)
                if detailed {
                    context.draw(Text("\(metres) m").font(.caption2).foregroundStyle(.secondary),
                                 at: CGPoint(x: centre.x + 4, y: centre.y - rr + 3), anchor: .topLeading)
                }
            }
            context.stroke(disc, with: .color(.primary.opacity(0.2)), lineWidth: 1)

            let s: CGFloat = detailed ? 1.8 : 1
            let user = Path { p in
                p.move(to: CGPoint(x: centre.x, y: centre.y - 9 * s))
                p.addLine(to: CGPoint(x: centre.x - 6 * s, y: centre.y + 5.5 * s))
                p.addLine(to: CGPoint(x: centre.x, y: centre.y + 2.5 * s))
                p.addLine(to: CGPoint(x: centre.x + 6 * s, y: centre.y + 5.5 * s))
                p.closeSubpath()
            }
            context.fill(user, with: .color(.primary))

            // "Ahead" marker at the top of the disc, in the accent like everything "now".
            let tip = CGPoint(x: centre.x, y: centre.y - r)
            let marker = Path { p in
                p.move(to: CGPoint(x: tip.x, y: tip.y + 2))
                p.addLine(to: CGPoint(x: tip.x - 5 * s, y: tip.y + 9 * s))
                p.addLine(to: CGPoint(x: tip.x + 5 * s, y: tip.y + 9 * s))
                p.closeSubpath()
            }
            context.fill(marker, with: .color(.accentColor))
            if detailed {
                context.draw(Text("Ahead").font(.caption.weight(.semibold)).foregroundStyle(.tint),
                             at: CGPoint(x: tip.x, y: tip.y - 4), anchor: .bottom)
                context.draw(Text("L").font(.caption.weight(.semibold)).foregroundStyle(.secondary),
                             at: CGPoint(x: centre.x - r - 6, y: centre.y), anchor: .trailing)
                context.draw(Text("R").font(.caption.weight(.semibold)).foregroundStyle(.secondary),
                             at: CGPoint(x: centre.x + r + 6, y: centre.y), anchor: .leading)
            }
        }
        .accessibilityHidden(true)
    }

    /// Occupancy image, alert cone and the current target, in the heading-up frame.
    private func drawWorld(_ snap: SceneSnapshot, in context: GraphicsContext, centre: CGPoint, scale: CGFloat) {
        let p0 = snap.cameraPosition
        var world = context
        world.translateBy(x: centre.x, y: centre.y)
        world.rotate(by: Angle(radians: -.pi / 2 - atan2(Double(snap.heading.z), Double(snap.heading.x))))
        func point(_ x: Float, _ z: Float) -> CGPoint {
            CGPoint(x: CGFloat(x - p0.x) * scale, y: CGFloat(z - p0.z) * scale)
        }

        let map = snap.map
        let palette: MinimapPalette = colorScheme == .dark ? .dark : .light
        if let image = cache.image(for: map, timestamp: snap.timestamp, palette: palette) {
            let side = CGFloat(map.size) * CGFloat(map.cellSize) * scale
            // Nearest-neighbour: every 2.5 cm cell stays a crisp square instead of a blur.
            world.draw(image.interpolation(.none),
                       in: CGRect(origin: point(map.origin.x, map.origin.y), size: CGSize(width: side, height: side)))
        }

        let coneR = CGFloat(alertRange) * scale
        let cone = Path { p in
            p.move(to: .zero)
            p.addArc(center: .zero, radius: coneR,
                     startAngle: .radians(-.pi / 2 - Double(coneHalfAngle)),
                     endAngle: .radians(-.pi / 2 + Double(coneHalfAngle)), clockwise: false)
            p.closeSubpath()
        }
        world.fill(cone, with: .color(.accentColor.opacity(0.15)))
        world.stroke(cone, with: .color(.accentColor.opacity(0.5)), lineWidth: 1)

        if let hit = snap.nearestForwardObstacle {
            let p = point(hit.point.x, hit.point.z)
            let d: CGFloat = detailed ? 7 : 4.5
            world.fill(Path(ellipseIn: CGRect(x: p.x - d, y: p.y - d, width: 2 * d, height: 2 * d)), with: .color(.accentColor))
            world.stroke(Path(ellipseIn: CGRect(x: p.x - d - 3, y: p.y - d - 3, width: 2 * d + 6, height: 2 * d + 6)),
                         with: .color(.accentColor.opacity(0.5)), lineWidth: 1.5)
        }
    }

    /// Nearest surface per 15-degree sector as an arc: the parking-sensor picture.
    private func drawSonar(_ snap: SceneSnapshot, in context: GraphicsContext, centre: CGPoint, scale: CGFloat) {
        let sectors = snap.fineSectorHits
        guard !sectors.isEmpty else { return }
        var sonar = context
        sonar.translateBy(x: centre.x, y: centre.y)
        let step = 2 * Double.pi / Double(sectors.count)
        let gap = 0.03
        for (index, hit) in sectors.enumerated() {
            guard let hit, hit.horizontalDistance.isFinite, hit.horizontalDistance <= radius else { continue }
            let rr = CGFloat(hit.horizontalDistance) * scale
            let mid = -Double.pi / 2 + Double(index) * step   // index 0 ahead, clockwise
            let arc = Path { p in
                p.addArc(center: .zero, radius: rr,
                         startAngle: .radians(mid - step / 2 + gap),
                         endAngle: .radians(mid + step / 2 - gap), clockwise: false)
            }
            sonar.stroke(arc, with: .color(.primary.opacity(0.75)),
                         style: StrokeStyle(lineWidth: detailed ? 5 : 2.5, lineCap: .round))
        }
    }
}

// MARK: - Occupancy map raster

/// Premultiplied RGBA for each cell kind, one set per appearance so walls stay visible
/// on both the dark HUD and a light sheet.
nonisolated struct MinimapPalette: Equatable, Sendable {
    var floor: SIMD4<UInt8>
    var wall: SIMD4<UInt8>
    var furniture: SIMD4<UInt8>
    var obstacle: SIMD4<UInt8>
    /// Cells the depth camera sees right now: the app accent (system blue).
    var live: SIMD4<UInt8>

    static let dark = MinimapPalette(
        floor: [28, 28, 28, 28], wall: [235, 235, 235, 235], furniture: [150, 150, 150, 150],
        obstacle: [120, 120, 120, 120], live: [10, 132, 255, 255])
    static let light = MinimapPalette(
        floor: [0, 0, 0, 18], wall: [38, 38, 38, 235], furniture: [78, 78, 78, 160],
        obstacle: [35, 35, 35, 150], live: [0, 122, 255, 255])
}

/// Rasterises the occupancy grid into one small RGBA image per snapshot, so the
/// Canvas draws a single bitmap (bilinear-smoothed by the GPU) instead of thousands
/// of rectangles at 20 Hz.
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

/// The expanded map, presented as a system sheet (HIG › Sheets: drag indicator, Done on
/// the trailing edge, swipe to dismiss). Content, so it uses the standard background,
/// not glass (HIG › Materials: "Don't use Liquid Glass in the content layer").
struct MapView: View {
    let manager: ARLiDARManager
    let audio: SpatialAudioEngine

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HUDMetrics.spacingLarge) {
                    MinimapView(snapshot: manager.snapshot, radius: manager.config.mapRadius,
                                coneHalfAngle: audio.coneHalfAngle, alertRange: audio.alertRange, detailed: true)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 400)
                        .background(Color(.secondarySystemBackground), in: .circle)

                    MinimapLegend()

                    readings

                    Text("The map turns with you: up is always the way you are facing. Arcs are the nearest surface in each direction; the blue cone is where the beeps listen.")
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
        item(.secondary, "Furniture")
        item(.tint, "Seen now")
        item(.quaternary, "Floor")
    }

    private func item(_ style: some ShapeStyle, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(style).frame(width: 8, height: 8)
            Text(label)
        }
    }
}
