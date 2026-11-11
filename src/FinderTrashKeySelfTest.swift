import AppKit
import Carbon.HIToolbox

// --selftest finder-trash: when Delete counts, then a Finder window of scratch files, handing the delete keys straight to
// the handler, as a tap doesn't see posted keys on this macOS, and posting what it passes on. Delete and ⌫ trash the
// highlighted file and ⌘Z brings it back; renaming, a RubberMAC panel with the keyboard, and holding the key don't trash anything more. Never presses a delete key unless Finder is in front with exactly the
// scratch file highlighted, and waits for an idle, ordinary desktop. Removes its files from the Trash, or says it couldn't.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

extension FinderTrashKey {
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func finish() -> String {
            (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
        }

        let finderID = "com.apple.finder"
        check(trashes(flags: 0, app: finderID, ownWindowIsKey: false), "plain Delete in Finder")
        check(trashes(flags: Modifiers.arrowKey, app: finderID, ownWindowIsKey: false), "⌦'s own fn flag doesn't count as a modifier")
        for (flag, name) in [(Modifiers.command, "⌘"), (Modifiers.control, "⌃"), (Modifiers.option, "⌥"), (Modifiers.shift, "⇧")] {
            check(!trashes(flags: flag, app: finderID, ownWindowIsKey: false), "not with \(name)")
        }
        check(!trashes(flags: 0, app: "com.apple.TextEdit", ownWindowIsKey: false), "not in another app")
        check(!trashes(flags: 0, app: nil, ownWindowIsKey: false), "not when the front app isn't known")
        check(!trashes(flags: 0, app: finderID, ownWindowIsKey: true), "not while a RubberMAC panel has the keyboard")
        guard AX.isTrusted else { return (lines + ["skipped the Finder run: accessibility not trusted"]).joined(separator: "\n") }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            return (lines + ["skipped the Finder run: the screen is locked"]).joined(separator: "\n")
        }
        if let spaces = SpaceWindows.spaces(), !spaces.current.isDisjoint(with: spaces.fullScreen) {
            return (lines + ["skipped the Finder run: a full-screen app's desktop is showing; switch to an ordinary desktop and run again"])
                .joined(separator: "\n")
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= 20 else {
            return (lines + ["skipped the Finder run: the Mac was in use \(Int(idle)) s ago; run it after 20 s without typing or the mouse"])
                .joined(separator: "\n")
        }
        guard FinderWindow.permission(ask: false) == noErr else {
            return (lines + ["skipped the Finder run: not allowed to control Finder"]).joined(separator: "\n")
        }

        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        Frontmost.start()
        func pump(_ seconds: TimeInterval) {
            let until = Date(timeIntervalSinceNow: seconds)
            while Date() < until {
                if let event = NSApp.nextEvent(matching: .any, until: min(until, Date(timeIntervalSinceNow: 0.02)),
                                               inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            }
        }
        func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
            let until = Date(timeIntervalSinceNow: seconds)
            while !condition() && Date() < until { pump(0.05) }
            return condition()
        }

        let fm = FileManager.default
        let tag = "rubbermac-trash-test-\(UUID().uuidString)"
        let scratch = fm.temporaryDirectory.appendingPathComponent(tag)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let names = ["1 forward delete", "2 mac delete", "3 renaming", "4 panel", "5 held", "6 next", "7 next"].map { "\(tag) \($0).txt" }
        let files = names.map { scratch.appendingPathComponent($0) }
        for file in files { try? "test".write(to: file, atomically: true, encoding: .utf8) }
        let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        var trashed: Set<String> = []
        func gone(_ index: Int) -> Bool {
            let isGone = !fm.fileExists(atPath: files[index].path)
            if isGone { trashed.insert(names[index]) }
            return isGone
        }

        let handler = FinderTrashKey()
        handler.isEnabled = true
        var finderInFront: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderID }
        func highlighted(_ file: URL) -> Bool {
            guard finderInFront, let selection = try? FinderWindow.selection(), selection.count == 1 else { return false }
            return selection[0].resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path
        }
        func highlight(_ index: Int) -> Bool {
            NSWorkspace.shared.activateFileViewerSelecting([files[index]])
            // Macs don't always let a background app bring Finder forward this way.
            pump(0.8)
            if !finderInFront, let pid = NSRunningApplication.runningApplications(withBundleIdentifier: finderID).first?.processIdentifier,
               let window = AX.windows(of: pid).first {
                AX.focus(window, pid: pid)
            }
            return waitFor(8) { highlighted(files[index]) && Frontmost.bundleID == finderID }
        }
        func wrapUp() -> String {
            if finderInFront, (try? FinderWindow.currentFolder())?.lastPathComponent == tag {
                Paster.press(kVK_ANSI_W, flags: .maskCommand)
                pump(0.5)
            }
            var left = 0
            for name in trashed {
                let file = trash.appendingPathComponent(name)
                if fm.fileExists(atPath: file.path) { do { try fm.removeItem(at: file) } catch { left += 1 } }
            }
            if left > 0 { lines.append("     \(left) test file(s) left in the Trash, named \(tag)…") }
            try? fm.removeItem(at: scratch)
            return finish()
        }

        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ key: Int, down: Bool) {
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)?.post(tap: .cghidEventTap)
        }
        func type(_ key: Int) {
            post(key, down: true)
            pump(0.06)
            post(key, down: false)
        }
        // True when the handler let the key go on, which then goes on for real.
        @discardableResult func deliver(_ key: Int, down: Bool, repeating: Bool = false) -> Bool {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down) else { return false }
            if repeating { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            event.flags = []
            guard let passed = handler.handle(down ? .keyDown : .keyUp, event) else { return false }
            passed.post(tap: .cghidEventTap)
            return true
        }
        func tapKey(_ key: Int) -> Bool {
            let passed = deliver(key, down: true)
            pump(0.06)
            deliver(key, down: false)
            return passed
        }
        var passedOn = false

        // The only way a delete key gets pressed here: with Finder in front and exactly this scratch file highlighted.
        func pressDelete(_ key: Int, on index: Int) -> Bool {
            guard highlighted(files[index]) else {
                lines.append("stopped: Finder isn't showing the scratch file highlighted, so no key was pressed")
                failures += 1
                return false
            }
            passedOn = tapKey(key)
            return true
        }

        guard highlight(0) else {
            var selection = "none"
            do { selection = "\(try FinderWindow.selection().count) item(s)" } catch { selection = "error \((error as? FinderWindow.Failure)?.status ?? 0)" }
            check(false, "Finder highlights the scratch file (Finder in front: \(finderInFront), selection: \(selection), scratch files there: \(files.filter { fm.fileExists(atPath: $0.path) }.count))")
            return wrapUp()
        }
        guard pressDelete(kVK_ForwardDelete, on: 0) else { return wrapUp() }
        check(waitFor(5) { gone(0) }, "Delete (⌦) moves the highlighted file out of its folder")
        pump(0.6)
        Paster.press(kVK_ANSI_Z, flags: .maskCommand)
        check(waitFor(5) { fm.fileExists(atPath: files[0].path) }, "⌘Z puts it back")
        pump(0.5)

        guard highlight(1), pressDelete(kVK_Delete, on: 1) else { return wrapUp() }
        check(waitFor(5) { gone(1) }, "the Mac keyboard's delete (⌫) does too")
        pump(0.5)

        guard highlight(2) else { return wrapUp() }
        type(kVK_Return)
        guard waitFor(3, { FinderPathPaste.isEditingText(in: Frontmost.pid) == true }) else {
            check(false, "Return starts renaming")
            return wrapUp()
        }
        check(true, "Return starts renaming")
        check(tapKey(kVK_Delete), "while renaming, delete goes on to the name")
        pump(1)
        check(fm.fileExists(atPath: files[2].path), "and the file stays")
        type(kVK_Escape)
        pump(0.6)

        guard highlight(3) else { return wrapUp() }
        let panel = KeyPanel(contentRect: NSRect(x: 200, y: 400, width: 240, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.level = .floating
        let field = NSTextField(frame: panel.contentLayoutRect)
        field.stringValue = "some text"
        panel.contentView?.addSubview(field)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        check(waitFor(2) { Frontmost.ownWindowIsKey }, "a panel of ours has the keyboard")
        check(finderInFront, "with Finder still the app in front, as for the address bar and the pad")
        if pressDelete(kVK_ForwardDelete, on: 3) {
            pump(1.2)
            check(passedOn && fm.fileExists(atPath: files[3].path), "then delete goes on to the panel and nothing is trashed")
            pump(0.3)
            let text = field.currentEditor()?.string ?? field.stringValue
            check(text != "some text", "and the panel's text changes (now \"\(text)\")")
        }
        panel.orderOut(nil)
        check(waitFor(2) { !Frontmost.ownWindowIsKey }, "and the keys go back to Finder when it closes")
        pump(0.4)

        guard highlight(4), highlighted(files[4]) else { return wrapUp() }
        deliver(kVK_ForwardDelete, down: true)
        check(waitFor(5) { gone(4) }, "pressing and holding trashes the highlighted file")
        var repeatsPassed = 0
        for _ in 0..<4 {
            if deliver(kVK_ForwardDelete, down: true, repeating: true) { repeatsPassed += 1 }
            pump(0.25)
        }
        deliver(kVK_ForwardDelete, down: false)
        check(repeatsPassed == 0, "its repeats go no further")
        pump(1)
        check(!gone(5) && !gone(6), "and the repeats don't trash the next files")
        return wrapUp()
    }
}
