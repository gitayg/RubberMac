import AppKit
import Carbon.HIToolbox

// --selftest finder-bar: where the strip goes on a window (under the toolbar, under a tab bar, under the title bar,
// on screens above and left of the main one), how a folder reads in it, and which typed text it takes. With `live`
// as well, a Finder window of scratch folders: the strip shows under its toolbar with that folder's path and
// RubberMAC doesn't take the focus; a path set in the field and committed moves that same window, a file's path
// selects the file, text that isn't a path is refused, Esc puts the path back, and a minimized window loses the
// strip. Calls the field's commit and cancel directly rather than typing. Closes its window with ⌘W only while
// that window is in front.
extension FinderAddressBar {
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
        typealias Layout = FinderAddressBarLayout

        // Accessibility frames (y down from the top of the main screen) against AppKit ones (y up from its bottom).
        let primary: CGFloat = 982
        func appKit(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: primary - r.maxY, width: r.width, height: r.height) }
        let window = CGRect(x: 100, y: 200, width: 900, height: 600)
        let toolbar = CGRect(x: 100, y: 200, width: 900, height: 52)
        let top = Layout.top(window: window, toolbar: toolbar, tabGroups: [])
        check(top == 52 + Layout.gap, "the strip starts under the toolbar (\(top))")
        let strip = Layout.strip(window: window, top: top, primaryHeight: primary)
        check(strip == appKit(CGRect(x: 100 + Layout.inset, y: 200 + top, width: 900 - 2 * Layout.inset, height: Layout.height)),
              "it spans the window less an inset, \(Layout.height) pt tall, in AppKit coordinates (\(strip))")
        let tabBar = CGRect(x: 100, y: 252, width: 900, height: 26)
        check(Layout.top(window: window, toolbar: toolbar, tabGroups: [tabBar]) == 78 + Layout.gap, "with several tabs, under the tab bar")
        check(Layout.top(window: window, toolbar: toolbar, tabGroups: [CGRect(x: 300, y: 400, width: 500, height: 30),
                                                                     CGRect(x: 100, y: 252, width: 900, height: 400)]) == top,
              "a tab group further down, or a tall one, isn't a tab bar")
        check(Layout.top(window: window, toolbar: nil, tabGroups: []) == Layout.titleBar + Layout.gap,
              "with the toolbar hidden, under the title bar")
        check(Layout.top(window: window, toolbar: CGRect(x: 100, y: 200, width: 900, height: 0), tabGroups: []) == Layout.titleBar + Layout.gap,
              "an empty toolbar doesn't put it over the title bar")
        let short = CGRect(x: 100, y: 200, width: 500, height: 60)
        check(appKit(short).contains(Layout.strip(window: short, top: top, primaryHeight: primary)), "it stays inside a window too short for it")
        // A screen above the main one, and one to its left: negative Accessibility coordinates.
        for (screen, place) in [(CGRect(x: 0, y: -1080, width: 1920, height: 1080), CGRect(x: 300, y: -900, width: 800, height: 500)),
                                (CGRect(x: -1920, y: 0, width: 1920, height: 1080), CGRect(x: -1500, y: 100, width: 800, height: 500))] {
            let onIt = Layout.strip(window: place, top: top, primaryHeight: primary)
            check(appKit(screen).contains(onIt) && appKit(place).contains(onIt)
                  && onIt.maxY == appKit(place).maxY - top && onIt.minX == place.minX + Layout.inset,
                  "on a screen at \(screen.origin), it's on that screen, under the same window's toolbar")
        }

        check(Layout.shown(URL(fileURLWithPath: "/Users/x"), home: "/Users/x") == "~"
              && Layout.shown(URL(fileURLWithPath: "/Users/x/"), home: "/Users/x/") == "~", "the home folder reads as ~")
        check(Layout.shown(URL(fileURLWithPath: "/Users/x/My Folder"), home: "/Users/x") == "~/My Folder", "a folder in it as ~/…")
        check(Layout.shown(URL(fileURLWithPath: "/Users/xy/Docs"), home: "/Users/x") == "/Users/xy/Docs",
              "a folder beside it keeps its full path")
        check(Layout.shown(URL(fileURLWithPath: "/"), home: "/Users/x") == "/"
              && Layout.shown(URL(fileURLWithPath: "/Volumes/Data/"), home: "/Users/x") == "/Volumes/Data", "/, and no trailing slash")

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("finder-bar-selftest-\(UUID().uuidString)")
        let start = scratch.appendingPathComponent("Start here")
        let went = scratch.appendingPathComponent("Went (here)")
        let holder = scratch.appendingPathComponent("Has a file")
        let file = holder.appendingPathComponent("note.txt")
        for folder in [start, went, holder] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try? "note".write(to: file, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: scratch) }

        func same(_ a: URL, _ b: URL) -> Bool { a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path }
        func reads(_ text: String, as expected: FinderPathPaste.Destination?) -> Bool {
            switch (FinderPathPaste.destination(from: text), expected) {
            case (nil, nil): return true
            case (.folder(let a)?, .folder(let b)?), (.item(let a)?, .item(let b)?): return same(a, b)
            default: return false
            }
        }
        let home = fm.homeDirectoryForCurrentUser
        check(reads(Layout.shown(home), as: .folder(home)), "the shown ~ goes back to the home folder")
        check(reads(Layout.shown(home.appendingPathComponent("Library")), as: .folder(home.appendingPathComponent("Library"))),
              "the shown ~/Library goes back to it")
        check(reads(Layout.shown(went), as: .folder(went)), "a shown path with spaces and brackets goes back to its folder")
        check(reads(file.path, as: .item(file)), "a typed file's path goes to its folder, to select it")
        check(["hello world", "Start here", "~nobody-\(UUID().uuidString)/x", scratch.appendingPathComponent("missing").path, ""]
            .allSatisfy { reads($0, as: nil) }, "text, a relative path, an unknown ~user, a missing path and nothing aren't paths")

        let offline = FinderAddressBar()
        offline.panel.show("~/Somewhere", placeholder: "")
        offline.panel.text = "not a path"
        offline.commit()
        check(offline.panel.isRejected && offline.panel.text == "not a path" && offline.lastOutcome == nil,
              "committing text that isn't a path tints the field and leaves the text to fix")
        offline.cancel()
        check(offline.panel.text == "~/Somewhere", "Esc puts the folder's path back")

        guard CommandLine.arguments.contains("live") else {
            lines.append("skipped the Finder run: add live to open a Finder window")
            return finish()
        }
        guard AX.isTrusted else { lines.append("skipped the Finder run: accessibility not trusted"); return finish() }
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

        // The first run shows the system's prompt to let RubberMAC control Finder.
        var permission: OSStatus?
        DispatchQueue.global().async { let status = FinderWindow.permission(ask: true); DispatchQueue.main.async { permission = status } }
        _ = waitFor(120) { permission != nil }
        guard permission == noErr else {
            lines.append("skipped the Finder run: not allowed to control Finder (\(permission.map { "\($0)" } ?? "no answer"))")
            return finish()
        }

        var finderApp: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: Self.finder).first }
        func front() -> AXUIElement? { finderApp.flatMap { AX.focusedWindow(of: $0.processIdentifier) } }
        func showing(_ folder: URL) -> Bool {
            finderApp?.isActive == true && front().flatMap { AX.string($0, kAXTitleAttribute) } == folder.lastPathComponent
        }
        NSWorkspace.shared.open(start)
        guard waitFor(10, { showing(start) }), let pid = finderApp?.processIdentifier, let id = front().flatMap(AX.windowID) else {
            check(false, "Finder opens the scratch folder")
            return finish()
        }
        let bar = FinderAddressBar()
        // ⌘W closes just the scratch tab or window, and only while it's the one in front; the strip goes first.
        defer {
            bar.isEnabled = false
            if [start, went, holder].contains(where: showing), front().flatMap(AX.windowID) == id {
                Paster.press(kVK_ANSI_W, flags: .maskCommand)
                pump(0.5)
            }
        }
        func barShows(_ folder: URL) -> Bool {
            guard bar.isShown, bar.window?.id == id, case .folder(let shown)? = FinderPathPaste.destination(from: bar.panel.text)
            else { return false }
            return same(shown, folder)
        }

        bar.isEnabled = true
        check(waitFor(5) { barShows(start) }, "the strip shows on the scratch window with its folder's path")
        check(!NSApp.isActive && !bar.panel.isKeyWindow && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finder,
              "RubberMAC didn't take the focus from Finder")
        if let element = front(), let frame = AX.frame(of: element), let tracked = bar.window {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            let children = (value as? [AXUIElement]) ?? []
            let roles = Dictionary(grouping: children.map { AX.string($0, kAXRoleAttribute) ?? "?" }, by: { $0 })
                .map { "\($0.key)×\($0.value.count)" }.sorted().joined(separator: ", ")
            lines.append("     window: \(roles); toolbar \(tracked.hasToolbar ? "found" : "NOT found"), tab bar \(tracked.hasTabBar ? "found" : "none")")
            let panel = bar.panel.frame
            let placed = CGRect(x: panel.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - panel.maxY,
                                width: panel.width, height: panel.height)
            let toolbar = children.first { AX.string($0, kAXRoleAttribute) == kAXToolbarRole }.flatMap(AX.frame)
            let under = (tracked.hasTabBar ? nil : toolbar).map { abs(placed.minY - $0.maxY - Layout.gap) <= 1 }
                ?? (placed.minY >= (toolbar?.maxY ?? frame.minY + Layout.titleBar))
            check(toolbar != nil && under && abs(placed.minX - frame.minX - Layout.inset) <= 1
                  && abs(placed.width - (frame.width - 2 * Layout.inset)) <= 1 && placed.height == Layout.height,
                  "it sits under the toolbar\(tracked.hasTabBar ? " and tab bar" : ""), across the window (window \(frame), strip \(placed))")
            let above = (CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, id) as? [[String: Any]] ?? [])
                .filter { $0[kCGWindowLayer as String] as? Int == 0 }
            check(above.last?[kCGWindowNumber as String] as? Int == bar.panel.windowNumber,
                  "it's ordered just above the Finder window (\(above.count) normal windows above it)")
        } else {
            check(false, "the scratch window and the strip can be read")
        }

        bar.panel.text = went.path
        bar.commit()
        check(waitFor(10) { bar.lastOutcome != nil } && bar.lastOutcome == .moved && waitFor(3) { showing(went) }
              && front().flatMap(AX.windowID) == id,
              "a path committed in the field moved the same window there (\(bar.lastOutcome.map { "\($0)" } ?? "no outcome"))")
        check(waitFor(3) { barShows(went) }, "and the strip shows the new folder's path")

        bar.panel.text = file.path
        bar.commit()
        check(waitFor(10) { bar.lastOutcome == .selected } && waitFor(3) { showing(holder) },
              "a file's path goes to its folder (\(bar.lastOutcome.map { "\($0)" } ?? "no outcome"))")
        var selected: [URL] = []
        _ = waitFor(3) { selected = (try? FinderWindow.selection()) ?? []; return selected.count == 1 && same(selected[0], file) }
        check(selected.count == 1 && same(selected[0], file), "and selects the file (\(selected.count) selected)")

        bar.panel.text = "not a path"
        bar.commit()
        check(bar.panel.isRejected && bar.panel.text == "not a path", "text that isn't a path is tinted and left to fix")
        pump(0.5)
        check(showing(holder), "and the window stays where it was")
        bar.cancel()
        check(barShows(holder) && !bar.panel.isKeyWindow, "Esc puts the folder's path back")

        if let element = front() {
            AX.setMinimized(element, true)
            check(waitFor(3) { bar.window?.id != id }, "a minimized window loses the strip")
            AX.focus(element, pid: pid)
            check(waitFor(5) { showing(holder) && front().flatMap(AX.windowID) == id && barShows(holder) },
                  "and gets it back once it's in front again")
        }
        bar.isEnabled = false
        check(!bar.isShown, "turning it off hides the strip")
        return finish()
    }
}
