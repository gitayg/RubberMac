import AppKit
import Carbon.HIToolbox
import ServiceManagement

// --selftest settings [folder]: the settings panel and the Permissions page. PermissionCheck's words for each state,
// that everything the old menu offered is on a page, that every control reaches something that can answer it, the
// panel's own behaviour on made-up pages, and each page drawn off screen in light and dark to PNGs in the folder.
// Builds the real pages but never presses anything on them, and leaves every stored setting as it was.
extension SettingsPanel {
    static func selfTestReport(folder: URL) -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }

        NSApp.setActivationPolicy(.accessory)
        let stored = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) as NSDictionary?

        permissionChecks(check)
        let delegate = AppDelegate(lockWarning: LockWarning(timeoutOverride: nil))
        parityChecks(delegate, check)
        wiringChecks(delegate, check)
        widgetChecks(check)
        drawChecks(delegate, folder: folder, check)

        let after = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) as NSDictionary?
        check(stored?.isEqual(after) ?? (after == nil), "no stored setting changed")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    private typealias Check = (Bool, String) -> Void

    // MARK: 1. PermissionCheck

    private static func permissionChecks(_ check: Check) {
        func rows(ax: Bool = true, screen: Bool = true, finder: PermissionCheck.FinderState? = .on, used: Bool = true) -> [PermissionCheck.Row] {
            PermissionCheck(accessibility: ax, screenRecording: screen, finder: finder, finderUsed: used).rows
        }

        let on = rows()
        check(on.map(\.state) == ["On", "On", "On"] && on.allSatisfy { !$0.offersTurnOn && $0.hint == nil },
              "all on: each row says On, with no hint and no Turn On")
        check(on[0].title == "Accessibility" && on[0].note.contains("Alt-Tab"), "Accessibility says what it's for")
        check(on[1].title.contains("Screen Recording") && on[1].title.contains("optional") && on[1].note.contains("window pictures"),
              "Screen Recording is marked optional and says what it's for")

        let ax = rows(ax: false)[0]
        check(ax.state == "Off" && ax.offersTurnOn && ax.note.contains("don't work without it")
              && ax.hint == "If its switch is already on in System Settings, turn it off and on again.",
              "Accessibility off: Off, what's lost, its Turn On, and the off-and-on-again hint")
        let screen = rows(screen: false)[1]
        check(screen.state == "Off" && screen.offersTurnOn && screen.note.contains("Without it")
              && screen.hint == "If you just turned it on and it still says off, quit and reopen RubberMAC.",
              "Screen Recording off: Off, what's lost, its Turn On, and the quit-and-reopen hint")

        check(PermissionCheck.FinderState(status: noErr) == .on, "Finder status noErr is on")
        check(PermissionCheck.FinderState(status: FinderWindow.notPermitted) == .off, "Finder status errAEEventNotPermitted is off")
        check(PermissionCheck.FinderState(status: OSStatus(errAEEventWouldRequireUserConsent)) == .notAskedYet,
              "Finder status errAEEventWouldRequireUserConsent is not asked yet")
        check(PermissionCheck.FinderState(status: OSStatus(procNotFound)) == .notAskedYet, "Finder status procNotFound (Finder not running) is not asked yet")

        let later = rows(finder: .notAskedYet)[2]
        check(later.isOn == nil && !later.offersTurnOn && later.state == "macOS asks the first time you paste a path",
              "Finder not asked yet: no on/off, no Turn On, and says macOS asks on the first paste")
        let denied = rows(finder: .off)[2]
        check(denied.state == "Off" && denied.offersTurnOn && denied.note.contains("new Finder window"), "Finder off: Off, what's lost, and its Turn On")
        check(rows(finder: nil)[2].state == "Checking…", "Finder before its first reading says Checking…")
        check(rows(used: false).count == 2 && !rows(used: false).contains { $0.kind == .finder }, "Finder's row is gone when neither Finder feature is on")
        check(rows(used: true).contains { $0.kind == .finder }, "and there when one is")

        let line = PermissionCheck(accessibility: true, screenRecording: false, finder: .on, finderUsed: true).logLine
        check(line == "permissions: accessibility on, screen recording off, finder on", "the log line is states only: \(line)")
        let now = Date()
        check(PermissionCheck.checkedNote(at: now, now: now.addingTimeInterval(5)).hasPrefix("Checked just now"), "a check seconds ago reads Checked just now")
        check(PermissionCheck.checkedNote(at: now, now: now.addingTimeInterval(120)).hasPrefix("Last checked"), "an older one reads Last checked")
    }

    // MARK: 2. Everything the old menu had

    private static func base() -> SettingsFacts {
        SettingsFacts(version: "9.9.9", saverSummary: "Screen saver after 20 min idle", setupName: "")
    }

    private static func strings(_ pages: [SettingsPage]) -> Set<String> {
        var all = Set<String>()
        for page in pages {
            all.insert(page.title)
            for section in page.sections {
                if let title = section.title { all.insert(title) }
                for row in section.rows {
                    all.insert(row.title)
                    if let note = row.note { all.formUnion(note.components(separatedBy: "\n")) }
                    if case .popup(let items) = row.control { all.formUnion(items.map(\.title)) }
                }
            }
        }
        return all
    }

    // Frozen from the old menuNeedsUpdate (1.21.0). What was "Warning Time: 15s", "Grid: 3 × 2" or "Alt-Tab: Off" is a
    // title with the choices in a popup now, so the title and the choices are listed instead.
    private static let oldMenuAlways: [String] = [
        "Show Big Clock Now",
        "Pre-Lock Warning", "Warn Before Screen Saver", "Warning Time",
        "5 seconds", "10 seconds", "15 seconds", "20 seconds", "30 seconds", "45 seconds", "60 seconds",
        "Dim Screens 5s Before Warning",
        "Brightness", "Brightness Keys ⌃⌥⌘↑ / ⌃⌥⌘↓",
        "Window Snapping", "Snap to Grid, Maximize, Minimize", "Grid",
        "2 columns × 1 row", "2 columns × 2 rows", "2 columns × 3 rows", "3 columns × 1 row", "3 columns × 2 rows", "3 columns × 3 rows",
        "4 columns × 1 row", "4 columns × 2 rows", "4 columns × 3 rows",
        "Keys", "⌘ + arrows  (Windows key + arrow)", "⌃⌥ + arrows",
        "Keep Windows Clear of the Camera", "Mark Where the Camera Is…",
        "⌘M Minimizes All Windows (⌘⇧M Brings Back)",
        "Bring Up the Dock in Full-Screen Apps", "Moving the pointer to the edge is enough, no push needed",
        "Click an App in the Dock to Pick Its Window", "With two or more windows, shows them to choose from",
        "PC Keyboard Habits", "Alt-Tab", "Switch Windows (like Windows)", "Switch Apps (macOS switcher)", "Off",
        "Ctrl-C / X / V / Z: Copy, Cut, Paste, Undo", "Ctrl stays Ctrl in terminals, VS Code and remote desktops",
        "Ctrl-←/→ by Word, Home/End to Line Start/End", "Left Alt-Shift Switches Language",
        "Paste a Path in Finder to Go There", "⌘V or Ctrl-V in a Finder window, no ⌘⇧G needed",
        "Address Bar in Finder Windows", "Shows the folder's path; paste or type one and press ↩",
        "Writing", "⌘⇧Space Opens a Pad That Fixes What You Write", "↩ pastes the fixed text where you were typing", "Open Saved Replies",
        "Mouse", "System Settings stops pointer speed at 3; this goes to 16",
        "Hold the Wheel and Move to Scroll, One Direction at a Time", "A quick wheel click is still a middle click",
        "Window Layouts", "Remember Layout per Monitor Setup", "Save Layout Now", "Restore Layout Now",
        "Version 9.9.9", "Check for Updates", "Install Updates Automatically",
        "Open at Login",
        // Added to the menu in 1.22.0, with camrelay not set up.
        "Eye Color Camera", "Recolours your eyes live on video calls", "Set Up camrelay…",
    ]

    private static func parityChecks(_ delegate: AppDelegate, _ check: Check) {
        func texts(_ edit: (inout SettingsFacts) -> Void = { _ in }) -> Set<String> {
            var facts = base()
            edit(&facts)
            return strings(delegate.settingsPages(facts))
        }

        let plain = texts()
        let missing = oldMenuAlways.filter { !plain.contains($0) }
        check(missing.isEmpty, "all \(oldMenuAlways.count) always-present titles and notes of the old menu are on a page"
              + (missing.isEmpty ? "" : "; missing: " + missing.joined(separator: " | ")))
        check(plain.contains("Screen saver after 20 min idle"), "the screen saver summary note")

        // Each conditional row, with its condition on and off, built by the same code the panel uses.
        func conditional(_ text: String, _ edit: (inout SettingsFacts) -> Void) {
            check(texts(edit).contains(text) && !plain.contains(text), "conditional row appears only under its condition: \(text)")
        }
        let display = Brightness.Display(id: 1, name: "Test Display", hardware: false)
        conditional("Brightness (software dimming)") { $0.displays = [display] }
        conditional("DisplayLink dock: monitors can't take brightness commands") { $0.displays = [display] }
        conditional("Test Display") { $0.displays = [display] }
        check(!texts { $0.displays = [Brightness.Display(id: 1, name: "Real", hardware: true)] }.contains("Brightness (software dimming)"),
              "a monitor on DDC is not software dimming")
        let camera = CameraArea(display: "1:2:3", name: "Test Screen", box: CGRect(x: 10, y: 10, width: 10, height: 10), on: CGRect(x: 0, y: 0, width: 100, height: 100))
        conditional("Marked on Test Screen (not connected)") { $0.camera = camera }
        conditional("Marked on Test Screen") { $0.camera = camera; $0.cameraConnected = true }
        conditional("⌘Tab Switches Windows Too") { $0.altTab = .windows }
        let noScreen = PermissionCheck(accessibility: true, screenRecording: false, finder: .on, finderUsed: true)
        conditional("Show Window Pictures in the Switcher…") { $0.altTab = .windows; $0.permissions = noScreen }
        check(!texts { $0.permissions = noScreen }.contains("Show Window Pictures in the Switcher…"), "window pictures row needs Alt-Tab on windows too")
        conditional("Let the Pad Read the Screen You're Replying To…") { $0.permissions = noScreen }
        conditional("Let RubberMAC Move Finder Windows…") { $0.finderDenied = true }
        conditional("Fixing needs Apple Intelligence (System Settings)") { $0.fixerAvailable = false }
        let one = ["Test Mouse"], two = ["Mouse A", "Mouse B"]
        check(plain.contains("No mouse connected") && !texts { $0.mice = one }.contains("No mouse connected"), "No mouse connected shows only with no mouse")
        conditional("Mouse: Test Mouse") { $0.mice = one }
        conditional("Remembered for each mouse model") { $0.mice = one }
        conditional("Pointer speed") { $0.mice = one }
        conditional("Wheel speed") { $0.mice = one }
        conditional("The wheel speed used is Mouse B's, connected last") { $0.mice = two }
        check(texts { $0.mice = two }.isSuperset(of: ["Mouse A", "Mouse B", "Pointer speed"]), "with two mice each has its own card and both sliders")
        conditional("My Displays") { $0.setupName = "My Displays" }
        let release = UpdateFeed.Release(version: "2.0.0", zipURL: URL(string: "https://example.invalid/a.zip")!, pageURL: URL(string: "https://example.invalid/")!)
        conditional("Install 2.0.0 and Relaunch") { $0.update = .available(release) }
        conditional("2.0.0 is available") { $0.update = .available(release) }
        conditional("Checking…") { $0.update = .checking }
        conditional("Up to date") { $0.update = .upToDate }
        conditional("Installing 2.0.0…") { $0.update = .installing("2.0.0") }
        conditional("Last check failed: no network") { $0.update = .failed("no network") }
        conditional("Approve in System Settings › Login Items") { $0.login = .requiresApproval }
        let cameras = [EyeCamera.Camera(index: 0, name: "Test Camera", virtual: false), EyeCamera.Camera(index: 1, name: "OBS Virtual Camera", virtual: true)]
        // "Camera" alone is also the Windows page's card about a camera on a stand, so its choices stand in for it.
        for text in ["Recolour My Eyes on the Virtual Camera", "Colour", "Blue", "Strength", "30%", "90%", "Refresh List",
                     "Calibrate…", "Turn On When RubberMAC Starts", "In Zoom, Meet or Teams, choose OBS Virtual Camera", "Looking for cameras…"] {
            conditional(text) { $0.eye.installed = true }
        }
        conditional("Test Camera") { $0.eye.installed = true; $0.eye.cameras = cameras }
        conditional("OBS Virtual Camera (virtual, can't be the input)") { $0.eye.installed = true; $0.eye.cameras = cameras }
        conditional("Show the Whole Error…") { $0.eye.installed = true; $0.eye.hasError = true }
        conditional("Quit the Separate camrelay App (It Uses the Same Camera)") { $0.eye.installed = true; $0.eye.separateApp = true }

        // "Grant Accessibility Access…" asked the same question Turn On… now does, on the Permissions page.
        var noAccess = base()
        noAccess.needsAccess = true
        noAccess.permissions = PermissionCheck(accessibility: false, screenRecording: true, finder: .on, finderUsed: true)
        let pages = delegate.settingsPages(noAccess)
        let permissions = pages.first { $0.id == AppDelegate.permissionsPageID }
        let turnOn = permissions?.rows.first { $0.title == "Accessibility" }
        var offered = false
        if case .status(_, _, let button)? = turnOn?.control { offered = button == "Turn On…" }
        check(offered && turnOn?.action != nil, "Grant Accessibility Access… lives on as Permissions › Accessibility › Turn On…")
        check(permissions?.needsAttention == true, "and the Permissions page wants attention when Accessibility is needed and off")
        var given = base()
        given.needsAccess = false
        check(delegate.settingsPages(given).first { $0.id == AppDelegate.permissionsPageID }?.needsAttention == false, "and not otherwise")

        let panel = SettingsPanel()
        check(panel.sidebar.quit.title == "Quit RubberMAC" && panel.sidebar.quit.action == #selector(NSApplication.terminate(_:))
              && panel.sidebar.quit.target === NSApp, "Quit RubberMAC is at the bottom of the sidebar and quits")
    }

    // MARK: 3. Wiring

    private static func wiringChecks(_ delegate: AppDelegate, _ check: Check) {
        var everything = base()
        let release = UpdateFeed.Release(version: "2.0.0", zipURL: URL(string: "https://example.invalid/a.zip")!, pageURL: URL(string: "https://example.invalid/")!)
        everything.update = .available(release)
        everything.altTab = .windows
        everything.finderDenied = true
        everything.mice = ["Mouse A", "Mouse B"]
        everything.displays = [Brightness.Display(id: 1, name: "Test Display", hardware: true)]
        everything.camera = CameraArea(display: "1:2:3", name: "Test", box: CGRect(x: 10, y: 10, width: 10, height: 10), on: CGRect(x: 0, y: 0, width: 100, height: 100))
        everything.permissions = PermissionCheck(accessibility: false, screenRecording: false, finder: .off, finderUsed: true)
        everything.eye = EyeFacts(installed: true, hasError: true,
                                  cameras: [EyeCamera.Camera(index: 0, name: "Test Camera", virtual: false)], separateApp: true)

        for (name, pages) in [("real", delegate.settingsPages()), ("every conditional row", delegate.settingsPages(everything))] {
            var checked = 0
            var broken: [String] = []
            func wired(_ title: String, _ target: AnyObject?, _ action: Selector?) {
                checked += 1
                guard let target, let action, target.responds(to: action) else { broken.append(title); return }
            }
            for row in pages.flatMap(\.rows) {
                switch row.control {
                case .none, .note, .custom:
                    break
                case .toggle, .button:
                    wired(row.title, row.target, row.action)
                case .status(_, _, let button):
                    if button != nil { wired(row.title, row.target, row.action) }
                case .popup(let items):
                    // A line that can't be chosen ("Looking for cameras…") has no action to answer.
                    for item in items where !item.isSeparatorItem && item.isEnabled { wired("\(row.title) › \(item.title)", item.target, item.action) }
                }
            }
            check(broken.isEmpty && checked > 0, "\(name) pages: all \(checked) controls have a target that answers their action"
                  + (broken.isEmpty ? "" : "; broken: " + broken.joined(separator: " | ")))
        }

        let pages = delegate.settingsPages(everything).flatMap(\.rows)
        for title in ["Show Big Clock Now", "Mark Where the Camera Is…", "Open Saved Replies", "Install 2.0.0 and Relaunch",
                      "Show Window Pictures in the Switcher…", "Let the Pad Read the Screen You're Replying To…", "Let RubberMAC Move Finder Windows…"] {
            check(pages.first { $0.title == title }?.closesPanel == true, "closes the panel first: \(title)")
        }
        let turnOns = pages.filter { if case .status(_, _, "Turn On…"?) = $0.control { true } else { false } }
        check(turnOns.count == 3 && turnOns.allSatisfy(\.closesPanel), "all three Turn On… buttons close the panel first")
        check(pages.first { $0.title == "Warn Before Screen Saver" }?.closesPanel == false, "a plain switch leaves it open")
        check(pages.first { $0.title == "Keep Windows Clear of the Camera" }?.closesPanel == false, "camera switch with a place marked stays open")
        var unmarked = everything
        unmarked.camera = nil
        let cameraOff = !Settings.cameraAvoid
        check(delegate.settingsPages(unmarked).flatMap(\.rows).first { $0.title == "Keep Windows Clear of the Camera" }?.closesPanel == cameraOff,
              "camera switch with nothing marked closes it, since it goes straight to marking")
        check(!SwitcherSource.regularApps().contains { $0.pid == getpid() }, "RubberMAC's own windows aren't in Alt-Tab's list of apps")
    }

    // MARK: 4. The panel, on made-up pages

    private final class Recorder: NSObject {
        var flips = 0, presses = 0
        var picked: [Int] = []
        var closedBeforeAction = false
        weak var panel: SettingsPanel?
        @objc func flip() { flips += 1 }
        @objc func press() { presses += 1; closedBeforeAction = panel?.returnsFocus == false }
        @objc func pick(_ sender: NSMenuItem) { picked.append(sender.tag) }
    }

    private final class FakeSlider: NSView, SettingsSlider {
        var isDragging = false
        var onDragEnd: (() -> Void)?
    }

    private static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? views(type, in: $0) }
    }

    private static func window(for panel: SettingsPanel, appearance: NSAppearance.Name = .aqua) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = panel.root
        return window
    }

    private static func widgetChecks(_ check: Check) {
        let recorder = Recorder()
        var state = false
        let slider = FakeSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let sparse = SettingsPage(id: "sparse", title: "Sparse", symbol: "gearshape", tint: .systemGray, sections: [
            SettingsSection(title: "Card", rows: [
                SettingsRow(title: "Needle Switch", note: nil, control: .toggle(on: false), target: recorder, action: #selector(Recorder.flip)),
            ]),
        ])
        var long = SettingsPage(id: "long", title: "Long", symbol: "keyboard", tint: .systemBlue, sections: [])
        func longRows() -> [SettingsSection] {
            let items = [(5, "Five"), (10, "Ten")].map { NSMenuItem.action($0.1, #selector(Recorder.pick(_:)), target: recorder, on: $0.0 == 10, tag: $0.0) }
            return [SettingsSection(title: "Tall", rows: (0..<40).map {
                SettingsRow(title: "Row \($0)", note: "Note of row \($0)", control: .toggle(on: state), target: recorder, action: #selector(Recorder.flip))
            } + [
                SettingsRow(title: "Choice", note: nil, control: .popup(items)),
                SettingsRow(title: "Press", note: nil, control: .button("Go", enabled: true), target: recorder, action: #selector(Recorder.press), closesPanel: true),
                SettingsRow(title: "Slider", note: nil, control: .custom(slider)),
            ])]
        }
        let panel = SettingsPanel()
        recorder.panel = panel
        var extra = false
        panel.pages = {
            long.sections = longRows()
            if extra { long.sections.append(SettingsSection(title: "New", rows: [.note("Added later")])) }
            return [sparse, long]
        }
        let window = window(for: panel)
        panel.start(on: "long")
        panel.reload()

        check(panel.shown == "long" && panel.sidebar.pages.count == 2 && panel.detail.pageTitle == "Long", "opens on the page it was told to, with both in the sidebar")
        let switches = views(NSSwitch.self, in: panel.detail)
        switches.first?.performClick(nil)
        check(recorder.flips == 1, "a switch's click fires its row's action (flips: \(recorder.flips))")

        // Scrolling survives a re-render where only a state changes, and one where a card appears.
        let scroll = panel.detail.scroll
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        scroll.reflectScrolledClipView(scroll.contentView)
        let before = scroll.contentView.bounds.minY
        let firstSwitch = views(NSSwitch.self, in: panel.detail).first
        state = true
        panel.reload()
        check(panel.shown == "long" && scroll.contentView.bounds.minY == before && before == 500,
              "re-render keeps the page and the scroll position (\(Int(scroll.contentView.bounds.minY)) of 500)")
        check(views(NSSwitch.self, in: panel.detail).first === firstSwitch, "a change of state keeps the same switch, so its animation isn't cut")
        check((views(NSSwitch.self, in: panel.detail).first?.state ?? .off) == .on, "and shows the new state")
        extra = true
        panel.reload()
        check(panel.shown == "long" && scroll.contentView.bounds.minY == before, "a re-render that adds a card keeps them too")
        extra = false
        panel.reload()

        // Popup items go through the row's own target, with the original tagged item as the sender.
        let popup = views(NSPopUpButton.self, in: panel.detail).first
        check(popup?.titleOfSelectedItem == "Ten", "a popup shows the item that's on")
        popup?.menu?.performActionForItem(at: 0)
        check(recorder.picked == [5], "a popup choice reaches its own target with its own tag (picked \(recorder.picked))")

        // A button that closes the panel does so before its action.
        let button = views(NSButton.self, in: panel.detail).first { $0.title == "Go" }
        button?.performClick(nil)
        check(recorder.presses == 1 && recorder.closedBeforeAction, "a closing row closes the panel before its action runs")
        panel.close()

        // While a slider is dragged a re-render waits, and happens when it's let go.
        let rowsBefore = panel.detail.visibleRows.first
        slider.isDragging = true
        extra = true
        panel.reload()
        check(panel.detail.visibleRows.first === rowsBefore, "no re-render during a slider drag")
        slider.isDragging = false
        slider.onDragEnd?()
        check(panel.detail.visibleRows.first !== rowsBefore, "it happens when the slider is let go")
        extra = false
        panel.reload()

        var announced: [String] = []
        panel.onShowPage = { announced.append($0) }
        panel.choose("sparse")
        panel.onShowPage = { _ in }
        check(announced == ["sparse"], "choosing a page announces it, which is what re-reads the permissions (\(announced))")

        // Search.
        panel.choose("long")
        check(panel.detail.isShowingEmptyState == false && panel.detail.visibleRows.count == 43, "before searching all 43 rows of the page show")
        panel.search(for: "needle")
        check(panel.sidebar.pages.map(\.id) == ["sparse"] && panel.detail.visibleRows.map(\.row.title) == ["Needle Switch"],
              "search keeps only the page with a match and only its matching rows (\(panel.sidebar.pages.map(\.id)))")
        panel.search(for: "NOTE OF ROW 13")
        check(panel.sidebar.pages.map(\.id) == ["long"] && panel.detail.visibleRows.map(\.row.title) == ["Row 13"], "search matches notes, in any case")
        panel.search(for: "no such setting")
        check(panel.sidebar.pages.isEmpty && panel.detail.isShowingEmptyState && panel.detail.visibleRows.isEmpty, "no match anywhere shows the empty state and an empty sidebar")
        panel.search(for: "")
        check(panel.sidebar.pages.count == 2 && panel.shown == "long" && !panel.detail.isShowingEmptyState && panel.detail.visibleRows.count == 43,
              "clearing restores every page, the chosen one and its rows")

        // Keys, handed straight to the view: no event goes anywhere near the system.
        func key(_ code: Int) -> NSEvent {
            // The character of a Hebrew layout on purpose: the panel goes by key position.
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                             characters: "כ", charactersIgnoringModifiers: "כ", isARepeat: false, keyCode: UInt16(code))!
        }
        var closed = 0
        panel.root.onClose = { closed += 1 }
        panel.root.onFind = { closed += 10 }
        check(panel.root.performKeyEquivalent(with: key(kVK_ANSI_W)) && closed == 1, "⌘W closes the panel")
        check(panel.root.performKeyEquivalent(with: key(kVK_ANSI_F)) && closed == 11, "⌘F goes to search")
        panel.root.cancelOperation(nil)
        check(closed == 12, "Esc closes the panel")

        check(!clickOpens(isShown: true, sinceClosed: 100), "clicking the icon with the panel open doesn't reopen it")
        check(!clickOpens(isShown: false, sinceClosed: 0.01), "nor when that same click has just closed it")
        check(clickOpens(isShown: false, sinceClosed: 5), "a later click opens it")

        // The page change crossfades, unless Reduce Motion is on.
        panel.root.displayIfNeeded()
        panel.detail.layer?.removeAllAnimations()
        panel.choose("sparse")
        let faded = panel.detail.layer?.animation(forKey: kCATransition) != nil
        check(faded == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "page changes crossfade, and don't under Reduce Motion (faded: \(faded))")
        _ = window
    }

    // MARK: 5. Pictures

    private static func drawChecks(_ delegate: AppDelegate, folder: URL, _ check: Check) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var facts = base()
        facts.version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.22.0"
        facts.displays = [Brightness.Display(id: 1, name: "Built-in Retina Display", hardware: false), Brightness.Display(id: 2, name: "DELL U2720Q", hardware: false)]
        facts.levels = [1: 80]
        facts.camera = CameraArea(display: "1:2:3", name: "DELL U2720Q", box: CGRect(x: 10, y: 10, width: 10, height: 10), on: CGRect(x: 0, y: 0, width: 100, height: 100))
        facts.cameraConnected = true
        facts.altTab = .windows
        facts.finderDenied = true
        facts.fixerAvailable = false
        facts.mice = ["MX Master 3", "Magic Mouse"]
        facts.setupName = "Built-in Retina Display + DELL U2720Q"
        facts.update = .available(UpdateFeed.Release(version: "2.0.0", zipURL: URL(string: "https://example.invalid/a.zip")!, pageURL: URL(string: "https://example.invalid/")!))
        facts.login = .requiresApproval
        facts.needsAccess = true
        facts.permissions = PermissionCheck(accessibility: false, screenRecording: false, finder: .off, finderUsed: true)
        facts.permissionsChecked = Date()

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let panel = SettingsPanel()
            panel.pages = { [unowned delegate] in delegate.settingsPages(facts) }
            let window = window(for: panel, appearance: appearance)
            var drawn = 0
            for page in delegate.settingsPages(facts) {
                panel.choose(page.id)
                panel.root.setFrameSize(size)
                panel.reload(resetScroll: true)
                // Tall enough for the whole page, so nothing is hidden below the fold of the picture.
                let height = max(size.height, panel.detail.neededHeight)
                panel.root.setFrameSize(NSSize(width: size.width, height: height))
                panel.reload(resetScroll: true)
                panel.root.layoutSubtreeIfNeeded()
                if save(panel, to: folder.appendingPathComponent("\(page.id)-\(name).png")) { drawn += 1 }
            }
            panel.root.setFrameSize(size)
            panel.search(for: "finder")
            _ = save(panel, to: folder.appendingPathComponent("search-finder-\(name).png"))
            panel.search(for: "no such setting")
            _ = save(panel, to: folder.appendingPathComponent("search-nothing-\(name).png"))
            panel.search(for: "")
            panel.choose("keyboard")
            _ = save(panel, to: folder.appendingPathComponent("natural-size-keyboard-\(name).png"))
            let total = delegate.settingsPages(facts).count
            check(drawn == total, "drew \(drawn) of \(total) pages in \(name) to \(folder.path)")
            _ = window
        }
    }

    // The sidebar is drawn separately: a visual effect view inside another view comes out blank when cached, and its
    // translucency needs a real window behind it anyway, so a plain colour stands in for that.
    private static func save(_ panel: SettingsPanel, to url: URL) -> Bool {
        try? FileManager.default.removeItem(at: url)
        func bitmap(_ view: NSView) -> NSBitmapImageRep? {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        guard let whole = bitmap(panel.root), let side = bitmap(panel.sidebar) else { return false }
        let composed = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: whole.pixelsWide, pixelsHigh: whole.pixelsHigh, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        composed.size = panel.root.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: composed)
        panel.root.effectiveAppearance.performAsCurrentDrawingAppearance {
            whole.draw(in: panel.root.bounds)
            NSColor.underPageBackgroundColor.setFill()
            panel.sidebar.frame.fill()
            side.draw(in: panel.sidebar.frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            NSColor.separatorColor.setFill()
            NSRect(x: panel.sidebar.frame.maxX - 0.5, y: 0, width: 0.5, height: panel.root.bounds.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        try? composed.representation(using: .png, properties: [:])?.write(to: url)
        return FileManager.default.fileExists(atPath: url.path)
    }
}
