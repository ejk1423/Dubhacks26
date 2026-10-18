import SwiftUI
import Playgrounds

struct ContentView: View {
    @State private var manager = ARLiDARManager()
    @State private var audio = SpatialAudioEngine()

    var body: some View {
        ARWireframeView(manager: manager)
            .ignoresSafeArea()
            .overlay(alignment: .top) { badges }
            .overlay(alignment: .bottom) { readout }
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

    // MARK: Top: what is working

    private var badges: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                badge(manager.capabilities.hasLiDAR ? "LiDAR ✓ · \(manager.meshAnchorCount) chunks" : "No LiDAR",
                      ok: manager.capabilities.hasLiDAR)
                badge(audio.headphonesConnected ? "Headphones ✓" : "Use headphones",
                      ok: audio.headphonesConnected)
            }
            if let message = statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
            }
        }
        .padding(.top, 8)
    }

    private func badge(_ text: String, ok: Bool) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(ok ? .white : .orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
    }

    /// Only shown when something needs attention.
    private var statusMessage: String? {
        switch manager.status {
        case .running:
            return manager.snapshot?.groundSource == .assumed ? "Finding the floor…" : nil
        case .idle: return "Idle"
        case .starting: return "Starting…"
        case .limited(let reason): return reason
        case .interrupted: return "Interrupted"
        case .failed(let msg): return "Failed: \(msg)"
        case .unsupported(let msg): return msg
        }
    }

    // MARK: Bottom: distance ahead + controls

    private var readout: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(distanceText)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(distanceColor)
                    .contentTransition(.numericText())
                if let hazard = manager.tripHazards.first {
                    Text("\(hazardName(hazard.kind)) \(String(format: "%.1f m", hazard.distanceAhead))")
                        .font(.headline)
                        .foregroundStyle(.red)
                }
            }
            .accessibilityElement(children: .combine)

            Button {
                audio.isMuted.toggle()
            } label: {
                Label(audio.isMuted ? "Unmute" : "Mute",
                      systemImage: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.black.opacity(0.6))
        }
        .padding(.bottom, 24)
    }

    private var forwardDistance: Float? {
        manager.snapshot?.nearestForwardObstacle?.horizontalDistance
    }

    private var distanceText: String {
        guard manager.status == .running, manager.snapshot != nil else { return "–" }
        guard let d = forwardDistance else { return "Clear" }
        return String(format: "%.1f m", d)
    }

    private var distanceColor: Color {
        guard let d = forwardDistance else { return .green }
        if d < 1.0 { return .red }
        if d < 2.0 { return .orange }
        return .green
    }

    private func hazardName(_ kind: TripHazardKind) -> String {
        switch kind {
        case .drop: return "Step down"
        case .bump: return "Curb / step up"
        case .unknownSurface: return "Uneven ground"
        }
    }
}

#Preview {
    ContentView()
}

#Playground {
    _ = 1 + 2
}
