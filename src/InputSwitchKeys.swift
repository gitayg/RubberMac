import AppKit

// Windows-style Left Alt+Shift (Left Option+Shift on a Mac): switch to the next keyboard language.
// Like Windows it fires when the keys are let go with nothing typed in between, so Alt-Shift-arrow
// (select by word) and Alt-Shift-Tab keep working. Remote desktops and VMs keep the keys.
final class InputSwitchKeys: TapHandler {
    var isEnabled = false
    var isActive: Bool { isEnabled }

    private var chord = LanguageChord()

    // Only watches; never changes or swallows an event.
    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard isEnabled, chord.feed(type, flags: event.flags.rawValue) else { return event }
        let app = Frontmost.bundleID
        if !AppLists.remote.contains(app ?? "") {
            DispatchQueue.main.async { InputSources.selectNext() }
        }
        return event
    }
}

struct LanguageChord {
    private static let leftOption: UInt64 = 0x20
    private var armed = false

    // Feed every key event; returns true when Left Alt+Shift was pressed and let go on its own.
    mutating func feed(_ type: CGEventType, flags: UInt64) -> Bool {
        if type == .keyDown { armed = false }
        guard type == .flagsChanged else { return false }
        let held = flags & (Modifiers.control | Modifiers.command | Modifiers.option | Modifiers.shift)
        switch held {
        case Modifiers.option | Modifiers.shift:
            if flags & Self.leftOption != 0 { armed = true }
        case 0:
            defer { armed = false }
            return armed
        case Modifiers.option, Modifiers.shift:
            break
        default:
            armed = false
        }
        return false
    }
}
