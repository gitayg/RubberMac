import AppKit
import Carbon.HIToolbox

// --selftest finder: which pasted text counts as a path, then a Finder window of scratch folders: ⌘V with a folder
// path moves that window there, a file path selects the file, and ⌘V in the search field, ⌥⌘V, plain text and
// copied files are left to Finder. Hands ⌘V to the key handler directly rather than typing it. Closes its window
// with ⌘W only while that window is in front, and puts the clipboard back.
extension FinderPathPaste {
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

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("finder-selftest-\(UUID().uuidString)")
        let start = scratch.appendingPathComponent("Start here")
        let pasted = scratch.appendingPathComponent("Pasted (folder)")
        let holder = scratch.appendingPathComponent("Has a file")
        let file = holder.appendingPathComponent("note.txt")
        let package = scratch.appendingPathComponent("Tool.app")
        for folder in [start, pasted, holder, package] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try? "note".write(to: file, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: scratch) }

        func same(_ a: URL, _ b: URL) -> Bool { a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path }
        func reads(_ text: String, as expected: Destination?) -> Bool {
            switch (destination(from: text), expected) {
            case (nil, nil): return true
            case (.folder(let a)?, .folder(let b)?), (.item(let a)?, .item(let b)?): return same(a, b)
            default: return false
            }
        }
        let path = pasted.path
        let escaped = path.replacingOccurrences(of: " ", with: "\\ ").replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
        check(reads(path, as: .folder(pasted)), "a folder path")
        check(reads(path + "/", as: .folder(pasted)), "with a trailing slash")
        check(reads(pasted.absoluteString, as: .folder(pasted)), "a file:// link, %20 and all")
        check(reads("\"\(path)\"", as: .folder(pasted)) && reads("'\(path)'", as: .folder(pasted)), "in quotes")
        check(reads(escaped, as: .folder(pasted)), "with \\-escaped spaces, as copied from a terminal")
        check(reads("  \(path)\n", as: .folder(pasted)), "with spaces and a newline around it")
        check(reads("~", as: .folder(fm.homeDirectoryForCurrentUser)), "~ for the home folder")
        check(reads(file.path, as: .item(file)), "a file's path")
        check(reads(package.path, as: .item(package)), "an app is shown in its folder, not opened up")
        check(["hello world", "Pasted (folder)", "/no/such/folder/\(UUID().uuidString)", "\(path)\n\(path)", ""]
            .allSatisfy { reads($0, as: nil) }, "text, a relative path, a missing path, two lines and nothing aren't paths")

        guard AX.isTrusted else { return (lines + ["skipped the Finder run: accessibility not trusted"]).joined(separator: "\n") }
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

        // The first run shows the system's prompt to let RubberMAC control Finder.
        var permission: OSStatus?
        DispatchQueue.global().async { let status = FinderWindow.permission(ask: true); DispatchQueue.main.async { permission = status } }
        _ = waitFor(120) { permission != nil }
        guard permission == noErr else {
            lines.append("skipped the Finder run: not allowed to control Finder (\(permission.map { "\($0)" } ?? "no answer"))")
            return finish()
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

        var finder: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first }
        func window() -> AXUIElement? { finder.flatMap { AX.focusedWindow(of: $0.processIdentifier) } }
        func showing(_ folder: URL) -> Bool {
            finder?.isActive == true && window().flatMap { AX.string($0, kAXTitleAttribute) } == folder.lastPathComponent
        }
        NSWorkspace.shared.open(start)
        guard waitFor(10, { showing(start) }), let pid = finder?.processIdentifier, let id = window().flatMap(AX.windowID) else {
            check(false, "Finder opens the scratch folder")
            return finish()
        }
        // ⌘W closes just the scratch tab or window, and only while it's the one in front.
        defer {
            if [start, pasted, holder].contains(where: showing), window().flatMap(AX.windowID) == id {
                Paster.press(kVK_ANSI_W, flags: .maskCommand)
                pump(0.5)
            }
        }

        // Each ⌘V gets a fresh handler, so its outcome is that paste's alone. True when Finder never saw the V.
        func paste(_ flags: CGEventFlags = .maskCommand) -> (taken: Bool, outcome: Outcome?) {
            let handler = FinderPathPaste()
            handler.isEnabled = true
            var taken = true
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)!
                event.flags = flags
                if handler.handle(down ? .keyDown : .keyUp, event) == nil { continue }
                taken = false
            }
            if taken { _ = waitFor(10) { handler.lastOutcome != nil } }
            return (taken, handler.lastOutcome)
        }

        board.clearContents()
        board.setString(pasted.path, forType: .string)
        let toFolder = paste()
        check(toFolder.taken, "⌘V with a folder path is taken, not passed to Finder")
        check(toFolder.outcome == .moved && waitFor(3) { showing(pasted) } && window().flatMap(AX.windowID) == id,
              "the same window moved to the folder (\(toFolder.outcome.map { "\($0)" } ?? "no outcome"))")

        board.clearContents()
        board.setString(file.path, forType: .string)
        let toFile = paste()
        check(toFile.taken && toFile.outcome == .selected && waitFor(3) { showing(holder) },
              "a file path goes to its folder (\(toFile.outcome.map { "\($0)" } ?? "no outcome"))")
        var selected: [URL] = []
        _ = waitFor(3) { selected = (try? FinderWindow.selection()) ?? []; return selected.count == 1 && same(selected[0], file) }
        check(selected.count == 1 && same(selected[0], file), "and selects the file (\(selected.count) selected)")

        check(!paste([.maskCommand, .maskAlternate]).taken, "⌥⌘V (move here) is left to Finder")
        board.clearContents()
        board.setString("hello world", forType: .string)
        check(!paste().taken, "⌘V with text that isn't a path is left to Finder")
        board.clearContents()
        board.writeObjects([file as NSURL])
        check(!paste().taken, "⌘V with copied files is left to Finder, which pastes the files")

        if let search = window().flatMap({ searchField(in: $0, depth: 6) }) {
            AXUIElementSetAttributeValue(search, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            board.clearContents()
            board.setString(pasted.path, forType: .string)
            let editing = waitFor(3) { isEditingText(in: pid) == true }
            check(editing && !paste().taken, "⌘V in Finder's search field pastes the path there as text (search focused: \(editing))")
            AXUIElementSetAttributeValue(search, kAXFocusedAttribute as CFString, kCFBooleanFalse)
        } else {
            lines.append("skipped the search field: not found in the window's toolbar")
        }
        return finish()
    }

    private static func searchField(in element: AXUIElement, depth: Int) -> AXUIElement? {
        if AX.string(element, kAXSubroleAttribute) == kAXSearchFieldSubrole { return element }
        guard depth > 0 else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success else { return nil }
        for child in (children as? [AXUIElement]) ?? [] {
            if let found = searchField(in: child, depth: depth - 1) { return found }
        }
        return nil
    }
}
