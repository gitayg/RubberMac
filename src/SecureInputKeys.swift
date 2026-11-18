import AppKit

// In the keyboard tap, first, only watching: Secure Input hides the keys but not ⌘, Ctrl and Alt going down, so a
// press of one while it's on is the moment it gets in the way. It tells the main thread at most once a second and
// never changes or swallows an event. On while any of the keyboard tap's other handlers is.
final class SecureInputKeys: TapHandler {
    static let interval: TimeInterval = 1

    private(set) var watched: [TapHandler] = []
    var isActive: Bool { watched.contains { $0.isActive } }

    // The system's side, swapped out by the self-test.
    var secureInput: () -> Bool = SecureInput.isOn
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var onSeen: () -> Void = { SecureInputMonitor.shared.noteOn() }
    private var lastSeen = -Double.infinity

    // The keyboard tap's handlers: this one first, then the ones it watches.
    func watching(_ others: [TapHandler]) -> [TapHandler] {
        watched = others
        return [self] + others
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard type == .flagsChanged,
              event.flags.rawValue & (Modifiers.command | Modifiers.control | Modifiers.option) != 0 else { return event }
        let time = now()
        guard time - lastSeen >= Self.interval, secureInput() else { return event }
        lastSeen = time
        DispatchQueue.main.async { [onSeen] in onSeen() }
        return event
    }
}
