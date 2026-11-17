import CoreGraphics
import Synchronization

// The user pressing Spotlight's own shortcut (⌘Space unless changed): the search bar is about to open, so switch to
// English now. Only watches; the shortcut goes on to Spotlight untouched. Remote desktops and VMs keep their keys.
final class InputPerAppKeys: TapHandler {
    // Set on the main thread, read on the tap's.
    private let state = Mutex<(enabled: Bool, shortcut: Spotlight.Shortcut?)>((false, nil))
    // The system's side, swapped out by the self-test. onShortcut is called on the main thread, told whether Spotlight
    // was already up, which makes this press the one that closes it. That's read here, as the key goes by: by the time
    // a busy main thread gets to it, Spotlight may have come up for this very press.
    var onShortcut: (_ closes: Bool) -> Void = { InputPerApp.shared.prepareForSpotlight(closes: $0) }
    var spotlightOpen: () -> Bool = Spotlight.isOpen
    var frontmost: () -> String? = { Frontmost.bundleID }

    var isActive: Bool { state.withLock { $0.enabled } }

    func set(enabled: Bool, shortcut: Spotlight.Shortcut?) {
        state.withLock { $0 = (enabled, shortcut) }
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              let shortcut = state.withLock({ $0.enabled ? $0.shortcut : nil }),
              Self.matches(shortcut, keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags.rawValue),
              !AppLists.remote.contains(frontmost() ?? "") else { return event }
        let closes = spotlightOpen()
        DispatchQueue.main.async { [onShortcut] in onShortcut(closes) }
        return event
    }

    // Fn counts too: a shortcut on an F-key carries it, and so does that key's press.
    private static let held = Modifiers.control | Modifiers.option | Modifiers.shift | Modifiers.command | CGEventFlags.maskSecondaryFn.rawValue

    static func matches(_ shortcut: Spotlight.Shortcut, keyCode: Int, flags: UInt64) -> Bool {
        keyCode == shortcut.keyCode && flags & held == shortcut.flags.rawValue & held
    }
}
