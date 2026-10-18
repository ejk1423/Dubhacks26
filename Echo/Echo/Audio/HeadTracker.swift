//
//  HeadTracker.swift
//  Echo
//
//  AirPods head tracking via `CMHeadphoneMotionManager`. Reports how far the head is
//  turned relative to the body (the phone's walking heading), so `SpatialAudioEngine`
//  can keep a wall ping on the wall while the user looks around.
//
//  Both yaws are measured around gravity, so their changes are comparable even though
//  the AirPods and ARKit use unrelated reference frames:
//      relativeYaw = (headYaw - headYaw0) - (phoneYaw - phoneYaw0)
//  The two references are captured together on the first update and by `recenter()`
//  (call it while looking straight ahead along the phone).
//

import CoreMotion
import Foundation

final class HeadTracker {

    private let motion = CMHeadphoneMotionManager()
    private var headYaw: Float?
    private var lastUpdate: TimeInterval = 0
    private var headYaw0: Float?
    private var phoneYaw0: Float?

    /// True while AirPods (or other supported headphones) are streaming head motion.
    var isActive: Bool {
        headYaw != nil && ProcessInfo.processInfo.systemUptime - lastUpdate < 1.0
    }

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.startDeviceMotionUpdates(to: .main) { [weak self] deviceMotion, _ in
            guard let yaw = deviceMotion?.attitude.yaw else { return }
            MainActor.assumeIsolated {
                self?.headYaw = Float(yaw)
                self?.lastUpdate = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        headYaw = nil
        recenter()
    }

    /// Treat the current head direction as "looking along the phone".
    func recenter() {
        headYaw0 = nil
        phoneYaw0 = nil
    }

    /// Head yaw relative to the body in radians, counter-clockwise (left) positive, or nil
    /// when no head motion is available.
    func relativeYaw(phoneYaw: Float) -> Float? {
        guard isActive, let head = headYaw else { return nil }
        if headYaw0 == nil || phoneYaw0 == nil {
            headYaw0 = head
            phoneYaw0 = phoneYaw
        }
        return Self.wrap((head - headYaw0!) - (phoneYaw - phoneYaw0!))
    }

    private static func wrap(_ angle: Float) -> Float {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a < -.pi { a += 2 * .pi }
        return a
    }
}
