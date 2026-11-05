import Foundation
import IOKit.hid

// Remembers pointer and wheel speed per mouse model and puts them back whenever a mouse connects.
// Pointer speed is each mouse's own; the wheel speed is the mouse in use's (the newest connection when
// several are plugged in), since a scroll event doesn't say which mouse sent it.
final class MouseProfiles {
    // Called when the mice or a wheel speed change, so the scroll tap can pick up the new multiplier.
    var onChange: (() -> Void)?

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

    var mice: [String] { PointerSpeed.mice() }
    var activeMouse: String? { mice.last }
    var wheelSpeed: Double { wheelSpeed(for: activeMouse) }

    // Matching only, never opening a device, so this needs no Input Monitoring permission.
    func start() {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                                                kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            Unmanaged<MouseProfiles>.fromOpaque(context!).takeUnretainedValue().devicesChanged()
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            Unmanaged<MouseProfiles>.fromOpaque(context!).takeUnretainedValue().devicesChanged()
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    func pointerSpeed(for mouse: String) -> Double? { PointerSpeed.current(for: mouse) }

    func setPointerSpeed(_ speed: Double, for mouse: String) {
        Settings.pointerSpeeds[mouse] = speed
        PointerSpeed.set(speed, for: mouse)
    }

    func wheelSpeed(for mouse: String?) -> Double {
        Self.wheelSpeed(for: mouse, remembered: Settings.wheelSpeeds, fallback: Settings.wheelSpeed)
    }

    func setWheelSpeed(_ multiplier: Double, for mouse: String) {
        Settings.wheelSpeeds[mouse] = multiplier
        onChange?()
    }

    // A mouse that has none of its own starts from the single wheel speed 1.10.0 kept for every mouse.
    static func wheelSpeed(for mouse: String?, remembered: [String: Double], fallback: Double) -> Double {
        mouse.flatMap { remembered[$0] } ?? fallback
    }

    // macOS sets a new connection to the System Settings speed shortly after it appears, so put ours back
    // once that has happened, and again in case it was slow.
    private func devicesChanged() {
        onChange?()
        for delay in [1.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.restore() }
        }
    }

    private func restore() {
        for mouse in mice {
            guard let speed = Settings.pointerSpeeds[mouse], PointerSpeed.current(for: mouse) != speed else { continue }
            PointerSpeed.set(speed, for: mouse)
            log("mouse: \(mouse) pointer speed \(speed)")
        }
        onChange?()
    }
}
