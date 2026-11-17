import AppKit

// --selftest dockscreen-live probe, with one screen: measures what can be measured of the guard without a second
// screen, on the hidden Dock of this one (auto-hide on, an ordinary desktop). How close to the bottom the pointer
// must rest for the hidden Dock to come up; whether the guard's tap sees posted moves at all and where the pointer
// ends after it holds one; and whether the guard, holding this screen's edge as if another screen were chosen, keeps
// the Dock hidden with the shipped depth, for the pointer resting on the bottom row and for pushes past it.
// Bringing up a hidden Dock on its own screen is not moving it to another, so this says nothing certain about the
// move. Puts the pointer back.
extension DockScreenLive {
    static func probe() -> String {
        guard DockScreenDock.autohide else { return "skipped: the probe needs the Dock's auto-hide on, for a hidden Dock to bring up" }
        guard FullScreenDock.dockEdge() == .bottom else { return "skipped: the probe needs the Dock at the bottom" }
        guard !shown() else { return "skipped: the Dock is showing; move the pointer away from it and run again" }

        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        let real = CGDisplayBounds(CGMainDisplayID())
        let x = real.midX.rounded(.down)
        let bottomRow = CGPoint(x: x, y: real.maxY - 1)
        let middle = CGPoint(x: real.midX, y: real.midY)
        let saved = CGEvent(source: nil)?.location ?? middle
        defer { CGWarpMouseCursorPosition(saved) }
        let source = CGEventSource(stateID: .hidSystemState)
        func move(_ point: CGPoint, dy: Int64 = 0) {
            let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventDeltaY, value: dy)
            event?.post(tap: .cghidEventTap)
        }
        // Milliseconds until the Dock showed, nil if it didn't.
        func shownWithin(_ seconds: TimeInterval) -> Int? {
            let start = Date()
            while -start.timeIntervalSinceNow < seconds {
                if shown() { return Int(-start.timeIntervalSinceNow * 1000) }
                pump(0.02)
            }
            return nil
        }
        func away() -> Bool {
            move(middle)
            let start = Date()
            while shown() && -start.timeIntervalSinceNow < 3 { pump(0.05) }
            pump(0.4)
            return !shown()
        }
        // Rests on the bottom row for 1.5 s, then pushes 40 times, 6 points every 15 ms.
        func restThenPush() -> String {
            move(bottomRow)
            pump(0.05)
            let landed = CGEvent(source: nil)?.location.y ?? -1
            if let ms = shownWithin(1.5) { return "came up resting, after \(ms) ms (the pointer at y \(landed))" }
            for i in 1...40 {
                move(bottomRow, dy: 6)
                pump(0.015)
                if shown() { return "stayed hidden resting at y \(landed), came up after \(i) pushes" }
            }
            return shownWithin(1.0).map { _ in "came up just after 40 pushes" } ?? "stayed hidden, resting at y \(landed) and through 40 pushes"
        }

        lines.append("\(DockScreen.connectedDisplays().first?.name ?? "screen") \(Int(real.width))x\(Int(real.height)); bottom row y \(Int(bottomRow.y))")
        // From further up to the bottom row: the first rest that brings the Dock up.
        var band: Int?
        for rows in [12, 8, 6, 5, 4, 3, 2, 1, 0] {
            move(CGPoint(x: x, y: real.maxY - 1 - CGFloat(rows)))
            if shownWithin(1.2) != nil {
                band = rows
                break
            }
        }
        lines.append("without the guard, resting k rows above the bottom row brings the Dock up from k = \(band.map(String.init) ?? "none (not even 0)")")
        check(away(), "it hides again when the pointer leaves")

        let holder = DockScreenGuard(edge: { .bottom })
        let tap = EventTap(name: "dock screen probe", types: [.mouseMoved], location: .cghidEventTap, ownThread: true, handlers: [holder])
        let fake = CGRect(x: real.maxX, y: real.minY, width: 2560, height: 1440)
        for depth in [1, DockScreen.guardDepth] {
            holder.layout = DockScreenLayout(screens: [real, fake], chosen: 1, depth: depth)
            tap.update()
            let outcome = restThenPush()
            let seen = holder.seen, held = holder.heldCount
            holder.layout = nil
            tap.update()
            lines.append("with the guard keeping the bottom \(Int(depth)) row\(depth == 1 ? "" : "s") clear: the Dock \(outcome); \(seen) moves seen, \(held) held")
            if depth == DockScreen.guardDepth {
                check(outcome.hasPrefix("stayed hidden, resting"), "the shipped depth (\(Int(depth))) keeps the hidden Dock down")
                check(seen > 0 && held > 0, "the guard's tap sees posted moves and holds them")
            }
            check(away(), "the Dock is hidden after that")
        }
        CGWarpMouseCursorPosition(saved)
        pump(0.3)
        let now = CGEvent(source: nil)?.location ?? .zero
        check(abs(now.x - saved.x) <= 1 && abs(now.y - saved.y) <= 1, "the pointer is back where it was")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    // The Dock's window is on screen, or its strip of icons has come up past the bottom edge.
    private static func shown() -> Bool {
        if FullScreenDock.dockIsShown() { return true }
        let real = CGDisplayBounds(CGMainDisplayID())
        return DockScreenDock.stripFrame().map { $0.minY < real.maxY - 1 } == true
    }
}
