//
//  ARWireframeView.swift
//  Echo
//
//  SwiftUI wrapper around the single `ARView` owned by `ARLiDARManager`.
//  `ContentView` layers the HUD on top; the view itself is invisible to VoiceOver
//  so the hero gauge and controls are the only things it lands on.
//

import SwiftUI
import RealityKit

struct ARWireframeView: UIViewRepresentable {
    let manager: ARLiDARManager

    func makeUIView(context: Context) -> ARView {
        // The manager owns the view so the AR session survives SwiftUI re-creation.
        let view = manager.arView
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Nothing to push: the manager drives the view directly.
    }
}
