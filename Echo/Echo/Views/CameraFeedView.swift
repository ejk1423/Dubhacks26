//
//  CameraFeedView.swift
//  Echo
//
//  The camera, drawn by us instead of ARKit so it can be shown in greyscale: ARKit's
//  own background is switched off (transparent ARView) and every captured frame is
//  rendered through Core Image on a Metal view underneath. The LiDAR surfaces then
//  sit in colour on a monochrome world, which is what makes them read.
//
//  Frames arrive on the main thread from `ARLiDARManager.onFrame`; the view keeps the
//  latest pixel buffer and draws it on its own display link, so dropped frames cost
//  nothing. Everything here is main-actor (MTKView drives its delegate on main).
//

import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit
import SwiftUI

/// Holds the latest camera frame and draws it, desaturated, filling the view.
final class CameraFeedRenderer: NSObject, MTKViewDelegate {
    /// 0 = black, 1 = normal. Set from the display preference.
    var brightness: Float = 1
    var enabled = true

    private var latest: CVPixelBuffer?
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private lazy var context: CIContext? = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }

    func submit(_ pixelBuffer: CVPixelBuffer) {
        latest = pixelBuffer
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard enabled, let buffer = latest, let context, let queue,
              let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { return }

        // Sensor frames are landscape; held upright they rotate 90 degrees clockwise.
        var image = CIImage(cvPixelBuffer: buffer).oriented(.right)

        // Scale to fill the drawable, centred (the same crop ARKit uses).
        let size = view.drawableSize
        let scale = max(size.width / image.extent.width, size.height / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(translationX: (size.width - image.extent.width) / 2 - image.extent.minX,
                                                        y: (size.height - image.extent.height) / 2 - image.extent.minY))

        let mono = CIFilter.colorControls()
        mono.inputImage = image
        mono.saturation = 0
        mono.brightness = 0
        mono.contrast = 1.05
        var output = mono.outputImage ?? image
        if brightness < 1 {
            let dim = CIFilter.exposureAdjust()
            dim.inputImage = output
            dim.ev = -4 * (1 - brightness)
            output = dim.outputImage ?? output
        }

        context.render(output, to: drawable.texture, commandBuffer: command,
                       bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpaceCreateDeviceRGB())
        command.present(drawable)
        command.commit()
    }
}

struct CameraFeedView: UIViewRepresentable {
    let renderer: CameraFeedRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.delegate = renderer
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 30
        view.colorPixelFormat = .bgra8Unorm
        view.isOpaque = true
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
