import AppKit
import Carbon.HIToolbox

// --selftest wheelzoom-live: ⌘ + wheel in Claude for real, measured by the size of its text. First the user's whole path:
// a ⌘-held wheel notch posted at the hardware level, for whichever RubberMAC's mouse tap is running to zoom. Then this
// build's own: its ⌘ + wheel handler handed a ⌘ notch, and its press (ZoomKeys.press) on its own, each of which has to
// zoom in and back out. Then other ways of pressing Zoom In, for the record, two presses queued at once, and what a
// press costs. Every step that zoomed is undone with Zoom Out and checked. Claude has to be in front already (it's never
// brought forward), and the Mac idle, as it changes what's on the screen.
extension WheelStyle {
    static let claudeID = "com.anthropic.claudefordesktop"

    static func zoomLiveSelfTestReport() -> String {
        guard AX.isTrusted else { return "skipped: accessibility not trusted" }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            return "skipped: the screen is locked"
        }
        if let spaces = SpaceWindows.spaces(), !spaces.current.isDisjoint(with: spaces.fullScreen) {
            return "skipped: a full-screen app's desktop is showing; switch to an ordinary desktop and run again"
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= 20 else { return "skipped: the Mac was in use \(Int(idle)) s ago; run it after 20 s without typing or the mouse" }
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == claudeID else {
            return "skipped: Claude isn't in front (\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"))"
        }
        let pid = front.processIdentifier
        guard let menu = ZoomMenus.pick(ZoomMenus.read(pid) ?? []) else { return "skipped: no Zoom In and Zoom Out in Claude's menus" }

        var lines: [String] = ["claude pid \(pid), secure input \(IsSecureEventInputEnabled() ? "on" : "off"), "
                               + "zoom items \(menu.zoomIn.title) \(menu.zoomIn.shortcut) / \(menu.zoomOut.title) \(menu.zoomOut.shortcut)"]
        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var manualValue: CFTypeRef?
        let manualWas = AXUIElementCopyAttributeValue(app, "AXManualAccessibility" as CFString, &manualValue) == .success
            ? (manualValue as? Bool ?? false) : false
        if !manualWas { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
        defer {
            if !manualWas { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse) }
        }

        // The median height of the text in Claude's front window, and where its first line is.
        func measure() -> (height: Double, top: Double, count: Int)? {
            var window: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window,
                  CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
            var heights: [Double] = []
            var top = Double.infinity
            var nodes = 0
            func walk(_ element: AXUIElement, _ depth: Int) {
                nodes += 1
                guard nodes < 6000, depth < 60 else { return }
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                if role as? String == "AXStaticText", let frame = AX.frame(of: element), frame.height > 5, frame.height < 80 {
                    heights.append(frame.height)
                    top = min(top, frame.minY)
                }
                var children: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                for child in (children as? [AXUIElement]) ?? [] { walk(child, depth + 1) }
            }
            walk(window as! AXUIElement, 0)
            guard heights.count >= 5 else { return nil }
            heights.sort()
            return (heights[heights.count / 2], top, heights.count)
        }
        func describe(_ m: (height: Double, top: Double, count: Int)?) -> String {
            m.map { String(format: "text %.1f pt high, top %.0f, %d texts", $0.height, $0.top, $0.count) } ?? "no text"
        }
        var built: (height: Double, top: Double, count: Int)?
        let start = Date()
        while -start.timeIntervalSinceNow < 4 {
            built = measure()
            if built != nil { break }
            pump(0.2)
        }
        guard var baseline = built else {
            lines.append("Claude's text never showed up in Accessibility within 4 s; nothing pressed")
            return (lines + ["FAIL: can't measure"]).joined(separator: "\n")
        }
        lines.append("baseline: \(describe(baseline)) after \(Int(-start.timeIntervalSinceNow * 1000)) ms")
        let original = baseline

        let source = CGEventSource(stateID: .hidSystemState)
        func key(_ code: Int, _ flags: CGEventFlags, _ character: String, toPid: Bool) {
            var chars = Array(character.utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: toPid ? nil : source, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
                event.flags = flags
                event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
                if toPid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
            }
        }
        func command(_ down: Bool) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: down)
            event?.type = .flagsChanged
            event?.flags = down ? [.maskCommand, CGEventFlags(rawValue: 0x08)] : []
            event?.post(tap: .cghidEventTap)
        }
        // One wheel notch with ⌘ held, as the hand does it: away from you (up) zooms in, Natural scrolling off.
        func notch(_ lines: Int32) {
            command(true)
            pump(0.05)
            let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
            pump(0.05)
            command(false)
        }
        // A bare Accessibility press, timed.
        var rawPresses: [Double] = []
        func press(_ element: AXUIElement?) {
            guard let element else { return }
            let start = DispatchTime.now().uptimeNanoseconds
            AXUIElementPerformAction(element, kAXPressAction as CFString)
            rawPresses.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        // ZoomKeys.press as the handler calls it: how long it holds the caller, and how long until the press is done.
        var handedOver: [Double] = []
        var done: [Double] = []
        func timed(_ body: () -> Void) {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            handedOver.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e3)
            ZoomKeys.presser.queue.sync {}
            done.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        let natural = WheelStyle.naturalScrolling()
        // This build's ⌘ + wheel handler, with Claude's zoom items as read above, handed a made-up ⌘ notch: nothing posted.
        let handler = WheelStyleHandler(zoom: WheelZoom(lookup: { _ in .found(menu) }, press: ZoomKeys.press))
        handler.zoomOn = true
        handler.natural = { natural }
        handler.zoom.front = { (claudeID, pid) }
        func handed(away: Bool) {
            let up = away != natural
            let event = WheelStyleChecks.scroll(lines: up ? 1 : -1, fixed: up ? 0.1 : -0.1, points: up ? 1 : -1, flags: .maskCommand)
            timed { _ = handler.handle(.scrollWheel, event) }
        }
        let ways: [(name: String, required: Bool, zoomIn: () -> Void, zoomOut: () -> Void)] = [
            ("the whole path: ⌘ + one wheel notch posted at the hardware level, for the running RubberMAC's mouse tap", false,
             { notch(natural ? -1 : 1) }, { notch(natural ? 1 : -1) }),
            ("this build's ⌘ + wheel handler, handed a ⌘ notch away and then towards you (nothing posted)", true,
             { handed(away: true) }, { handed(away: false) }),
            ("RubberMAC's press (ZoomKeys.press: asks the menu item, then presses it through Accessibility, on its own queue)", true,
             { timed { ZoomKeys.press(menu.zoomIn, in: pid) } }, { timed { ZoomKeys.press(menu.zoomOut, in: pid) } }),
            ("⌘= without ⇧, posted to Claude's pid", false, { key(kVK_ANSI_Equal, .maskCommand, "=", toPid: true) },
             { key(kVK_ANSI_Minus, .maskCommand, "-", toPid: true) }),
            ("⌘⇧= posted at the hardware level", false, { key(kVK_ANSI_Equal, [.maskCommand, .maskShift], "+", toPid: false) },
             { key(kVK_ANSI_Minus, .maskCommand, "-", toPid: false) }),
            ("Accessibility press on the menu item", false, { press(menu.zoomIn.element) }, { press(menu.zoomOut.element) }),
        ]
        final class PressLog {
            private let lock = NSLock()
            private var notes: [String] = []
            var start = Date()
            func note(_ what: String) {
                lock.lock(); notes.append("\(what) at \(Int(-start.timeIntervalSinceNow * 1000)) ms"); lock.unlock()
            }
            func take() -> String {
                lock.lock(); defer { notes = []; lock.unlock() }
                return notes.isEmpty ? "none" : notes.joined(separator: ", ")
            }
        }
        let pressLog = PressLog()
        let originalAsk = ZoomKeys.presser.ask, originalPress = ZoomKeys.presser.pressElement
        ZoomKeys.presser.ask = { element in let result = originalAsk(element); pressLog.note("asked \(result.rawValue)"); return result }
        ZoomKeys.presser.pressElement = { element in
            let result = originalPress(element); pressLog.note("pressed \(result.rawValue)"); return result
        }
        defer { ZoomKeys.presser.ask = originalAsk; ZoomKeys.presser.pressElement = originalPress }
        func follow() -> (settled: (height: Double, top: Double, count: Int)?, heights: String) {
            var seen: [String] = []
            var last: Double?
            var settled = measure()
            let start = Date()
            while -start.timeIntervalSinceNow < 2.5 {
                settled = measure() ?? settled
                if let height = settled?.height, height != last {
                    seen.append("\(String(format: "%.0f", height)) pt at \(Int(-pressLog.start.timeIntervalSinceNow * 1000)) ms")
                    last = height
                }
                pump(0.1)
            }
            return (settled, seen.joined(separator: " → "))
        }
        // Whatever is left over, either way, undone by the menu items one step at a time, each followed until it settles,
        // so a press that lands late is never doubled.
        func putBack() -> (height: Double, top: Double, count: Int)? {
            for _ in 0..<4 {
                guard let height = measure()?.height else { break }
                if height / baseline.height > 1.02 { press(menu.zoomOut.element) }
                else if height / baseline.height < 0.98 { press(menu.zoomIn.element) }
                else { break }
                _ = follow()
            }
            return measure()
        }
        var failures = 0
        var stopped = false
        for way in ways {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                lines.append("stopped: Claude is no longer in front")
                stopped = true
                break
            }
            baseline = measure() ?? baseline
            _ = pressLog.take()
            pressLog.start = Date()
            way.zoomIn()
            let zoomed = follow()
            let ratio = (zoomed.settled?.height ?? baseline.height) / baseline.height
            let took = ratio > 1.04
            lines.append("\(took ? "zooms " : "nothing") \(way.name): \(describe(zoomed.settled)), ×\(String(format: "%.2f", ratio))")
            lines.append("  presses: \(pressLog.take()); heights: \(zoomed.heights)")
            if way.required, !took {
                failures += 1
                lines.append("  FAIL: it has to zoom in")
            }
            if took {
                pressLog.start = Date()
                way.zoomOut()
                let unzoomed = follow()
                var back = unzoomed.settled
                let undone = back.map { abs($0.height / baseline.height - 1) <= 0.02 } ?? false
                lines.append("  \(undone ? "its own zoom out undid it" : "its zoom out didn't undo it"); presses: \(pressLog.take()); heights: \(unzoomed.heights)")
                if !undone {
                    if way.required {
                        failures += 1
                        lines.append("  FAIL: its own zoom out has to undo it")
                    }
                    back = putBack()
                }
                let restored = back.map { abs($0.height / baseline.height - 1) <= 0.02 } ?? false
                if !restored { failures += 1 }
                lines.append("  \(restored ? "restored" : "NOT RESTORED"): \(describe(back))")
                if !restored {
                    stopped = true
                    break
                }
            } else if let settled = zoomed.settled, abs(settled.top - baseline.top) > 2 {
                lines.append("  the page scrolled instead (top \(Int(baseline.top)) → \(Int(settled.top)))")
                way.zoomOut()
                pump(0.6)
                lines.append("  scrolled back: \(describe(measure()))")
            }
            pump(0.3)
        }
        // Two presses back to back, as two quick notches give, then 70 ms apart, as the throttle spaces them: both land, in
        // order, then two out bring it back. Every press the presser makes is logged with its result, and the text height
        // followed for 2.5 s, so a press that didn't land can be told from a size read before Claude had finished.
        for gap in [0.0, 0.07] where !stopped {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { break }
            let name = gap == 0 ? "two Zoom Ins queued at once" : "two Zoom Ins 70 ms apart, as the throttle spaces two quick notches"
            baseline = measure() ?? baseline
            _ = pressLog.take()
            pressLog.start = Date()
            var kept = [ZoomKeys.presser.press(menu.zoomIn, in: pid)]
            if gap > 0 { pump(gap) }
            kept.append(ZoomKeys.presser.press(menu.zoomIn, in: pid))
            let zoomed = follow()
            let ratio = (zoomed.settled?.height ?? baseline.height) / baseline.height
            let both = ratio > 1.14
            if !both { failures += 1 }
            lines.append("\(both ? "ok  " : "FAIL") \(name) (kept \(kept)): \(describe(zoomed.settled)), ×\(String(format: "%.2f", ratio))")
            lines.append("  presses: \(pressLog.take()); heights: \(zoomed.heights)")
            pressLog.start = Date()
            ZoomKeys.presser.press(menu.zoomOut, in: pid)
            if gap > 0 { pump(gap) }
            ZoomKeys.presser.press(menu.zoomOut, in: pid)
            let unzoomed = follow()
            var back = unzoomed.settled
            let restored = back.map { abs($0.height / baseline.height - 1) <= 0.02 } ?? false
            lines.append("\(restored ? "ok  " : "FAIL") and two Zoom Outs the same way: \(describe(back))")
            lines.append("  presses: \(pressLog.take()); heights: \(unzoomed.heights)")
            if !restored {
                back = putBack()
                lines.append("  put back with the menu items: \(describe(back))")
                failures += 1
            }
        }
        func spread(_ values: [Double], _ unit: String, _ format: String) -> String {
            guard !values.isEmpty else { return "none" }
            let sorted = values.sorted()
            return "\(values.count) presses, median \(String(format: format, sorted[sorted.count / 2])) \(unit), "
                + "\(String(format: format, sorted.first!))–\(String(format: format, sorted.last!)) \(unit)"
        }
        lines.append("cost, ZoomKeys.press on the caller's thread: \(spread(handedOver, "µs", "%.0f"))")
        lines.append("cost, until ZoomKeys' press was done (asked, then pressed, Claude answering both): \(spread(done, "ms", "%.1f"))")
        lines.append("cost, a bare Accessibility press on the item: \(spread(rawPresses, "ms", "%.1f"))")
        // Checked against the size found at the start, and put back to it if a step left it off.
        baseline = original
        var final = measure()
        if let height = final?.height, abs(height / original.height - 1) > 0.02 {
            lines.append("FAIL Claude's zoom not as found (\(describe(final))), put back with the menu items")
            failures += 1
            final = putBack()
        }
        lines.append("Claude's zoom left as found: \(describe(final))")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }
}
