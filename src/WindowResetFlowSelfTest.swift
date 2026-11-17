import AppKit

// The forget flow with stand-ins, defaults itself on a scratch file, and the settings rows: part of --selftest windowreset.
enum WindowResetFlowSelfTest {
    typealias Check = WindowResetSelfTest.Check

    // An app, its preferences and its saved windows, made up. Records each step the flow takes.
    private final class Stage {
        var calls: [String] = []
        var domains: [String: [String]]
        var open: [pid_t] = [41]
        var quits = WindowResetForget.Quit.quit
        var unreadable: Set<String> = []
        var undeletable: Set<String> = []
        var trashResult = WindowResetForget.Trashed.moved(URL(fileURLWithPath: "/Users/test/.Trash/com.example.alpha.savedState"))

        init(_ domains: [String: [String]]) { self.domains = domains }

        var steps: WindowResetForget.Steps {
            WindowResetForget.Steps(
                running: { [self] in calls.append("running \($0)"); return open },
                quit: { [self] pids in
                    calls.append("quit \(pids)")
                    // On its way out the app saves where its window was, as AppKit does.
                    if quits == .quit { domains["com.example.alpha", default: []].append("NSWindow Frame Written On Quit") }
                    return quits
                },
                keys: { [self] domain in
                    calls.append("keys \(domain)")
                    return unreadable.contains(domain) ? nil : domains[domain] ?? []
                },
                delete: { [self] domain, key in
                    calls.append("delete \(key)")
                    guard !undeletable.contains(key) else { return false }
                    domains[domain]?.removeAll { $0 == key }
                    return true
                },
                trash: { [self] url in calls.append("trash \(url.lastPathComponent)"); return trashResult },
                reopen: { [self] url in calls.append("reopen \(url.lastPathComponent)") })
        }
    }

    static func forgetChecks(_ check: Check) {
        let container = URL(fileURLWithPath: "/Users/test/Library/Containers/com.example.alpha/Data/Library/Preferences/com.example.alpha")
        let app = WindowResetSavedFrames.App(bundleID: "com.example.alpha", name: "Alpha", url: URL(fileURLWithPath: "/Applications/Alpha.app"),
                                             keys: ["NSWindow Frame Main"], container: container, containerKeys: ["NSWindow Frame Box"],
                                             savedState: URL(fileURLWithPath: "/Users/test/Library/Saved Application State/com.example.alpha.savedState"),
                                             hasSavedState: true)
        func stage() -> Stage {
            Stage(["com.example.alpha": ["NSWindow Frame Main", "NSSplitView Subview Frames Side", "NSToolbar Configuration Main", "Other"],
                   container.path: ["NSWindow Frame Box", "Keep"]])
        }

        let full = stage()
        let done = WindowResetForget.run(app, full.steps)
        check(full.calls == ["running com.example.alpha", "quit [41]", "keys com.example.alpha", "delete NSWindow Frame Main",
                             "delete NSSplitView Subview Frames Side", "delete NSWindow Frame Written On Quit", "keys \(container.path)",
                             "delete NSWindow Frame Box", "trash com.example.alpha.savedState", "reopen Alpha.app"],
              "open: quits it, reads its keys again after it quit, deletes the frames, trashes its saved windows, opens it again: "
              + full.calls.joined(separator: " → "))
        check(full.domains["com.example.alpha"] == ["NSToolbar Configuration Main", "Other"] && full.domains[container.path] == ["Keep"],
              "every other key stays, in its preferences and its container's")
        check(done == WindowResetForget.Outcome(removed: 4, trashed: full.trashResult, reopened: true)
              && done.note("Alpha") == "Forgot Alpha's window sizes and opened it again", "and says so: \(done.note("Alpha"))")
        check(done.logLine("Alpha") == "window reset: Alpha forgot 4 window frames, its saved windows went to the Trash, opened again",
              "the log names the app, not its windows or keys: \(done.logLine("Alpha"))")

        let refusing = stage()
        refusing.quits = .stillOpen
        let refused = WindowResetForget.run(app, refusing.steps)
        check(refusing.calls == ["running com.example.alpha", "quit [41]"] && refusing.domains == stage().domains
              && refused == WindowResetForget.Outcome(quit: .stillOpen), "an app that doesn't quit: it stops there, nothing deleted, trashed or reopened")
        check(refused.note("Alpha") == "Alpha didn't quit, so nothing was forgotten; it may be asking about unsaved work"
              && refused.logLine("Alpha") == "window reset: Alpha didn't quit; nothing forgotten", "and says so: \(refused.note("Alpha"))")
        let forbidden = stage()
        forbidden.quits = .notAllowed
        let notAllowed = WindowResetForget.run(app, forbidden.steps)
        check(forbidden.calls == ["running com.example.alpha", "quit [41]"] && forbidden.domains == stage().domains
              && notAllowed == WindowResetForget.Outcome(quit: .notAllowed)
              && notAllowed.note("Alpha") == "macOS didn't let RubberMAC quit Alpha, so nothing was forgotten; allow it in Privacy & Security › Automation",
              "macOS not letting RubberMAC quit it: it stops there too, and says what macOS needs: \(notAllowed.note("Alpha"))")

        let closed = stage()
        closed.open = []
        let quiet = WindowResetForget.run(app, closed.steps)
        check(!closed.calls.contains { $0.hasPrefix("quit") || $0.hasPrefix("reopen") } && quiet.removed == 3
              && quiet.note("Alpha") == "Forgot Alpha's window sizes", "not open: nothing to quit or open again: \(quiet.note("Alpha"))")

        let partly = stage()
        partly.undeletable = ["NSSplitView Subview Frames Side"]
        partly.unreadable = [container.path]
        let some = WindowResetForget.run(app, partly.steps)
        check(some.removed == 2 && some.failed == 2 && some.note("Alpha") == "Forgot some of Alpha's window sizes; the rest couldn't be removed",
              "a key defaults won't delete and a container it can't read: counted, and said: \(some.note("Alpha"))")

        let nothing = Stage([:])
        nothing.open = []
        nothing.trashResult = .absent
        let none = WindowResetForget.run(app, nothing.steps)
        check(none == WindowResetForget.Outcome() && none.note("Alpha") == "Alpha had no window sizes left to forget",
              "nothing left to forget: \(none.note("Alpha"))")
        let stuck = stage()
        stuck.trashResult = .failed
        check(WindowResetForget.run(app, stuck.steps).note("Alpha").hasPrefix("Forgot some"), "saved windows that won't go to the Trash: said")

        let open = WindowResetForget.confirmation(for: app, isOpen: true)
        check(open.messageText == "Quit Alpha, forget where its windows were and how big, and open it again?"
              && open.informativeText.contains("won't come back") && open.buttons.map(\.title) == ["Quit and Forget", "Cancel"],
              "the question for an open app names it and says its windows won't come back: \(open.messageText)")
        let shut = WindowResetForget.confirmation(for: app, isOpen: false)
        check(shut.messageText == "Forget where Alpha's windows were and how big?" && shut.informativeText.contains("don't come back")
              && shut.buttons.map(\.title) == ["Forget", "Cancel"], "and for a closed one: \(shut.messageText)")
    }

    // The real keys and delete steps, through /usr/bin/defaults, on a scratch file.
    static func defaultsChecks(_ scratch: URL, _ check: Check) {
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let domain = scratch.appendingPathComponent("app.rubbermac.selftest.windowreset.unit").path
        let real = WindowResetForget.Steps.real()
        _ = WindowResetForget.Steps.defaults(["write", domain, "NSWindow Frame Main", "-string", "100 200 800 600 0 0 1920 1055 "])
        _ = WindowResetForget.Steps.defaults(["write", domain, "NSSplitView Subview Frames Side", "-array", "0 0 200 600 NO NO"])
        _ = WindowResetForget.Steps.defaults(["write", domain, "Keep", "-string", "yes"])
        let before = real.keys(domain)
        var steps = real
        steps.running = { _ in [] }
        steps.trash = { _ in .absent }
        let app = WindowResetSavedFrames.App(bundleID: domain, name: "Scratch", url: scratch, savedState: scratch.appendingPathComponent("none"))
        let outcome = WindowResetForget.run(app, steps)
        let after = real.keys(domain)
        check(before == ["Keep", "NSSplitView Subview Frames Side", "NSWindow Frame Main"] && outcome.removed == 2 && outcome.failed == 0
              && after == ["Keep"], "through defaults on a scratch file: \(before ?? []) → \(after ?? [])")
        check(!real.delete(domain, "NSWindow Frame Gone") && real.keys(scratch.appendingPathComponent("none").path) == [],
              "deleting a key that isn't there reports a failure; a domain that isn't there has no keys")
        try? FileManager.default.removeItem(atPath: domain + ".plist")
    }

    static func settingsChecks(_ check: Check) {
        let delegate = AppDelegate(lockWarning: LockWarning(timeoutOverride: nil))
        var facts = SettingsFacts()
        func rows(_ facts: SettingsFacts, bringBack: String? = nil, forget: String? = nil, busy: Bool = false) -> [SettingsRow] {
            let sections = delegate.windowResetSections(facts, bringBackNote: bringBack, forgetNote: forget, bringingBack: busy, forgetting: busy)
            return sections.count == 1 && sections[0].title == WindowReset.sectionTitle ? sections[0].rows : []
        }
        func label(_ row: SettingsRow?) -> String? {
            if case .button(let label, _) = row?.control { label } else { nil }
        }
        func enabled(_ row: SettingsRow?) -> Bool {
            if case .button(_, let enabled) = row?.control { enabled } else { false }
        }
        let plain = rows(facts)
        check(plain.map(\.title) == [WindowReset.bringBackTitle, WindowReset.forgetTitle] && plain.map(label) == ["Bring Back", "Choose"]
              && plain.allSatisfy { $0.target === delegate && $0.action.map { delegate.responds(to: $0) } == true && enabled($0) },
              "a Lost Windows card: \(plain.map(\.title).joined(separator: " | ")), each wired to the app")
        check(plain.first?.note == WindowReset.bringBackAbout + "\n" + WindowReset.otherDesktops && plain.last?.note == WindowReset.forgetAbout,
              "their notes say what each is for, and that only the desktop showing is looked at")
        let after = rows(facts, bringBack: "Moved 2 windows", forget: "Forgot Calendar's window sizes and opened it again", busy: true)
        check(after.first?.note == "Moved 2 windows\n" + WindowReset.otherDesktops && after.last?.note == "Forgot Calendar's window sizes and opened it again"
              && !after.contains(where: enabled), "after a press each note says what happened, and the buttons wait while they work")
        facts.permissions = PermissionCheck(accessibility: false, screenRecording: true, finder: .on, finderUsed: true)
        check(rows(facts).first?.closesPanel == true && plain.first?.closesPanel == false && rows(facts).last?.closesPanel == false,
              "without Accessibility Bring Back closes the panel, for macOS's question; with it, it doesn't")
        let sections = delegate.settingsPages(SettingsFacts()).first { $0.id == "windows" }?.sections.compactMap(\.title) ?? []
        check((sections.firstIndex(of: "Background Windows") ?? .max) < (sections.firstIndex(of: WindowReset.sectionTitle) ?? -1),
              "on the Windows page, after Background Windows: \(sections.joined(separator: " | "))")

        func app(_ name: String) -> WindowResetSavedFrames.App {
            WindowResetSavedFrames.App(bundleID: "com.example.\(name.lowercased())", name: name, url: URL(fileURLWithPath: "/System/Applications/Calendar.app"),
                                       savedState: URL(fileURLWithPath: "/tmp/none"))
        }
        let listed = delegate.windowResetMenu(WindowResetSavedFrames.Scan(apps: [app("Alpha"), app("Zulu")]), containersRead: true)
        check(listed.items.map(\.title) == ["Alpha", "Zulu"] && listed.items.allSatisfy {
            $0.isEnabled && $0.target === delegate && $0.action == #selector(AppDelegate.forgetAppWindowSizes(_:))
                && ($0.representedObject as? WindowResetSavedFrames.App)?.name == $0.title && $0.image != nil
        }, "the list: each app with its icon, carrying the app, reaching forgetAppWindowSizes(_:)")
        let closed = delegate.windowResetMenu(WindowResetSavedFrames.Scan(apps: [app("Alpha")]), containersRead: false)
        let refused = delegate.windowResetMenu(WindowResetSavedFrames.Scan(apps: [app("Alpha")], refused: true), containersRead: true)
        for (name, menu) in [("without Full Disk Access", closed), ("when a container was refused", refused)] {
            let items = menu.items
            check(items.map(\.title) == ["Alpha", "", WindowReset.containersNote, WindowReset.fullDiskAccessTitle] && items[1].isSeparatorItem
                  && !items[2].isEnabled && items[3].isEnabled && items[3].target === delegate && delegate.responds(to: items[3].action!),
                  "\(name), the list says what macOS needs and offers its setting")
        }
        let empty = delegate.windowResetMenu(WindowResetSavedFrames.Scan(), containersRead: true)
        check(empty.items.map(\.title) == ["No app has saved window sizes"] && !empty.items[0].isEnabled, "with nothing to forget, it says so")

        typealias Outcome = WindowResetMover.Outcome
        let notes = [Outcome(checked: 5).note, Outcome(checked: 5, lost: ["Calendar"], moved: ["Calendar"]).note,
                     Outcome(checked: 5, lost: ["Calendar", "Messages"], moved: ["Calendar", "Messages"]).note,
                     Outcome(checked: 5, lost: ["Calendar", "Xcode"], moved: ["Calendar"], stuck: ["Xcode"]).note,
                     Outcome(checked: 5, lost: ["Xcode"], stuck: ["Xcode"]).note]
        check(notes == ["All windows were on screen", "Moved 1 window", "Moved 2 windows", "Moved 1 window; 1 wouldn't move or shrink (Xcode)",
                        "No window could be moved; 1 wouldn't move or shrink (Xcode)"], "Bring Back's notes: \(notes.joined(separator: " | "))")
        let line = Outcome(checked: 9, lost: ["Messages", "Calendar", "Calendar"], moved: ["Messages", "Calendar", "Calendar"]).logLine
        check(line == "window reset: moved 3 of 9 windows (Calendar, Messages)" && Outcome(checked: 9).logLine.contains("all 9 windows"),
              "its log line names apps only: \(line)")
    }
}
