import AppKit

// --selftest openonscreen: which new windows move, to where and at what size, on made-up screens; which count as just
// opened, on made-up times; the rules' storage and the settings rows. Moves nothing, observes nothing, changes no setting.
// --selftest openonscreen-live: see OpenOnScreenLiveSelfTest.swift.
enum OpenOnScreenSelfTest {
    private typealias Check = (Bool, String) -> Void
    private typealias Plan = OpenOnScreenPlan

    // A 1920 × 1080 main screen with a 25-point menu bar, and a taller 2560 × 1440 one to its right, reaching higher.
    private static let main = Plan.Screen(key: "1:2:3", name: "Built-in Retina Display", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                          visible: CGRect(x: 0, y: 25, width: 1920, height: 1055))
    private static let right = Plan.Screen(key: "4:5:6", name: "DELL U2723QE", frame: CGRect(x: 1920, y: -180, width: 2560, height: 1440),
                                           visible: CGRect(x: 1920, y: -155, width: 2560, height: 1415))
    private static let onMain = CGPoint(x: 900, y: 500)
    private static let onRight = CGPoint(x: 3000, y: 500)

    static func report() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let stored = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?

        planChecks(check)
        kindChecks(check)
        ruleChecks(check)
        openingChecks(check)
        storeChecks(check)
        rowChecks(check)

        let after = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?
        check(stored?.isEqual(after) ?? (after == nil), "no stored setting changed")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    private static func context(_ pointer: CGPoint, rule: String? = nil, opening: Bool = true, screens: [Plan.Screen] = [main, right]) -> Plan.Context {
        Plan.Context(screens: screens, pointer: pointer, rule: rule, opening: opening)
    }

    private static func show(_ outcome: Plan.Outcome) -> String {
        switch outcome {
        case .move(let to, let frame): return "move to screen \(to) at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))"
        case .wait: return "wait"
        case .leave(let reason): return "leave: \(reason.rawValue)"
        }
    }

    // MARK: Where it goes

    private static func planChecks(_ check: Check) {
        let window = Plan.Window(frame: CGRect(x: 100, y: 125, width: 800, height: 600))
        let moved = Plan.decide(window, context(onRight))
        check(moved == .move(to: 1, frame: CGRect(x: 2077, y: 24, width: 800, height: 600)),
              "opened on the main screen with the pointer on the right one: moves there, same size, as far into its room: " + show(moved))
        check(Plan.decide(window, context(onMain)) == .leave(.alreadyThere), "the pointer on its own screen: left where it is")
        check(Plan.decide(window, context(onRight, screens: [main])) == .leave(.oneScreen), "one screen: nothing to do")
        check(Plan.decide(window, context(onRight, opening: false)) == .leave(.notOpening),
              "a window the app opened on its own, not right after the user opened something: left alone")

        let corner = Plan.decide(Plan.Window(frame: CGRect(x: 1120, y: 480, width: 800, height: 600)), context(onRight))
        check(corner == .move(to: 1, frame: CGRect(x: 3680, y: 660, width: 800, height: 600)),
              "a window in the bottom-right corner stays in the bottom-right corner: " + show(corner))
        if case .move(_, let frame) = Plan.decide(Plan.Window(frame: CGRect(x: 560, y: 252, width: 800, height: 600)), context(onRight)) {
            check(abs(frame.midX - right.visible.midX) <= 1 && abs(frame.midY - right.visible.midY) <= 1,
                  "a centred one stays centred: middle \(Int(frame.midX)),\(Int(frame.midY)) of \(Int(right.visible.midX)),\(Int(right.visible.midY))")
        } else {
            check(false, "a centred one stays centred")
        }
        let big = Plan.decide(Plan.Window(frame: CGRect(x: 2000, y: -100, width: 2400, height: 1300)), context(onMain))
        check(big == .move(to: 0, frame: main.visible), "one too big for the main screen is shrunk to its visible area: " + show(big))

        let straddling = CGRect(x: 1500, y: 100, width: 800, height: 600)
        check(Plan.screen(of: straddling, [main, right]) == 0, "a window across both screens is on the one holding most of it")
        check(Plan.screen(of: CGRect(x: -5000, y: -5000, width: 400, height: 300), [main, right]) == nil
              && Plan.decide(Plan.Window(frame: CGRect(x: -5000, y: -5000, width: 400, height: 300)), context(onMain)) == .leave(.offScreen),
              "one on no screen is left to Lost Windows")
        check(Plan.screen(at: CGPoint(x: 1000, y: -50), [main, right]) == 0, "the pointer in a gap between screens counts for the nearest one")

        var dragging = context(onRight)
        dragging.mouseDown = true
        check(Plan.decide(window, dragging) == .wait, "a mouse button down: waits")
        dragging.heldAt = window.frame
        check(Plan.decide(window, dragging) == .wait, "still down, the window where it was: still waits")
        dragging.mouseDown = false
        check(Plan.decide(window, dragging) == moved, "let go with the window where it was: it wasn't being dragged, so it moves")
        dragging.heldAt = window.frame.offsetBy(dx: 40, dy: 10)
        check(Plan.decide(window, dragging) == .leave(.dragged), "but if it moved while the button was down, the user dragged it: left alone")

        var tab = context(onRight)
        tab.isTabOfOlderWindow = { true }
        check(Plan.decide(window, tab) == .leave(.tabOfOlderWindow), "a new tab in a window that was already open: left with it")

        var changing = context(onRight)
        changing.screensChanging = true
        check(Plan.decide(window, changing) == .leave(.screensChanging), "while the screens are changing: nothing moves")
        var asked: [String] = []
        var full = context(onRight)
        full.showsFullScreen = { asked.append($0.key); return $0.key == right.key }
        check(Plan.decide(window, full) == .leave(.targetFullScreen) && asked == [right.key],
              "the pointer's screen showing a full-screen app: left alone (asked about \(asked.joined(separator: ", ")))")
    }

    // MARK: Which windows

    private static func kindChecks(_ check: Check) {
        let frame = CGRect(x: 100, y: 125, width: 800, height: 600)
        let kinds: [(String, Plan.Window)] = [
            ("a panel", Plan.Window(subrole: kAXFloatingWindowSubrole, frame: frame)),
            ("a dialog", Plan.Window(subrole: kAXDialogSubrole, frame: frame)),
            ("a system dialog", Plan.Window(subrole: kAXSystemDialogSubrole, frame: frame)),
            ("a sheet", Plan.Window(role: kAXSheetRole, subrole: nil, frame: frame)),
            ("a popover", Plan.Window(role: kAXPopoverRole, subrole: nil, frame: frame)),
            ("a window without a subrole", Plan.Window(subrole: nil, frame: frame)),
        ]
        for (name, window) in kinds {
            check(Plan.decide(window, context(onRight)) == .leave(.notOrdinary), "\(name) is left alone: " + show(Plan.decide(window, context(onRight))))
        }
        check(Plan.decide(Plan.Window(fullScreen: true, frame: frame), context(onRight)) == .leave(.fullScreen), "a full-screen window is left alone")
        check(Plan.decide(Plan.Window(minimized: true, frame: frame), context(onRight)) == .leave(.minimized), "a minimized one too")
        check(Plan.decide(Plan.Window(subrole: kAXFloatingWindowSubrole, frame: frame), context(onRight, rule: main.key)) == .leave(.notOrdinary),
              "and a rule doesn't move a panel either")
    }

    // MARK: Rules

    private static func ruleChecks(_ check: Check) {
        let onRightScreen = Plan.Window(frame: CGRect(x: 2100, y: 100, width: 800, height: 600))
        let ruled = Plan.decide(onRightScreen, context(onRight, rule: main.key))
        check(ruled == .move(to: 0, frame: CGRect(x: 115, y: 167, width: 800, height: 600)),
              "a rule beats the pointer: opened on the right screen with the pointer there, it goes to the app's screen: " + show(ruled))
        check(Plan.decide(onRightScreen, context(onMain, rule: main.key, opening: false)) == ruled,
              "and applies whenever the app opens one, not only right after the user opened something")
        check(Plan.decide(onRightScreen, context(onMain, rule: right.key)) == .leave(.alreadyThere),
              "already on the app's screen: stays, though the pointer is on the other one")
        check(Plan.decide(onRightScreen, context(onMain, rule: "7:8:9", opening: false)) == .leave(.ruleWaits),
              "the app's screen not connected: the rule waits, and a window the app opened on its own stays")
        check(Plan.decide(onRightScreen, context(onMain, rule: "7:8:9")) == .move(to: 0, frame: CGRect(x: 115, y: 167, width: 800, height: 600)),
              "meanwhile one the user just opened goes to the pointer's screen, as without a rule")
    }

    // MARK: Which windows the user just opened

    private static func openingChecks(_ check: Check) {
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
        typealias Openings = OpenOnScreenOpenings

        var openings = Openings(newest: 100)
        let watch = openings.activated(1, now: t0, lastInput: at(-0.5), newest: 150)
        check(watch == Openings.Watch(until: at(Openings.afterActivation), since: 100) && openings.newestAtLastSwitch == 150,
              "a switch to an app half a second after a click: watched for \(Int(Openings.afterActivation)) s, for windows newer than the last switch")
        check(openings.activated(2, now: at(10), lastInput: at(5), newest: 200) == nil && openings.newestAtLastSwitch == 200,
              "an app that came forward with no click or key in the \(Int(Openings.inputGap)) s before: not watched, but counted")
        check(!openings.appeared(1, window: 99, at: at(0.5)), "a window made before the last switch isn't new")
        check(openings.appeared(1, window: 151, at: at(0.5)), "one made since, half a second in, is just opened")
        check(openings.appeared(1, window: 152, at: at(1.2)), "and so is another within \(Int(Openings.siblingGap)) s of it, as files opened together")
        check(!openings.appeared(1, window: 153, at: at(1.6)), "but not one after that: those were the first windows")
        check(!openings.appeared(2, window: 201, at: at(10.5)), "nor one of the app that wasn't watched")

        var late = Openings(newest: 100)
        _ = late.activated(1, now: t0, lastInput: t0, newest: 150)
        check(!late.appeared(1, window: 160, at: at(Openings.afterActivation + 0.5)), "a first window \(Openings.afterActivation + 0.5) s after a switch is too late")

        var launches = Openings(newest: 500)
        let launch = launches.launched(3, at: t0, now: at(0.2), lastInput: at(-1))
        check(launch == Openings.Watch(until: at(0.2 + Openings.afterLaunch), since: 0),
              "a launch a second after a click: watched for \(Int(Openings.afterLaunch)) s, and all its windows are new")
        check(launches.appeared(3, window: 7, at: at(8)), "so a slow app's first window 8 s in still counts")
        check(launches.launched(4, at: t0, now: at(0.2), lastInput: at(-10)) == nil, "a launch with no click or key before it, as at login: not watched")
        let after = launches.activated(3, now: at(8.5), lastInput: at(8), newest: 600)
        check(after?.since == 0, "a switch to an app still being watched since its launch keeps all its windows new")
        check(Set(launches.expire(at(30))) == [3] && launches.watches.isEmpty, "watches are dropped once over")
        check(Set(openings.expire(at(30))) == [1] && openings.watches.isEmpty, "including a switch's")
    }

    // MARK: Storage and rows

    private static let safari = OpenOnScreenRule(app: "com.apple.Safari", appName: "Safari", screen: right.key, screenName: right.name)
    private static let preview = OpenOnScreenRule(app: "com.apple.Preview", appName: "Preview", screen: "7:8:9", screenName: "LG UltraFine")
    private static let displays = [main, right].map { DockScreen.Display(key: $0.key, name: $0.name, bounds: $0.frame) }

    private static func storeChecks(_ check: Check) {
        check(OpenOnScreenRule.decode(OpenOnScreenRule.encode([safari, preview])) == [safari, preview], "two rules survive being stored and read back")
        check(OpenOnScreenRule.decode(nil).isEmpty && OpenOnScreenRule.decode(Data("not json".utf8)).isEmpty, "nothing stored, or junk, reads as no rules")
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        check(registered["openOnScreenEnabled"] == nil, "the switch has no registered default, so it starts off")

        func titles(_ rule: OpenOnScreenRule) -> String { rule.choices(displays).map { $0.on ? "[\($0.title)]" : $0.title }.joined(separator: " | ") }
        check(titles(safari) == "Built-in Retina Display | [DELL U2723QE]", "a rule's screens: \(titles(safari))")
        check(titles(preview) == "Built-in Retina Display | DELL U2723QE | [LG UltraFine (not connected)]", "with its screen not connected: \(titles(preview))")
    }

    private static func rowChecks(_ check: Check) {
        let delegate = AppDelegate(lockWarning: LockWarning(timeoutOverride: nil))
        let sections = delegate.openOnScreenSections(SettingsFacts(), on: false, rules: [safari, preview], displays: displays)
        let rows = sections.flatMap(\.rows)
        func items(_ row: SettingsRow?) -> [NSMenuItem] { if case .popup(let list) = row?.control { list } else { [] } }
        check(sections.count == 1 && sections[0].title == OpenOnScreen.sectionTitle && rows.count == 4,
              "one \(OpenOnScreen.sectionTitle) section: the switch, a row per rule and Add App (\(rows.map(\.title).joined(separator: " / ")))")

        var toggledOff = false
        if case .toggle(let on) = rows.first?.control { toggledOff = !on }
        check(rows.first?.title == OpenOnScreen.switchTitle && rows.first?.note == OpenOnScreen.switchNote && toggledOff,
              "the switch: \(OpenOnScreen.switchTitle), off, with its note")
        var noAccess = SettingsFacts()
        noAccess.permissions = PermissionCheck(accessibility: false, screenRecording: true, finder: .on, finderUsed: true)
        let without = delegate.openOnScreenSections(noAccess, on: false, rules: [safari], displays: displays).flatMap(\.rows)
        check(rows.allSatisfy { !$0.closesPanel } && without.map(\.closesPanel) == [true, true, false],
              "without Accessibility the switch and the rules' popups close the panel first, as macOS will ask; Add App keeps it open for its menu")

        let safariItems = items(rows[safe: 1])
        check(rows[safe: 1]?.title == "Safari Always Opens On"
              && safariItems.map(\.title) == ["Built-in Retina Display", "DELL U2723QE", "", OpenOnScreen.removeItem]
              && safariItems[2].isSeparatorItem && safariItems.filter { $0.state == .on }.map(\.title) == ["DELL U2723QE"],
              "a rule's row: Safari Always Opens On, each screen with its own ticked, a line, then Remove")
        check(safariItems.prefix(2).map { ($0.representedObject as? OpenOnScreenRule)?.screen } == [main.key, right.key]
              && (safariItems.first?.representedObject as? OpenOnScreenRule)?.screenName == main.name
              && (safariItems.last?.representedObject as? OpenOnScreenRule) == safari,
              "each screen carries the rule as it would be with that screen, and Remove the rule")
        let previewItems = items(rows[safe: 2])
        check(previewItems.map(\.title) == ["Built-in Retina Display", "DELL U2723QE", "LG UltraFine (not connected)", "", OpenOnScreen.removeItem]
              && previewItems.filter { $0.state == .on }.map(\.title) == ["LG UltraFine (not connected)"],
              "a rule whose screen isn't connected shows it, ticked, as (not connected)")

        var button = ""
        if case .button(let label, _) = rows[safe: 3]?.control { button = label }
        check(rows[safe: 3]?.title == OpenOnScreen.addTitle && button == OpenOnScreen.addButton,
              "the last row: \(OpenOnScreen.addTitle), with an \(OpenOnScreen.addButton) button")
        let apps = ["Finder", "Preview", "Safari", "TextEdit"].map { OpenOnScreen.App(bundleID: "com.apple.\($0)", name: $0) }
        let menu = delegate.openOnScreenAppsMenu(apps, rules: [safari, preview]).items
        check(menu.map(\.title) == ["Finder", "TextEdit"] && menu.compactMap { $0.representedObject as? OpenOnScreen.App } == [apps[0], apps[3]],
              "its menu lists the running apps without a rule, each carrying its app")
        let full = delegate.openOnScreenAppsMenu([apps[2]], rules: [safari]).items
        check(full.map(\.title) == [OpenOnScreen.noApps] && !full[0].isEnabled, "and says so, unchoosable, when every one has a rule")

        let chosen = rows.flatMap(items).filter { !$0.isSeparatorItem && $0.isEnabled } + menu
        check(chosen.allSatisfy { $0.target === delegate && delegate.responds(to: $0.action!) }
              && [rows[0], rows[3]].allSatisfy { $0.target === delegate && delegate.responds(to: $0.action!) },
              "the switch, Add App and all \(chosen.count) choices reach their actions")
        let none = delegate.openOnScreenSections(SettingsFacts(), on: true, rules: [], displays: displays).flatMap(\.rows)
        check(none.map(\.title) == [OpenOnScreen.switchTitle, OpenOnScreen.addTitle], "with no rules: the switch and Add App")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
