import AppKit

// --selftest dimmer: the Background Windows setting and its rows, which window counts as the one in front, when an
// overlay counts as right below it, which displays show a full-screen Space, and the overlay windows themselves, built
// but never put on the screen. Needs no permission and leaves every stored setting as it was.
// --selftest dimmer helper <folder> is the live test's other app.
extension BackgroundDimmer {
    static func selfTestReport() -> String {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "dimmer"), i + 2 < args.count, args[i + 1] == "helper" { runHelper(folder: args[i + 2]) }

        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        NSApp.setActivationPolicy(.accessory)
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let stored = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?

        settingChecks(check)
        rowChecks(check)
        frontChecks(check)
        placementChecks(check)
        fullScreenChecks(check)
        overlayChecks(check)

        let after = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?
        check(stored?.isEqual(after) ?? (after == nil), "no stored setting changed")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    private typealias Check = (Bool, String) -> Void

    private static func settingChecks(_ check: Check) {
        check(BackgroundDimMode(stored: nil) == .off, "nothing stored is Leave As They Are")
        check(BackgroundDimMode(stored: "dim") == .dim && BackgroundDimMode(stored: "blur") == .blur
              && BackgroundDimMode(stored: "haze") == .off, "dim and blur read back; an unknown value is off")
        check(BackgroundDimMode.allCases.map(\.title) == ["Leave As They Are", "Dim", "Blur"], "the three choices, off first")
        check(Settings.backgroundDimStrength(stored: nil) == 0.4, "strength defaults to 40%")
        check(Settings.backgroundDimStrength(stored: 3) == 0.9 && Settings.backgroundDimStrength(stored: -1) == 0.1,
              "a stored strength is kept to 10–90%")
        let ends = [0, 0.5, 1].map(Settings.backgroundDimStrength(atSlider:))
        check(ends == [0.1, 0.5, 0.9], "the slider's ends and middle are 10%, 50% and 90% (\(ends))")
        check(Settings.backgroundDimStrength(atSlider: 0.33) == 0.35, "the slider moves in 5% steps")
        let back = stride(from: 0.1, through: 0.9, by: 0.05).allSatisfy {
            abs(Settings.backgroundDimStrength(atSlider: Settings.backgroundDimSlider(for: $0)) - $0) < 0.001
        }
        check(back, "every 5% step comes back from its slider position")
        check(BackgroundDimmer(mode: { .dim }).wantsAccess && BackgroundDimmer(mode: { .blur }).wantsAccess
              && !BackgroundDimmer(mode: { .off }).wantsAccess, "Dim and Blur need Accessibility, off doesn't")
    }

    private static func rowChecks(_ check: Check) {
        let delegate = AppDelegate(lockWarning: LockWarning(timeoutOverride: nil))
        var facts = SettingsFacts()
        func rows(_ mode: BackgroundDimMode, strength: Double = 0.4) -> [SettingsRow] {
            delegate.backgroundDimSections(facts, mode: mode, strength: strength).flatMap(\.rows)
        }
        let sections = delegate.backgroundDimSections(facts, mode: .off, strength: 0.4)
        check(sections.map(\.title) == ["Background Windows"], "one card, Background Windows")
        let off = rows(.off)
        guard case .popup(let items)? = off.first?.control, off.first?.title == "Background Windows" else {
            return check(false, "its first row is the Background Windows popup")
        }
        check(items.map(\.title) == BackgroundDimMode.allCases.map(\.title) && items.map(\.state) == [.on, .off, .off],
              "the popup offers the three choices with Leave As They Are ticked")
        check(items.allSatisfy { ($0.target as AnyObject?)?.responds(to: $0.action) == true }
              && items.map(\.tag) == [0, 1, 2], "each choice reaches an action that answers it, tagged by its place")
        check(off.count == 1 && off[0].note?.contains("menu bar and the Dock") == true, "off: no strength slider, and a note on what stays clear")
        for mode in [BackgroundDimMode.dim, .blur] {
            let on = rows(mode, strength: 0.65)
            var slider: ValueSliderView?
            if on.count == 2, case .custom(let view) = on[1].control { slider = view as? ValueSliderView }
            let label = slider.flatMap { view in view.subviews.compactMap { $0 as? NSTextField }.first?.stringValue }
            let value = slider.flatMap { view in view.subviews.compactMap { $0 as? NSSlider }.first?.doubleValue }
            guard case .popup(let items)? = on.first?.control else { check(false, "\(mode.title): the popup first"); continue }
            check(items.first { $0.state == .on }?.title == mode.title && on.last?.title == "Strength" && label == "Strength  65%"
                  && value.map { abs($0 - Settings.backgroundDimSlider(for: 0.65)) < 0.001 } == true,
                  "\(mode.title): ticked, with a Strength slider at 65% (\(label ?? "no slider"))")
        }
        check(rows(.off).first?.closesPanel == false, "with Accessibility, choosing leaves the panel open")
        facts.permissions = PermissionCheck(accessibility: false, screenRecording: true, finder: .on, finderUsed: true)
        check(rows(.off).first?.closesPanel == true, "without it, choosing closes the panel for macOS's question")
        let windows = delegate.settingsPages(SettingsFacts()).first { $0.id == "windows" }
        let titles = windows?.sections.map(\.title) ?? []
        check(titles.firstIndex(of: "Dock").map { $0 + 1 < titles.count && titles[$0 + 1] == "Background Windows" } == true,
              "the card comes right after the Dock card on the Windows page (\(titles.map { $0 ?? "-" }.joined(separator: ", ")))")
    }

    private static func frontChecks(_ check: Check) {
        typealias W = BackgroundDimFront.Window
        func target(focused: W?, parent: W? = nil, main: W? = nil) -> BackgroundDimFront.Target {
            BackgroundDimFront.target(focused: focused, parent: { parent }, main: { main })
        }
        let plain = W(id: 7, layer: 0, onScreen: true)
        check(target(focused: plain) == .below(7), "the front app's focused window: everything behind it")
        check(target(focused: nil) == .none, "an app with no focused window: no effect")
        check(target(focused: W(id: 3, layer: -2147483603, onScreen: true)) == .none, "the desktop has focus: no effect")
        check(target(focused: W(id: 7, layer: 0, onScreen: true, fullScreen: true)) == .none, "a full-screen window: no effect")
        check(target(focused: W(id: 7, layer: 0, onScreen: false)) == .none, "a window that isn't on the screen (just minimized): no effect")
        check(target(focused: W(id: 9, layer: 0, onScreen: true, isSheet: true), parent: plain) == .below(7),
              "a sheet: behind the window it belongs to, so the sheet and its window both stay clear")
        check(target(focused: W(id: 5, layer: 3, onScreen: true), main: plain) == .below(7),
              "the app's floating panel has the keyboard: behind the app's main window")
        check(target(focused: W(id: 5, layer: 3, onScreen: true)) == .none, "a floating panel and no main window: no effect")
        var asked = 0
        _ = BackgroundDimFront.target(focused: plain, parent: { asked += 1; return nil }, main: { asked += 1; return nil })
        check(asked == 0, "an ordinary window reads no parent or main window")

        let own: pid_t = 100
        var looked = false
        func app(_ frontmost: pid_t?, last: pid_t = 0, topmost: pid_t? = 300) -> pid_t? {
            BackgroundDimFront.frontApp(frontmost: frontmost, ownPID: own, last: last) { looked = true; return topmost }
        }
        check(app(200, last: 250) == 200 && !looked, "another app in front is the front app, whatever was before")
        check(app(own, last: 250) == 250, "RubberMAC in front (its settings panel): the app that was in front before it")
        check(app(own) == 300, "RubberMAC in front and nothing seen before (just turned on): the app with the topmost window")
        check(app(own, topmost: nil) == nil && app(nil) == nil, "no other app with a window, or no app in front: none")
    }

    private static func placementChecks(_ check: Check) {
        let own: pid_t = 100
        func nearest(_ above: [(CGWindowID, pid_t, Int)]) -> CGWindowID? {
            BackgroundDimOverlays.nearest(above.map { (id: $0.0, pid: $0.1, layer: $0.2) }, ownPID: own)
        }
        check(nearest([(1, 50, 25), (2, 60, 3), (7, 200, 0)]) == 7, "right below the front window, with the menu bar and a floating panel higher up")
        check(nearest([(7, 200, 0), (8, 300, 0)]) == 8, "another window between them is what the overlay is below")
        check(nearest([(7, 200, 0), (4, own, 0), (5, own, 0)]) == 7, "RubberMAC's own windows in between (another screen's overlay) don't count")
        check(nearest([(9, 200, 0), (7, 200, 0)]) == 7, "a sheet above its window leaves the window nearest")
        check(nearest([(1, 50, 25)]) == nil, "nothing ordinary above: the overlay is on top of every window")
    }

    private static func fullScreenChecks(_ check: Check) {
        func display(_ id: String, type: Int) -> [String: Any] {
            ["Display Identifier": id, "Current Space": ["type": NSNumber(value: type), "ManagedSpaceID": NSNumber(value: 4)]]
        }
        check(BackgroundDimFront.fullScreenIdentifiers([display("A", type: 0), display("B", type: 4)]) == ["B"],
              "a display showing a full-screen Space is found, one showing a desktop isn't")
        check(BackgroundDimFront.fullScreenIdentifiers([display("Main", type: 4)]) == ["Main"], "with Spaces shared across displays: Main")
        check(BackgroundDimFront.fullScreenIdentifiers([["Display Identifier": "C"]]).isEmpty, "a display with no current Space read counts as a desktop")
        let ids = NSScreen.screens.compactMap(\.displayID).map(BackgroundDimFront.identifier(of:))
        check(!ids.isEmpty && ids.allSatisfy { $0.count == 36 }, "each screen has the UUID the window server names it by (\(ids.count))")
        let now = BackgroundDimFront.fullScreenDisplays()
        check(now.isSubset(of: Set(NSScreen.screens.compactMap(\.displayID))), "showing a full-screen Space now: \(now.count) of \(ids.count) screens")
    }

    private static func overlayChecks(_ check: Check) {
        let window = BackgroundDimOverlays.makeWindow()
        check(window.ignoresMouseEvents, "the overlay lets clicks through to the window underneath")
        check(window.level == .normal && !window.hasShadow && !window.isOpaque && window.styleMask == .borderless,
              "borderless, see-through, shadowless, at the normal window level")
        let behaviour = window.collectionBehavior
        check(behaviour.contains(.canJoinAllSpaces) && behaviour.contains(.ignoresCycle) && !behaviour.contains(.fullScreenAuxiliary),
              "on every desktop, out of window cycling, and not over full-screen apps")
        BackgroundDimOverlays.style(window, .dim, 0.4)
        check(window.backgroundColor == .black && abs(window.alphaValue - 0.4) < 0.001 && window.blurRadius == 0,
              "Dim: black at the strength (\(window.alphaValue))")
        check(BackgroundDimWindow.canBlur, "this macOS has the window server's blur")
        BackgroundDimOverlays.style(window, .blur, 0.7)
        check(window.blurRadius == 35 && window.alphaValue == 1 && window.backgroundColor.alphaComponent < 0.02,
              "Blur: the window server blurs what's behind, radius 35 at 70%, over an all but clear window")
        BackgroundDimOverlays.style(window, .dim, 0.2)
        check(window.blurRadius == 0 && window.backgroundColor == .black && abs(window.alphaValue - 0.2) < 0.001, "and back to Dim, with no blur")
        check(!window.isVisible, "none of it went on the screen")
        let dimmer = BackgroundDimmer(mode: { .off })
        dimmer.start()
        check(!dimmer.isOn && dimmer.overlays.windows.isEmpty && dimmer.updates == 0, "left as they are: started, it watches nothing and makes no window")
    }
}
