import AppKit

// --selftest resolution-live: the real thing on the main screen, so it changes the screen you're using for about 20
// seconds. It switches to another usable mode, the nearest one (the same size at another refresh rate where there is
// one), as the popup would; checks macOS reports it and the question is on every screen and counts down; gives no
// answer; and checks the countdown puts the previous mode back exactly. Never saves a mode, and puts the original back
// itself on every path. It shows a window over everything, so it waits for an idle, ordinary desktop.
extension ScreenResolution {
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

        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func note(_ text: String) { lines.append("note: " + text) }
        func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Int? {
            let start = Date()
            while !condition() {
                guard -start.timeIntervalSinceNow < seconds else { return nil }
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            return Int(-start.timeIntervalSinceNow * 1000)
        }
        NSApp.setActivationPolicy(.accessory)
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let stored = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?

        let display = CGMainDisplayID()
        let quartz = ScreenResolutionQuartz()
        let name = NSScreen.screens.first { $0.displayID == display }?.localizedName ?? "the main screen"
        guard let original = quartz.current(of: display) else { return "FAIL \(name)'s mode can't be read\nFAIL: 1 failed" }
        let modes = quartz.modes(of: display)
        guard let target = nearest(to: original, in: modes) else { return "skipped: \(name) offers no other usable mode" }
        note("\(name): from \(title(of: original, among: modes)) to \(title(of: target, among: modes)), left to go back by itself")

        let recording = RecordingScreens(quartz)
        let windows = ScreenResolutionWindows()
        let feature = ScreenResolution(switcher: recording, presenter: windows)
        feature.start()
        var outcomes: [ScreenResolutionChange.Outcome] = []
        let ended = feature.change.onEnd
        feature.change.onEnd = { pending, outcome in
            outcomes.append(outcome)
            ended(pending, outcome)
        }
        var screenChanges = 0
        let token = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            screenChanges += 1
        }

        let began = Date()
        feature.choose(Pick(display: display, name: name, mode: target))
        let switched = waitFor(5) { CGDisplayCopyDisplayMode(display).map(Mode.init) == target }
        check(switched != nil, "macOS reports the new mode" + (switched.map { " after \($0) ms" } ?? "; it reports \(describe(display, modes))"))
        let shown = waitFor(3) { windows.panels.count == NSScreen.screens.count && windows.panels.values.allSatisfy(\.isVisible) }
        check(shown != nil, "the question is on every screen (\(windows.panels.count) of \(NSScreen.screens.count))")
        check(windows.panels[display]?.isKeyWindow == true, "the changed screen's question takes the keyboard")
        let first = windows.panels[display]?.question.body.stringValue ?? ""
        _ = waitFor(3.2) { false }
        let later = windows.panels[display]?.question.body.stringValue ?? ""
        let left = { (text: String) in Int(text.components(separatedBy: " in ").last?.components(separatedBy: " ").first ?? "") }
        check(left(first).map { $0 >= 14 } == true && left(later).map { $0 >= 10 && $0 <= 13 } == true,
              "it counts down: \(left(first).map(String.init) ?? "?") seconds, then \(left(later).map(String.init) ?? "?") about 3 s later")

        let answered = waitFor(ScreenResolutionChange.countdown + 5) { !outcomes.isEmpty }
        let after = -began.timeIntervalSinceNow
        check(answered != nil && outcomes == [.timedOut] && after >= ScreenResolutionChange.countdown && after < ScreenResolutionChange.countdown + 2,
              "with no answer it went back by itself after \(String(format: "%.1f", after)) s (\(outcomes.map { "\($0)" }.joined(separator: ", ")))")
        let back = waitFor(5) { CGDisplayCopyDisplayMode(display).map(Mode.init) == original }
        check(back != nil, "the previous mode is back exactly: \(describe(display, modes))")
        check(windows.panels.isEmpty && !NSApp.windows.contains { $0 is ScreenResolutionPanel && $0.isVisible }, "the question is gone")
        check(!recording.asked.isEmpty && recording.asked.allSatisfy { !$0.permanently },
              "nothing was saved: every change was for this session only (\(recording.asked.map { "mode \($0.mode.id)" }.joined(separator: ", ")))")
        note("screen-change notifications seen: \(screenChanges)")
        NotificationCenter.default.removeObserver(token)

        // Every path ends here, so whatever happened above, the screen is left as it was found.
        if feature.change.pending != nil { feature.change.goBack() }
        if CGDisplayCopyDisplayMode(display).map(Mode.init) != original {
            note("putting \(title(of: original, among: modes)) back by hand: " + (quartz.apply(original, to: display, permanently: false) ? "done" : "macOS refused"))
        }
        check(CGDisplayCopyDisplayMode(display).map(Mode.init) == original, "\(name) ends in the mode it started in")
        let now = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?
        check(stored?.isEqual(now) ?? (now == nil), "no stored setting changed")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    // The usable mode least unlike the one in use: the same sizes at another refresh rate, else the same look at other
    // pixels, else the nearest number of pixels.
    static func nearest(to current: Mode, in modes: [Mode]) -> Mode? {
        let others = menu(modes, current: current).joined().map(\.mode).filter { $0 != current && $0.usable }
        let area = current.pixelWidth * current.pixelHeight
        return others.min { a, b in
            func rank(_ m: Mode) -> (Int, Int, Int, Int) {
                let sameLook = m.width == current.width && m.height == current.height
                let samePixels = m.pixelWidth == current.pixelWidth && m.pixelHeight == current.pixelHeight
                return (sameLook && samePixels ? 0 : 1, sameLook ? 0 : 1, abs(m.pixelWidth * m.pixelHeight - area), -Mode.rate(m.refresh))
            }
            return rank(a) < rank(b)
        }
    }

    private static func describe(_ display: CGDirectDisplayID, _ modes: [Mode]) -> String {
        guard let now = CGDisplayCopyDisplayMode(display).map(Mode.init) else { return "nothing" }
        return "\(title(of: now, among: modes)) (mode \(now.id))"
    }

    // Quartz, with every change asked of it written down.
    private final class RecordingScreens: ScreenResolutionSwitcher {
        let real: ScreenResolutionSwitcher
        private(set) var asked: [(mode: Mode, permanently: Bool)] = []

        init(_ real: ScreenResolutionSwitcher) { self.real = real }

        func displays() -> [CGDirectDisplayID] { real.displays() }
        func key(of display: CGDirectDisplayID) -> String { real.key(of: display) }
        func modes(of display: CGDirectDisplayID) -> [Mode] { real.modes(of: display) }
        func current(of display: CGDirectDisplayID) -> Mode? { real.current(of: display) }

        func apply(_ mode: Mode, to display: CGDirectDisplayID, permanently: Bool) -> Bool {
            asked.append((mode, permanently))
            return real.apply(mode, to: display, permanently: permanently)
        }
    }
}
