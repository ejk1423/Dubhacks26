//
//  MinimapView.swift
//  Echo
//
//  Heading-up blueprint of the room: the occupancy map rasterised once per snapshot
//  into a CGImage (one draw call instead of thousands of rects), the sonar readings
//  per 15-degree sector as arcs around the user, the alert cone, range rings and an
//  "ahead" marker. `ExpandedMapView` shows the same thing full screen with a legend
//  and the four cardinal distances in words.
//

import SwiftUI
import CoreGraphics

struct MinimapView: View {
    let snapshot: SceneSnapshot?
    let radius: Float
    let coneHalfAngle: Float
    let alertRange: Float
    let accent: Color
    /// Ring labels, bigger marks and sonar arcs for the full-screen map.
    var detailed = false

    @State private var cache = MinimapImageCache()

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let inset: CGFloat = detailed ? 22 : 13
            let r = min(size.width, size.height) / 2 - inset
            let scale = r / CGFloat(max(radius, 0.1))
            let disc = Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))

            context.fill(disc, with: .color(.black.opacity(0.28)))
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
                               with: .color(.white.opacity(0.12)), lineWidth: 1)
                if detailed {
                    context.draw(Text("\(metres) m").font(Theme.font(11, .semibold)).foregroundStyle(.white.opacity(0.55)),
                                 at: CGPoint(x: centre.x + 4, y: centre.y - rr + 3), anchor: .topLeading)
                }
            }
            context.stroke(disc, with: .color(.white.opacity(0.18)), lineWidth: 1)

            let s: CGFloat = detailed ? 1.8 : 1
            let user = Path { p in
                p.move(to: CGPoint(x: centre.x, y: centre.y - 9 * s))
                p.addLine(to: CGPoint(x: centre.x - 6 * s, y: centre.y + 5.5 * s))
                p.addLine(to: CGPoint(x: centre.x, y: centre.y + 2.5 * s))
                p.addLine(to: CGPoint(x: centre.x + 6 * s, y: centre.y + 5.5 * s))
                p.closeSubpath()
            }
            context.fill(user, with: .color(.white))

            // "Ahead" marker at the top of the disc.
            let tip = CGPoint(x: centre.x, y: centre.y - r)
            let marker = Path { p in
                p.move(to: CGPoint(x: tip.x, y: tip.y + 2))
                p.addLine(to: CGPoint(x: tip.x - 5 * s, y: tip.y + 9 * s))
                p.addLine(to: CGPoint(x: tip.x + 5 * s, y: tip.y + 9 * s))
                p.closeSubpath()
            }
            context.fill(marker, with: .color(accent))
            context.draw(Text("AHEAD").font(Theme.font(detailed ? 13 : 8, .heavy)).foregroundStyle(accent),
                         at: CGPoint(x: tip.x, y: tip.y - 2), anchor: .bottom)
            if detailed {
                context.draw(Text("L").font(Theme.font(13, .heavy)).foregroundStyle(.white.opacity(0.6)),
                             at: CGPoint(x: centre.x - r - 4, y: centre.y), anchor: .trailing)
                context.draw(Text("R").font(Theme.font(13, .heavy)).foregroundStyle(.white.opacity(0.6)),
                             at: CGPoint(x: centre.x + r + 4, y: centre.y), anchor: .leading)
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
        if let image = cache.image(for: map, timestamp: snap.timestamp) {
            let side = CGFloat(map.size) * CGFloat(map.cellSize) * scale
            world.draw(image, in: CGRect(origin: point(map.origin.x, map.origin.y), size: CGSize(width: side, height: side)))
        }

        let coneR = CGFloat(alertRange) * scale
        let cone = Path { p in
            p.move(to: .zero)
            p.addArc(center: .zero, radius: coneR,
                     startAngle: .radians(-.pi / 2 - Double(coneHalfAngle)),
                     endAngle: .radians(-.pi / 2 + Double(coneHalfAngle)), clockwise: false)
            p.closeSubpath()
        }
        world.fill(cone, with: .color(accent.opacity(0.16)))
        world.stroke(cone, with: .color(accent.opacity(0.55)), lineWidth: 1)

        if let hit = snap.nearestForwardObstacle {
            let p = point(hit.point.x, hit.point.z)
            let d: CGFloat = detailed ? 7 : 4.5
            world.fill(Path(ellipseIn: CGRect(x: p.x - d, y: p.y - d, width: 2 * d, height: 2 * d)), with: .color(accent))
            world.stroke(Path(ellipseIn: CGRect(x: p.x - d - 3, y: p.y - d - 3, width: 2 * d + 6, height: 2 * d + 6)),
                         with: .color(accent.opacity(0.5)), lineWidth: 1.5)
        }
    }

    /// Nearest surface per 15-degree sector as a coloured arc: the parking-sensor picture.
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
            let closeness = 1 - (hit.horizontalDistance - 0.3) / max(radius - 0.3, 0.1)
            sonar.stroke(arc, with: .color(Theme.proximityColor(closeness: closeness).opacity(0.85)),
                         style: StrokeStyle(lineWidth: detailed ? 5 : 2.5, lineCap: .round))
        }
    }
}

// MARK: - Occupancy map raster

/// Rasterises the occupancy grid into one small RGBA image per snapshot, so the
/// Canvas draws a single bitmap (bilinear-smoothed by the GPU) instead of thousands
/// of rectangles at 20 Hz.
final class MinimapImageCache {
    private var timestamp: TimeInterval = -1
    private var image: Image?

    func image(for map: OccupancyMap, timestamp: TimeInterval) -> Image? {
        if timestamp == self.timestamp { return image }
        self.timestamp = timestamp
        image = Self.render(map).map { Image(decorative: $0, scale: 1) }
        return image
    }

    private static func render(_ map: OccupancyMap) -> CGImage? {
        let n = map.size
        guard n > 0, map.cells.count >= n * n else { return nil }
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        for i in 0..<(n * n) {
            let raw = map.cells[i]
            let live = raw & OccupancyMap.liveFlag != 0
            let kind = OccupancyMap.Cell(rawValue: raw & ~OccupancyMap.liveFlag) ?? .empty
            // Premultiplied RGBA.
            let px: (UInt8, UInt8, UInt8, UInt8)
            if live {
                px = (107, 214, 255, 255)
            } else {
                switch kind {
                case .empty: continue
                case .floor: px = (26, 26, 26, 26)
                case .wall: px = (235, 235, 235, 235)
                case .furniture: px = (230, 170, 50, 230)
                case .obstacle: px = (150, 150, 150, 150)
                }
            }
            let o = i * 4
            pixels[o] = px.0; pixels[o + 1] = px.1; pixels[o + 2] = px.2; pixels[o + 3] = px.3
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

// MARK: - Legend

struct MinimapLegend: View {
    var large = false

    var body: some View {
        HStack(spacing: large ? 16 : 8) {
            item(Theme.wall, "Wall")
            item(Theme.furniture, "Furniture")
            item(Theme.live, "Seen now")
            if large { item(Color.white.opacity(0.35), "Floor") }
        }
        .font(Theme.font(large ? 14 : 9, .bold))
        .foregroundStyle(.white.opacity(0.75))
        .accessibilityHidden(true)
    }

    private func item(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: large ? 12 : 8, height: large ? 12 : 8)
            Text(label)
        }
    }
}

// MARK: - Full-screen map

struct ExpandedMapView: View {
    let manager: ARLiDARManager
    let audio: SpatialAudioEngine
    let accent: Color
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 20) {
                HStack {
                    Text("Map")
                        .font(Theme.font(30, .heavy))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        Haptics.tap()
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close map")
                }

                MinimapView(snapshot: manager.snapshot, radius: manager.config.mapRadius,
                            coneHalfAngle: audio.coneHalfAngle, alertRange: audio.alertRange,
                            accent: accent, detailed: true)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)

                MinimapLegend(large: true)

                sectorGrid

                Text("The map turns with you: up is always the way you are facing. Coloured arcs are the nearest surface in each direction, red when close.")
                    .font(Theme.font(14, .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            }
            .padding(Theme.gutter)
        }
        .accessibilityAddTraits(.isModal)
    }

    private var readings: [(name: String, distance: Float)] {
        guard let s = manager.snapshot?.sectorDistances, s.count == 8 else { return [] }
        return [("Ahead", s[0]), ("Right", min(s[1], s[2])), ("Behind", min(s[3], s[4], s[5])), ("Left", min(s[6], s[7]))]
    }

    private func words(_ distance: Float) -> String {
        guard distance.isFinite, distance <= manager.config.mapRadius else { return "Clear" }
        return String(format: "%.1f m", distance)
    }

    private var sectorGrid: some View {
        HStack(spacing: 8) {
            ForEach(readings, id: \.name) { reading in
                VStack(spacing: 4) {
                    Text(reading.name)
                        .font(Theme.font(12, .bold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(words(reading.distance))
                        .font(Theme.font(20, .heavy))
                        .monospacedDigit()
                        .foregroundStyle(reading.distance.isFinite && reading.distance <= manager.config.mapRadius
                                         ? Theme.proximityColor(closeness: 1 - reading.distance / manager.config.mapRadius)
                                         : Theme.clear)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .glass(cornerRadius: 16)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(readings.map { "\($0.name) \(words($0.distance))" }.joined(separator: ", "))
        .accessibilityAddTraits(.updatesFrequently)
    }
}
