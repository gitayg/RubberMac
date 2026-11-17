import AppKit

// The keyboard's volume and brightness keys. They don't come as key presses but as "system defined" events
// (NX_SYSDEFINED, subtype 8), with the key and whether it went down packed into data1. A volume key is taken when the
// device sound goes to has a volume a Mac can set; a brightness key when the pointer is on an external screen whose
// brightness macOS can't set itself. Everything else, and anything with ⌘ or ⌃, or ⌥ alone (which opens Sound or
// Displays settings), goes on to macOS. A taken key keeps its repeats and key-up, so macOS never sees half a press.
// Runs on the tap's own thread: the system side is CoreAudio and CoreGraphics, and the work goes to the main queue.
final class MediaKeys: TapHandler {
    enum Key: Int {
        case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7

        var isVolume: Bool { self == .volumeUp || self == .volumeDown || self == .mute }
        var isUp: Bool { self == .volumeUp || self == .brightnessUp }
        // Held, mute would switch on and off with each repeat.
        var repeats: Bool { self != .mute }
    }

    struct Press: Equatable {
        let key: Key
        // ⌥⇧ with the key: a quarter step, as macOS does.
        let fine: Bool
        // The screen for a brightness key.
        let display: CGDirectDisplayID?
    }

    // A decoded aux-control event: the key's code, down or up, and whether it's the key repeating.
    struct Event: Equatable {
        let code: Int
        let down: Bool
        let repeating: Bool

        init(code: Int, down: Bool, repeating: Bool) {
            self.code = code
            self.down = down
            self.repeating = repeating
        }

        // data1 is the key's code in the high 16 bits, then 0x0A for down or 0x0B for up, then 1 for a repeat.
        init?(data1: Int) {
            let state = (data1 >> 8) & 0xFF
            guard state == 0x0A || state == 0x0B else { return nil }
            self.init(code: (data1 >> 16) & 0xFFFF, down: state == 0x0A, repeating: data1 & 1 == 1)
        }

        var data1: Int { code << 16 | (down ? 0x0A : 0x0B) << 8 | (repeating ? 1 : 0) }
    }

    static let systemDefined = CGEventType(rawValue: 14)!
    static let auxControlSubtype: Int16 = 8

    var isEnabled = false
    var isActive: Bool { isEnabled }

    // The system side, swapped out by the self-test.
    var canSetVolume: () -> Bool = { OutputVolume.current?.canSetVolume ?? false }
    var canMute: () -> Bool = { OutputVolume.current?.canMute ?? false }
    var displayUnderPointer: () -> CGDirectDisplayID? = MediaKeys.displayUnderPointer
    var macOSSetsBrightness: (CGDirectDisplayID) -> Bool = MediaKeys.macOSSetsBrightness
    var onPress: (Press) -> Void = { _ in }

    // Codes of the keys taken while down; only the tap's thread touches it.
    private var taken: Set<Int> = []

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard type == Self.systemDefined, let key = Self.decode(event) else { return event }
        if !key.down { return taken.remove(key.code) == nil ? event : nil }
        // A repeat goes where its first press went, even if the pointer has moved to another screen since.
        if key.repeating {
            guard taken.contains(key.code) else { return event }
            if Key(rawValue: key.code)?.repeats == true, let press = press(for: key, flags: event.flags) { send(press) }
            return nil
        }
        taken.remove(key.code)
        guard let press = press(for: key, flags: event.flags) else { return event }
        taken.insert(key.code)
        send(press)
        return nil
    }

    private func send(_ press: Press) {
        DispatchQueue.main.async { [onPress] in onPress(press) }
    }

    func tapWasDisabled() {
        taken = []
    }

    // What a key going down would do, or nil to leave it to macOS.
    private func press(for event: Event, flags: CGEventFlags) -> Press? {
        guard let key = Key(rawValue: event.code), !flags.contains(.maskCommand), !flags.contains(.maskControl) else { return nil }
        let shift = flags.contains(.maskShift), option = flags.contains(.maskAlternate)
        if option && !shift { return nil }
        let fine = option && shift
        if key.isVolume {
            // Mute too only where the volume can be set, so a TV's three keys all stay macOS's.
            guard canSetVolume(), key != .mute || canMute() else { return nil }
            return Press(key: key, fine: fine, display: nil)
        }
        guard let display = displayUnderPointer(), !macOSSetsBrightness(display) else { return nil }
        return Press(key: key, fine: fine, display: display)
    }

    // NSEvent only reads the event here, which is safe off the main thread.
    static func decode(_ event: CGEvent) -> Event? {
        guard event.type == systemDefined, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == auxControlSubtype else { return nil }
        return Event(data1: ns.data1)
    }

    static func displayUnderPointer() -> CGDirectDisplayID? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        var display = CGDirectDisplayID(0)
        var count = UInt32(0)
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1 else { return nil }
        return display
    }

    // A made-up key event as the keyboard sends it, for the self-tests.
    static func event(_ event: Event, flags: CGEventFlags = []) -> CGEvent? {
        NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)),
                           timestamp: 0, windowNumber: 0, context: nil, subtype: auxControlSubtype, data1: event.data1, data2: -1)?.cgEvent
    }
}
