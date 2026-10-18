//
//  OnboardingView.swift
//  Echo
//
//  First-run tutorial: headphones on, phone at chest height, what the beeps and the
//  voice mean, and the Describe button. Shown once (HUDPreferences.hasSeenOnboarding)
//  and again from Settings › Replay Tutorial.
//
//  Presented full screen rather than as a sheet because it is a multistep flow
//  (HIG › Sheets: "For complex or prolonged user flows, consider alternatives to
//  sheets"). Skip is the cancel action on the leading edge; the one prominent button
//  advances. Every text uses a system text style so it scales with Dynamic Type.
//

import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 64

    private struct Page: Identifiable {
        let id: Int
        let symbol: String
        let title: String
        let text: String
    }

    private static let pages: [Page] = [
        Page(id: 0, symbol: "wave.3.right", title: "Welcome to Echo",
             text: "A parking sensor for walking. The phone's LiDAR scans the way ahead and your headphones tell you what is in your way."),
        Page(id: 1, symbol: "headphones", title: "Put on Headphones",
             text: "The beeps are stereo: something slightly to your left sounds slightly left. AirPods work; turn off Spatial Audio for Echo so iOS does not re-mix the sound."),
        Page(id: 2, symbol: "iphone.gen3.radiowaves.left.and.right", title: "Hold the Phone Forward",
             text: "Chest height, screen facing you, camera pointing where you walk. Keep it steady and Echo keeps up with your pace."),
        Page(id: 3, symbol: "dot.radiowaves.left.and.right", title: "Beeps Mean Something Ahead",
             text: "Silence means the way is clear. Beeps get faster, louder and higher as you close in, and go solid when you should stop. Nothing beside or behind you makes a sound."),
        Page(id: 4, symbol: "waveform", title: "The Voice Names Things",
             text: "Step up. Step down. Person ahead, slightly left. Door ahead. Exit sign. It speaks just before you reach them, timed by how fast you walk."),
        Page(id: 5, symbol: "text.bubble.fill", title: "Tap Describe Any Time",
             text: "The big button at the bottom speaks a summary: the kind of place, what is ahead and how far, which sides are open, people and steps nearby."),
    ]

    private var isLast: Bool { page == Self.pages.count - 1 }

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                ForEach(Self.pages) { item in
                    pageView(item).tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .onChange(of: page) { Haptics.select() }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Haptics.tap()
                    if isLast {
                        finish()
                    } else {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { page += 1 }
                    }
                } label: {
                    Text(isLast ? "Start Walking" : "Continue")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .hudButtonStyle(prominent: true)
                .controlSize(.extraLarge)
                .padding(.horizontal, HUDMetrics.margin)
                .padding(.bottom, HUDMetrics.spacingSmall)
                .frame(maxWidth: HUDMetrics.maxColumnWidth)
                .accessibilityHint(isLast ? "Closes the tutorial" : "Shows the next page")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { finish() }
                        .accessibilityLabel("Skip tutorial")
                }
            }
        }
    }

    private func pageView(_ item: Page) -> some View {
        ScrollView {
            VStack(spacing: HUDMetrics.spacingLarge) {
                Image(systemName: item.symbol)
                    .font(.system(size: symbolSize, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(minHeight: symbolSize * 1.5)
                    .accessibilityHidden(true)

                VStack(spacing: HUDMetrics.spacing) {
                    Text(item.title)
                        .font(.title)
                        .fontWeight(.bold)
                        .fontDesign(.rounded)
                    Text(item.text)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                Text("\(item.id + 1) of \(Self.pages.count)")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: HUDMetrics.maxColumnWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, HUDMetrics.spacingLarge)
            .padding(.top, HUDMetrics.spacingLarge * 2)
            .padding(.bottom, HUDMetrics.spacingLarge)
            .accessibilityElement(children: .combine)
        }
    }

    private func finish() {
        Haptics.toggled(on: true)
        onFinish()
    }
}
