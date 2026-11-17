import AppKit

// --selftest dockscreen-live: the real thing, on two or more screens. With the pointer just put on another screen's
// Dock edge the Dock stays put; pushed past that edge, as a hand does, macOS moves the Dock there (how many pushes
// that takes is reported); with a guard of its own keeping it on that screen, the same pushes on the first screen's
// edge leave it where it is; and a push on the first screen's edge, as the feature brings it, takes it back. Ends
// with the Dock on the screen it started on and the pointer where it was, and says whether it did. Moves the Dock and
// the pointer, so it waits for an idle, ordinary desktop; with one screen there's nothing to move, and it says so.
// With `probe` after it and one screen, runs DockScreenProbeSelfTest.swift's measurement instead.
enum DockScreenLive {
    private typealias G = DockScreenGeometry

    static func report() -> String {
        let displays = DockScreen.connectedDisplays()
        if displays.count == 1, CommandLine.arguments.last == "probe" { return unready() ?? probe() }
        guard displays.count >= 2 else {
            return "skipped: one screen connected (\(displays.map(\.name).joined(separator: ", "))); the Dock can only be kept on a screen, "
                + "or moved between them, with two or more"
        }
        guard !DockScreenDock.spansDisplays else { return "skipped: \"Displays have separate Spaces\" is off, so the Dock stays on the main screen" }
        if let reason = unready() { return reason }

        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func finish() -> String { (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n") }
        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }

        let screens = displays.map(\.bounds)
        let edge = FullScreenDock.dockEdge()
        func dockOn() -> Int? { DockScreenDock.screen(among: screens, edge: edge) }
        func describe(_ push: DockScreenDock.Push) -> String {
            "\(push.pushes) pushes of 6 points, \(push.milliseconds) ms" + (push.interrupted ? ", stopped: the pointer was moved" : "")
        }
        lines.append("\(displays.count) screens: " + displays.map(\.name).joined(separator: ", ")
                     + "; Dock \(edge.rawValue), auto-hide \(DockScreenDock.autohide ? "on" : "off")")
        guard let start = dockOn() else {
            check(false, "the Dock is found on one of the screens")
            return finish()
        }
        guard let other = screens.indices.first(where: { $0 != start && G.pushPoint(on: $0, edge: edge, screens: screens) != nil }),
              let otherPoint = G.pushPoint(on: other, edge: edge, screens: screens),
              let startPoint = G.pushPoint(on: start, edge: edge, screens: screens) else {
            return "skipped: no other screen has a \(edge.rawValue) edge free to push against"
        }
        let saved = CGEvent(source: nil)?.location ?? .zero
        lines.append("the Dock starts on \(displays[start].name); pushing on \(displays[other].name) at \(Int(otherPoint.x)),\(Int(otherPoint.y))")
        defer { CGWarpMouseCursorPosition(saved) }

        // Only on the edge, no push: a pointer resting there isn't enough.
        CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved, mouseCursorPosition: otherPoint,
                mouseButton: .left)?.post(tap: .cghidEventTap)
        pump(1.0)
        check(dockOn() == start, "the pointer put on \(displays[other].name)'s edge for a second, with no push, leaves the Dock on \(displays[start].name)")
        CGWarpMouseCursorPosition(saved)
        pump(0.3)

        let free = DockScreenDock.push(at: otherPoint, edge: edge, maxPushes: 100, checkEvery: 1) { dockOn() == other }
        pump(0.5)
        check(free.arrived && dockOn() == other, "pushed past that edge, macOS moves the Dock there: \(describe(free))")
        guard free.arrived else {
            if dockOn() != start { _ = DockScreenDock.push(at: startPoint, edge: edge) { dockOn() == start } }
            check(dockOn() == start, "the Dock is back on \(displays[start].name)")
            return finish()
        }

        let holder = DockScreenGuard(edge: { edge })
        holder.layout = DockScreenLayout(screens: screens, chosen: other, depth: DockScreen.guardDepth)
        let tap = EventTap(name: "dock screen test", types: [.mouseMoved], location: .cghidEventTap, ownThread: true, handlers: [holder])
        tap.update()
        let held = DockScreenDock.push(at: startPoint, edge: edge, maxPushes: max(2 * free.pushes, 40), checkEvery: 1) { dockOn() == start }
        pump(0.5)
        let seen = holder.seen, heldMoves = holder.heldCount
        holder.layout = nil
        tap.update()
        check(!held.arrived && dockOn() == other, "kept on \(displays[other].name), the same pushes on \(displays[start].name)'s edge leave it there: "
              + "\(describe(held)); the guard saw \(seen) moves and held \(heldMoves)")

        let back = DockScreenDock.push(at: startPoint, edge: edge) { dockOn() == start }
        pump(0.5)
        check(back.arrived, "a push on \(displays[start].name)'s edge, as the feature brings it, takes the Dock back: \(describe(back))")
        if dockOn() != start { _ = DockScreenDock.push(at: startPoint, edge: edge, maxPushes: 200) { dockOn() == start } }
        CGWarpMouseCursorPosition(saved)
        pump(0.3)
        check(dockOn() == start, "the Dock ends on \(displays[start].name), where it started")
        let now = CGEvent(source: nil)?.location ?? .zero
        check(abs(now.x - saved.x) <= 1 && abs(now.y - saved.y) <= 1, "the pointer is back where it was (\(Int(now.x)),\(Int(now.y)))")
        return finish()
    }

    // Why the pointer can't be moved now, if it can't: no Accessibility, a locked screen, a full-screen app's desktop
    // showing, or someone at the Mac.
    static func unready() -> String? {
        guard AX.isTrusted else { return "skipped: accessibility not trusted" }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            return "skipped: the screen is locked"
        }
        if let spaces = SpaceWindows.spaces(), !spaces.current.isDisjoint(with: spaces.fullScreen) {
            return "skipped: a full-screen app's desktop is showing; switch to an ordinary desktop and run again"
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= 20 else { return "skipped: the Mac was in use \(Int(idle)) s ago; run it after 20 s without typing or the mouse" }
        return nil
    }
}
