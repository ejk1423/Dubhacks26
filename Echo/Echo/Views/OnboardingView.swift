//
//  OnboardingView.swift
//  Echo
//
//  First-run tutorial: headphones on, phone at chest height, what the beeps and the
//  voice mean, and the Describe button. Shown once (HUDPreferences.hasSeenOnboarding)
//  and again from Settings > Replay tutorial.
//

import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page = 0

    private struct Page: Identifiable {
        let id: Int
        let symbol: String
        let title: String
        let text: String
        let tint: Color
    }

    private static let pages: [Page] = [
        Page(id: 0, symbol: "wave.3.right", title: "Welcome to Echo",
             text: "A parking sensor for walking. The phone's LiDAR scans the way ahead and your headphones tell you what is in your way.",
             tint: Theme.live),
        Page(id: 1, symbol: "headphones", title: "Put on headphones",
             text: "The beeps are stereo: something slightly to your left sounds slightly left. AirPods work; turn off Spatial Audio for Echo so iOS does not re-mix the sound.",
             tint: Theme.live),
        Page(id: 2, symbol: "iphone.gen3.radiowaves.left.and.right", title: "Hold the phone forward",
             text: "Chest height, screen facing you, camera pointing where you walk. Keep it steady and Echo keeps up with your pace.",
             tint: Theme.clear),
        Page(id: 3, symbol: "dot.radiowaves.left.and.right", title: "Beeps mean something ahead",
             text: "Silence means the way is clear. Beeps get faster, louder and higher as you close in, and go solid when you should stop. Nothing beside or behind you makes a sound.",
             tint: Theme.caution),
        Page(id: 4, symbol: "waveform", title: "The voice names things",
             text: "Step up. Step down. Person ahead, slightly left. Door ahead. Exit sign. It speaks just before you reach them, timed by how fast you walk.",
             tint: Theme.danger),
        Page(id: 5, symbol: "text.bubble.fill", title: "Tap Describe any time",
             text: "The big button at the bottom speaks a summary: the kind of place, what is ahead and how far, which sides are open, people and steps nearby.",
             tint: .white),
    ]

    private var isLast: Bool { page == Self.pages.count - 1 }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip") { finish() }
                        .font(Theme.font(16, .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(height: 44)
                        .accessibilityLabel("Skip tutorial")
                }
                .padding(.horizontal, Theme.gutter)

                TabView(selection: $page) {
                    ForEach(Self.pages) { item in
                        pageView(item).tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .never))
                .onChange(of: page) { Haptics.select() }

                Button {
                    Haptics.tap()
                    if isLast { finish() } else { withAnimation(.easeInOut(duration: 0.3)) { page += 1 } }
                } label: {
                    Text(isLast ? "Start walking" : "Next")
                        .font(Theme.font(22, .heavy))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 68)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 12)
                .accessibilityHint(isLast ? "Closes the tutorial" : "Shows the next page")
            }
        }
        .accessibilityAddTraits(.isModal)
    }

    private func pageView(_ item: Page) -> some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill(item.tint.opacity(0.18))
                    .frame(width: 180, height: 180)
                Circle()
                    .strokeBorder(item.tint.opacity(0.5), lineWidth: 2)
                    .frame(width: 180, height: 180)
                Image(systemName: item.symbol)
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(item.tint)
            }
            VStack(spacing: 14) {
                Text(item.title)
                    .font(Theme.font(32, .heavy))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(item.text)
                    .font(Theme.font(19, .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .padding(.horizontal, 28)
            Spacer(minLength: 0)
            Text("\(item.id + 1) of \(Self.pages.count)")
                .font(Theme.font(13, .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.bottom, 30)
        }
        .accessibilityElement(children: .combine)
    }

    private func finish() {
        Haptics.toggled(on: true)
        onFinish()
    }
}
