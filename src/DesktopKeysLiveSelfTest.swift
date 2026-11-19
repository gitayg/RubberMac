import AppKit
import Carbon.HIToolbox

// --selftest desktopkeys-live: the real thing. With ⌃ and ⌘ held down, as when ⌃⌘→ is pressed, the handler gets the
// arrow and swipes; the window server must then show the next desktop to the right, and ⌃⌘← must take it back. Toward
// the left first when there's nothing to the right. Back where it started, at an end, a press toward that end must
// make no swipe and stay. It switches desktops and posts keys, so it waits for an idle Mac; with one desktop and no
// full-screen app there's nowhere to go, and it says so.
extension DesktopKeys {
    static func liveSelfTestReport() -> String {
        guard AX.isTrusted else { return "skipped: accessibility not trusted" }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            return "skipped: the screen is locked"
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= 20 else { return "skipped: the Mac was in use \(Int(idle)) s ago; run it after 20 s without typing or the mouse" }
        guard let row = Desktops.row() else { return "skipped: the window server's list of Spaces can't be read" }
        guard row.spaces.count > 1 else { return "skipped: this screen has one desktop and no full-screen app, so there's nowhere to move" }
        let start = row.spaces[row.index]
        let there: Direction = row.index + 1 < row.spaces.count ? .right : .left
        let back: Direction = there == .right ? .left : .right
        let neighbour = row.spaces[row.index + (there == .right ? 1 : -1)]
        func current() -> UInt64? { Desktops.row().map { $0.spaces[$0.index] } }
        func number(_ space: UInt64?) -> String { space.flatMap { row.spaces.firstIndex(of: $0) }.map { "\($0 + 1)" } ?? "?" }

        var lines = ["note: \(row.spaces.count) Spaces on the menu bar's screen, starting on number \(row.index + 1); "
                     + "natural scrolling \(DesktopSwipe.naturalScrolling() ? "on" : "off")"]
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        // Milliseconds until the condition held, nil if it didn't within the time.
        func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Int? {
            let begin = Date()
            while -begin.timeIntervalSinceNow < seconds {
                if condition() { return Int(-begin.timeIntervalSinceNow * 1000) }
                pump(0.02)
            }
            return condition() ? Int(seconds * 1000) : nil
        }
        let source = CGEventSource(stateID: .hidSystemState)
        func modifier(_ key: Int, _ flags: CGEventFlags) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: true)
            event?.type = .flagsChanged
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        let control = CGEventFlags(rawValue: Modifiers.control | 0x01)
        let controlCommand = CGEventFlags(rawValue: control.rawValue | Modifiers.command | 0x08)

        let handler = DesktopKeys()
        handler.isEnabled = true
        var outcomes: [Desktops.Outcome] = []
        handler.onMove = { outcomes.append(Desktops.move($0)) }
        // ⌃⌘ held, the arrow through the handler, ⌃⌘ let go. True when the handler swallowed the arrow.
        func press(_ direction: Direction) -> Bool {
            let arrow = direction == .left ? kVK_LeftArrow : kVK_RightArrow
            modifier(kVK_Control, control)
            modifier(kVK_Command, controlCommand)
            pump(0.05)
            var swallowed = true
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(arrow), keyDown: down)!
                event.flags = CGEventFlags(rawValue: controlCommand.rawValue | Modifiers.arrowKey)
                swallowed = handler.handle(down ? .keyDown : .keyUp, event) == nil && swallowed
                pump(0.05)
            }
            modifier(kVK_Command, control)
            modifier(kVK_Control, [])
            return swallowed
        }
        func menuBar() -> String {
            let owner = NSWorkspace.shared.menuBarOwningApplication?.localizedName ?? "none"
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
            return "menu bar \(owner), front \(front)"
        }

        lines.append("note: before: \(menuBar())")
        check(press(there), "⌃⌘\(there.arrow) is swallowed")
        let arrived = waitFor(3) { current() == neighbour }
        check(arrived != nil, "⌃⌘\(there.arrow) shows the Space to the \(there), number \(number(neighbour))"
              + (arrived.map { ", after \($0) ms" } ?? "; still on number \(number(current())) after 3 s"))
        check(outcomes.last == .moved(to: row.spaces.firstIndex(of: neighbour)!, of: row.spaces.count), "and says so (\(outcomes))")
        pump(1)
        lines.append("note: there: \(menuBar())")
        if arrived != nil {
            check(press(back), "⌃⌘\(back.arrow) is swallowed")
            let returned = waitFor(3) { current() == start }
            check(returned != nil, "⌃⌘\(back.arrow) goes back to number \(row.index + 1)" + (returned.map { ", after \($0) ms" } ?? "; not back after 3 s"))
            pump(1.2)
            lines.append("note: back: \(menuBar())")
            let end: Direction? = row.index == 0 ? .left : row.index == row.spaces.count - 1 ? .right : nil
            if let end, current() == start {
                outcomes = []
                check(press(end), "at the \(end) end, ⌃⌘\(end.arrow) is swallowed")
                pump(1)
                check(outcomes == [.atEnd] && current() == start, "makes no swipe and stays on number \(row.index + 1) (\(outcomes))")
            }
        }
        if current() != start { lines.append("note: left on another Space; press ⌃⌘\(back.arrow) or swipe to get back") }
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }
}
