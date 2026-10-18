//
//  ARWireframeView.swift
//  Echo
//
//  SwiftUI wrapper around the single `ARView` owned by `ARLiDARManager`.
//  The HUD (Step 6) layers status indicators and the emergency controls on top.
//

import SwiftUI
import RealityKit

struct ARWireframeView: UIViewRepresentable {
    let manager: ARLiDARManager

    func makeUIView(context: Context) -> ARView {
        // The manager owns the view so the AR session survives SwiftUI re-creation.
        manager.arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Nothing to push: the manager drives the view directly.
    }
}
