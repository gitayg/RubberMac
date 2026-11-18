import AppKit

// --selftest wheelstyle: made-up scroll events fed straight to the handler, nothing posted. Off, untouched; turned the
// classic way only with Natural scrolling on; one notch's distance for a slow and a fast notch, Logi Options+'s too;
// trackpad, momentum, WheelDragScroll's and a smoothing driver's steps untouched; horizontal and ⇧ + wheel like
// vertical; ⌘ + wheel zooming through a made-up menu and a recorded press, without its ⌘ opening Start; the Mouse
// page's rows. Changes no setting.
// The presses' queue: WheelStylePressSelfTest.swift. What a scroll costs the handler: WheelStyleCost.swift.
// --selftest wheelstyle menus: WheelStyleMenus.swift. --selftest wheelstyle probe: WheelStyleProbe.swift.
extension WheelStyle {
    static func selfTestReport() -> String {
        switch CommandLine.arguments.last {
        case "probe": return WheelStyleProbe.report()
        case "menus": return WheelStyleMenus.report()
        default: break
        }
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let stored = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?

        WheelStyleChecks.restyle(check)
        WheelStyleChecks.zoom(check)
        WheelStyleChecks.menus(check)
        WheelStyleChecks.cache(check)
        WheelStyleChecks.presses(check)
        WheelStyleChecks.rows(check)
        WheelStyleCost.measure(check)

        let after = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?
        check(stored?.isEqual(after) ?? (after == nil), "no stored setting changed")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }
}

enum WheelStyleChecks {
    typealias Check = (Bool, String) -> Void

    // A made-up scroll event on one axis. The line count goes in first, as setting it recomputes the other two.
    static func scroll(lines: Int64 = 0, fixed: Double = 0, points: Int64 = 0, axis: Int = 0, phase: Int64 = 0, momentum: Int64 = 0,
                       continuous: Bool = false, marked: Bool = false, flags: CGEventFlags = [], inverted: Bool = false) -> CGEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: continuous ? .pixel : .line, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)!
        let fields = WheelNotch.axes[axis]
        event.setIntegerValueField(fields.lines, value: lines)
        event.setDoubleValueField(fields.fixed, value: fixed)
        event.setIntegerValueField(fields.points, value: points)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        if marked { event.setIntegerValueField(.eventSourceUserData, value: WheelDragScroll.marker) }
        event.setIntegerValueField(WheelNotch.invertedField, value: inverted ? 1 : 0)
        event.flags = flags
        return event
    }

    // Lines, fixed-point and points on each axis; a fixed-point delta keeps 16 bits of fraction, so two places.
    static func describe(_ event: CGEvent?) -> String {
        guard let event else { return "swallowed" }
        return WheelNotch.axes.map { axis in
            "\(event.getIntegerValueField(axis.lines)) \(String(format: "%.2f", event.getDoubleValueField(axis.fixed))) \(event.getIntegerValueField(axis.points))"
        }.joined(separator: " | ") + (event.getIntegerValueField(WheelNotch.invertedField) != 0 ? " (turned round)" : "")
    }

    static func handler(classic: Bool = false, steady: Bool = false, zoom: Bool = false, natural: Bool = true,
                        lookup: @escaping (pid_t) -> ZoomLookup = { _ in .none }) -> WheelStyleHandler {
        let handler = WheelStyleHandler(zoom: WheelZoom(lookup: lookup, press: { _, _ in }))
        handler.classic = classic
        handler.steady = steady
        handler.zoomOn = zoom
        handler.natural = { natural }
        return handler
    }

    static func through(_ handler: WheelStyleHandler, _ event: CGEvent) -> String {
        describe(handler.handle(.scrollWheel, event))
    }

    // MARK: Classic and Steady

    // As macOS might send them (not measured: --selftest wheelstyle probe records the real thing): a slow notch with
    // a tenth of a line in fixed point, and a fast one accelerated to 9 lines.
    static let slow = (lines: Int64(1), fixed: 0.1, points: Int64(1))
    static let fast = (lines: Int64(9), fixed: 9.4, points: Int64(94))

    static func restyle(_ check: Check) {
        let notch = "3 3.00 30 | 0 0.00 0", back = "-3 -3.00 -30 | 0 0.00 0"
        let off = handler()
        let plain = scroll(lines: slow.lines, fixed: slow.fixed, points: slow.points)
        let before = describe(plain)
        check(!off.isActive && through(off, plain) == before, "all switches off: inactive, so the tap can stay off, and a notch goes by untouched (\(before))")
        check(handler(classic: true).isActive && handler(steady: true).isActive && handler(zoom: true).isActive, "any one switch on: active")
        check(!WheelStyle.Switches(classic: false, steady: false, zoom: false).any && WheelStyle.Switches(classic: false, steady: true, zoom: false).any,
              "Accessibility is wanted while any switch is on, and only then")

        // Classic.
        let classic = handler(classic: true)
        let down = scroll(lines: slow.lines, fixed: slow.fixed, points: slow.points, inverted: true)
        let came = describe(down)
        check(through(classic, down) == "-1 -0.10 -1 | 0 0.00 0", "classic, Natural scrolling on: a notch (\(came)) is turned round, fixed point and points too")
        check(NSEvent(cgEvent: down)?.isDirectionInvertedFromDevice == false, "and no longer marked as turned round, as with Natural scrolling off")
        let fastDown = scroll(lines: -fast.lines, fixed: -fast.fixed, points: -fast.points)
        check(through(classic, fastDown) == "9 9.40 94 | 0 0.00 0", "a fast notch the other way too, its distance kept: \(describe(fastDown))")
        let unnatural = handler(classic: true, natural: false)
        let classicAlready = scroll(lines: -1, fixed: -0.1, points: -1)
        check(through(unnatural, classicAlready) == "-1 -0.10 -1 | 0 0.00 0", "Natural scrolling off: the wheel already scrolls the classic way, so it's left alone")
        let marked = scroll(lines: 1, fixed: 0.1, points: 1, inverted: true)
        check(through(unnatural, marked) == "-1 -0.10 -1 | 0 0.00 0", "but an event macOS marks as turned round is turned back even with the setting read as off")
        var natural = true
        let following = handler(classic: true)
        following.natural = { natural }
        let first = through(following, scroll(lines: 1, fixed: 0.1, points: 1))
        natural = false
        let second = through(following, scroll(lines: 1, fixed: 0.1, points: 1))
        check(first == "-1 -0.10 -1 | 0 0.00 0" && second == "1 0.10 1 | 0 0.00 0",
              "Natural scrolling turned off while running: the very next notch follows it, no restart (\(first), then \(second))")

        // Steady.
        let steady = handler(steady: true)
        let slowOut = through(steady, scroll(lines: slow.lines, fixed: slow.fixed, points: slow.points))
        let fastOut = through(steady, scroll(lines: fast.lines, fixed: fast.fixed, points: fast.points))
        check(slowOut == notch && fastOut == notch, "steady: a slow notch (1, 0.1, 1) and a fast one (9, 9.4, 94) both scroll \(WheelNotch.lines) lines: \(slowOut) and \(fastOut)")
        check(through(steady, scroll(lines: -fast.lines, fixed: -fast.fixed, points: -fast.points)) == back, "the other way, -3 lines")
        check(through(steady, scroll(lines: 2)) == notch && through(steady, scroll(points: -7)) == back,
              "a notch with only a line count, or only points, takes its direction from that")
        let speed = WheelSpeed()
        speed.multiplier = 2
        let scaled = speed.handle(.scrollWheel, steady.handle(.scrollWheel, scroll(lines: fast.lines, fixed: fast.fixed, points: fast.points))!)
        check(describe(scaled) == "6 6.00 60 | 0 0.00 0", "the wheel speed after it still scales a steady notch: ×2 gives \(describe(scaled))")

        // An MX Master 3 through Logi Options+, as the probe recorded it: every event continuous, no phase, whole lines.
        let optionsSlow = scroll(lines: -1, fixed: -1, points: -13, continuous: true)
        let optionsSpin = scroll(lines: -10, fixed: -10, points: -103, continuous: true)
        let optionsOdd = scroll(lines: -2, fixed: -3, points: -28, continuous: true)
        check([optionsSlow, optionsSpin, optionsOdd].allSatisfy(WheelNotch.isNotched),
              "Logi Options+'s events (-1 -1.00 -13, -10 -10.00 -103, -2 -3.00 -28, continuous) count as notches")
        check(through(steady, scroll(lines: -1, fixed: -1, points: -13, continuous: true)) == back
              && through(steady, scroll(lines: -10, fixed: -10, points: -103, continuous: true)) == back
              && through(steady, scroll(lines: -2, fixed: -3, points: -28, continuous: true)) == back,
              "steady: its slow notch, a free-spin step and an odd one all scroll -3 lines")
        check(through(classic, scroll(lines: 1, fixed: 1, points: 13, continuous: true)) == "-1 -1.00 -13 | 0 0.00 0",
              "classic, Natural scrolling on: its notch is turned round")
        check(through(unnatural, scroll(lines: 1, fixed: 1, points: 13, continuous: true)) == "1 1.00 13 | 0 0.00 0",
              "Natural scrolling off: its notch goes by as it came")
        check(!WheelNotch.isNotched(scroll(fixed: 0.4, points: 4, continuous: true)) && !WheelNotch.isNotched(scroll(lines: 1, fixed: 1.4, points: 14, continuous: true)),
              "a smoothing driver's steps (0 lines and 0.40, or 1 line and 1.40) are not notches")

        // Left alone, with every switch on.
        let all = handler(classic: true, steady: true, zoom: true)
        let untouched: [(String, CGEvent)] = [
            ("a trackpad swipe (scroll phase changed)", scroll(lines: 1, fixed: 0.4, points: 4, phase: 2, continuous: true)),
            ("its first event (phase began)", scroll(fixed: 0.1, points: 1, phase: 1, continuous: true)),
            ("momentum after it", scroll(lines: 2, fixed: 2.5, points: 25, momentum: 2, continuous: true)),
            ("a Magic Mouse swipe with ⌘ held", scroll(lines: 1, fixed: 0.4, points: 4, phase: 2, continuous: true, flags: .maskCommand)),
            ("WheelDragScroll's own scroll", scroll(lines: 3, fixed: 3, points: 30, continuous: true, marked: true)),
            ("WheelDragScroll's own scroll with ⌘ held", scroll(lines: 3, fixed: 3, points: 30, continuous: true, marked: true, flags: .maskCommand)),
            ("a smoothing driver's step of less than a line (continuous, no phase)", scroll(fixed: 0.6, points: 6, continuous: true)),
            ("a smoothing driver's step of a line and a bit", scroll(lines: 1, fixed: 1.4, points: 14, continuous: true)),
        ]
        for (name, event) in untouched {
            let was = describe(event)
            check(through(all, event) == was, "every switch on, \(name) goes by untouched (\(was))")
        }

        // Horizontal.
        let sideways = scroll(lines: -1, fixed: -0.1, points: -1, axis: 1, inverted: true)
        check(through(classic, sideways) == "0 0.00 0 | 1 0.10 1", "classic: a sideways notch (axis 2) is turned round like a vertical one")
        check(through(steady, scroll(lines: -fast.lines, fixed: -fast.fixed, points: -fast.points, axis: 1)) == "0 0.00 0 | -3 -3.00 -30",
              "steady: a fast sideways notch scrolls 3 lines")
        // ⇧ + wheel may reach the tap on axis 1 with ⇧ held (AppKit turns it sideways, measured) or already on axis 2.
        let shiftUp = scroll(lines: -1, fixed: -0.1, points: -1, flags: .maskShift, inverted: true)
        let shiftSide = scroll(lines: -1, fixed: -0.1, points: -1, axis: 1, flags: .maskShift, inverted: true)
        let both = handler(classic: true, steady: true)
        let a = both.handle(.scrollWheel, shiftUp).flatMap { NSEvent(cgEvent: $0) }
        let b = both.handle(.scrollWheel, shiftSide).flatMap { NSEvent(cgEvent: $0) }
        check(a?.scrollingDeltaX == 3 && a?.scrollingDeltaY == 0 && b?.scrollingDeltaX == 3,
              "⇧ + wheel scrolls sideways by the same 3 lines, turned the same way, whichever axis it comes on (\(a.map { "\($0.scrollingDeltaX)" } ?? "none"), \(b.map { "\($0.scrollingDeltaX)" } ?? "none"))")
        let diagonal = scroll(lines: 4, fixed: 4.2, points: 42, inverted: true)
        diagonal.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -2)
        diagonal.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -2.2)
        diagonal.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -22)
        check(through(both, diagonal) == "-3 -3.00 -30 | 3 3.00 30", "both switches, a tilt-wheel notch on both axes: each one notch, turned round")

        // Both together.
        check(through(both, scroll(lines: fast.lines, fixed: fast.fixed, points: fast.points, inverted: true)) == back
              && through(both, scroll(lines: slow.lines, fixed: slow.fixed, points: slow.points, inverted: true)) == back,
              "classic and steady: a slow and a fast notch both scroll 3 lines, turned round")
        check(through(handler(classic: true, steady: true, natural: false), scroll(lines: -fast.lines, fixed: -fast.fixed, points: -fast.points)) == back,
              "and with Natural scrolling off, 3 lines the way they came")
    }

    // MARK: ⌘ + wheel

    static func zoom(_ check: Check) {
        let zoomIn = ZoomItem(title: "Zoom In", key: "+"), zoomOut = ZoomItem(title: "Zoom Out", key: "-")
        var answer = ZoomLookup.found(ZoomMenu(zoomIn: zoomIn, zoomOut: zoomOut))
        var front = "com.google.Chrome"
        var pressed: [String] = []
        var looked = 0
        var time = 100.0
        var natural = false
        let handler = WheelStyleHandler(zoom: WheelZoom(lookup: { _ in looked += 1; return answer },
                                                        press: { item, pid in pressed.append("\(item.title) in \(pid)") }))
        handler.zoomOn = true
        handler.natural = { natural }
        handler.zoom.front = { (front, 4242) }
        handler.zoom.now = { time }
        func turn(_ away: Bool, flags: CGEventFlags = .maskCommand, inverted: Bool = false, step: Double = 0.2) -> String {
            time += step
            // With Natural scrolling on, macOS sends a turn away from you as a scroll down.
            let up = away != (natural || inverted)
            let event = scroll(lines: up ? 1 : -1, fixed: up ? 0.1 : -0.1, points: up ? 1 : -1, flags: flags, inverted: inverted)
            return handler.handle(.scrollWheel, event) == nil ? "swallowed" : "passed"
        }
        func presses(_ body: () -> Void) -> [String] {
            pressed = []
            body()
            return pressed
        }

        check(presses { check(turn(true) == "swallowed", "⌘ + a notch away from you is swallowed") } == ["Zoom In in 4242"],
              "and presses the app's Zoom In, in its own process")
        check(presses { _ = turn(false) } == ["Zoom Out in 4242"], "a notch towards you presses Zoom Out")
        natural = true
        check(presses { _ = turn(true); _ = turn(false) } == ["Zoom In in 4242", "Zoom Out in 4242"],
              "Natural scrolling on (the deltas come the other way round): away still zooms in, towards you out")
        natural = false
        check(presses { _ = turn(true, inverted: true) } == ["Zoom In in 4242"], "an event marked as turned round, with the setting read off: away still zooms in")

        let quick = presses {
            _ = turn(true, step: 0.2)
            check(turn(true, step: 0.05) == "swallowed", "a notch 50 ms after a step is swallowed")
            _ = turn(true, step: 0.04)
            _ = turn(true, step: 0.03)
        }
        check(quick.count == 2, "throttle: four notches at 200, 250, 290 and 320 ms give \(quick.count) steps, at 200 and 290 ms: \(quick.joined(separator: ", "))")
        time += 1
        let spin = presses { for _ in 0..<20 { _ = turn(true, step: 0.025) } }
        check(spin.count == 7, "a fast spin, 20 notches 25 ms apart, gives \(spin.count) steps, one each 75 ms")
        // The probe's own ⌘ notches from an MX Master 3 through Logi Options+: 1 line, 13 points, continuous.
        time += 1
        var real: [String] = []
        let steps = presses {
            for gap in [0, 0.041, 0.150, 0.135, 0.082, 0.142] {
                time += gap
                let event = scroll(lines: 1, fixed: 1, points: 13, continuous: true, flags: .maskCommand)
                real.append(handler.handle(.scrollWheel, event) == nil ? "swallowed" : "passed")
            }
        }
        check(steps.count == 5 && real.allSatisfy { $0 == "swallowed" },
              "the probe's real ⌘ notches, 41, 150, 135, 82 and 142 ms apart, give \(steps.count) steps: only the one 41 ms after a step is held")

        // A smooth-scrolling driver: many small pixel events, one step per notch's worth (30 points).
        time += 1
        var kept = 0
        let smooth = presses {
            for _ in 0..<10 {
                time += 0.016
                if handler.handle(.scrollWheel, scroll(fixed: 0.4, points: 4, continuous: true, flags: .maskCommand)) != nil { kept += 1 }
            }
        }
        check(smooth.count == 1 && kept == 0, "a smooth wheel's ten 4-point events in 160 ms (40 points) are all swallowed and give \(smooth.count) step, not ten")

        time += 1
        let notch = scroll(lines: 1, fixed: 0.1, points: 1, flags: .maskCommand)
        let stepped = handler.zoom.scroll(notch, natural: false)
        time += 0.05
        let next = handler.zoom.scroll(notch, natural: false)
        check(stepped == .zoomed(in: true) && next == .held, "the zoom's own outcome: a step, then held (\(stepped), \(next))")

        // Passed through untouched.
        func passes(_ name: String, _ make: () -> CGEvent) {
            time += 1
            let event = make()
            let was = describe(event)
            let out = presses { check(describe(handler.handle(.scrollWheel, event)) == was, "\(name): goes by untouched") }
            check(out.isEmpty, "\(name): nothing pressed")
        }
        answer = .none
        passes("an app with no Zoom In and Zoom Out in its menus") { scroll(lines: 1, fixed: 0.1, points: 1, flags: .maskCommand) }
        answer = .reading
        passes("an app whose menus are still being read") { scroll(lines: 1, fixed: 0.1, points: 1, flags: .maskCommand) }
        answer = .found(ZoomMenu(zoomIn: zoomIn, zoomOut: zoomOut))
        for id in ["com.figma.Desktop", "com.adobe.Photoshop", "com.microsoft.rdc.macos", "com.vmware.fusion", "com.utmapp.UTM"] {
            front = id
            looked = 0
            passes(id) { scroll(lines: 1, fixed: 0.1, points: 1, flags: .maskCommand) }
            check(looked == 0, "\(id): its menus aren't even looked at")
        }
        front = "com.google.Chrome"
        for (name, flags) in [("⌘⇧", CGEventFlags([.maskCommand, .maskShift])), ("⌘⌥", [.maskCommand, .maskAlternate]),
                              ("⌘⌃", [.maskCommand, .maskControl]), ("⌃ alone", .maskControl), ("no modifier", [])] as [(String, CGEventFlags)] {
            passes("\(name) + wheel") { scroll(lines: 1, fixed: 0.1, points: 1, flags: flags) }
        }
        passes("⌘ + a trackpad swipe") { scroll(lines: 1, fixed: 0.4, points: 4, phase: 2, continuous: true, flags: .maskCommand) }
        passes("⌘ + momentum") { scroll(lines: 1, fixed: 0.4, points: 4, momentum: 2, continuous: true, flags: .maskCommand) }
        passes("⌘ + WheelDragScroll's own scroll") { scroll(lines: 3, fixed: 3, points: 30, continuous: true, marked: true, flags: .maskCommand) }
        passes("⌘ + a sideways-only notch") { scroll(lines: 1, fixed: 0.1, points: 1, axis: 1, flags: .maskCommand) }
        handler.zoomOn = false
        passes("the zoom switch off, ⌘ + wheel") { scroll(lines: 1, fixed: 0.1, points: 1, flags: .maskCommand) }
        handler.zoomOn = true
        handler.classic = true
        handler.steady = true
        answer = .none
        natural = true
        passes("classic and steady on, ⌘ + wheel in an app that can't zoom (not restyled)") { scroll(lines: 9, fixed: 9.4, points: 94, flags: .maskCommand, inverted: true) }
        handler.classic = false
        handler.steady = false
        natural = false
        answer = .found(ZoomMenu(zoomIn: zoomIn, zoomOut: zoomOut))

        // The ⌘ tap that opens Start (CommandTap) compares the system's counters and ScrollSeen at ⌘'s press and release.
        // The system's scroll counter is held still here, as it is for Logi Options+'s wheel (measured).
        func counters() -> CommandTap.Counters { CommandTap.Counters(keyDowns: 10, clicks: 20, scrolls: 30, seen: ScrollSeen.count) }
        func tapAround(_ body: () -> Void) -> Bool {
            var tap = CommandTap()
            _ = tap.feed(.flagsChanged, flags: Modifiers.command, counters: counters)
            body()
            return tap.feed(.flagsChanged, flags: 0, counters: counters)
        }
        time += 1
        var swallowed = false
        let zoomTap = tapAround {
            swallowed = handler.handle(.scrollWheel, scroll(lines: 1, fixed: 1, points: 13, continuous: true, flags: .maskCommand)) == nil
        }
        check(swallowed && !zoomTap, "⌘ down, a ⌘ + wheel zoom (swallowed, the system's count unchanged), ⌘ up: no ⌘ tap, so Start doesn't open")
        handler.zoomOn = false
        handler.classic = true
        let offTap = tapAround { _ = handler.handle(.scrollWheel, scroll(lines: 1, fixed: 1, points: 13, continuous: true, flags: .maskCommand)) }
        check(!offTap, "the zoom off, ⌘ + wheel goes by, and still no ⌘ tap")
        handler.zoomOn = true
        handler.classic = false
        check(tapAround {}, "while ⌘ down and up with nothing in between is a tap")
        let before = ScrollSeen.count
        _ = handler.handle(.scrollWheel, scroll(lines: 1, fixed: 1, points: 13, continuous: true))
        let plain = ScrollSeen.count
        _ = handler.handle(.scrollWheel, scroll(lines: 1, fixed: 0.4, points: 4, phase: 2, continuous: true, flags: .maskShift))
        check(plain == before && ScrollSeen.count == before &+ 1,
              "only a scroll with a modifier held is counted: none without, one for ⇧ + a trackpad swipe")
    }

    // MARK: Finding the zoom in an app's menus

    static func menus(_ check: Check) {
        func entry(_ title: String, _ key: String?, _ modifiers: Int = 0, menu: Int = 1) -> ZoomMenus.Entry {
            ZoomMenus.Entry(item: ZoomItem(title: title, key: key, modifiers: modifiers), menu: menu)
        }
        func found(_ entries: [ZoomMenus.Entry]) -> String {
            guard let menu = ZoomMenus.pick(entries) else { return "none" }
            return "\(menu.zoomIn.title) \(menu.zoomIn.shortcut), \(menu.zoomOut.title) \(menu.zoomOut.shortcut)"
        }
        // Google Chrome's View menu, as read on this Mac (--selftest wheelstyle menus).
        let chrome = [entry("Always Show Bookmarks Bar", "B", 1, menu: 4), entry("Stop", ".", menu: 4), entry("Actual Size", "0", menu: 4),
                      entry("Zoom In", "+", menu: 4), entry("Zoom Out", "-", menu: 4), entry("Enter Full Screen", "F", 4, menu: 4)]
        check(found(chrome) == "Zoom In ⌘+, Zoom Out ⌘-", "Chrome's View menu: \(found(chrome))")
        // Electron's own View menu (Claude): Zoom In is CommandOrControl+Plus.
        let electron = [entry("Reload", "R", menu: 3), entry("Actual Size", "0", menu: 3), entry("Zoom In", "+", menu: 3),
                        entry("Zoom Out", "-", menu: 3), entry("Toggle Full Screen", "F", 4, menu: 3)]
        check(found(electron) == "Zoom In ⌘+, Zoom Out ⌘-", "an Electron app's View menu (Claude): \(found(electron))")
        let terminal = [entry("Show Fonts", "T", menu: 5), entry("Bigger", "+", menu: 5), entry("Smaller", "-", menu: 5)]
        check(found(terminal) == "Bigger ⌘+, Smaller ⌘-", "Terminal's and Messages' Bigger and Smaller, their only zoom: \(found(terminal))")
        // TextEdit and Notes, as read: Bigger changes the selected text, Zoom In the view.
        let textEdit = [entry("Bigger", "+", menu: 17), entry("Smaller", "-", menu: 17), entry("Zoom In", ".", 1, menu: 25),
                        entry("Zoom Out", ",", 1, menu: 25)]
        check(found(textEdit) == "Zoom In ⇧⌘., Zoom Out ⇧⌘,", "TextEdit's View Zoom In wins over Bigger, which would change the text itself: \(found(textEdit))")
        let safari = [entry("Zoom In", "+", menu: 4), entry("Zoom Out", "-", menu: 4),
                      entry("Make Text Bigger", "+", 2, menu: 4), entry("Make Text Smaller", "-", 2, menu: 4)]
        check(found(safari) == "Zoom In ⌘+, Zoom Out ⌘-", "Zoom In with ⌘+ wins over Make Text Bigger with ⌥⌘+: \(found(safari))")
        let word = [entry("Superscript", "=", 1, menu: 6), entry("Subscript", "=", menu: 6), entry("Bold", "B", menu: 6)]
        check(found(word) == "none", "Word's Subscript ⌘= and Superscript ⌘⇧= are no zoom: \(found(word))")
        let hebrew = [entry("הגדלה", "=", menu: 4), entry("הקטנה", "-", menu: 4)]
        check(found(hebrew) == "הגדלה ⌘=, הקטנה ⌘-", "titles in another language, ⌘= and ⌘- side by side in one menu: \(found(hebrew))")
        let apart = [entry("Something", "=", menu: 4), entry("Other", "-", menu: 7)]
        check(found(apart) == "none", "but the same shortcuts in different menus, with other titles, are not a pair")
        let noShortcut = [entry("Zoom In", nil, menu: 2), entry("Zoom Out", nil, menu: 2)]
        check(found(noShortcut) == "Zoom In none, Zoom Out none", "titles alone, no shortcuts: found, to be pressed through Accessibility")
        check(found([entry("Zoom In", "+")]) == "none", "a Zoom In with no Zoom Out is not enough")
    }

    // MARK: The Mouse page

    static func rows(_ check: Check) {
        let delegate = AppDelegate(lockWarning: LockWarning(timeoutOverride: nil))
        let facts = SettingsFacts()
        let titles = [WheelStyle.classicTitle, WheelStyle.steadyTitle, WheelStyle.zoomTitle]
        func states(_ rows: [SettingsRow]) -> [Bool?] {
            rows.map { if case .toggle(let on) = $0.control { on } else { nil } }
        }
        let some = delegate.wheelStyleRows(facts, on: WheelStyle.Switches(classic: true, steady: false, zoom: true), natural: true)
        check(some.map(\.title) == titles, "three switches: \(some.map(\.title).joined(separator: " | "))")
        check(states(some) == [true, false, true], "each shows its own state")
        check(states(delegate.wheelStyleRows(facts, on: .init(classic: false, steady: true, zoom: false), natural: true)) == [false, true, false],
              "the other way round too")
        check(some.map(\.note) == [WheelStyle.classicNote, WheelStyle.steadyNote, WheelStyle.zoomNote],
              "notes: \(some.compactMap(\.note).joined(separator: " | "))")
        let unnatural = delegate.wheelStyleRows(facts, on: .init(classic: true, steady: false, zoom: true), natural: false)
        check(unnatural.first?.note == WheelStyle.alreadyClassicNote, "Natural scrolling off: \(unnatural.first?.note ?? "no note")")
        check(some.allSatisfy { $0.target === delegate && $0.action.map(delegate.responds(to:)) == true }, "each switch reaches its toggle")
        var noAccess = facts
        noAccess.permissions = PermissionCheck(accessibility: false, screenRecording: true, finder: .on, finderUsed: true)
        check(delegate.wheelStyleRows(noAccess, on: .init(classic: false, steady: false, zoom: false), natural: true).allSatisfy(\.closesPanel)
              && !some.contains(where: \.closesPanel), "without Accessibility each closes the panel, for macOS's question; with it, none does")

        let stored = delegate.wheelStyleRows(facts)
        check(stored.map(\.title) == titles && states(stored) == [Settings.wheelClassicEnabled, Settings.wheelSteadyEnabled, Settings.wheelZoomEnabled],
              "the page's own rows show the stored switches: \(states(stored).map { $0 == true ? "on" : "off" }.joined(separator: ", "))")
        let defaults = [("wheelClassicEnabled", Settings.wheelClassicEnabled, false), ("wheelSteadyEnabled", Settings.wheelSteadyEnabled, false),
                        ("wheelZoomEnabled", Settings.wheelZoomEnabled, true)]
        for (key, value, fallback) in defaults where UserDefaults.standard.object(forKey: key) == nil {
            check(value == fallback, "\(key) never set: \(fallback ? "on" : "off")")
        }

        var one = facts
        one.mice = ["Test Mouse"]
        let mouse = delegate.settingsPages(one).first { $0.id == "mouse" }?.rows.map(\.title) ?? []
        let note = mouse.firstIndex { $0.hasPrefix("System Settings stops pointer speed") }
        let hold = mouse.firstIndex { $0.hasPrefix("Hold the Wheel and Move to Scroll") }
        let mine = titles.compactMap { mouse.firstIndex(of: $0) }
        check(mine.count == 3 && note.map { $0 < mine[0] } == true && hold.map { mine[2] < $0 } == true && mine == mine.sorted(),
              "on the Mouse page, in order, after the pointer-speed note and before the hold-the-wheel switch")
    }
}
