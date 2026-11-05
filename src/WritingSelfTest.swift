import AppKit
import Carbon.HIToolbox

// --selftest pad: the writing pad end to end with real keystrokes, in a scratch TextEdit document: opens the pad,
// types a sloppy message, waits for the fix, presses ↩ and checks the fixed text landed in the document, then
// ⌥↩, ⇧↩ and Esc. Stops typing the moment the pad isn't the key window, so nothing lands anywhere else.
// Puts the clipboard back and closes the scratch document (quitting TextEdit only if it wasn't running).
extension WritingAssistant {
    static func selfTestReport() -> String {
        var lines = ["fixer available: \(TextFixer.isAvailable), screen readable: \(ScreenText.hasPermission)"]
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }

        let marks = FixDiff.segments(from: "putting you intermim manager", to: "putting you in as manager")
            .filter { $0.kind != .same }.map { "\($0.kind == .added ? "+" : "-")\($0.text)" }
        check(marks == ["-intermim ", "+in", "+as"], "added words are marked and dropped ones struck out: \(marks)")

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pad-selftest-\(UUID().uuidString)")
        let store = scratch.appendingPathComponent("Replies")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let reply = SavedReply(date: Date(timeIntervalSince1970: 1_800_000_000), app: "Test", bundleID: nil,
                               screen: "שלום\nDana", typed: "a", sent: "A.")
        try? ReplyStore.save(reply, in: store)
        try? ReplyStore.save(reply, in: store)
        let saved = (try? ReplyStore.load(from: store.appendingPathComponent("\(ReplyStore.month(of: reply.date)).jsonl"))) ?? []
        check(saved == [reply, reply], "replies are saved and read back, Hebrew included")

        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty
        guard AX.isTrusted else { return (lines + ["skipped the TextEdit run: accessibility not trusted"]).joined(separator: "\n") }

        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
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

        let board = NSPasteboard.general
        let clipboard = (board.pasteboardItems ?? []).map { item in
            Dictionary(item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }, uniquingKeysWith: { a, _ in a })
        }
        defer {
            board.clearContents()
            board.writeObjects(clipboard.map { types in
                let item = NSPasteboardItem()
                types.forEach { item.setData($1, forType: $0) }
                return item
            })
        }
        let sentinel = "clipboard before the pad \(UUID().uuidString)"
        board.clearContents()
        board.setString(sentinel, forType: .string)

        let document = scratch.appendingPathComponent("pad test.txt")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try? "".write(to: document, atomically: true, encoding: .utf8)
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([document], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        var editor: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first }
        func scratchWindow() -> AXUIElement? {
            editor.flatMap { AX.focusedWindow(of: $0.processIdentifier) }.flatMap { AX.string($0, kAXTitleAttribute) == "pad test.txt" ? $0 : nil }
        }
        guard waitFor(10, { editor?.isActive == true && scratchWindow() != nil }), let pid = editor?.processIdentifier,
              let window = scratchWindow() else {
            return (lines + ["FAIL TextEdit didn't open the scratch document"]).joined(separator: "\n")
        }
        // Only the scratch document goes; the user's own TextEdit windows stay.
        defer {
            if wasRunning {
                var button: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success {
                    AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
                }
                // TextEdit saves the document as it closes; let it finish before the scratch folder goes.
                pump(1.5)
            } else {
                editor?.terminate()
            }
        }
        pump(0.5)
        func documentText() -> String? {
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AX.app(pid), kAXFocusedUIElementAttribute as CFString, &focused) == .success
            else { return nil }
            return AX.string(focused as! AXUIElement, kAXValueAttribute)
        }

        let assistant = WritingAssistant(store: store)
        var stopped = false
        func padIsKey() -> Bool { assistant.isShown && NSApp.keyWindow != nil }
        // Opens the pad only over the scratch document; if the user switched apps, the run stops instead.
        func openPad() -> Bool {
            guard !stopped, editor?.isActive == true, scratchWindow() != nil else { stopped = true; return false }
            assistant.open()
            pump(0.3)
            return true
        }
        func type(_ text: String) {
            for character in text {
                guard !stopped else { return }
                guard padIsKey() else { stopped = true; return }
                if character == "\n" { press(kVK_Return, .maskShift); continue }
                let source = CGEventSource(stateID: .combinedSessionState)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    let units = Array(String(character).utf16)
                    event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    event?.post(tap: .cghidEventTap)
                }
                pump(0.03)
            }
            pump(0.2)
        }
        func press(_ key: Int, _ flags: CGEventFlags = []) {
            guard !stopped, padIsKey() else { stopped = true; return }
            Paster.press(key, flags: flags)
            pump(0.1)
        }

        // 1. Type, wait for the fix, ↩ sends it.
        let typed = "thx for the update, lets meet tmrw at 10 to go over the the numbers"
        _ = openPad()
        check(padIsKey(), "the pad opens over TextEdit and takes the typing (TextEdit stays frontmost: \(editor?.isActive == true))")
        type(typed)
        check(assistant.text == typed, "keystrokes reach the pad")
        let start = Date()
        let fixedReady = waitFor(20) { assistant.fixedText != nil }
        let fixed = assistant.fixedText ?? ""
        check(fixedReady, String(format: "fixed %.1fs after the last key: \"%@\"", -start.timeIntervalSinceNow, fixed))
        press(kVK_Return)
        _ = waitFor(3) { documentText() == fixed }
        check(!assistant.isShown, "↩ closes the pad")
        check(documentText() == fixed, "↩ pastes the fixed text into the document: \"\(documentText() ?? "nil")\"")
        check(board.string(forType: .string) == fixed, "the fixed text is on the clipboard too")
        if ScreenText.hasPermission, let id = AX.focusedWindow(of: pid).flatMap(AX.windowID) {
            var read: String?
            let readStart = Date()
            Task { @MainActor in read = await ScreenText.read(window: id) }
            _ = waitFor(60) { read != nil }
            check(read?.contains("numbers") == true, String(format: "the screen reader reads the document back (%.1fs, %d characters)",
                                                             -readStart.timeIntervalSinceNow, read?.count ?? 0))
        } else {
            lines.append("skipped reading the screen: no Screen Recording permission")
        }
        let replies = (try? ReplyStore.load(from: store.appendingPathComponent("\(ReplyStore.month(of: Date())).jsonl"))) ?? []
        check(replies.last.map { $0.typed == typed && $0.sent == fixed && $0.app == "TextEdit" } == true,
              "the reply is saved with what was typed and sent, and \(replies.last?.screen.count ?? 0) characters read from the screen")

        // 2. ⌥↩ sends what was typed.
        guard openPad() else { return stop() }
        type(" ok thx")
        check(assistant.text == " ok thx", "typed into the reopened pad: \(assistant.text.debugDescription)")
        press(kVK_Return, .maskAlternate)
        _ = waitFor(3) { documentText()?.hasSuffix("ok thx") == true }
        check(documentText() == fixed + "ok thx", "⌥↩ pastes it as typed: \"\(documentText() ?? "nil")\"")

        // 3. ⇧↩ is a new line; Esc closes without sending and keeps the draft for next time.
        guard openPad() else { return stop() }
        type("line one\nline two")
        check(assistant.text == "line one\nline two", "⇧↩ starts a new line")
        press(kVK_Escape)
        pump(0.5)
        check(!assistant.isShown && documentText() == fixed + "ok thx", "Esc closes without pasting")
        guard openPad() else { return stop() }
        check(assistant.text == "line one\nline two", "the draft is back when the pad opens again")
        type(" and three")
        check(assistant.text == "line one\nline two and three", "typing works after the pad was closed with Esc")
        press(kVK_Escape)
        pump(0.3)

        func stop() -> String {
            if assistant.isShown { assistant.toggle() }
            return (lines + ["STOPPED: something else took the focus, so the run stopped typing (\(failures) failed before that)"])
                .joined(separator: "\n")
        }
        if stopped { return stop() }
        lines.append(failures == 0 ? "PASS" : "FAIL: \(failures) failed")
        return lines.joined(separator: "\n")
    }
}
