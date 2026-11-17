import AppKit

// --selftest dockscreen: the pointer guard, finding the Dock's screen and the popup, as pure geometry on made-up
// screens; the guard's handler fed made-up moves; FullScreenDock's edge check on what the guard passes on, on this
// Mac's real screen; and this Mac's Dock, read without changing it. Moves nothing, posts nothing, changes no setting.
// --selftest dockscreen-live: see DockScreenLiveSelfTest.swift.
extension DockScreen {
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        let stored = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) as NSDictionary?

        guardChecks(check)
        dockScreenChecks(check)
        pushPointChecks(check)
        choiceChecks(check)
        handlerChecks(check)
        fullScreenDockChecks(check)
        thisMac(check) { lines.append($0) }

        let after = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) as NSDictionary?
        check(stored?.isEqual(after) ?? (after == nil), "no stored setting changed")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    static func liveSelfTestReport() -> String { DockScreenLive.report() }

    private typealias Check = (Bool, String) -> Void
    private typealias G = DockScreenGeometry

    // A 1920 × 1080 main screen and a taller 2560 × 1440 one to its right, reaching further down.
    private static let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private static let right = CGRect(x: 1920, y: 0, width: 2560, height: 1440)

    private static func held(_ point: CGPoint, _ delta: CGVector, _ edge: FullScreenDock.Edge, _ layout: DockScreenLayout) -> String {
        guard let held = G.held(point, delta: delta, edge: edge, layout: layout) else { return "left alone" }
        return "\(Int(held.point.x)),\(Int(held.point.y)) Δ\(Int(held.delta.dx)),\(Int(held.delta.dy))"
    }

    // MARK: The guard's geometry

    private static func guardChecks(_ check: Check) {
        let side = [main, right]
        let onMain = DockScreenLayout(screens: side, chosen: 0)
        let onRight = DockScreenLayout(screens: side, chosen: 1)
        let down = CGVector(dx: 0, dy: 5)

        check(held(CGPoint(x: 3000, y: 1439), down, .bottom, onMain) == "3000,1438 Δ0,0",
              "kept on the main screen, a push down at the other screen's bottom edge is held a point short, without the push: "
              + held(CGPoint(x: 3000, y: 1439), down, .bottom, onMain))
        check(held(CGPoint(x: 960, y: 1079), down, .bottom, onMain) == "left alone", "the chosen screen's own bottom edge is left alone")
        check(held(CGPoint(x: 960, y: 1079), down, .bottom, onRight) == "960,1078 Δ0,0",
              "kept on the right screen, the main screen's bottom edge is held: " + held(CGPoint(x: 960, y: 1079), down, .bottom, onRight))
        check(held(CGPoint(x: 3000, y: 1439.6), down, .bottom, onMain) == "3000,1438 Δ0,0", "a fraction of a point into the last row counts")
        check(held(CGPoint(x: 3000, y: 1440), down, .bottom, onMain) == "3000,1438 Δ0,0", "and so does the far border itself (y = maxY)")
        check(held(CGPoint(x: 3000, y: 1438), down, .bottom, onMain) == "left alone", "a point short of the edge is left alone: it isn't pushing yet")
        check(held(CGPoint(x: 3000, y: 700), down, .bottom, onMain) == "left alone", "the middle of the other screen is left alone")
        check(held(CGPoint(x: 3000, y: 1439), CGVector(dx: 12, dy: 0), .bottom, onMain) == "3000,1438 Δ12,0",
              "moving along the held edge keeps going sideways: " + held(CGPoint(x: 3000, y: 1439), CGVector(dx: 12, dy: 0), .bottom, onMain))
        check(held(CGPoint(x: 3000, y: 1439), CGVector(dx: 0, dy: -4), .bottom, onMain) == "3000,1438 Δ0,-4", "moving up off it keeps going up")
        check(held(CGPoint(x: 1919, y: 1079), CGVector(dx: 8, dy: 0), .right, onRight) == "left alone",
              "the main screen's right edge runs into the other screen, so it's crossed, not pushed: left alone")
        check(held(CGPoint(x: 4479, y: 500), CGVector(dx: 8, dy: 0), .right, onMain) == "4478,500 Δ0,0",
              "Dock on the right: the other screen's right edge is held: " + held(CGPoint(x: 4479, y: 500), CGVector(dx: 8, dy: 0), .right, onMain))
        check(held(CGPoint(x: 1920, y: 500), CGVector(dx: -8, dy: 0), .left, onMain) == "left alone",
              "Dock on the left: the other screen's left edge runs into the main one, so it's left alone")
        let leftOfMain = DockScreenLayout(screens: [main, CGRect(x: -2560, y: 0, width: 2560, height: 1440)], chosen: 0)
        check(held(CGPoint(x: -2560, y: 700), CGVector(dx: -7, dy: 3), .left, leftOfMain) == "-2559,700 Δ0,3",
              "Dock on the left, a screen to the left of the main one: its left edge is held: "
              + held(CGPoint(x: -2560, y: 700), CGVector(dx: -7, dy: 3), .left, leftOfMain))
        check(held(CGPoint(x: -2560, y: 700), CGVector(dx: -7, dy: 3), .bottom, leftOfMain) == "left alone",
              "with the Dock at the bottom, the same left edge is left alone")

        // One below the other, the lower one shifted right: the main screen's bottom edge is outer only on its left part.
        let below = CGRect(x: 960, y: 1080, width: 1920, height: 1080)
        let stacked = DockScreenLayout(screens: [main, below], chosen: 1)
        check(held(CGPoint(x: 100, y: 1079), down, .bottom, stacked) == "100,1078 Δ0,0",
              "stacked: the outer part of the upper screen's bottom edge is held: " + held(CGPoint(x: 100, y: 1079), down, .bottom, stacked))
        check(held(CGPoint(x: 1500, y: 1079), down, .bottom, stacked) == "left alone", "and the part above the lower screen is crossed, so left alone")

        let deep = DockScreenLayout(screens: side, chosen: 0, depth: 4)
        check(held(CGPoint(x: 3000, y: 1436), down, .bottom, deep) == "3000,1435 Δ0,0",
              "keeping 4 rows clear: a move 3 rows above the bottom row is held 4 rows above it: " + held(CGPoint(x: 3000, y: 1436), down, .bottom, deep))
        check(held(CGPoint(x: 3000, y: 1435), down, .bottom, deep) == "left alone", "and one 4 rows above is left alone")
        check(held(CGPoint(x: 4477, y: 500), CGVector(dx: 8, dy: 0), .right, deep) == "4475,500 Δ0,0", "on the right, the same band of columns")
        let deepLeft = DockScreenLayout(screens: [main, CGRect(x: -2560, y: 0, width: 2560, height: 1440)], chosen: 0, depth: 4)
        check(held(CGPoint(x: -2557, y: 700), CGVector(dx: -7, dy: 0), .left, deepLeft) == "-2556,700 Δ0,0", "and on the left")

        var stuck = onMain
        stuck.dockAt = 1
        check(held(CGPoint(x: 3000, y: 1439), down, .bottom, stuck) == "left alone",
              "while the Dock is still on the other screen, that screen's edge is left alone, so the Dock can be reached there")
    }

    // MARK: Finding the Dock's screen

    private static func dockScreenChecks(_ check: Check) {
        let side = [main, right]
        func on(_ strip: CGRect, _ edge: FullScreenDock.Edge = .bottom, _ screens: [CGRect] = side) -> String {
            G.dockScreen(strip: strip, edge: edge, screens: screens).map { "\($0)" } ?? "none"
        }
        check(on(CGRect(x: 600, y: 1010, width: 720, height: 70)) == "0", "a Dock shown at the main screen's bottom is on screen 0")
        check(on(CGRect(x: 600, y: 1080, width: 720, height: 70)) == "0", "hidden just below it, still screen 0")
        check(on(CGRect(x: 36, y: 1080, width: 1848, height: 66)) == "0", "as this Mac's hidden Dock was read (36,1080 1848x66 under a 1920x1080 screen), screen 0")
        check(on(CGRect(x: 600, y: 940, width: 720, height: 70)) == "none", "a strip well above the bottom, against nothing, is on none")
        check(on(CGRect(x: 2800, y: 1370, width: 800, height: 70)) == "1", "shown at the other screen's bottom, screen 1")
        check(on(CGRect(x: 2800, y: 1440, width: 800, height: 70)) == "1", "hidden below that, screen 1")
        check(on(CGRect(x: 2800, y: 1000, width: 800, height: 70)) == "none", "a strip against no edge is on none")
        check(on(CGRect(x: 1920, y: 300, width: 70, height: 600), .left) == "1", "on the left: against the other screen's left side, screen 1")
        check(on(CGRect(x: 4480, y: 300, width: 70, height: 600), .right) == "1", "on the right, hidden past the other screen's right side, screen 1")
        let below = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        check(on(CGRect(x: 600, y: 1080, width: 720, height: 70), .bottom, [main, below]) == "0",
              "stacked: a strip hidden below the upper screen, inside the lower one, is the upper screen's")
        check(on(CGRect(x: 600, y: 2090, width: 720, height: 70), .bottom, [main, below]) == "1", "and one shown at the lower one's bottom is the lower one's")
    }

    // MARK: Where to push

    private static func pushPointChecks(_ check: Check) {
        check(G.pushPoint(on: 0, edge: .bottom, screens: [main, right]) == CGPoint(x: 959, y: 1079), "push point: the middle of the main screen's bottom row")
        check(G.pushPoint(on: 1, edge: .right, screens: [main, right]) == CGPoint(x: 4479, y: 719), "on the right: the middle of the other screen's last column")
        let below = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        check(G.pushPoint(on: 0, edge: .bottom, screens: [main, below]) == nil, "an edge that runs into another screen all along has no push point")
        let shifted = CGRect(x: 960, y: 1080, width: 1920, height: 1080)
        let point = G.pushPoint(on: 0, edge: .bottom, screens: [main, shifted])
        check(point.map { $0.x < 960 && $0.y == 1079 } == true, "partly covered: the push point is on the outer part (\(point.map { "\(Int($0.x)),\(Int($0.y))" } ?? "none"))")
        check(G.pushDelta(.bottom, 6) == CGVector(dx: 0, dy: 6) && G.pushDelta(.left, 6) == CGVector(dx: -6, dy: 0)
              && G.pushDelta(.right, 6) == CGVector(dx: 6, dy: 0), "a push goes down, left or right, past the edge")
    }

    // MARK: Choosing

    private static func choiceChecks(_ check: Check) {
        let displays = [Display(key: "1:2:3", name: "Studio Display", bounds: main), Display(key: "4:5:6", name: "DELL U2723QE", bounds: right)]
        check(layout(displays, chosen: "4:5:6", spansDisplays: false) == DockScreenLayout(screens: [main, right], chosen: 1, depth: guardDepth),
              "layout: the chosen screen by its key, keeping \(Int(guardDepth)) rows clear")
        check(layout(displays, chosen: nil, spansDisplays: false) == nil, "nothing chosen: no layout, the tap stays off")
        check(layout(displays, chosen: "7:8:9", spansDisplays: false) == nil, "the chosen screen not connected: none, as Any Screen")
        check(layout([displays[0]], chosen: "1:2:3", spansDisplays: false) == nil, "one screen: none")
        check(layout(displays, chosen: "4:5:6", spansDisplays: true) == nil, "\"Displays have separate Spaces\" off: none")

        func titles(_ chosen: String?, _ name: String?) -> String {
            choices(displays, chosen: chosen, chosenName: name).map { $0.on ? "[\($0.title)]" : $0.title }.joined(separator: " | ")
        }
        check(titles(nil, nil) == "[\(anyScreen)] | Studio Display | DELL U2723QE", "popup with nothing chosen: \(titles(nil, nil))")
        check(titles("4:5:6", "DELL U2723QE") == "\(anyScreen) | Studio Display | [DELL U2723QE]", "with one chosen: \(titles("4:5:6", "DELL U2723QE"))")
        check(titles("7:8:9", "LG UltraFine") == "\(anyScreen) | Studio Display | DELL U2723QE | [LG UltraFine (not connected)]",
              "with one not connected: \(titles("7:8:9", "LG UltraFine"))")

        let delegate = AppDelegate(lockWarning: LockWarning(timeoutOverride: nil))
        let facts = SettingsFacts()
        let rows = delegate.dockScreenRows(facts, displays: displays, chosen: "4:5:6", chosenName: nil, spansDisplays: false)
        let items: [NSMenuItem]
        if case .popup(let list) = rows.first?.control { items = list } else { items = [] }
        check(rows.count == 1 && rows[0].title == popupTitle && items.map(\.title) == [anyScreen, "", "Studio Display", "DELL U2723QE"]
              && items[1].isSeparatorItem, "the row: \(popupTitle), Any Screen, a line, then each screen")
        check(items.filter { !$0.isSeparatorItem }.map { $0.representedObject as? String } == [nil, "1:2:3", "4:5:6"]
              && items.filter { $0.state == .on }.map(\.title) == ["DELL U2723QE"], "each item carries its screen's key, and the chosen one is ticked")
        check(items.filter { !$0.isSeparatorItem }.allSatisfy { $0.target === delegate && delegate.responds(to: $0.action!) },
              "and each reaches setDockScreen(_:)")
        let spans = delegate.dockScreenRows(facts, displays: displays, chosen: nil, chosenName: nil, spansDisplays: true)
        check(spans.count == 2 && spans[1].isNote && spans[1].title == spansNote, "\"Displays have separate Spaces\" off: the note under the popup")
        var noAccess = facts
        noAccess.permissions = PermissionCheck(accessibility: false, screenRecording: true, finder: .on, finderUsed: true)
        check(delegate.dockScreenRows(noAccess, displays: displays, chosen: nil, chosenName: nil, spansDisplays: false)[0].closesPanel
              && !rows[0].closesPanel, "without Accessibility the popup closes the panel, for macOS's question; with it, it doesn't")
    }

    // MARK: The handler

    private static func handlerChecks(_ check: Check) {
        let handler = DockScreenGuard(edge: { .bottom })
        let rows = guardDepth
        func move(_ type: CGEventType, _ point: CGPoint, dy: Int64) -> CGEvent {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
            event.setIntegerValueField(.mouseEventDeltaY, value: dy)
            return event
        }
        func after(_ event: CGEvent) -> String {
            guard let out = handler.handle(event.type, event) else { return "swallowed" }
            return "\(Int(out.location.x)),\(Int(out.location.y)) Δ\(out.getIntegerValueField(.mouseEventDeltaY))"
        }
        check(!handler.isActive && after(move(.mouseMoved, CGPoint(x: 3000, y: 1439), dy: 5)) == "3000,1439 Δ5", "no layout: off, and moves go by untouched")
        handler.layout = DockScreenLayout(screens: [main, right], chosen: 0, depth: rows)
        let heldAt = "3000,\(Int(1440 - rows - 1)) Δ0"
        check(handler.isActive, "with a layout, on")
        check(after(move(.mouseMoved, CGPoint(x: 3000, y: 1439), dy: 5)) == heldAt, "a push down at the other screen's edge goes on held: \(heldAt)")
        check(after(move(.leftMouseDragged, CGPoint(x: 3000, y: 1439), dy: 5)) == heldAt, "a drag there too")
        check(after(move(.mouseMoved, CGPoint(x: 960, y: 1079), dy: 5)) == "960,1079 Δ5", "on the chosen screen it goes by untouched")
        check(after(move(.mouseMoved, CGPoint(x: 3000, y: 700), dy: 5)) == "3000,700 Δ5", "away from the edge too")
        check(handler.seen == 4 && handler.heldCount == 2, "counted: \(handler.seen) seen, \(handler.heldCount) held")
    }

    // MARK: Next to FullScreenDock

    // On this Mac's real screen, with a made-up screen to its right chosen: what the guard passes on from the bottom
    // edge is no longer at an edge for FullScreenDock, so it adds no push there; with the real screen chosen,
    // FullScreenDock's arrival and its own marked pushes go by untouched.
    private static func fullScreenDockChecks(_ check: Check) {
        let real = CGDisplayBounds(CGMainDisplayID())
        let made = CGRect(x: real.maxX, y: real.minY, width: 2560, height: 1440)
        let edgePoint = CGPoint(x: real.midX, y: real.maxY - 1)
        guard FullScreenDock.edge(at: edgePoint) == .bottom else {
            check(false, "FullScreenDock sees the real screen's bottom row as its bottom edge (it sees \(FullScreenDock.edge(at: edgePoint).map(\.rawValue) ?? "none"))")
            return
        }
        let handler = DockScreenGuard(edge: { .bottom })
        handler.layout = DockScreenLayout(screens: [real, made], chosen: 1, depth: guardDepth)
        let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: edgePoint, mouseButton: .left)!
        event.setIntegerValueField(.mouseEventDeltaY, value: 6)
        let out = handler.handle(.mouseMoved, event)
        check(out.map { FullScreenDock.edge(at: $0.location) == nil } == true,
              "another screen chosen: FullScreenDock sees no edge in what the guard passes on (\(out.map { "y \($0.location.y)" } ?? "nothing"))")

        handler.layout = DockScreenLayout(screens: [real, made], chosen: 0, depth: guardDepth)
        let arrival = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: edgePoint, mouseButton: .left)!
        check(handler.handle(.mouseMoved, arrival).map { FullScreenDock.edge(at: $0.location) == .bottom } == true,
              "this screen chosen: FullScreenDock still sees the pointer arrive at its bottom edge")
        let push = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: edgePoint, mouseButton: .left)!
        push.setIntegerValueField(.mouseEventDeltaY, value: 6)
        push.setIntegerValueField(.eventSourceUserData, value: 0x5354_444F_434B)
        let passed = handler.handle(.mouseMoved, push)
        check(passed?.location == edgePoint && passed?.getIntegerValueField(.mouseEventDeltaY) == 6,
              "and one of its marked pushes there goes by as it was")
    }

    // MARK: This Mac

    private static func thisMac(_ check: Check, _ say: (String) -> Void) {
        let displays = connectedDisplays()
        say("this Mac: \(displays.count) screen\(displays.count == 1 ? "" : "s"): "
            + displays.map { "\($0.name) (\($0.key)) at \(Int($0.bounds.minX)),\(Int($0.bounds.minY)) \(Int($0.bounds.width))x\(Int($0.bounds.height))" }.joined(separator: ", "))
        say("Dock: \(FullScreenDock.dockEdge().rawValue), auto-hide \(DockScreenDock.autohide ? "on" : "off"), "
            + "separate Spaces \(DockScreenDock.spansDisplays ? "off" : "on"); kept on: \(Settings.dockScreen.map { "\(Settings.dockScreenName ?? "?") (\($0))" } ?? "any screen")")
        guard AX.isTrusted else { return say("skipped reading the Dock's place: accessibility not trusted") }
        let strip = DockScreenDock.stripFrame()
        let found = DockScreenDock.screen(among: displays.map(\.bounds))
        check(strip != nil && found != nil, "the Dock's strip of icons is read and found on a screen: "
              + (strip.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "not read")
              + " → " + (found.map { displays[$0].name } ?? "none"))
    }
}
