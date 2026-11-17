import CoreGraphics

// ⌘ pressed and let go on its own, like a tap of the Windows key. It counts only if ⌘ (either one) was the only
// modifier from press to release, with no key, click or scroll in between. The keyboard tap sees no mouse, and a key an
// earlier tap took never reaches it, so the system's own event counters are compared as well.
struct CommandTap {
    struct Counters: Equatable {
        var keyDowns: UInt32
        var clicks: UInt32
        var scrolls: UInt32
        // The scrolls RubberMAC's own mouse tap saw, which the system's count misses for some mice.
        var seen: UInt32 = 0

        static func now() -> Counters {
            func count(_ type: CGEventType) -> UInt32 { CGEventSource.counterForEventType(.combinedSessionState, eventType: type) }
            return Counters(keyDowns: count(.keyDown),
                            clicks: count(.leftMouseDown) &+ count(.rightMouseDown) &+ count(.otherMouseDown),
                            scrolls: count(.scrollWheel), seen: ScrollSeen.count)
        }
    }

    private var held: UInt64 = 0
    // The counters when ⌘ went down on its own; nil once anything else happened.
    private var pressed: Counters?

    // Feed every flagsChanged and keyDown; returns true on the release that ends a tap. The counters are read only
    // when ⌘ goes down alone and when it comes back up.
    mutating func feed(_ type: CGEventType, flags: UInt64, counters: () -> Counters) -> Bool {
        if type == .keyDown { pressed = nil }
        guard type == .flagsChanged else { return false }
        let now = flags & (Modifiers.control | Modifiers.command | Modifiers.option | Modifiers.shift)
        defer { held = now }
        switch now {
        case Modifiers.command:
            if held == 0 { pressed = counters() }
        case 0:
            defer { pressed = nil }
            guard let pressed else { return false }
            return pressed == counters()
        default:
            pressed = nil
        }
        return false
    }

    mutating func reset() {
        held = 0
        pressed = nil
    }
}
