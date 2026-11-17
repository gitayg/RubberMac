import AppKit
import Carbon.HIToolbox

// Spotlight's two ways in. The Apps view is an app of its own. The search bar isn't (Spotlight.app won't launch), so
// it's opened by pressing Spotlight's own shortcut, as set in System Settings › Keyboard › Keyboard Shortcuts.
enum Spotlight {
    struct Shortcut: Equatable {
        let keyCode: Int
        let flags: CGEventFlags
    }

    static let appsURL = URL(fileURLWithPath: "/System/Applications/Apps.app")
    static let defaultShortcut = Shortcut(keyCode: kVK_Space, flags: .maskCommand)
    private static let searchHotKey = "64"
    private static let noKey = 65535

    // nil when the shortcut is off, so there's nothing to press. The system writes this entry with strings as well as
    // numbers ("1", "49"), so both are read.
    static func shortcut(in hotKeys: [String: Any]?) -> Shortcut? {
        guard let entry = hotKeys?[searchHotKey] as? [String: Any] else { return defaultShortcut }
        if let enabled = number(entry["enabled"]), enabled == 0 { return nil }
        guard let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Any], parameters.count == 3,
              let keyCode = number(parameters[1]), let flags = number(parameters[2]) else { return defaultShortcut }
        guard keyCode != noKey else { return nil }
        return Shortcut(keyCode: keyCode, flags: CGEventFlags(rawValue: UInt64(flags)))
    }

    // The search bar or the Apps view is on screen: Spotlight's windows belong to Siri, at a level of their own.
    static let windowLayer = 23

    static func isOpen() -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { $0[kCGWindowOwnerName as String] as? String == "Siri" && $0[kCGWindowLayer as String] as? Int == windowLayer }
    }

    static func systemHotKeys() -> [String: Any]? {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any]
    }

    static func searchShortcut() -> Shortcut? {
        shortcut(in: systemHotKeys())
    }

    private static func number(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return (value as? String).flatMap { Int($0) }
    }

    // Only the key itself, with the shortcut's flags on it. ⌘ is still under the finger when ⌘R gets here; a posted
    // ⌘-up would have the system think it was let go while it's still held.
    static func openSearch(_ shortcut: Shortcut) {
        // Before the key goes, so the search bar comes up in English. Pressed while it's up, the key closes it.
        InputPerApp.shared.prepareForSpotlight(closes: isOpen())
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: down)
            event?.flags = shortcut.flags
            event?.post(tap: .cghidEventTap)
        }
    }

    static func openApps() {
        InputPerApp.shared.prepareForSpotlight(closes: false)
        NSWorkspace.shared.openApplication(at: appsURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { DispatchQueue.main.async { log("spotlight: couldn't open Apps (error \((error as NSError).code))") } }
        }
    }
}
