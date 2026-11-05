import AppKit
import Carbon.HIToolbox

// --selftest padkeys: which keys the handler takes, then the bug as it's hit: ⌘⇧Space held for 0.8 s, first with
// this handler in a keyboard tap of the test's own (no Siri, and the pad's action runs once), then with only the
// Carbon hotkey (Siri should come up; its alert stays up to close by hand). The live part opens and closes the
// running app's pad; with "nolive" it's skipped.
extension WritingPadKeys {
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func finish() -> String { (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n") }

        func event(_ key: Int, _ down: Bool, _ flags: CGEventFlags, repeating: Bool = false) -> CGEvent {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down)!
            event.flags = flags
            if repeating { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            return event
        }
        let handler = WritingPadKeys()
        handler.isEnabled = true
        var presses = 0
        handler.onPress = { presses += 1 }
        let chord: CGEventFlags = [.maskCommand, .maskShift]
        let taken = [handler.handle(.keyDown, event(kVK_Space, true, chord)),
                     handler.handle(.keyDown, event(kVK_Space, true, chord, repeating: true)),
                     handler.handle(.keyUp, event(kVK_Space, false, .maskCommand))]
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        check(taken.allSatisfy { $0 == nil } && presses == 1,
              "⌘⇧Space, its key repeats and its key-up (⇧ already let go) are all taken, and open the pad once (\(presses))")
        let others: [(Int, CGEventFlags)] = [(kVK_Space, .maskCommand), (kVK_Space, [.maskCommand, .maskShift, .maskControl]),
                                             (kVK_Space, []), (kVK_ANSI_A, chord)]
        let passed = others.allSatisfy { handler.handle(.keyDown, event($0.0, true, $0.1)) != nil }
        check(passed, "⌘Space, ⌃⌘⇧Space, Space and ⌘⇧A are left alone")
        guard !CommandLine.arguments.contains("nolive") else { return finish() }
        guard AX.isTrusted else { return (lines + ["skipped the live part: accessibility not trusted"]).joined(separator: "\n") }

        NSApp.setActivationPolicy(.accessory)
        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ key: Int, _ down: Bool, _ flags: CGEventFlags, flagsChanged: Bool = false) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            if flagsChanged { event?.type = .flagsChanged }
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        // As a hand does it: ⌘, then ⇧, then Space held, let go in reverse.
        func press(hold: TimeInterval) {
            post(kVK_Command, true, .maskCommand, flagsChanged: true); pump(0.05)
            post(kVK_Shift, true, chord, flagsChanged: true); pump(0.05)
            post(kVK_Space, true, chord); pump(hold)
            post(kVK_Space, false, chord); pump(0.05)
            post(kVK_Shift, false, .maskCommand, flagsChanged: true); pump(0.04)
            post(kVK_Command, false, [], flagsChanged: true)
        }
        // Siri's alert: a small window of SystemUIServer's at the modal-panel level.
        func siriAlerts() -> Set<Int> {
            let level = Int(CGWindowLevelForKey(.modalPanelWindow))
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return Set(windows.filter { $0[kCGWindowOwnerName as String] as? String == "SystemUIServer" && $0[kCGWindowLayer as String] as? Int == level }
                .compactMap { $0[kCGWindowNumber as String] as? Int })
        }
        // Siri gives up on connecting after anything from a fraction of a second to several, so each wait is long.
        func newAlerts(after before: Set<Int>, within seconds: TimeInterval, stopEarly: Bool) -> (Set<Int>, Int?) {
            let start = Date()
            var found: Set<Int> = []
            var when: Int?
            while -start.timeIntervalSinceNow < seconds {
                pump(0.1)
                found = siriAlerts().subtracting(before)
                if !found.isEmpty && when == nil { when = Int(-start.timeIntervalSinceNow * 1000) }
                if !found.isEmpty && stopEarly { break }
            }
            return (found, when)
        }
        guard siriAlerts().isEmpty else {
            lines.append("skipped the live part: a Siri alert is already up; close it and run again")
            return finish()
        }
        // With the handler first, since Siri's alert can't be closed from here: the control below leaves one up.
        let live = WritingPadKeys()
        live.isEnabled = true
        var livePresses = 0
        live.onPress = { livePresses += 1 }
        let tap = EventTap(name: "pad keys test", types: [.keyDown, .keyUp], location: .cghidEventTap, ownThread: true, handlers: [live])
        tap.update()
        press(hold: 0.8)
        let (with, withAt) = newAlerts(after: [], within: 8, stopEarly: false)
        live.isEnabled = false
        tap.update()
        check(with.isEmpty && livePresses == 1, "with the handler, holding ⌘⇧Space brings up no alert in 8 s (\(with.count) new\(withAt.map { ", after \($0) ms" } ?? "")) and opens the pad once (\(livePresses))")
        guard with.isEmpty else { return finish() }

        press(hold: 0.8)
        let (control, controlAt) = newAlerts(after: [], within: 8, stopEarly: true)
        pump(0.5)
        press(hold: 0.05)  // closes the pad the running app opened
        pump(1.0)
        check(!control.isEmpty, "without it, the same press brings up Siri's alert (\(control.count) new, after \(controlAt.map { "\($0) ms" } ?? "-")); close it with OK")
        return finish()
    }
}
