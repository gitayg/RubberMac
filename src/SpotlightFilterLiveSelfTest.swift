import AppKit
import ApplicationServices
import Carbon.HIToolbox

// --selftest spotlightfilter-live: the real thing. Turns the feature on in this process (not in the installed app),
// opens Spotlight's search bar the way its shortcut does; the bar must come to show only apps (Spotlight's Back button
// shows) from one ⌘1, and two keys typed 60 ms apart once the switch is done must both stay. Esc then goes back to
// everything before it closes the bar, and the filter stays off. A second opening gets its own ⌘1 and none more when
// its shortcut closes it, and notes whether keys typed the moment its ⌘1 went out survived Spotlight's switch (they
// may not: a letter that reaches Spotlight mid-switch is wiped). A third, with the feature off, shows whether
// Spotlight remembers the filter.
// The bar is opened by its shortcut's key alone, never a lone ⌘, which RubberMAC's own ⌘ tap would take for Start.
// Keys go only while Spotlight holds the keyboard. Waits for an idle, ordinary desktop like spotlightkeys-live.
enum SpotlightFilterLive {
    static func report() -> String {
        guard AX.isTrusted else { return "skipped: accessibility not trusted" }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            return "skipped: the screen is locked"
        }
        if let spaces = SpaceWindows.spaces(), !spaces.current.isDisjoint(with: spaces.fullScreen) {
            return "skipped: a full-screen app's desktop is showing; switch to an ordinary desktop and run again"
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= 20 else { return "skipped: the Mac was in use \(Int(idle)) s ago; run it after 20 s without typing or the mouse" }
        guard SpotlightKeys.spotlightWindows().isEmpty else { return "skipped: Spotlight is already open; close it and run again" }
        guard let shortcut = Spotlight.searchShortcut() else { return "skipped: Spotlight's shortcut is off in System Settings" }
        guard let ui = NSRunningApplication.runningApplications(withBundleIdentifier: SpotlightFilter.uiBundleID).first else {
            return "skipped: Spotlight's search bar (\(SpotlightFilter.uiBundleID)) isn't running"
        }
        let pid = ui.processIdentifier

        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func note(_ what: String) { lines.append("note: \(what)") }
        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Int? {
            let start = Date()
            while -start.timeIntervalSinceNow < seconds {
                if condition() { return Int(-start.timeIntervalSinceNow * 1000) }
                pump(0.01)
            }
            return condition() ? Int(seconds * 1000) : nil
        }
        let source = CGEventSource(stateID: .hidSystemState)
        func bar() -> SpotlightFilterOpenings.Bar { SpotlightFilterWatcher.bar(pid) }
        func holdsKeyboard() -> Bool { bar().focusedPid == pid }
        func value() -> String {
            var element: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AX.app(pid), kAXFocusedUIElementAttribute as CFString, &element) == .success,
                  let element else { return "?" }
            return AX.string(element as! AXUIElement, kAXValueAttribute) ?? "?"
        }
        // Spotlight's sign of a filter: a Back button ahead of the field (described in English on this Mac). The
        // placeholder isn't one: it reads "Applications" only while the field is empty, and " " once letters are typed
        // after the ⌘1 (measured).
        func back() -> Bool {
            func find(_ element: AXUIElement, _ depth: Int) -> Bool {
                if AX.string(element, kAXRoleAttribute) == kAXButtonRole, AX.string(element, kAXDescriptionAttribute) == "Back" { return true }
                guard depth < 4 else { return false }
                var children: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success else { return false }
                return ((children as? [AXUIElement]) ?? []).prefix(8).contains { find($0, depth + 1) }
            }
            return AX.windows(of: pid).contains { find($0, 0) }
        }
        func filtered() -> Bool { back() }
        func state() -> String { "placeholder \"\(bar().placeholder ?? "-")\", text \"\(value())\", Back \(back() ? "shown" : "gone")" }
        // Real keys a quick typist's 60 ms apart, only into Spotlight; whatever letters the layout makes of them.
        func type(_ keys: [Int]) -> Bool {
            for key in keys {
                guard holdsKeyboard() else { return false }
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
                    event?.flags = []
                    event?.post(tap: .cghidEventTap)
                }
                pump(0.06)
            }
            return true
        }
        func escape() -> Bool {
            guard holdsKeyboard() else { return false }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: down)
                event?.flags = []
                event?.post(tap: .cghidEventTap)
            }
            return true
        }
        // Milliseconds until the bar's window is on screen.
        func open() -> Int? {
            let start = Date()
            Spotlight.openSearch(shortcut)
            return waitFor(2) { !SpotlightKeys.spotlightWindows().isEmpty }.map { _ in Int(-start.timeIntervalSinceNow * 1000) }
        }
        func ownerPids() -> [Int] {
            Set((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { $0[kCGWindowOwnerName as String] as? String == "Siri" && $0[kCGWindowLayer as String] as? Int == Spotlight.windowLayer }
                .compactMap { $0[kCGWindowOwnerPID as String] as? Int }).sorted()
        }
        // Esc until the bar lets go of the keyboard; Spotlight's window stays listed for a moment after.
        func closeWithEscape(_ what: String) {
            var steps: [String] = []
            for i in 1...4 where holdsKeyboard() {
                _ = escape()
                let gone = waitFor(0.8) { !holdsKeyboard() }
                steps.append("Esc \(i): " + (gone.map { "closed after \($0) ms" } ?? "open, \(state())"))
            }
            let unlisted = waitFor(3) { SpotlightKeys.spotlightWindows().isEmpty }
            check(!holdsKeyboard() && unlisted != nil, "\(what): " + (steps.isEmpty ? "already closed" : steps.joined(separator: ", "))
                  + "; its window off the list \(unlisted.map { "\($0) ms later" } ?? "not within 3 s")")
            pump(0.4)
        }

        let feature = SpotlightFilter()
        var on = true
        feature.isOn = { on }
        feature.start()
        // Read through the feature, never held here: holding it would keep it watching after the switch goes off.
        guard feature.watcher != nil else { return "FAIL couldn't watch Spotlight's search bar (pid \(pid))\nFAIL: 1 failed" }
        func presses() -> Int { feature.watcher?.openings.presses ?? -1 }

        // 1. Open and type at once.
        let shown = open()
        check(shown != nil, "the search bar opens from its shortcut's key: on screen \(shown.map { "after \($0) ms" } ?? "not within 2 s")")
        guard shown != nil else { return (lines + ["FAIL: \(failures) failed"]).joined(separator: "\n") }
        check(ownerPids() == [Int(pid)], "its window belongs to the process watched, \(SpotlightFilter.uiBundleID) pid \(pid) (owners \(ownerPids()))")
        let pressedAt = waitFor(1.5) { presses() >= 1 }
        pump(0.15)
        let typed = pressedAt != nil && type([kVK_ANSI_S, kVK_ANSI_A])
        check(typed, "the feature sends its ⌘1 \(pressedAt.map { "\($0) ms after the window showed" } ?? "not within 1.5 s"), "
              + "and S, A are typed 150 ms later, 60 ms apart")
        let appsOnly = waitFor(2) { filtered() }
        check(appsOnly != nil && presses() == 1,
              "it comes to show only apps \(appsOnly.map { "\($0) ms after the typing" } ?? "not within 2 s"), from \(presses()) ⌘1 (\(state()))")
        pump(0.5)
        check(value().count == 2, "both letters typed after the switch are kept (text \"\(value())\")")
        check(presses() == 1, "one ⌘1 for this opening (\(presses()))")

        // 2. Esc goes back to everything before it closes the bar, and the filter stays off.
        var steps: [String] = []
        for i in 1...2 where filtered() {
            guard escape() else { break }
            _ = waitFor(0.8) { !filtered() || value().isEmpty }
            pump(0.3)
            steps.append("Esc \(i): \(holdsKeyboard() ? "open" : "closed"), \(state())")
        }
        check(!filtered() && holdsKeyboard() && value().isEmpty, "Esc goes back to everything, the bar still open: " + steps.joined(separator: "; "))
        pump(1)
        check(!filtered() && presses() == 1, "and it stays that way, no second ⌘1 (\(presses()) in all; \(state()))")
        closeWithEscape("Esc closes it")

        // 3. The next opening gets its own ⌘1, and closing it with its shortcut gets none. Keys typed the moment its ⌘1
        // goes out are the worst case for a quick typist.
        let again = open()
        let pressedAgain = again != nil ? waitFor(1.5) { presses() >= 2 } : nil
        let quick = pressedAgain != nil && type([kVK_ANSI_S, kVK_ANSI_A])
        let againApps = again != nil ? waitFor(2) { filtered() } : nil
        check(againApps != nil && presses() == 2,
              "opened again, it shows only apps again \(againApps.map { "\($0) ms after the keys" } ?? "not within 2 s") (\(presses()) ⌘1 in all)")
        pump(0.4)
        note("S, A typed the moment that ⌘1 went out: " + (quick ? "text \"\(value())\", " + (value().count == 2 ? "both kept" : "wiped by Spotlight's switch to apps") : "not typed"))
        var closedByShortcut = false
        if holdsKeyboard() {
            Spotlight.openSearch(shortcut)
            closedByShortcut = waitFor(1.5) { !holdsKeyboard() } != nil
            _ = waitFor(3) { SpotlightKeys.spotlightWindows().isEmpty }
            pump(0.5)
            check(closedByShortcut && presses() == 2, "its shortcut closes it, with no ⌘1 on the way out (\(presses()) in all)")
        }
        let received = feature.watcher?.received ?? [:]
        on = false
        feature.apply()
        check(feature.watcher == nil && !feature.isWatching, "switched off, the feature stops watching")

        // 4. With the feature off, the next opening shows what Spotlight itself kept.
        if closedByShortcut, open() != nil, waitFor(1.5, { holdsKeyboard() }) != nil {
            pump(0.5)
            note("closed with its shortcut while showing only apps, Spotlight opens next time "
                 + (filtered() ? "still showing only apps" : "showing everything") + " (\(state()))")
        }
        closeWithEscape("closed with Esc")
        note("Spotlight's notices received: " + received.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))
        check(SpotlightKeys.spotlightWindows().isEmpty && !holdsKeyboard(), "Spotlight is left closed")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }
}
