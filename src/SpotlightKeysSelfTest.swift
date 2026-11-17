import AppKit
import Carbon.HIToolbox

// --selftest spotlightkeys: which ⌘R presses are taken, that a taken one keeps its key-up and repeats, when a ⌘ on its
// own counts as a tap, and how Spotlight's shortcut is read. Nothing opens: the handler's system side is swapped out,
// and the event counters are the test's own, so a click while it runs changes nothing.
extension SpotlightKeys {
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }

        // ⌘R
        let command = Modifiers.command | 0x08, rightCommand = Modifiers.command | 0x10
        let capsLock = CGEventFlags.maskAlphaShift.rawValue
        let editor = "com.apple.TextEdit"
        check(takesSearchKey(keyCode: kVK_ANSI_R, flags: command, app: editor), "⌘R is taken")
        check(takesSearchKey(keyCode: kVK_ANSI_R, flags: rightCommand, app: editor), "right ⌘R is taken")
        check(takesSearchKey(keyCode: kVK_ANSI_R, flags: command | capsLock, app: editor), "⌘R with Caps Lock on is taken")
        check(takesSearchKey(keyCode: kVK_ANSI_R, flags: command, app: nil), "⌘R with the front app not known yet is taken")
        let others: [(UInt64, String)] = [(command | Modifiers.shift, "⌘⇧R"), (command | Modifiers.control, "⌃⌘R"),
                                          (command | Modifiers.option, "⌥⌘R"), (0, "plain R"), (Modifiers.control, "⌃R")]
        for (flags, name) in others {
            check(!takesSearchKey(keyCode: kVK_ANSI_R, flags: flags, app: editor), "\(name) is left to the app")
        }
        check(!takesSearchKey(keyCode: kVK_ANSI_T, flags: command, app: editor), "⌘T is left to the app")
        let remoteKept = AppLists.remote.filter { takesSearchKey(keyCode: kVK_ANSI_R, flags: command, app: $0) }
        check(remoteKept.isEmpty, "⌘R is left to all \(AppLists.remote.count) remote desktops and VMs"
              + (remoteKept.isEmpty ? "" : "; taken in: " + remoteKept.sorted().joined(separator: ", ")))

        // The handler, with its system side swapped out.
        let handler = SpotlightKeys()
        handler.searchKeyEnabled = true
        handler.appsKeyEnabled = true
        var searches: [Spotlight.Shortcut] = [], offs = 0, apps = 0, unseen = 0
        var counters = CommandTap.Counters(keyDowns: 100, clicks: 200, scrolls: 300)
        var shortcut: Spotlight.Shortcut? = Spotlight.defaultShortcut
        var front: String? = editor
        var secure = false
        handler.onSearch = { searches.append($0) }
        handler.onSearchOff = { offs += 1 }
        handler.onApps = { apps += 1 }
        handler.onAppsUnseen = { unseen += 1 }
        handler.secureInput = { secure }
        handler.counters = { counters }
        handler.searchShortcut = { shortcut }
        handler.frontmost = { front }
        func reset() {
            searches = []; offs = 0; apps = 0; unseen = 0
        }
        func key(_ code: Int, _ down: Bool, _ flags: UInt64, repeating: Bool = false) -> CGEvent? {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
            event.flags = CGEventFlags(rawValue: flags | 0x100)
            if repeating { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            return handler.handle(down ? .keyDown : .keyUp, event)
        }
        // A modifier key going down or up, leaving `flags` held. Returns whether the event was passed on.
        func modifier(_ code: Int, _ down: Bool, _ flags: UInt64) -> Bool {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
            event.type = .flagsChanged
            event.flags = CGEventFlags(rawValue: flags | 0x100)
            return handler.handle(.flagsChanged, event) != nil
        }

        reset()
        let pressed = [key(kVK_ANSI_R, true, command), key(kVK_ANSI_R, true, command, repeating: true),
                       key(kVK_ANSI_R, true, 0, repeating: true), key(kVK_ANSI_R, false, 0)]
        pump()
        check(pressed.allSatisfy { $0 == nil } && searches == [Spotlight.defaultShortcut],
              "⌘R, its repeats (also once ⌘ is let go) and its key-up are all taken, and open the search once (\(searches.count))")
        check(key(kVK_ANSI_R, false, command) != nil, "an R key-up with no taken press before it is passed on")
        reset()
        let shifted = [key(kVK_ANSI_R, true, command | Modifiers.shift), key(kVK_ANSI_R, false, command | Modifiers.shift)]
        pump()
        check(shifted.allSatisfy { $0 != nil } && searches.isEmpty, "⌘⇧R goes to the app, key-down and key-up")
        reset()
        let typed = [key(kVK_ANSI_R, true, 0), key(kVK_ANSI_R, true, 0, repeating: true), key(kVK_ANSI_R, false, 0)]
        pump()
        check(typed.allSatisfy { $0 != nil } && searches.isEmpty, "a typed r and its repeats go to the app")

        reset()
        front = "com.microsoft.rdc.macos"
        let remote = [key(kVK_ANSI_R, true, command), key(kVK_ANSI_R, false, command)]
        pump()
        check(remote.allSatisfy { $0 != nil } && searches.isEmpty, "in Windows App (remote desktop) ⌘R goes through, key-down and key-up")
        front = editor

        reset()
        shortcut = nil
        let off = [key(kVK_ANSI_R, true, command), key(kVK_ANSI_R, false, command)]
        pump()
        check(off.allSatisfy { $0 != nil } && searches.isEmpty && offs == 1,
              "with Spotlight's shortcut off, ⌘R goes to the app and the log says why once (\(offs))")
        shortcut = Spotlight.Shortcut(keyCode: kVK_Space, flags: .maskAlternate)
        reset()
        _ = [key(kVK_ANSI_R, true, command), key(kVK_ANSI_R, false, command)]
        pump()
        check(searches == [Spotlight.Shortcut(keyCode: kVK_Space, flags: .maskAlternate)], "⌘R presses whatever Spotlight's shortcut is (⌥Space here)")
        shortcut = Spotlight.defaultShortcut

        // ⌘ on its own.
        func tap(_ steps: () -> Void) -> Int {
            reset()
            steps()
            pump()
            return apps
        }
        var passed = true
        check(tap { passed = modifier(kVK_Command, true, command) && modifier(kVK_Command, false, 0) } == 1 && passed,
              "⌘ pressed and let go opens Apps once, and both its events are passed on")
        check(tap { _ = modifier(kVK_RightCommand, true, rightCommand); _ = modifier(kVK_RightCommand, false, 0) } == 1,
              "right ⌘ on its own opens Apps")
        check(tap {
            _ = modifier(kVK_Command, true, command); _ = modifier(kVK_RightCommand, true, command | 0x10)
            _ = modifier(kVK_RightCommand, false, command); _ = modifier(kVK_Command, false, 0)
        } == 1, "both ⌘ keys together, nothing else, open Apps once")
        check(tap {
            _ = modifier(kVK_Command, true, command); _ = key(kVK_ANSI_T, true, command); _ = key(kVK_ANSI_T, false, command)
            _ = modifier(kVK_Command, false, 0)
        } == 0, "⌘T: a key in between, no Apps")
        check(tap {
            _ = modifier(kVK_Command, true, command); _ = modifier(kVK_Shift, true, command | Modifiers.shift | 0x02)
            _ = modifier(kVK_Shift, false, command); _ = modifier(kVK_Command, false, 0)
        } == 0, "⌘ then ⇧, let go without a key: another modifier joined, no Apps")
        check(tap {
            _ = modifier(kVK_Shift, true, Modifiers.shift | 0x02); _ = modifier(kVK_Command, true, command | Modifiers.shift | 0x02)
            _ = modifier(kVK_Shift, false, command); _ = modifier(kVK_Command, false, 0)
        } == 0, "⇧ first, then ⌘, ⇧ let go first: ⌘ wasn't alone from its press, no Apps")
        check(tap { _ = modifier(kVK_Option, true, Modifiers.option | 0x20); _ = modifier(kVK_Option, false, 0) } == 0,
              "⌥ on its own doesn't open Apps")
        check(tap {
            _ = modifier(kVK_Command, true, command); counters.clicks &+= 1; _ = modifier(kVK_Command, false, 0)
        } == 0, "⌘-click: a click in between, no Apps")
        check(tap {
            _ = modifier(kVK_Command, true, command); counters.scrolls &+= 1; _ = modifier(kVK_Command, false, 0)
        } == 0, "⌘-scroll: a scroll in between, no Apps")
        check(tap {
            _ = modifier(kVK_Command, true, command); counters.keyDowns &+= 1; _ = modifier(kVK_Command, false, 0)
        } == 0, "a ⌘ key another handler swallowed (seen only in the system's key count), no Apps")
        counters.clicks = .max
        check(tap {
            _ = modifier(kVK_Command, true, command); counters.clicks &+= 1; _ = modifier(kVK_Command, false, 0)
        } == 0, "a click that wraps the counter around still counts")
        check(tap { _ = modifier(kVK_Command, true, command); _ = modifier(kVK_Command, false, 0) } == 1,
              "after all that, a plain ⌘ tap opens Apps again")
        check(tap {
            _ = modifier(kVK_Command, true, command); _ = key(kVK_ANSI_R, true, command); _ = key(kVK_ANSI_R, false, command)
            _ = modifier(kVK_Command, false, 0)
        } == 0 && searches.count == 1, "⌘R opens the search only, not Apps as well")
        check(tap { _ = modifier(kVK_Command, true, command); handler.tapWasDisabled(); _ = modifier(kVK_Command, false, 0) } == 0,
              "a ⌘ whose press went by while the tap was off doesn't count")
        front = "com.vmware.fusion"
        check(tap { _ = modifier(kVK_Command, true, command); _ = modifier(kVK_Command, false, 0) } == 0, "in VMware Fusion a ⌘ tap opens nothing")
        front = editor
        secure = true
        check(tap { _ = modifier(kVK_Command, true, command); _ = modifier(kVK_Command, false, 0) } == 0 && unseen == 1,
              "with Secure Input on (⌘← looks like ⌘ alone then) a ⌘ tap opens nothing and the log says why")
        secure = false
        check(tap { _ = modifier(kVK_Command, true, command); _ = modifier(kVK_Command, false, 0) } == 1 && unseen == 0,
              "with Secure Input off again, a ⌘ tap opens Apps")

        // Off.
        let inert = SpotlightKeys()
        var inertCalls = 0
        inert.onSearch = { _ in inertCalls += 1 }
        inert.onApps = { inertCalls += 1 }
        inert.onSearchOff = { inertCalls += 1 }
        inert.onAppsUnseen = { inertCalls += 1 }
        inert.secureInput = { false }
        inert.counters = { counters }
        inert.searchShortcut = { shortcut }
        inert.frontmost = { front }
        func feed(_ handler: SpotlightKeys) -> Bool {
            func modifier(_ code: Int, _ down: Bool, _ flags: UInt64) -> CGEvent? {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
                event.type = .flagsChanged
                event.flags = CGEventFlags(rawValue: flags)
                return handler.handle(.flagsChanged, event)
            }
            func key(_ down: Bool) -> CGEvent? {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_R), keyDown: down)!
                event.flags = CGEventFlags(rawValue: command)
                return handler.handle(down ? .keyDown : .keyUp, event)
            }
            let results = [modifier(kVK_Command, true, command), modifier(kVK_Command, false, 0),
                           modifier(kVK_Command, true, command), key(true), key(false), modifier(kVK_Command, false, 0)]
            pump()
            return results.allSatisfy { $0 != nil }
        }
        check(!inert.isActive && feed(inert) && inertCalls == 0, "with both off it isn't active, passes everything on and opens nothing")
        inert.searchKeyEnabled = true
        check(inert.isActive && !feed(inert) && inertCalls == 1, "with only ⌘R on, a ⌘ tap opens nothing (only the search: \(inertCalls))")
        inert.searchKeyEnabled = false
        inert.appsKeyEnabled = true
        inertCalls = 0
        check(inert.isActive && feed(inert) && inertCalls == 1, "with only ⌘ on, ⌘R goes to the app (only the ⌘ tap: \(inertCalls))")

        // Spotlight's shortcut, as the system stores it.
        func entry(enabled: Any, _ parameters: [Any]) -> [String: Any] {
            ["64": ["enabled": enabled, "value": ["parameters": parameters, "type": "standard"]]]
        }
        let optionSpace = Spotlight.Shortcut(keyCode: kVK_Space, flags: .maskAlternate)
        check(Spotlight.shortcut(in: nil) == Spotlight.defaultShortcut, "no list of shortcuts at all: ⌘Space")
        check(Spotlight.shortcut(in: ["60": ["enabled": true]]) == Spotlight.defaultShortcut, "a list without Spotlight's: ⌘Space")
        check(Spotlight.shortcut(in: entry(enabled: "1", ["32", "49", "1048576"])) == Spotlight.defaultShortcut,
              "written as strings, as on this Mac: ⌘Space")
        check(Spotlight.shortcut(in: entry(enabled: true, [32, 49, 1_048_576])) == Spotlight.defaultShortcut, "written as numbers: ⌘Space")
        check(Spotlight.shortcut(in: entry(enabled: 1, [32, 49, 524_288])) == optionSpace, "changed to ⌥Space: ⌥Space")
        for (enabled, name) in [("0" as Any, "\"0\""), (false as Any, "false"), (0 as Any, "0")] {
            check(Spotlight.shortcut(in: entry(enabled: enabled, [32, 49, 1_048_576])) == nil, "turned off (enabled = \(name)): none")
        }
        check(Spotlight.shortcut(in: entry(enabled: true, [65535, 65535, 0])) == nil, "no key set: none")
        let system = Spotlight.systemHotKeys()
        let read = Spotlight.shortcut(in: system)
        check(system?["64"] != nil, "this Mac's list of shortcuts is read and has Spotlight's in it ("
              + (read.map { "key \($0.keyCode), flags \(String($0.flags.rawValue, radix: 16))" } ?? "turned off") + ")")

        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }
}
