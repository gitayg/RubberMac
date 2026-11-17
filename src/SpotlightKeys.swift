import AppKit
import Carbon.HIToolbox

// Windows-style Win+R and the Windows key on its own: ⌘R opens Spotlight's search bar, and ⌘ tapped alone opens its
// Apps view, like Start. Remote desktops and VMs keep the keys. First in the keyboard tap, so it sees every key before
// another handler can swallow it; it never changes or swallows the ⌘ presses themselves.
final class SpotlightKeys: TapHandler {
    var searchKeyEnabled = false
    var appsKeyEnabled = false
    var isActive: Bool { searchKeyEnabled || appsKeyEnabled }

    // The system's side, swapped out by the self-test. The on… ones are called on the main thread.
    var onSearch: (Spotlight.Shortcut) -> Void = { shortcut in
        log("spotlight: ⌘R → search")
        Spotlight.openSearch(shortcut)
    }
    var onSearchOff: () -> Void = { log("spotlight: ⌘R left to the app, Spotlight's shortcut is off in System Settings") }
    var onApps: () -> Void = {
        log("spotlight: ⌘ alone → apps")
        Spotlight.openApps()
    }
    // While an app (or a stuck login window) holds Secure Input, the tap sees ⌘ but not the keys pressed with it,
    // and the key count doesn't move either: ⌘← would look like ⌘ on its own.
    var onAppsUnseen: () -> Void = { log("spotlight: ⌘ alone ignored, Secure Input is on so keys pressed with ⌘ can't be seen") }
    var secureInput: () -> Bool = { IsSecureEventInputEnabled() }
    var searchShortcut: () -> Spotlight.Shortcut? = Spotlight.searchShortcut
    var counters: () -> CommandTap.Counters = CommandTap.Counters.now
    var frontmost: () -> String? = { Frontmost.bundleID }

    // Set once ⌘R's key-down was taken, so its key-up and repeats are swallowed too, even if ⌘ was let go first.
    private var searchTaken = false
    private var tap = CommandTap()

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        if appsKeyEnabled, type == .flagsChanged || type == .keyDown,
           tap.feed(type, flags: event.flags.rawValue, counters: counters), !AppLists.remote.contains(frontmost() ?? "") {
            let action = secureInput() ? onAppsUnseen : onApps
            DispatchQueue.main.async { action() }
        }
        guard searchKeyEnabled, type == .keyDown || type == .keyUp else { return event }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp || event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            guard searchTaken, keyCode == kVK_ANSI_R else { return event }
            if type == .keyUp { searchTaken = false }
            return nil
        }
        guard Self.takesSearchKey(keyCode: keyCode, flags: event.flags.rawValue, app: frontmost()) else { return event }
        guard let shortcut = searchShortcut() else {
            DispatchQueue.main.async { [onSearchOff] in onSearchOff() }
            return event
        }
        searchTaken = true
        DispatchQueue.main.async { [onSearch] in onSearch(shortcut) }
        return nil
    }

    func tapWasDisabled() {
        searchTaken = false
        tap.reset()
    }

    static func takesSearchKey(keyCode: Int, flags: UInt64, app: String?) -> Bool {
        keyCode == kVK_ANSI_R && !AppLists.remote.contains(app ?? "")
            && flags & (Modifiers.control | Modifiers.command | Modifiers.option | Modifiers.shift) == Modifiers.command
    }
}
