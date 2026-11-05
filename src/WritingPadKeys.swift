import AppKit
import Carbon.HIToolbox

// ⌘⇧Space for the writing pad, taken in the keyboard tap so Siri never sees it. Siri's own watcher ignores ⇧, so a
// ⌘⇧Space held a moment reads to it as "hold ⌘Space", and Siri (or its "Siri Unavailable" alert) comes up over
// the pad. The Carbon hotkey stays registered for when this tap isn't running; while it is, the key never gets there.
final class WritingPadKeys: TapHandler {
    var isEnabled = false
    var isActive: Bool { isEnabled }
    // Called on the main thread.
    var onPress: () -> Void = {}

    // Set once Space went down with ⌘⇧, so its key-up is swallowed too, even if ⌘ or ⇧ was let go first.
    private var taken = false

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard isEnabled, type == .keyDown || type == .keyUp,
              event.getIntegerValueField(.keyboardEventKeycode) == kVK_Space else { return event }
        if type == .keyUp {
            defer { taken = false }
            return taken ? nil : event
        }
        guard Self.isChord(flags: event.flags.rawValue) else { return event }
        if !taken && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { [onPress] in onPress() }
        }
        taken = true
        return nil
    }

    func tapWasDisabled() {
        taken = false
    }

    static func isChord(flags: UInt64) -> Bool {
        flags & (Modifiers.control | Modifiers.command | Modifiers.option | Modifiers.shift) == Modifiers.command | Modifiers.shift
    }
}
