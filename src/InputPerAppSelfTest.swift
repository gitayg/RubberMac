import AppKit
import Carbon.HIToolbox

// --selftest inputperapp: which language each app gets and which switches are remembered for it, what a search puts
// back, the ⌘Space handler, when a Spotlight search counts as over, the scratch file it's kept in, which English layout
// search picks, and the two rows on the Keyboard page. The system's side is made up throughout: the real input source
// is only read, never switched, and the real input-per-app.json is left alone.
extension InputPerApp {
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        let realBefore = try? Data(contentsOf: InputPerAppStore.defaultURL)
        let realSource = InputSources.currentID()

        modelChecks(check)
        searchChecks(check)
        keyChecks(check)
        watchChecks(check)
        lines.append("     Spotlight is \(Spotlight.isOpen() ? "up" : "not up") now, read from its windows")
        storeChecks(check)
        englishChecks(check) { lines.append("     " + $0) }
        settingsChecks(check)

        check(InputSources.currentID() == realSource, "the real input source is still \(realSource)")
        check((try? Data(contentsOf: InputPerAppStore.defaultURL)) == realBefore,
              "the real input-per-app.json is as it was (\(realBefore.map { "\($0.count) bytes" } ?? "not there"))")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    private typealias Check = (Bool, String) -> Void

    // A pretend Mac with U.S., Hebrew and ABC enabled.
    private final class FakeSystem {
        var current = "US"
        var enabled = ["US", "Hebrew", "ABC"]
        var english: String? = "US"
        var selects: [String] = []
        var saves: [[String: String]] = []

        // A switch by the user: Alt-Shift, the menu-bar picker, ⌃Space. Its notice comes later.
        func userSwitch(_ id: String) { current = id }

        func model(memory: [String: String] = [:], front: String? = "com.apple.TextEdit") -> InputPerAppModel {
            InputPerAppModel(system: .init(current: { self.current },
                                           select: { id in
                                               self.selects.append(id)
                                               if self.enabled.contains(id) { self.current = id }
                                               return self.current
                                           },
                                           english: { self.english }, save: { self.saves.append($0) }),
                             memory: memory, ownBundleID: "app.rubbermac.RubberMAC", front: front)
        }
    }

    private static let edit = "com.apple.TextEdit", mail = "com.apple.mail", notes = "com.apple.Notes"

    private static func modelChecks(_ check: Check) {
        let mac = FakeSystem()
        let model = mac.model()
        model.activated(mail)
        check(mac.selects.isEmpty && mac.current == "US", "an app never seen keeps whatever is current (U.S.)")
        mac.userSwitch("Hebrew")
        model.sourceChanged()
        check(model.memory == [mail: "Hebrew"] && mac.saves.last == [mail: "Hebrew"], "a switch in Mail is remembered for Mail, and saved")
        model.sourceChanged()
        check(mac.saves.count == 1, "a second notice for the same switch changes nothing (\(mac.saves.count) save)")
        model.activated(edit)
        check(mac.selects.isEmpty && mac.current == "Hebrew", "TextEdit, never seen, keeps Hebrew")
        mac.userSwitch("US")
        model.sourceChanged()
        check(model.memory == [mail: "Hebrew", edit: "US"], "a switch in TextEdit is remembered for TextEdit")
        model.activated(mail)
        check(mac.selects == ["Hebrew"] && mac.current == "Hebrew", "back in Mail, its Hebrew is selected")
        model.sourceChanged()
        check(model.memory == [mail: "Hebrew", edit: "US"] && mac.saves.count == 2, "the notice of that switch, RubberMAC's own, changes nothing")
        model.activated(edit)
        check(mac.selects == ["Hebrew", "US"], "back in TextEdit, its U.S. is selected")

        // The notice of RubberMAC's own switch for Mail arrives only once Notes, never seen, is in front.
        mac.selects = []
        model.activated(mail)
        model.activated(notes)
        model.sourceChanged()
        check(model.memory[notes] == nil && mac.current == "Hebrew", "a late notice of the switch made for Mail isn't pinned on Notes")
        // A switch the user made just before switching apps, its notice not in yet, belongs to the app it was made in.
        mac.userSwitch("ABC")
        model.activated(edit)
        check(model.memory[notes] == "ABC" && mac.current == "US", "a switch whose notice comes after the next app is in front goes to the app it was made in")

        mac.selects = []
        model.activated("app.rubbermac.RubberMAC")
        mac.userSwitch("Hebrew")
        model.sourceChanged()
        model.activated("com.apple.Siri")
        model.activated("com.apple.apps.launcher")
        check(model.memory["app.rubbermac.RubberMAC"] == nil && model.memory[edit] == "US" && model.app == edit && mac.selects.isEmpty,
              "RubberMAC's panels, Spotlight and its Apps view get no language, and a switch while they're in front is nobody's")

        mac.current = "US"
        let gone = mac.model(memory: [mail: "Gone"], front: edit)
        gone.activated(mail)
        check(mac.current == "US" && gone.memory[mail] == "Gone", "a remembered language that's no longer enabled is asked for, and nothing changes")

        let off = mac.model(memory: [mail: "Hebrew"], front: edit)
        off.perApp = false
        mac.selects = []
        off.activated(mail)
        mac.userSwitch("ABC")
        off.sourceChanged()
        check(mac.selects.isEmpty && off.memory == [mail: "Hebrew"], "with the switch off, no app gets a language and nothing is remembered")
        off.perApp = true
        mac.userSwitch("US")
        off.sourceChanged()
        check(off.memory[mail] == "US", "turned back on, it remembers from the next switch")
    }

    private static func searchChecks(_ check: Check) {
        let mac = FakeSystem()
        mac.current = "Hebrew"
        let model = mac.model(memory: [edit: "Hebrew"], front: edit)
        model.searchStarted()
        check(mac.current == "US" && model.search?.app == edit && model.search?.source == "Hebrew", "a search over TextEdit (Hebrew) starts in U.S.")
        model.sourceChanged()
        check(model.memory[edit] == "Hebrew", "the notice of that switch isn't remembered for TextEdit")
        mac.selects = []
        model.searchStarted()
        check(mac.selects.isEmpty && model.search?.source == "Hebrew", "a second start (⌘Space again) keeps what to put back")
        mac.userSwitch("ABC")
        model.sourceChanged()
        model.activated("com.apple.Siri")
        check(model.memory[edit] == "Hebrew" && model.search != nil, "a switch made in the search is the search's, not TextEdit's")
        model.searchEnded()
        check(model.search == nil && mac.current == "Hebrew" && model.memory[edit] == "Hebrew", "closed with TextEdit still the app: its Hebrew comes back")
        model.searchEnded()
        check(mac.current == "Hebrew", "a second end changes nothing")

        mac.current = "Hebrew"
        let back = mac.model(memory: [:], front: edit)
        back.searchStarted()
        back.activated("com.apple.Siri")
        back.activated(edit)
        check(back.search == nil && mac.current == "Hebrew", "Spotlight closing with TextEdit coming back to the front ends the search, Hebrew back")

        mac.current = "Hebrew"
        let unseen = mac.model(memory: [:], front: edit)
        unseen.searchStarted()
        unseen.sourceChanged()
        unseen.searchEnded()
        unseen.sourceChanged()
        check(mac.current == "Hebrew" && unseen.memory.isEmpty,
              "over an app never switched in, Hebrew comes back, and the notice of putting it back isn't taken for the app's choice")

        mac.current = "Hebrew"
        let away = mac.model(memory: [mail: "ABC"], front: edit)
        away.searchStarted()
        away.activated(mail)
        check(away.search == nil && mac.current == "ABC", "an app opened from the search gets its own language, and nothing is put back")
        away.searchEnded()
        check(mac.current == "ABC", "the end of that search, coming later, changes nothing")
        mac.current = "Hebrew"
        let fresh = mac.model(memory: [:], front: edit)
        fresh.searchStarted()
        fresh.activated(notes)
        check(mac.current == "US" && fresh.memory[notes] == nil, "an app never seen, opened from the search, keeps English")

        mac.current = "US"
        let english = mac.model(memory: [:], front: edit)
        mac.selects = []
        english.searchStarted()
        mac.userSwitch("Hebrew")
        english.searchEnded()
        check(mac.selects == ["US"] && mac.current == "US", "started in English: nothing to switch, and a Hebrew search ends back in English")

        mac.current = "Hebrew"
        mac.english = nil
        let none = mac.model(memory: [:], front: edit)
        none.searchStarted()
        check(mac.current == "Hebrew", "with no English layout enabled, a search leaves the language as it is")
        mac.english = "US"

        let off = mac.model(memory: [:], front: edit)
        off.searchEnglish = false
        mac.selects = []
        off.searchStarted()
        check(mac.selects.isEmpty && off.search == nil, "with the switch off, a search changes nothing")

        mac.current = "Hebrew"
        let perAppOff = mac.model(memory: [:], front: edit)
        perAppOff.perApp = false
        perAppOff.searchStarted()
        perAppOff.searchEnded()
        check(mac.current == "Hebrew", "search in English works with Each App Keeps Its Own Language off")
    }

    private static func keyChecks(_ check: Check) {
        func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        let handler = InputPerAppKeys()
        var presses = 0, closing: [Bool] = []
        var front: String? = edit
        var open = false
        handler.onShortcut = { presses += 1; closing.append($0) }
        handler.frontmost = { front }
        handler.spotlightOpen = { open }
        let command = Modifiers.command | 0x08
        func key(_ code: Int, _ down: Bool, _ flags: UInt64, repeating: Bool = false) -> (passed: Bool, presses: Int) {
            presses = 0
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
            event.flags = CGEventFlags(rawValue: flags | 0x100)
            if repeating { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            let passed = handler.handle(down ? .keyDown : .keyUp, event) === event
            pump()
            return (passed, presses)
        }

        check(!handler.isActive && key(kVK_Space, true, command).presses == 0, "off until set: not active, ⌘Space does nothing")
        handler.set(enabled: true, shortcut: Spotlight.defaultShortcut)
        check(handler.isActive, "on once set")
        let pressed = key(kVK_Space, true, command)
        check(pressed.passed && pressed.presses == 1 && closing == [false], "⌘Space switches once and goes on to Spotlight untouched")
        open = true
        closing = []
        let closer = key(kVK_Space, true, command)
        check(closer.passed && closing == [true], "⌘Space with Spotlight already up is told it closes it, read as the key went by")
        open = false
        check(key(kVK_Space, true, Modifiers.command | 0x10).presses == 1, "right ⌘Space too")
        check(key(kVK_Space, true, command | CGEventFlags.maskAlphaShift.rawValue).presses == 1, "with Caps Lock on too")
        let up = key(kVK_Space, false, command), held = key(kVK_Space, true, command, repeating: true)
        check(up.passed && up.presses == 0 && held.passed && held.presses == 0, "its key-up and repeats go by without switching again")
        let others: [(Int, UInt64, String)] = [(kVK_Space, 0, "Space"), (kVK_Space, Modifiers.control | 0x01, "⌃Space (the system's language switch)"),
                                               (kVK_Space, Modifiers.option | 0x20, "⌥Space"), (kVK_Space, command | Modifiers.shift, "⌘⇧Space (the writing pad)"),
                                               (kVK_Space, command | Modifiers.option, "⌥⌘Space (Finder search)"), (kVK_ANSI_R, command, "⌘R")]
        for (code, flags, name) in others {
            let result = key(code, true, flags)
            check(result.passed && result.presses == 0, "\(name) goes by without switching")
        }
        front = "com.microsoft.rdc.macos"
        let remote = key(kVK_Space, true, command)
        check(remote.passed && remote.presses == 0, "in Windows App (remote desktop) ⌘Space goes by without switching")
        front = edit
        handler.set(enabled: true, shortcut: Spotlight.Shortcut(keyCode: kVK_Space, flags: .maskAlternate))
        check(key(kVK_Space, true, Modifiers.option | 0x20).presses == 1 && key(kVK_Space, true, command).presses == 0,
              "with Spotlight's shortcut changed to ⌥Space, ⌥Space switches and ⌘Space doesn't")
        let f5 = Spotlight.Shortcut(keyCode: kVK_F5, flags: .maskSecondaryFn)
        handler.set(enabled: true, shortcut: f5)
        check(key(kVK_F5, true, CGEventFlags.maskSecondaryFn.rawValue).presses == 1 && key(kVK_F5, true, 0).presses == 0,
              "a shortcut on F5 (it carries Fn, as F5's press does) is seen")
        handler.set(enabled: true, shortcut: nil)
        check(key(kVK_Space, true, command).presses == 0, "with Spotlight's shortcut off, nothing")
        handler.set(enabled: false, shortcut: Spotlight.defaultShortcut)
        let off = key(kVK_Space, true, command)
        check(!handler.isActive && off.passed && off.presses == 0, "turned off: not active, ⌘Space does nothing")
        let flags = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Command), keyDown: true)!
        flags.type = .flagsChanged
        handler.set(enabled: true, shortcut: Spotlight.defaultShortcut)
        check(handler.handle(.flagsChanged, flags) === flags, "a modifier going down goes by")
    }

    private static func watchChecks(_ check: Check) {
        let start = Date()
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
        var watch = SpotlightWatch(started: start)
        let steps = [(0.25, false), (0.5, true), (1.5, true), (4, true), (4.25, false)].map { watch.ended(open: $0.1, now: at($0.0)) }
        check(steps == [false, false, false, false, true], "comes up after 0.5 s, stays past the 3 s wait, over only once it's gone (\(steps))")
        var never = SpotlightWatch(started: start)
        let waiting = [0.25, 1, 2.75, 3.25].map { never.ended(open: false, now: at($0)) }
        check(waiting == [false, false, false, true], "never comes up: over after 3 s (\(waiting))")
        var already = SpotlightWatch(started: start)
        check(!already.ended(open: true, now: at(0.25)) && already.ended(open: false, now: at(0.5)), "up at the first look, over at the first look it's gone")
    }

    private static func storeChecks(_ check: Check) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("inputperapp-selftest-\(getpid())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ScreenTools/input-per-app.json")
        check(InputPerAppStore.load(url).isEmpty, "no file yet: nothing remembered")
        let memory = [edit: "com.apple.keylayout.Hebrew-PC", mail: "com.apple.keylayout.US"]
        InputPerAppStore.save(memory, to: url)
        check(InputPerAppStore.load(url) == memory, "saved to a scratch file (its folder made) and read back the same")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(text.contains("\"com.apple.TextEdit\" : \"com.apple.keylayout.Hebrew-PC\""), "the file is plain JSON, bundle ID to input source")
        try? Data("not json".utf8).write(to: url)
        check(InputPerAppStore.load(url).isEmpty, "a damaged file reads as nothing remembered")
        check(InputPerAppStore.defaultURL.path.hasSuffix("Library/Application Support/ScreenTools/input-per-app.json"),
              "the real one goes in RubberMAC's data folder: \(InputPerAppStore.defaultURL.path)")
    }

    private static func englishChecks(_ check: Check, _ note: (String) -> Void) {
        check(InputSources.pickEnglish(layouts: ["com.apple.keylayout.ABC", "com.apple.keylayout.British"], recent: "com.apple.keylayout.British")
              == "com.apple.keylayout.British", "the English layout used last wins (British over ABC)")
        check(InputSources.pickEnglish(layouts: ["com.apple.keylayout.ABC"], recent: "com.apple.keylayout.US") == "com.apple.keylayout.ABC",
              "one used last but no longer enabled: the first enabled one")
        check(InputSources.pickEnglish(layouts: [], recent: "com.apple.keylayout.US") == nil, "none enabled: none")
        let sources = InputSources.keyboards()
        let english = InputSources.english()
        let described = sources.map { "\(InputSources.id($0))\(InputSources.isEnglishLayout($0) ? " (English)" : "")" }
        note("enabled on this Mac: \(described.joined(separator: ", "))")
        check(english.map { id in sources.contains { InputSources.id($0) == id && InputSources.isEnglishLayout($0) } } ?? sources.allSatisfy { !InputSources.isEnglishLayout($0) },
              "search here would start in \(english ?? "nothing (no English layout enabled)")")
    }

    private static func settingsChecks(_ check: Check) {
        let stored = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
        let unset = ["inputPerAppEnabled", "inputSearchEnglishEnabled"].filter { stored?[$0] == nil }
        if unset.count == 2 {
            check(Settings.inputPerAppEnabled && Settings.inputSearchEnglishEnabled, "both are on until switched off")
        }
        let delegate = AppDelegate(lockWarning: LockWarning(timeoutOverride: nil))
        var facts = SettingsFacts()
        let rows = delegate.inputPerAppRows(facts)
        check(rows.map(\.title) == ["Each App Keeps Its Own Language", "Spotlight and Start Open in English"]
              && rows.map(\.note) == ["Switch in an app and it's that app's language next time too",
                                      "Search starts in English; the app gets its language back after"],
              "the Keyboard page's two rows: \(rows.map(\.title))")
        check(rows.allSatisfy { row in row.action.map { (row.target as AnyObject?)?.responds(to: $0) == true } ?? false },
              "each row's switch reaches an action that answers it")
        facts.permissions = PermissionCheck(accessibility: false, screenRecording: true, finder: .on, finderUsed: true)
        let noAccess = delegate.inputPerAppRows(facts)
        check(!noAccess[0].closesPanel && noAccess[1].closesPanel,
              "without Accessibility only the search one closes the panel for macOS's question (it needs the keyboard tap)")
        InputPerApp.shared.searchOn = { false }
        check(!InputPerApp.shared.wantsAccess, "turned off, it doesn't ask for Accessibility")
        InputPerApp.shared.searchOn = { true }
        check(InputPerApp.shared.wantsAccess, "on, it does")
        InputPerApp.shared.searchOn = { Settings.inputSearchEnglishEnabled }
        check(rows.allSatisfy { if case .toggle = $0.control { true } else { false } }, "each is a switch")
    }
}
