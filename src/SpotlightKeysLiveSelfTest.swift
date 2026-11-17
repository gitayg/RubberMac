import AppKit
import Carbon.HIToolbox

// --selftest spotlightkeys-live: opens Spotlight's Apps view and then its search bar for real, each the way its key
// does, finds it on screen (Spotlight's windows belong to "Siri") and closes it with Esc: from the Apps view the first
// Esc goes back to the search bar and a second closes it. For the search, ⌘ is held while the shortcut's own key goes
// by, as when ⌘R is pressed. It puts Spotlight on the screen and posts keys, so it waits for an idle, ordinary desktop.
extension SpotlightKeys {
    static func liveSelfTestReport() -> String {
        guard AX.isTrusted else { return "skipped: accessibility not trusted" }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            return "skipped: the screen is locked"
        }
        if let spaces = SpaceWindows.spaces(), !spaces.current.isDisjoint(with: spaces.fullScreen) {
            return "skipped: a full-screen app's desktop is showing; switch to an ordinary desktop and run again"
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= 20 else { return "skipped: the Mac was in use \(Int(idle)) s ago; run it after 20 s without typing or the mouse" }
        guard spotlightWindows().isEmpty else { return "skipped: Spotlight is already open; close it and run again" }
        guard let shortcut = Spotlight.searchShortcut() else { return "skipped: Spotlight's shortcut is off in System Settings" }

        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        // Milliseconds until the condition held, nil if it didn't within the time.
        func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Int? {
            let start = Date()
            while -start.timeIntervalSinceNow < seconds {
                if condition() { return Int(-start.timeIntervalSinceNow * 1000) }
                pump(0.02)
            }
            return condition() ? Int(seconds * 1000) : nil
        }
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ key: Int, _ down: Bool, _ flags: CGEventFlags, flagsChanged: Bool = false) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            if flagsChanged { event?.type = .flagsChanged }
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        func escape() {
            post(kVK_Escape, true, [])
            post(kVK_Escape, false, [])
        }
        func sizes() -> String {
            spotlightWindows().map { "\(Int($0.bounds.width))x\(Int($0.bounds.height)) layer \($0.layer)" }.joined(separator: ", ")
        }
        func openAndClose(_ what: String, _ open: () -> Void) {
            // A window left from the step before would pass for this one.
            guard spotlightWindows().isEmpty else {
                check(false, "\(what): can't tell, Spotlight is still on screen (\(sizes()))")
                return
            }
            open()
            let shown = waitFor(2) { !spotlightWindows().isEmpty }
            let first = sizes()
            pump(0.5)
            check(shown != nil, "\(what) opens: a window of Siri's on screen"
                  + (shown.map { " after \($0) ms (\(first)), then \(sizes())" } ?? " within 2 s"))
            guard shown != nil else { return }
            var presses: [String] = []
            for _ in 1...3 where !spotlightWindows().isEmpty {
                escape()
                presses.append(waitFor(1) { spotlightWindows().isEmpty }.map { "closed after \($0) ms" } ?? "still \(sizes())")
            }
            check(spotlightWindows().isEmpty, "Esc closes it: " + presses.enumerated().map { "Esc \($0.offset + 1) \($0.element)" }.joined(separator: ", "))
            pump(0.5)
        }

        openAndClose("the Apps view") { Spotlight.openApps() }
        openAndClose("the search bar (\(shortcut.keyCode), flags \(String(shortcut.flags.rawValue, radix: 16)))") {
            post(kVK_Command, true, [.maskCommand, CGEventFlags(rawValue: 0x08)], flagsChanged: true)
            pump(0.05)
            Spotlight.openSearch(shortcut)
            pump(0.05)
            post(kVK_Command, false, [], flagsChanged: true)
        }
        if !spotlightWindows().isEmpty { lines.append("note: Spotlight was left open; close it with Esc") }
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    // Spotlight's own windows, the Apps view and the search bar alike.
    static func spotlightWindows() -> [(layer: Int, bounds: CGRect)] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter { $0[kCGWindowOwnerName as String] as? String == "Siri" }.map {
            let bounds = ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            return ($0[kCGWindowLayer as String] as? Int ?? 0, bounds ?? .zero)
        }
    }
}
