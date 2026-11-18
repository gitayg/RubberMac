import AppKit
import Carbon.HIToolbox

// --selftest spotlightfilter: when an opening of Spotlight's search bar gets ⌘1 (once, only with Spotlight's own
// field holding the keyboard, not when it already shows only apps, not after the opening is over), the ⌘1 itself,
// the switch and its Keyboard row. No Accessibility and nothing opens: the bar is made up and the key isn't posted.
enum SpotlightFilterSelfTest {
    static func report() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        stepChecks(check)
        openingChecks(check)
        keyChecks(check)
        switchChecks(check)
        holdChecks(check)
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    typealias Check = (Bool, String) -> Void
    typealias Bar = SpotlightFilterOpenings.Bar
    static let ui: pid_t = 1159
    static let other: pid_t = 80752
    static let field = SpotlightFilter.fieldID
    
    private static func stepChecks(_ check: Check) {
        func step(_ bar: Bar, after: TimeInterval = 0.1, apps: String? = "Applications") -> SpotlightFilterOpenings.Step {
            SpotlightFilterOpenings.step(sinceOpened: after, bar: bar, uiPid: ui, appsTitle: apps)
        }
        check(step(Bar(focusedPid: ui, fieldID: field, placeholder: "Search or Ask")) == .press,
              "a bar just opened, its field holding the keyboard: ⌘1")
        check(step(Bar(focusedPid: ui, fieldID: field, placeholder: " ")) == .press, "the same with the placeholder Spotlight shows once typed in")
        check(step(Bar(focusedPid: other, fieldID: field, placeholder: " ")) == .wait,
              "another app holding the keyboard (Spotlight's field focused in its own process): waits")
        check(step(Bar(focusedPid: nil, fieldID: field, placeholder: " ")) == .wait, "no app known to hold the keyboard: waits")
        check(step(Bar(focusedPid: ui, fieldID: nil, placeholder: nil)) == .wait, "Spotlight in front but no field focused yet: waits")
        check(step(Bar(focusedPid: ui, fieldID: "QueryFilterBar", placeholder: nil)) == .wait, "something else of Spotlight's focused: waits")
        check(step(Bar(focusedPid: ui, fieldID: field, placeholder: "Applications")) == .alreadyOn, "already showing only apps: nothing")
        check(step(Bar(focusedPid: ui, fieldID: field, placeholder: "Applications"), apps: nil) == .press,
              "with the apps title unknown it presses anyway (a second ⌘1 changes nothing, measured)")
        check(step(Bar(focusedPid: ui, fieldID: field, placeholder: " "), after: SpotlightFilterOpenings.armedFor) == .press,
              "still within \(SpotlightFilterOpenings.armedFor) s of the window: ⌘1")
        check(step(Bar(focusedPid: ui, fieldID: field, placeholder: " "), after: SpotlightFilterOpenings.armedFor + 0.1) == .expired,
              "later than that: the opening is over")
    }

    private static func openingChecks(_ check: Check) {
        var clock = Date(timeIntervalSince1970: 0)
        var bar = Bar(focusedPid: ui, fieldID: field, placeholder: "Search or Ask")
        var presses = 0
        let openings = SpotlightFilterOpenings(uiPid: ui, read: { bar }, press: { presses += 1 })
        openings.now = { clock }
        openings.appsTitle = "Applications"

        openings.windowCreated()
        check(presses == 1 && openings.opened == nil, "the bar's window made with its field ready: ⌘1 once, opening done")
        // Not yet reading "Applications", as in a language whose filter name RubberMAC doesn't know.
        bar.placeholder = " "
        for _ in 1...20 { openings.focusChanged() }
        check(presses == 1, "the dozen focus changes Spotlight sends as it opens don't press again (\(presses))")
        clock += 5
        for _ in 1...5 { openings.focusChanged() }
        check(presses == 1, "Esc taking the filter off (focus moves, no new window) leaves it off")

        clock += 5
        openings.windowCreated()
        check(presses == 2, "the next opening gets its own ⌘1")

        clock += 5
        bar = Bar(focusedPid: other, fieldID: field, placeholder: " ")
        openings.windowCreated()
        check(presses == 2 && openings.opened != nil, "a window made while another app still has the keyboard: waits")
        clock += 0.05
        bar.focusedPid = ui
        openings.focusChanged()
        check(presses == 3 && openings.opened == nil, "then focus reaching Spotlight's field presses it")

        clock += 5
        bar = Bar(focusedPid: ui, fieldID: nil, placeholder: nil)
        openings.windowCreated()
        clock += SpotlightFilterOpenings.armedFor + 0.5
        bar = Bar(focusedPid: ui, fieldID: field, placeholder: " ")
        openings.focusChanged()
        check(presses == 3 && openings.expired == 1 && openings.opened == nil,
              "a window whose field didn't get the keyboard within \(SpotlightFilterOpenings.armedFor) s is left alone, even if it gets it later")

        clock += 5
        bar = Bar(focusedPid: ui, fieldID: field, placeholder: "Applications")
        openings.windowCreated()
        check(presses == 3 && openings.alreadyOn == 1, "a bar that opens already showing only apps gets no ⌘1")
        check(openings.presses == presses, "the count it keeps matches (\(openings.presses))")
    }

    private static func keyChecks(_ check: Check) {
        let events = SpotlightFilter.appsKeyEvents()
        let keys = events.map { Int($0.getIntegerValueField(.keyboardEventKeycode)) }
        let downs = events.map { $0.type == .keyDown }
        let flags = events.map { $0.flags.rawValue & (Modifiers.control | Modifiers.command | Modifiers.option | Modifiers.shift) }
        check(keys == [kVK_ANSI_1, kVK_ANSI_1] && downs == [true, false], "the press is 1's key down then up (keys \(keys))")
        check(flags == [Modifiers.command, Modifiers.command], "with ⌘ and no other modifier on both")
        check(SpotlightFilter.appsTitle == "Applications",
              "on this Mac the Applications folder's name is the filtered field's placeholder, \"Applications\" (\(SpotlightFilter.appsTitle))")
    }

    private static func switchChecks(_ check: Check) {
        let stored = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
        if stored?["spotlightAppsOnlyEnabled"] == nil {
            check(!Settings.spotlightAppsOnlyEnabled, "off until turned on")
        }
        let feature = SpotlightFilter()
        var on = false
        feature.isOn = { on }
        feature.start()
        check(!feature.isWatching && !feature.wantsAccess, "off: nothing watched, no Accessibility asked for")
        on = true
        feature.apply()
        check(feature.isWatching && feature.wantsAccess, "on: watching, and it needs Accessibility")
        on = false
        feature.apply()
        check(!feature.isWatching && feature.watcher == nil, "off again: the watcher and app notices are gone")

        let delegate = AppDelegate(lockWarning: LockWarning(timeoutOverride: nil))
        var facts = SettingsFacts()
        let rows = delegate.spotlightFilterRows(facts)
        check(rows.map(\.title) == ["Spotlight Searches Only Apps"]
              && rows.map(\.note) == ["Like pressing ⌘1 in the search bar; Esc goes back to searching everything"],
              "the Keyboard row: \(rows.map(\.title))")
        check(rows.allSatisfy { if case .toggle = $0.control { true } else { false } }, "it's a switch")
        check(rows.allSatisfy { row in row.action.map { (row.target as AnyObject?)?.responds(to: $0) == true } ?? false },
              "its switch reaches an action that answers it")
        check(rows.first?.closesPanel == false, "with Accessibility the panel stays open")
        facts.permissions = PermissionCheck(accessibility: false, screenRecording: true, finder: .on, finderUsed: true)
        check(delegate.spotlightFilterRows(facts).first?.closesPanel == true, "without it the panel closes for macOS's question")

        let keyboard = delegate.settingsPages(SettingsFacts()).first { $0.id == "keyboard" }
        let titles = keyboard?.sections.flatMap { $0.rows.map(\.title) } ?? []
        let mine = titles.firstIndex(of: SpotlightFilter.switchTitle)
        let search = titles.firstIndex(of: "⌘R Opens Spotlight, Like Win+R")
        let alone = titles.firstIndex(of: "⌘ Alone Opens Apps, Like the Windows Key")
        let start = titles.firstIndex { $0.hasPrefix("⌘ Alone Opens RubberMAC's Start") }
        check(mine != nil && search.map { $0 < mine! } == true && alone.map { $0 < mine! } == true && start.map { $0 + 1 == mine } == true,
              "on the Keyboard page right after the ⌘R, ⌘-alone and Start rows (row \(mine.map(String.init) ?? "-"))")
    }
}
