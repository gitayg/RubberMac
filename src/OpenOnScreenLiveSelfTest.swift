import AppKit

// --selftest openonscreen-live [folder]: the real observers and moves, on windows of a scratch app the test builds into
// the folder (or a temporary one) and opens files in. On this Mac's own screens first: with one, nothing is observed
// and nothing moves. Then on two made-up screens, the left and right halves of the main one, with the pointer taken to
// be on the right: a file opened right after switching to the app, and one whose window beat the switch, go right; a
// panel, a window already there, an old one and one the app opens later stay; a rule moves any new window to its
// screen, and waits while its screen isn't connected. Then what it costs in CPU. Brings the scratch app forward, so it
// waits for an idle, ordinary desktop; moves no window of yours and changes no setting.
enum OpenOnScreenLive {
    private typealias Plan = OpenOnScreenPlan
    private typealias Openings = OpenOnScreenOpenings

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

        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func note(_ text: String) { lines.append("note \(text)") }
        func pump(_ seconds: TimeInterval) {
            let until = Date(timeIntervalSinceNow: seconds)
            while let event = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        }
        // Milliseconds until the condition held, nil if it didn't in time.
        func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Int? {
            let start = Date()
            while -start.timeIntervalSinceNow < seconds {
                if condition() { return Int(-start.timeIntervalSinceNow * 1000) }
                pump(0.005)
            }
            return condition() ? Int(seconds * 1000) : nil
        }
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
            return (seconds(usage.ru_utime) + seconds(usage.ru_stime)) * 1000
        }
        func show(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))" }

        let fm = FileManager.default
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        // Without focusHistory: a running RubberMAC rewrites its Alt-Tab order whenever a window gets focus.
        func settings() -> NSDictionary {
            var all = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
            all["focusHistory"] = nil
            return all as NSDictionary
        }
        let stored = settings()
        let me = getpid()
        let previous = NSWorkspace.shared.frontmostApplication
        let args = CommandLine.arguments
        let folder = args.firstIndex(of: "openonscreen-live").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
            ?? fm.temporaryDirectory.appendingPathComponent("openonscreen-scratch")
        NSRunningApplication.runningApplications(withBundleIdentifier: OpenOnScreenScratch.bundleID).forEach { $0.forceTerminate() }
        let built = OpenOnScreenScratch.build(in: folder)
        guard let scratchURL = built.app else { return "FAIL couldn't build the scratch app: \(built.problem ?? "")\nFAIL: 1 failed" }
        note("scratch app: \(scratchURL.path)")
        let docs = fm.temporaryDirectory.appendingPathComponent("openonscreen-live-\(me)")
        try? fm.createDirectory(at: docs, withIntermediateDirectories: true)

        var count = 0
        func doc(_ kind: String, _ frame: CGRect) -> URL {
            count += 1
            let url = docs.appendingPathComponent("\(count).txt")
            try? "\(kind) \(frame.minX) \(frame.minY) \(frame.width) \(frame.height)".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        var scratch: NSRunningApplication?
        // As Finder does on a double-click, without bringing the app forward: the test does that itself where it wants.
        func open(_ urls: [URL]) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.arguments = ["--parent", "\(me)", "-ApplePersistenceIgnoreState", "YES"]
            NSWorkspace.shared.open(urls, withApplicationAt: scratchURL, configuration: config) { app, _ in
                DispatchQueue.main.async { scratch = scratch ?? app }
            }
        }
        var known: [CGWindowID: AXUIElement] = [:]
        // The scratch app's windows not seen before, one of each width (each file asks for its own), with where it put them.
        func shown(_ widths: [CGFloat]) -> [(id: CGWindowID, frame: CGRect)]? {
            var fresh: [CGFloat: (id: CGWindowID, frame: CGRect)] = [:]
            _ = waitFor(8) {
                guard let pid = scratch?.processIdentifier else { return false }
                for window in AX.windows(of: pid) {
                    guard let id = AX.windowID(of: window), known[id] == nil, let frame = AX.frame(of: window),
                          let width = widths.first(where: { abs($0 - frame.width) <= 2 }), fresh[width] == nil else { continue }
                    known[id] = window
                    fresh[width] = (id, frame)
                }
                return fresh.count == widths.count
            }
            return fresh.count == widths.count ? widths.compactMap { fresh[$0] } : nil
        }
        func frame(_ id: CGWindowID) -> CGRect? { known[id].flatMap(AX.frame(of:)) }
        // A tab not chosen isn't among Accessibility's windows, nor on screen; the window server still has its frame.
        func cgFrame(_ id: CGWindowID) -> CGRect? {
            var number = UnsafeRawPointer(bitPattern: UInt(id))
            guard let array = CFArrayCreate(nil, &number, 1, nil),
                  let info = (CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]])?.first else { return nil }
            return (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        }
        func bringForward(_ pid: pid_t) -> Bool {
            AXUIElementSetAttributeValue(AX.app(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            return waitFor(3) { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid } != nil
        }

        // The test stands in for the user: every launch and switch is taken as just made, and only the scratch app counts.
        func system(_ screens: [Plan.Screen], pointer: @escaping () -> CGPoint) -> OpenOnScreenMover.System {
            var system = OpenOnScreenMover.System()
            system.screens = { screens }
            system.pointer = pointer
            system.lastInput = { Date() }
            system.accepts = { $0.bundleIdentifier == OpenOnScreenScratch.bundleID }
            return system
        }
        var decisions: [(id: CGWindowID, outcome: Plan.Outcome)] = []
        func isMove(_ outcome: Plan.Outcome) -> Bool { if case .move = outcome { true } else { false } }
        func decided(_ id: CGWindowID) -> [Plan.Outcome] { decisions.filter { $0.id == id }.map(\.outcome) }
        func said(_ id: CGWindowID) -> String {
            decided(id).map { outcome in
                switch outcome {
                case .move(let to, _): return "move to \(to)"
                case .wait: return "wait"
                case .leave(let reason): return reason.rawValue
                }
            }.joined(separator: ", ")
        }

        let real = Plan.connectedScreens()
        guard let main = real.first else { return "FAIL no screen\nFAIL: 1 failed" }
        let middle = main.frame.midX.rounded()
        func half(_ r: CGRect, left: Bool) -> CGRect {
            left ? CGRect(x: r.minX, y: r.minY, width: middle - r.minX, height: r.height)
                : CGRect(x: middle, y: r.minY, width: r.maxX - middle, height: r.height)
        }
        let left = Plan.Screen(key: "test:left", name: "Left Half", frame: half(main.frame, left: true), visible: half(main.visible, left: true))
        let right = Plan.Screen(key: "test:right", name: "Right Half", frame: half(main.frame, left: false), visible: half(main.visible, left: false))
        let onRight = CGPoint(x: right.visible.midX, y: right.visible.midY)
        let one = OpenOnScreenMover(system: system(real, pointer: Plan.pointer))
        let two = OpenOnScreenMover(system: system([left, right], pointer: { onRight }))
        // What the observer had received by each decision: notifications by name, and windows found by listing.
        var received: [String: Int] = [:]
        for mover in [one, two] {
            mover.onDecision = { app, id, outcome in
                decisions.append((id, outcome))
                received.merge(mover.observers[app.processIdentifier]?.received ?? [:]) { max($0, $1) }
            }
        }
        func notices() -> String { received.isEmpty ? "none" : received.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") }

        func finish() -> String {
            one.stop()
            two.stop()
            if let scratch, !scratch.isTerminated {
                scratch.terminate()
                if waitFor(3, { scratch.isTerminated }) == nil { scratch.forceTerminate() }
            }
            try? fm.removeItem(at: docs)
            if let previous, previous.processIdentifier != me {
                AXUIElementSetAttributeValue(AX.app(previous.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }
            let after = settings()
            let changed = Set((stored.allKeys + after.allKeys).compactMap { $0 as? String }).filter { stored[$0] as? NSObject != after[$0] as? NSObject }
            check(changed.isEmpty, "no stored setting changed" + (changed.isEmpty ? "" : ": " + changed.sorted().joined(separator: ", ")))
            return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
        }

        // 1. This Mac's own screens, the scratch app launched by the "user".
        one.configure(switchOn: true, rules: [])
        let firstAsked = CGRect(x: left.visible.minX + 40, y: left.visible.minY + 60, width: 420, height: 300)
        open([doc("window", firstAsked)])
        guard let first = shown([firstAsked.width])?.first, let app = scratch else {
            check(false, "the scratch app launched and showed its first window")
            return finish()
        }
        var observedAtAll = false
        _ = waitFor(1.5) { observedAtAll = observedAtAll || !one.observers.isEmpty; return false }
        if real.count == 1 {
            check(one.isRunning && !observedAtAll && decided(first.id).isEmpty && frame(first.id) == first.frame,
                  "one screen (\(main.name)): with the switch on and the app just launched, it isn't observed and its window stays at \(show(first.frame))")
        } else {
            note("\(real.count) screens connected, so the one-screen check doesn't apply")
        }
        one.stop()

        // 2. Two made-up screens. A file opened right after the user switched to the app, as with a Finder double-click.
        two.configure(switchOn: true, rules: [])
        let newest = Openings.newestWindow()
        decisions = []
        check(bringForward(me) && bringForward(app.processIdentifier), "the test, then the scratch app, came forward (a switch to the app)")
        let asked = (window: CGRect(x: left.visible.minX + 30, y: left.visible.minY + 40, width: 400, height: 280),
                     panel: CGRect(x: left.visible.minX + 60, y: left.visible.maxY - 240, width: 240, height: 180),
                     wide: CGRect(x: left.visible.minX + 10, y: left.visible.minY + 120, width: right.visible.width + 100, height: 260),
                     there: CGRect(x: right.visible.minX + 50, y: right.visible.minY + 300, width: 380, height: 260))
        let opened = Date()
        open([doc("window", asked.window), doc("panel", asked.panel), doc("window", asked.wide), doc("window", asked.there),
              doc("sheet", CGRect(x: 0, y: 0, width: 300, height: 120))])
        guard let batch = shown([asked.window.width, asked.panel.width, asked.wide.width, asked.there.width]) else {
            check(false, "the scratch app showed the four windows; decided: " + decisions.map { "\($0.id) \($0.outcome)" }.joined(separator: ", "))
            return finish()
        }
        let shownAfter = Int(-opened.timeIntervalSinceNow * 1000)
        let (window, panel, wide, there) = (batch[0], batch[1], batch[2], batch[3])
        check(batch.allSatisfy { $0.id > newest }, "window numbers grow: each new one is above the newest before (\(newest)), as the switch's 'since' needs")
        pump(OpenOnScreenMover.settle + OpenOnScreenMover.recheck + 0.4)
        let wanted = Plan.fit(window.frame, from: left.visible, to: right.visible)
        check(frame(window.id) == wanted && wanted.size == window.frame.size,
              "a window opened on the left half moves to the pointer's right half, same size and place: \(show(window.frame)) → \(frame(window.id).map(show) ?? "gone") (shown \(shownAfter) ms after the open)")
        let narrowed = Plan.fit(wide.frame, from: left.visible, to: right.visible)
        check(frame(wide.id) == narrowed && narrowed.width == right.visible.width,
              "one wider than the right half is narrowed to fit it: \(show(wide.frame)) → \(frame(wide.id).map(show) ?? "gone")")
        check(frame(panel.id) == panel.frame && decided(panel.id) == [.leave(.notOrdinary)], "a panel stays (\(said(panel.id)))")
        check(frame(there.id) == there.frame && decided(there.id) == [.leave(.alreadyThere)], "a window opened on the right half stays (\(said(there.id)))")
        check(frame(first.id) == first.frame && decided(first.id).isEmpty, "the window the app already had stays, though the app came forward")
        let others = decisions.filter { ![window.id, panel.id, wide.id, there.id].contains($0.id) }
        check(others.allSatisfy { $0.outcome == .leave(.notOrdinary) },
              "the sheet: " + (others.isEmpty ? "Accessibility didn't hand it on" : "left alone (" + others.map { said($0.id) }.joined(separator: ", ") + ")"))
        note("the scratch app's observer, by its last decision: " + notices())
        received = [:]

        // 3. The window beats the switch: made before the app comes forward, found by its number when it does.
        check(waitFor(Openings.afterActivation + 1) { two.observers.isEmpty } != nil, "once the watch is over the app isn't observed any more")
        _ = bringForward(me)
        decisions = []
        open([doc("window", CGRect(x: left.visible.minX + 50, y: left.visible.minY + 90, width: 410, height: 270))])
        guard let raced = shown([410])?.first else {
            check(false, "the scratch app showed the window")
            return finish()
        }
        check(two.observers.isEmpty && bringForward(app.processIdentifier), "it came, unobserved, and then the app came forward")
        pump(OpenOnScreenMover.settle + OpenOnScreenMover.recheck + 0.4)
        check(frame(raced.id) == Plan.fit(raced.frame, from: left.visible, to: right.visible),
              "that window still moves right: \(show(raced.frame)) → \(frame(raced.id).map(show) ?? "gone") (\(said(raced.id)))")

        // 4. Later, with no switch: a window the app opens on its own.
        check(waitFor(Openings.afterActivation + 1) { two.observers.isEmpty } != nil, "the watch ends again")
        decisions = []
        open([doc("window", CGRect(x: left.visible.minX + 70, y: left.visible.minY + 110, width: 390, height: 250))])
        guard let late = shown([390])?.first else {
            check(false, "the scratch app showed the late window")
            return finish()
        }
        pump(OpenOnScreenMover.settle + OpenOnScreenMover.recheck)
        check(frame(late.id) == late.frame && decided(late.id).isEmpty && two.observers.isEmpty,
              "a window the app opens later on its own: not observed, stays at \(show(late.frame))")

        // 5. Tabs: a new window with a tab of its own moves with it; a tab added to the window the app already had stays.
        _ = bringForward(me)
        check(bringForward(app.processIdentifier), "the app came forward for the tabs")
        decisions = []
        received = [:]
        open([doc("window", CGRect(x: left.visible.minX + 20, y: left.visible.minY + 200, width: 330, height: 210)),
              doc("tablast", .zero), doc("tab", .zero)])
        pump(OpenOnScreenMover.settle + OpenOnScreenMover.recheck + 0.4)
        // Told apart by size: the new window is 330 points wide, the old one 420.
        let scratchWindows = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { info -> (CGWindowID, CGRect)? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value, let at = cgFrame(id) else { return nil }
            return (id, at)
        }
        note("the observer during the tabs: " + notices())
        let pair = scratchWindows.filter { $0.1.width == 330 }
        check(pair.count == 2 && pair.allSatisfy { $0.1 == pair[0].1 && right.frame.contains(CGPoint(x: $0.1.midX, y: $0.1.midY)) }
              && decisions.contains { pair.map(\.0).contains($0.id) && isMove($0.outcome) },
              "a new window and the tab added to it go to the right half together: " + pair.map { "\($0.0) at \(show($0.1))" }.joined(separator: ", ")
              + " (" + pair.map { said($0.0) }.joined(separator: " / ") + ")")
        let oldGroup = scratchWindows.filter { $0.1.width == 420 }
        let oldTab = decisions.first { oldGroup.map(\.0).contains($0.id) && $0.id != first.id }
        check(oldGroup.count == 2 && oldGroup.allSatisfy { $0.1 == first.frame } && oldTab?.outcome == .leave(.tabOfOlderWindow),
              "a tab added to the window the app already had stays there with it: " + oldGroup.map { "\($0.0) at \(show($0.1))" }.joined(separator: ", ")
              + " (\(oldTab.map { said($0.id) } ?? "not decided on"))")

        // 6. A rule for the left half: any new window goes there, the pointer on the right notwithstanding.
        let rule = OpenOnScreenRule(app: OpenOnScreenScratch.bundleID, appName: OpenOnScreenScratch.name, screen: left.key, screenName: left.name)
        check(waitFor(Openings.afterActivation + 1) { two.observers.isEmpty } != nil, "the tabs' watch ends")
        two.configure(switchOn: true, rules: [rule])
        check(two.observers[app.processIdentifier] != nil, "a rule observes its app at once")
        decisions = []
        open([doc("window", CGRect(x: right.visible.minX + 40, y: right.visible.minY + 70, width: 370, height: 240))])
        guard let ruled = shown([370])?.first else {
            check(false, "the scratch app showed the window for the rule")
            return finish()
        }
        pump(OpenOnScreenMover.settle + OpenOnScreenMover.recheck + 0.4)
        check(frame(ruled.id) == Plan.fit(ruled.frame, from: right.visible, to: left.visible),
              "a window it opens on its own on the right half goes to its screen, the left half: \(show(ruled.frame)) → \(frame(ruled.id).map(show) ?? "gone")")
        _ = bringForward(me)
        _ = bringForward(app.processIdentifier)
        pump(Openings.afterActivation + 0.5)
        check(two.observers[app.processIdentifier] != nil, "and the app is still observed after a switch to it, once the switch's few seconds are over")

        // 7. The rule's screen not connected: it waits, and the switch places what the user opens meanwhile.
        two.configure(switchOn: true, rules: [OpenOnScreenRule(app: rule.app, appName: rule.appName, screen: "test:gone", screenName: "Gone Screen")])
        decisions = []
        open([doc("window", CGRect(x: left.visible.minX + 90, y: left.visible.minY + 130, width: 360, height: 230))])
        guard let waiting = shown([360])?.first else {
            check(false, "the scratch app showed the window for the waiting rule")
            return finish()
        }
        pump(OpenOnScreenMover.settle + OpenOnScreenMover.recheck)
        check(frame(waiting.id) == waiting.frame && decided(waiting.id) == [.leave(.ruleWaits)],
              "with its screen not connected, a window the app opens on its own stays (\(said(waiting.id)))")
        _ = bringForward(me)
        check(bringForward(app.processIdentifier), "the app came forward again")
        open([doc("window", CGRect(x: left.visible.minX + 110, y: left.visible.minY + 150, width: 350, height: 220))])
        guard let meanwhile = shown([350])?.first else {
            check(false, "the scratch app showed the window opened meanwhile")
            return finish()
        }
        pump(OpenOnScreenMover.settle + OpenOnScreenMover.recheck + 0.4)
        check(frame(meanwhile.id) == Plan.fit(meanwhile.frame, from: left.visible, to: right.visible),
              "but one opened right after the switch goes to the pointer's right half: \(show(meanwhile.frame)) → \(frame(meanwhile.id).map(show) ?? "gone")")

        // 8. Without a click or a key just before, as when the app comes forward by itself: not the user's opening.
        two.configure(switchOn: false, rules: [])
        check(!two.isRunning && two.observers.isEmpty, "with the switch off and no rules nothing is observed or listened to")
        var unattended = system([left, right], pointer: { onRight })
        unattended.lastInput = OpenOnScreenOpenings.lastInput
        let alone = OpenOnScreenMover(system: unattended)
        alone.onDecision = { decisions.append(($1, $2)) }
        alone.configure(switchOn: true, rules: [])
        decisions = []
        _ = bringForward(me)
        let forward = bringForward(app.processIdentifier)
        let sinceInput = -OpenOnScreenOpenings.lastInput().timeIntervalSinceNow
        open([doc("window", CGRect(x: left.visible.minX + 130, y: left.visible.minY + 170, width: 340, height: 210))])
        guard let unasked = shown([340])?.first else {
            check(false, "the scratch app showed the window with no click or key before")
            return finish()
        }
        pump(OpenOnScreenMover.settle + OpenOnScreenMover.recheck)
        if sinceInput > Openings.inputGap {
            check(forward && frame(unasked.id) == unasked.frame && decided(unasked.id).isEmpty && alone.observers.isEmpty,
                  "the app came forward with no click or key in \(Int(sinceInput)) s: not observed, its new window stays")
        } else {
            note("the Mac was used \(String(format: "%.1f", sinceInput)) s before the switch, so the no-input check doesn't apply")
        }
        alone.stop()

        // 9. A file opened in an app that isn't running: the window comes with the launch.
        two.configure(switchOn: true, rules: [])
        // Its sheet would hold up a polite quit.
        app.forceTerminate()
        check(waitFor(5) { app.isTerminated } != nil, "the scratch app quit")
        scratch = nil
        decisions = []
        received = [:]
        open([doc("window", CGRect(x: left.visible.minX + 150, y: left.visible.minY + 190, width: 320, height: 200))])
        guard let launched = shown([320])?.first, let again = scratch, again.processIdentifier != app.processIdentifier else {
            check(false, "the scratch app launched again and showed its window")
            return finish()
        }
        pump(OpenOnScreenMover.settle + OpenOnScreenMover.recheck + 0.4)
        check(frame(launched.id) == Plan.fit(launched.frame, from: left.visible, to: right.visible),
              "launched with a file, its window goes to the pointer's right half: \(show(launched.frame)) → \(frame(launched.id).map(show) ?? "gone") (\(said(launched.id)); "
              + notices() + ")")
        two.configure(switchOn: false, rules: [])

        // 10. What it costs.
        _ = bringForward(me)
        pump(1)
        var start = cpu()
        pump(10)
        let off = cpu() - start
        two.configure(switchOn: true, rules: [rule])
        start = cpu()
        pump(10)
        let on = cpu() - start
        note(String(format: "CPU over 10 s idle: %.1f ms with it off, %.1f ms on (switch on, the scratch app observed for its rule)", off, on))
        // Twenty real switches between the test and the scratch app, off and on.
        func switches() -> Double {
            let start = cpu()
            for _ in 0..<10 { _ = bringForward(again.processIdentifier); _ = bringForward(me) }
            return cpu() - start
        }
        two.configure(switchOn: false, rules: [])
        let switchesOff = switches()
        two.configure(switchOn: true, rules: [])
        let switchesOn = switches()
        note(String(format: "CPU for 20 app switches: %.1f ms with it off, %.1f ms on (each switch to the scratch app observes it for %.0f s)",
                    switchesOff, switchesOn, Openings.afterActivation))
        let windows = AX.windows(of: again.processIdentifier).count
        start = cpu()
        for _ in 0..<50 {
            two.activated(again)
            two.terminated(again)
        }
        note(String(format: "one switch to an app (newest window, its observer made, its %d windows listed, then dropped): %.2f ms of CPU",
                    windows, (cpu() - start) / 50))
        start = cpu()
        for _ in 0..<200 { _ = Openings.newestWindow() }
        let newestCost = (cpu() - start) / 200
        start = cpu()
        for _ in 0..<200 { _ = Openings.lastInput() }
        note(String(format: "of which the newest window takes %.3f ms and the last click or key %.3f ms", newestCost, (cpu() - start) / 200))
        return finish()
    }
}
