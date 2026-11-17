import AppKit
import Carbon.HIToolbox

// --selftest startmenu-live [folder]: the real Start window on the real screen, in the signed app, with this Mac's apps
// plus scratch ones made for the run, and a scratch start.json. Opens it as the ⌘ tap does; types a search, moves with
// the arrows and opens with ↩; closes it with another ⌘ tap, Esc and a click elsewhere; pins through a real right-click;
// moves a scratch app to the Trash through the menu and its question (cancelled once, then confirmed) and takes it back
// out of the Trash; then drags a scratch app onto another to make a folder, renames it, drags one out again, reorders
// the grid and the pins. Opening an app is swapped for a note of which. Posts clicks, drags and keys (keys only while
// Start has the keyboard), then puts the pointer back, so it waits for an idle, ordinary desktop.
extension StartMenu {
    static func liveSelfTestReport() -> String {
        guard AX.isTrusted else { return "skipped: accessibility not trusted" }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            return "skipped: the screen is locked"
        }
        if let spaces = SpaceWindows.spaces(), !spaces.current.isDisjoint(with: spaces.fullScreen) {
            return "skipped: a full-screen app's desktop is showing; switch to an ordinary desktop and run again"
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= 20 else { return "skipped: the Mac was in use \(Int(idle)) s ago; run it after 20 s without typing or the mouse" }

        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func note(_ text: String) { lines.append("     \(text)") }

        let fm = FileManager.default
        let args = CommandLine.arguments
        let pictures = args.firstIndex(of: "startmenu-live").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        let realStore = try? Data(contentsOf: StartMenuStore.defaultURL)
        let tag = String(UUID().uuidString.prefix(6))
        let scratch = fm.temporaryDirectory.appendingPathComponent("startmenu-live-\(tag)")
        let appsFolder = scratch.appendingPathComponent("Apps")
        let names = ["Alpha", "Beta", "Gamma", "Delta"].map { "Start Test \($0) \(tag)" }
        let paths = names.map { appsFolder.appendingPathComponent("\($0).app").path }
        names.forEach { makeScratchApp(appsFolder.appendingPathComponent("\($0).app")) }
        let (alpha, beta, gamma, delta) = (paths[0], paths[1], paths[2], paths[3])
        var system = StartMenuController.System()
        system.roots = [appsFolder] + StartMenuApps.roots
        system.store = StartMenuStore(url: scratch.appendingPathComponent("start.json"))
        try? system.store.save(StartMenuLayout(pins: [], items: paths.map { .app($0) }))
        var opened: [URL] = []
        var searchStarts: [Bool] = []
        var searchEnds = 0
        let start: StartMenuController
        do {
            var panelIsKey: () -> Bool = { false }
            system.open = { opened.append($0) }
            system.showInFinder = { _ in }
            system.searchStarts = { searchStarts.append(panelIsKey()) }
            system.searchEnds = { searchEnds += 1 }
            start = StartMenuController(system: system)
            panelIsKey = { [unowned start] in start.panel?.isKeyWindow == true }
        }

        let driver = StartMenuLiveDriver()
        let target = StartMenuLiveTarget(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        driver.ownsKeyboard = { [unowned start] in
            guard let panel = start.panel else { return false }
            return panel.isKeyWindow || panel.attachedSheet?.isKeyWindow == true
        }
        driver.ownsPointer = { [unowned start] in start.panel?.isVisible == true }
        let savedPointer = CGEvent(source: nil)?.location ?? .zero
        // Which clicks reached this process, and where: told in a failure, so it says whether a click got here at all.
        var received: [String] = []
        let began = Date()
        let menuOpen = StartMenuLiveFlag()
        func trace(_ text: String) { received.append("\(Int(-began.timeIntervalSinceNow * 1000)) ms \(text)") }
        var moves = 0
        let watcher = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            if event.type == .leftMouseDragged { moves += 1; return event }
            let window = event.window.map { $0 === start.panel ? "Start" : "\(type(of: $0))" } ?? "no window"
            let kind = event.type == .leftMouseDown ? "press" : event.type == .leftMouseUp ? "release (after \(moves) drags)" : "right-click"
            trace("\(kind) in \(window)")
            return event
        }
        start.trace = { text in
            trace(text)
            if text == "menu opens" { menuOpen.set(true) }
        }
        driver.note = { trace($0) }
        let activations = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                           object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            trace("\(app == .current ? "this test" : app?.localizedName ?? "an app") came forward")
        }
        // The window the window server shows on top at a point.
        func windowAt(_ point: CGPoint) -> String {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let top = windows.first { info in
                let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
                return bounds.contains(point) && (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
            }
            guard let top else { return "none" }
            return (top[kCGWindowNumber as String] as? Int) == start.panel?.windowNumber ? "Start" : top[kCGWindowOwnerName as String] as? String ?? "?"
        }
        func heard() -> String { "seen here: " + (received.isEmpty ? "nothing" : received.suffix(10).joined(separator: ", ")) }
        let previous = NSWorkspace.shared.frontmostApplication
        func finish() -> String {
            if failures > 0 { note("what happened: " + received.suffix(40).joined(separator: " · ")) }
            driver.releaseIfHeld()
            if let watcher { NSEvent.removeMonitor(watcher) }
            NSWorkspace.shared.notificationCenter.removeObserver(activations)
            start.close()
            target.orderOut(nil)
            driver.pump(0.3)
            CGWarpMouseCursorPosition(savedPointer)
            try? fm.removeItem(at: scratch)
            check((try? Data(contentsOf: StartMenuStore.defaultURL)) == realStore, "the real start.json is as it was")
            return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
        }
        func picture(_ name: String, of window: NSWindow?) {
            guard let pictures, let number = window?.windowNumber, let image = SpaceWindows.picture(of: CGWindowID(number)) else { return }
            let url = pictures.appendingPathComponent("live-start-\(name).png")
            try? fm.createDirectory(at: pictures, withIntermediateDirectories: true)
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            note("picture: \(url.path)")
        }
        func onScreen(_ window: NSWindow?) -> Bool {
            guard let number = window?.windowNumber else { return false }
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return windows.contains { ($0[kCGWindowNumber as String] as? Int) == number }
        }
        // The middle of tile `index` of a grid, or a point inside it (fractions of the cell), on the screen.
        func tile(_ grid: StartMenuGrid, _ index: Int, _ x: CGFloat = 0.5, _ y: CGFloat = 0.35) -> CGPoint? {
            let cell = grid.frame(of: index)
            return StartMenuLiveDriver.point(NSRect(x: cell.minX + cell.width * x, y: cell.minY + cell.height * y, width: 0, height: 0), in: grid)
        }
        func mainPaths() -> [String] { start.layout.items.prefix(4).map { item in
            switch item {
            case .app(let path): return path
            case .folder(let folder): return "folder(" + folder.apps.joined(separator: ",") + ")"
            }
        } }
        func short(_ list: [String]) -> String {
            list.map { item in
                var item = item
                for (path, name) in zip(paths, ["Alpha", "Beta", "Gamma", "Delta"]) { item = item.replacingOccurrences(of: path, with: name) }
                return item
            }.joined(separator: ", ")
        }

        driver.releaseIfHeld()

        // Opening, as the ⌘ tap does.
        let opening = Date()
        start.toggle()
        let openMs = Int(-opening.timeIntervalSinceNow * 1000)
        guard let panel = start.panel, driver.waitFor(2, { panel.isKeyWindow }) != nil else {
            check(false, "a ⌘ tap opens Start with the keyboard")
            return finish()
        }
        check(true, "a ⌘ tap opens Start, with the keyboard, in \(openMs) ms (\(start.apps.count) apps)")
        driver.pump(0.3)
        check(onScreen(panel), "it's on the screen")
        check(searchStarts == [false], "the search is readied before the field takes the keys")
        check(panel.firstResponder === start.view.search.currentEditor(), "the search field has the typing")
        check(NSWorkspace.shared.frontmostApplication == previous, "the app in front stays in front (\(previous?.localizedName ?? "none"))")
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) {
            let frame = panel.frame, area = screen.visibleFrame
            check(area.contains(frame) && abs(frame.midX - area.midX) <= 1 && abs(frame.midY - area.midY) <= 1,
                  "centred on the screen with the pointer (\(Int(frame.width)) × \(Int(frame.height)) on \(screen.localizedName))")
        }
        picture("open", of: panel)

        // Search, arrows, ↩.
        driver.type("start test \(tag.lowercased())")
        check(driver.waitFor(1) { start.results.map(\.path) == paths } != nil,
              "typing finds the four scratch apps, in their order (\"\(start.query)\": \(start.results.count) found)")
        check(start.view.main.selected == 0, "the first is selected")
        picture("search", of: panel)
        driver.press(kVK_RightArrow)
        driver.press(kVK_RightArrow)
        check(start.selection?.index == 2, "→ → moves the selection to the third")
        driver.press(kVK_LeftArrow)
        check(start.selection?.index == 1, "← moves it back")
        driver.press(kVK_Return)
        check(driver.waitFor(1) { !start.isShown && !panel.isVisible } != nil && opened.last?.path == beta, "↩ opens the selected app and Start closes")
        check(searchEnds == 0, "an app opened, so the search isn't ended for the app that was in front")

        // The ways it closes. Each part starts from a fresh Start, so one failing doesn't carry on into the next.
        func reopen() -> Bool {
            start.close()
            driver.pump(0.2)
            start.toggle()
            return driver.waitFor(2) { panel.isKeyWindow } != nil
        }
        guard reopen() else { check(false, "it opens again"); return finish() }
        check(start.view.search.stringValue.isEmpty && start.query.isEmpty, "it opens again with an empty search")
        var ended = searchEnds
        start.toggle()
        check(driver.waitFor(1) { !panel.isVisible } != nil && searchEnds == ended + 1, "another ⌘ tap closes it, ending the search")
        guard reopen() else { check(false, "it opens again"); return finish() }
        ended = searchEnds
        driver.press(kVK_Escape)
        check(driver.waitFor(1) { !panel.isVisible } != nil && searchEnds == ended + 1, "Esc closes it")
        guard reopen() else { check(false, "it opens again"); return finish() }
        ended = searchEnds
        let area = panel.screen?.visibleFrame ?? .zero
        target.setFrame(NSRect(x: area.minX + 10, y: area.minY + 10, width: 90, height: 60), display: true)
        target.level = NSWindow.Level(rawValue: StartMenuPanel.level.rawValue - 1)
        target.backgroundColor = .systemGray
        target.orderFrontRegardless()
        driver.pump(0.3)
        driver.click(StartMenuLiveDriver.global(NSPoint(x: target.frame.midX, y: target.frame.midY)))
        check(driver.waitFor(1) { !panel.isVisible } != nil && searchEnds == ended + 1, "a click elsewhere closes it")
        target.orderOut(nil)
        check(!start.isWatching && NSApp.keyWindow !== panel, "closed, it watches nothing and has no keyboard")
        let main = start.view.main

        // Drags, on Alpha, Beta and Gamma, which are first in the grid. What each drag looked like just before it was
        // let go is noted.
        guard reopen() else { check(false, "it opens again"); return finish() }
        func seen(_ grid: StartMenuGrid) -> String {
            "dragged tile \(grid.lifted.map(String.init) ?? "none"), drop \(grid.drop.map { "\($0)" } ?? "none")"
        }
        var state = ""
        if let a = tile(main, 0), let b = tile(main, 1) {
            driver.drag(a, b) { state = seen(main) }
        }
        if case .folder(let made)? = start.layout.items.first {
            check(made.apps == [beta, alpha] && made.name == "Folder", "Alpha dragged onto Beta makes a folder of the two, called Folder")
            check(system.store.load() == start.layout && start.isShown, "start.json has it, and Start stayed open")
            if let folderTile = tile(main, 0) { driver.click(folderTile) }
            check(driver.waitFor(1) { start.openFolder == made.id && !start.view.folder.isHidden } != nil, "a click opens the folder")
            picture("folder", of: panel)
            if let name = StartMenuLiveDriver.point(start.view.folder.name.bounds, in: start.view.folder.name) {
                driver.click(name)
                trace("after a click on the name, typing goes to \(panel.firstResponder.map { "\(type(of: $0))" } ?? "nothing")"
                      + (panel.firstResponder === start.view.folder.name.currentEditor() ? " (the name)" : ""))
                driver.press(kVK_ANSI_A, .maskCommand)
                let editor = start.view.folder.name.currentEditor()
                trace("after ⌘A, \(editor?.selectedRange.length ?? -1) of \(editor?.string.count ?? -1) letters selected")
                driver.type("Tools")
                trace("the name field reads \(start.view.folder.name.currentEditor()?.string ?? start.view.folder.name.stringValue)")
                driver.press(kVK_Return)
                check(driver.waitFor(1) { start.layout.folder(made.id)?.name == "Tools" } != nil && system.store.load()?.folder(made.id)?.name == "Tools",
                      "its name clicked, ⌘A, \"Tools\" typed and ↩: renamed and saved (now \"\(start.layout.folder(made.id)?.name ?? "gone")\"; \(heard()))")
            }
            let card = start.view.folder.grid
            if start.openFolder != nil, let from = tile(card, 1), let gap = tile(main, 1, 0.12, 0.4) {
                driver.drag(from, gap, via: [CGPoint(x: from.x, y: from.y - 260)]) { state = seen(main) }
                check(mainPaths() == [beta, alpha, gamma, delta] && start.openFolder == nil,
                      "Alpha dragged out of the folder to before Gamma: the folder, left with Beta, dissolves (\(short(mainPaths())); \(state))")
            }
        } else {
            check(false, "Alpha dragged onto Beta makes a folder (now \(short(mainPaths())); \(state); \(heard()))")
        }
        if let index = start.layout.items.firstIndex(of: .app(gamma)), let from = tile(main, index), let gap = tile(main, 0, 0.1, 0.4) {
            driver.drag(from, gap) { state = seen(main) }
            check(start.layout.items.first == .app(gamma), "Gamma dragged to the front (\(short(mainPaths())); \(state); \(heard()))")
        }
        if let index = start.layout.items.firstIndex(of: .app(alpha)), let app = tile(main, index) {
            driver.click(app)
            check(driver.waitFor(1) { !panel.isVisible } != nil && opened.last?.path == alpha, "a click on an app opens it and Start closes")
        }

        // The right-click menu and pins.
        guard reopen() else { check(false, "it opens again"); return finish() }
        func rightClick(_ path: String) -> NSMenu? {
            guard let point = start.layout.items.firstIndex(of: .app(path)).flatMap({ tile(main, $0) }) else { return nil }
            menuOpen.set(false)
            return driver.rightClick(point, opened: menuOpen) ? start.lastMenu : nil
        }
        let onTop = start.layout.items.firstIndex(of: .app(gamma)).flatMap { tile(main, $0) }.map(windowAt) ?? "no point"
        if let menu = rightClick(gamma) {
            let titles = menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
            check(titles == ["Open", "Pin to Top", "-", "Show in Finder", "-", "Move to Trash…"], "a right-click opens its menu: \(titles.joined(separator: " | "))")
            check(driver.waitFor(1) { start.isShown && panel.isKeyWindow } != nil, "and Esc closes the menu, not Start, which has the keyboard again (\(heard()))")
            menu.performActionForItem(at: menu.indexOfItem(withTitle: "Pin to Top"))
        } else {
            check(false, "a right-click on an app opens its menu (on top there: \(onTop); \(heard()))")
        }
        if let betaApp = start.apps.first(where: { $0.path == beta }) {
            let second = start.menu(for: betaApp)
            second.performActionForItem(at: second.indexOfItem(withTitle: "Pin to Top"))
        }
        driver.pump(0.3)
        check(start.layout.pins == [gamma, beta] && !start.view.pinned.isHidden, "Pin to Top puts them in a row at the top")
        picture("pins", of: panel)
        if start.layout.pins.count == 2, let from = tile(start.view.pinned, 1), let gap = tile(start.view.pinned, 0, 0.1, 0.4) {
            var state = ""
            driver.drag(from, gap) { state = "dragged tile \(start.view.pinned.lifted.map(String.init) ?? "none")" }
            check(start.layout.pins == [beta, gamma], "a pin dragged to the front of its row (\(state))")
        }

        // Move to Trash, through the menu's question.
        let deltaURL = URL(fileURLWithPath: delta)
        func askToTrash() -> Bool {
            guard let menu = rightClick(delta) else { return false }
            let item = menu.indexOfItem(withTitle: "Move to Trash…")
            guard item >= 0 else { return false }
            menu.performActionForItem(at: item)
            return driver.waitFor(2) { panel.attachedSheet?.isKeyWindow == true } != nil
        }
        func texts(_ view: NSView?) -> [String] {
            guard let view else { return [] }
            return ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap { texts($0) }
        }
        if askToTrash() {
            check(texts(panel.attachedSheet?.contentView).contains("Move “Start Test Delta \(tag)” to the Trash?"), "Move to Trash… asks first, naming the app")
            check(start.isShown && onScreen(panel.attachedSheet), "the question is on screen, Start still open behind it")
            picture("trash-question", of: panel.attachedSheet)
            driver.press(kVK_Escape)
            driver.pump(0.8)
            check(panel.attachedSheet == nil && fm.fileExists(atPath: delta) && start.isShown, "Esc says no: nothing moves, Start stays open")
        } else {
            check(false, "Move to Trash… asks first, in a sheet on Start")
        }
        let finder = FinderWindow.permission(ask: false)
        note("RubberMAC may control Finder: \(finder == noErr ? "yes" : "no (status \(finder))"), so \(finder == noErr ? "Finder" : "NSWorkspace") moves it")
        // A destructive button takes no ↩ on macOS, so it's clicked.
        func button(_ title: String, in view: NSView?) -> NSButton? {
            guard let view else { return nil }
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap { button(title, in: $0) }.first
        }
        if start.isShown, askToTrash(), let yes = button("Move to Trash", in: panel.attachedSheet?.contentView),
           let point = StartMenuLiveDriver.point(yes.bounds, in: yes) {
            driver.click(point)
            check(driver.waitFor(10) { !fm.fileExists(atPath: delta) } != nil, "a click on Move to Trash says yes: the app leaves its folder")
            check(driver.waitFor(2) { !start.apps.contains { $0.path == delta } && !start.layout.allApps.contains(delta) } != nil,
                  "and vanishes from Start")
            check(start.isShown, "Start stays open (\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none") in front)")
            let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            let trashed = trash.appendingPathComponent(deltaURL.lastPathComponent)
            check(fm.fileExists(atPath: trashed.path), "it's in the Trash")
            // Finder keeps where each item came from in the Trash's .DS_Store (a "ptbL" record after its name), which is
            // what Put Back reads.
            let name = Data(deltaURL.lastPathComponent.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] })
            let putBack = driver.waitFor(6) {
                guard let store = try? Data(contentsOf: trash.appendingPathComponent(".DS_Store")) else { return false }
                var from = store.startIndex
                while let at = store.range(of: name, in: from..<store.endIndex) {
                    if store[at.upperBound...].prefix(4) == Data("ptbL".utf8) { return true }
                    from = at.upperBound
                }
                return false
            }
            note("Put Back record for it in the Trash's .DS_Store: \(putBack.map { "found after \($0) ms" } ?? "not found in 6 s")")
            do {
                try fm.removeItem(at: trashed)
                check(true, "taken back out of the Trash")
            } catch {
                check(false, "taken back out of the Trash (\((error as NSError).code)); remove \(trashed.lastPathComponent) by hand")
            }
        } else {
            check(false, "the question comes again")
        }

        guard reopen() else { check(false, "it opens again"); return finish() }
        driver.press(kVK_Escape)
        check(driver.waitFor(1) { !panel.isVisible } != nil && !start.isWatching, "Esc closes it")
        check(NSWorkspace.shared.frontmostApplication == previous, "and the app in front never changed")
        return finish()
    }
}
