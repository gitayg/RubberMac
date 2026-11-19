import AppKit

// A trackpad swipe between desktops, made up and handed to the Dock, which is the only way left to change desktops:
// macOS 27 ignores a posted ⌃←/→ (Mission Control's own shortcut). Translated from InstantSpaceSwitcher (MIT, see
// THIRD_PARTY_NOTICES.md): a DockControl event and its Gesture companion for each of began, changed and ended, with the
// raw IOHID payload macOS 27 wants appended to the DockControl one. Near-zero progress and a fling on ended switch at
// once, with no slide. The field numbers are undocumented and could change with macOS.
enum DesktopSwipe {
    // Gesture phases.
    static let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4

    private static func field(_ number: UInt32) -> CGEventField { unsafeBitCast(number, to: CGEventField.self) }
    static let eventType = field(55)
    static let hidType = field(110)
    static let swipeMask = field(115)
    static let motion = field(123)
    static let progress = field(124)
    static let positionX = field(125)
    static let positionY = field(126)
    static let velocityX = field(129)
    static let velocityY = field(130)
    static let phase = field(132)
    static let phaseAlias = field(134)
    static let zoomDeltaY = field(138)
    static let timeAlias = field(169)

    static let gestureEvent: Int64 = 29, dockControlEvent: Int64 = 30
    static let dockSwipe: Int64 = 23
    static let horizontal: Int64 = 1
    // The smallest non-zero 16.16 value: nothing left to animate.
    static let nudge = 0.000016
    // 16.16 fixed point tops out near 32767.
    static let fling = 9999.0

    // Right is negative with natural scrolling on, and the Dock reads the sign through that setting, so it flips with
    // natural scrolling off.
    static func sign(_ direction: DesktopKeys.Direction, naturalScrolling: Bool) -> Double {
        let natural: Double = direction == .right ? -1 : 1
        return naturalScrolling ? natural : -natural
    }

    static func naturalScrolling() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        var valid: DarwinBoolean = false
        let on = CFPreferencesGetAppBooleanValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication, &valid)
        return !valid.boolValue || on
    }

    // False when an event couldn't be made, so nothing was posted from there on.
    @discardableResult
    static func post(_ direction: DesktopKeys.Direction) -> Bool {
        let sign = sign(direction, naturalScrolling: naturalScrolling())
        for phase in [began, changed, ended] {
            guard let pair = events(phase: phase, sign: sign) else { return false }
            pair.dock.post(tap: .cgSessionEventTap)
            pair.companion.post(tap: .cgSessionEventTap)
        }
        return true
    }

    // The DockControl event, with its payload, and the Gesture event the Dock wants beside it.
    static func events(phase: Int64, sign: Double) -> (dock: CGEvent, companion: CGEvent)? {
        guard let event = CGEvent(source: nil), let companion = CGEvent(source: nil) else { return nil }
        event.setIntegerValueField(eventType, value: dockControlEvent)
        event.setIntegerValueField(hidType, value: dockSwipe)
        event.setIntegerValueField(self.phase, value: phase)
        event.setIntegerValueField(motion, value: horizontal)
        event.setDoubleValueField(progress, value: sign * nudge)
        // Fields a real trackpad swipe carries.
        event.setIntegerValueField(phaseAlias, value: phase)
        event.setDoubleValueField(zoomDeltaY, value: 3)
        event.setDoubleValueField(timeAlias, value: Double(mach_absolute_time()))
        event.setDoubleValueField(positionX, value: 0.1)
        if phase == ended { event.setDoubleValueField(velocityX, value: sign * fling) }
        guard let dock = augmented(event) else { return nil }
        companion.setIntegerValueField(eventType, value: gestureEvent)
        return (dock, companion)
    }

    // The event's serialized form with a tag and the IOHID payload after it, read back as an event. Nil if the form
    // isn't the version this was made for.
    static func augmented(_ event: CGEvent) -> CGEvent? {
        guard let data = event.data as Data?, data.count >= 4, Array(data.prefix(4)) == [0, 0, 0, 2] else { return nil }
        let body = payload(of: event)
        let size = UInt16(body.count), tag = UInt16(4205)
        let bytes = data + [UInt8(size >> 8), UInt8(size & 0xFF), UInt8(tag >> 8), UInt8(tag & 0xFF)] + body
        return CGEvent(withDataAllocator: nil, data: bytes as CFData)
    }

    // A queue element header, then a fluid touch gesture event, then (on ended, or with any velocity) a velocity event.
    static func payload(of event: CGEvent) -> [UInt8] {
        let phase = event.getIntegerValueField(self.phase)
        let velocity = (x: event.getDoubleValueField(velocityX), y: event.getDoubleValueField(velocityY))
        let withVelocity = velocity.x != 0 || velocity.y != 0 || phase == ended
        var bytes: [UInt8] = []
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
        let timestamp = event.timestamp
        put(timestamp == 0 ? mach_absolute_time() : timestamp)
        put(UInt64(0))
        put(UInt32(0))
        put(UInt32(0))
        put(UInt32(withVelocity ? 2 : 1))

        put(UInt32(40))
        put(UInt32(dockSwipe))
        put(UInt32(truncatingIfNeeded: (phase & 0xFF) << 24))
        put(UInt8(0)); put(UInt8(0)); put(UInt8(0)); put(UInt8(0))
        put(fixed(event.getDoubleValueField(positionX)))
        put(fixed(event.getDoubleValueField(positionY)))
        put(Int32(0))
        put(UInt32(truncatingIfNeeded: event.getIntegerValueField(swipeMask)))
        put(UInt16(truncatingIfNeeded: event.getIntegerValueField(motion)))
        put(UInt16(3))
        put(fixed(event.getDoubleValueField(progress)))

        if withVelocity {
            put(UInt32(28))
            put(UInt32(9))
            put(UInt32(0))
            put(UInt8(1)); put(UInt8(0)); put(UInt8(0)); put(UInt8(0))
            put(fixed(velocity.x))
            put(fixed(velocity.y))
            put(Int32(0))
        }
        return bytes
    }

    // 16.16 fixed point, never rounded to zero.
    static func fixed(_ value: Double) -> Int32 {
        let fixed = Int32(clamping: Int64(value * 65536))
        return fixed == 0 && value != 0 ? (value > 0 ? 1 : -1) : fixed
    }
}
