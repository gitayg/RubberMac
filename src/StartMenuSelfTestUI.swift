import AppKit

// The off-screen half of --selftest startmenu: a StartMenuController on scratch apps and a scratch start.json, driven as
// the keys, clicks, drops and the menu drive it, with opening apps and Finder swapped out; the window's settings; the
// settings row; and pictures.
extension StartMenu {
    static func controllerChecks(_ scratch: URL, pictures: URL, _ check: Check, _ note: (String) -> Void) {
        let fm = FileManager.default
        let root = scratch.appendingPathComponent("Controller Apps")
        for name in ["Alpha", "Beta", "Café Menu", "Gamma", "Visual Studio Code", "Delta", "Epsilon", "Zeta", "Eta"] {
            makeScratchApp(root.appendingPathComponent("\(name).app"))
        }
        var opened: [URL] = []
        var shownInFinder: [URL] = []
        var system = StartMenuController.System()
        system.roots = [root]
        system.store = StartMenuStore(url: scratch.appendingPathComponent("controller/start.json"))
        system.open = { opened.append($0) }
        system.showInFinder = { shownInFinder.append($0) }
        system.trash = { _, done in done(.failed("not in the self-test")) }
        system.searchStarts = {}
        system.searchEnds = {}
        let start = StartMenuController(system: system)
        func names() -> [String] { start.view.main.tiles.map(\.name) }
        func path(_ name: String) -> String { root.appendingPathComponent("\(name).app").path }

        start.refresh()
        check(names() == ["Alpha", "Beta", "Café Menu", "Delta", "Epsilon", "Eta", "Gamma", "Visual Studio Code", "Zeta"],
              "first time: A to Z (\(names().joined(separator: ", ")))")
        check(system.store.load() == start.layout, "and start.json is written")
        makeScratchApp(root.appendingPathComponent("Aardvark.app"))
        try? fm.removeItem(at: root.appendingPathComponent("Beta.app"))
        start.refresh()
        check(names().last == "Aardvark" && !names().contains("Beta"), "an app installed since is at the end, and one removed is gone")
        check(system.store.load()?.allApps.last == path("Aardvark"), "which start.json keeps")

        start.search("code")
        check(start.results.map(\.name) == ["Visual Studio Code"] && names() == ["Visual Studio Code"] && start.view.pinned.isHidden,
              "typing \"code\" shows only Visual Studio Code")
        check(start.selection == .init(kind: .results, index: 0) && start.view.main.selected == 0, "the first match is selected")
        check(start.command(#selector(NSResponder.insertNewline(_:))) && opened.last?.path == path("Visual Studio Code"), "↩ opens it")
        start.search("cafe")
        check(names() == ["Café Menu"], "\"cafe\" finds Café Menu")
        start.search("zz top")
        check(names().isEmpty && !start.view.empty.isHidden && start.view.empty.stringValue == "No apps match “zz top”", "no match says so")
        start.search("")
        check(names().count == 9 && start.selection == nil, "clearing the search shows everything again, nothing selected")

        // Pinned through the menu, as a right-click would.
        for name in ["Gamma", "Alpha"] {
            guard let app = start.apps.first(where: { $0.name == name }) else { continue }
            let menu = start.menu(for: app)
            menu.performActionForItem(at: menu.indexOfItem(withTitle: "Pin to Top"))
        }
        check(start.layout.pins == [path("Gamma"), path("Alpha")] && start.view.pinned.tiles.map(\.name) == ["Gamma", "Alpha"]
              && !start.view.pinned.isHidden, "Pin to Top puts apps in the pinned row, in the order pinned")
        if let alpha = start.apps.first(where: { $0.name == "Alpha" }) {
            let titles = start.menu(for: alpha).items.map { $0.isSeparatorItem ? "-" : $0.title }
            check(titles == ["Open", "Unpin", "-", "Show in Finder", "-", "Move to Trash…"], "a pinned app's menu: \(titles.joined(separator: " | "))")
            let menu = start.menu(for: alpha)
            menu.performActionForItem(at: menu.indexOfItem(withTitle: "Show in Finder"))
            check(shownInFinder.last?.path == alpha.path, "Show in Finder shows it in Finder")
        }
        let calculator = StartMenuApp(path: "/System/Applications/Calculator.app", name: "Calculator", isSystem: true)
        let systemTitles = start.menu(for: calculator).items.map { $0.isSeparatorItem ? "-" : $0.title }
        check(systemTitles == ["Open", "Pin to Top", "-", "Show in Finder"], "a system app's menu has no Move to Trash: \(systemTitles.joined(separator: " | "))")

        let pinned = start.view.pinned, main = start.view.main
        main.columns = 4
        start.moveSelection(.right)
        check(start.selection == .init(kind: .pins, index: 0), "→ with nothing selected selects the first pinned app")
        start.moveSelection(.right)
        start.moveSelection(.right)
        check(start.selection == .init(kind: .main, index: 0), "→ goes on from the pinned row to the grid")
        start.moveSelection(.down)
        check(start.selection == .init(kind: .main, index: 4), "↓ goes a row down (4 across)")
        start.moveSelection(.up)
        start.moveSelection(.up)
        check(start.selection == .init(kind: .pins, index: 0) && pinned.selected == 0 && main.selected == nil, "↑ from the grid's first row reaches the pinned row")
        start.moveSelection(.left)
        check(start.selection == .init(kind: .pins, index: 0), "← stops at the first")

        // Drops, as the grids hand them over.
        start.grid(main, beganDragging: 0)
        check(start.grid(main, allows: .onto(1)) && !start.grid(main, allows: .before(1)) && !start.grid(pinned, allows: .before(0)),
              "dragging Alpha: onto Café Menu is allowed, its own place and the pinned row aren't")
        check(start.grid(main, accepts: .onto(1)), "dropped onto Café Menu")
        start.gridEndedDrag(main)
        guard case .folder(let made)? = start.layout.items.first else { return check(false, "it made a folder") }
        check(made.apps == [path("Café Menu"), path("Alpha")] && made.name == "Folder" && names().first == "Folder",
              "a folder called Folder, where Café Menu was, with both")
        start.grid(main, clicked: 0)
        check(start.openFolder == made.id && !start.view.folder.isHidden && start.view.folder.grid.tiles.map(\.name) == ["Café Menu", "Alpha"],
              "a click on it opens it, showing its apps")
        check(start.view.folder.name.stringValue == "Folder", "with its name above them")
        start.rename(made.id, to: "Favourites")
        check(start.layout.folder(made.id)?.name == "Favourites" && system.store.load()?.folder(made.id)?.name == "Favourites", "renamed, and saved")
        drawPictures(start, pictures, "folder", check, note)
        start.grid(start.view.folder.grid, beganDragging: 1)
        check(start.grid(main, accepts: .before(main.tiles.count)), "Alpha dragged out of the folder to the end of the grid")
        start.gridEndedDrag(start.view.folder.grid)
        check(start.layout.items.first == .app(path("Café Menu")) && names().last == "Alpha" && start.openFolder == nil,
              "the folder, left with Café Menu, is Café Menu again")
        check(system.store.load() == start.layout, "every change is in start.json")

        start.grid(pinned, beganDragging: 1)
        check(start.grid(pinned, accepts: .before(0)) && start.layout.pins == [path("Alpha"), path("Gamma")], "pins dragged into another order")
        start.gridEndedDrag(pinned)

        start.grid(main, beganDragging: 0)
        _ = start.grid(main, accepts: .onto(1))
        start.gridEndedDrag(main)
        start.command(#selector(NSResponder.moveDown(_:)))
        start.command(#selector(NSResponder.moveDown(_:)))
        if case .folder(let second)? = start.layout.items.first {
            check(start.selection == .init(kind: .main, index: 0), "the keys reach a folder")
            start.command(#selector(NSResponder.insertNewline(_:)))
            check(start.openFolder == second.id, "↩ on a folder opens it")
            start.command(#selector(NSResponder.cancelOperation(_:)))
            check(start.openFolder == nil && start.selection == .init(kind: .main, index: 0), "Esc closes the folder first, leaving it selected")
        } else {
            check(false, "a second folder was made")
        }

        let opener = opened.count
        start.grid(pinned, clicked: 0)
        check(opened.count == opener + 1 && opened.last?.path == path("Alpha"), "a click on a pinned app opens it")
        drawPictures(start, pictures, "grid", check, note)
        start.search("a")
        drawPictures(start, pictures, "search", check, note)
        start.search("")

        if let gamma = start.apps.first(where: { $0.name == "Gamma" }) {
            let alert = StartMenuTrash.confirmation(for: gamma)
            check(alert.messageText == "Move “Gamma” to the Trash?" && alert.buttons.map(\.title) == ["Move to Trash", "Cancel"]
                  && alert.buttons[0].hasDestructiveAction, "Move to Trash asks first, naming the app: \(alert.messageText)")
            // As laid out for showing, which is when AppKit settles each button's key.
            alert.layout()
            let keys = alert.buttons.map { $0.keyEquivalent.unicodeScalars.map { String($0.value, radix: 16) }.joined() }
            check(keys == ["", "1b"], "Move to Trash takes a click (macOS gives a destructive button no ↩); Esc says no (keys \(keys.map { $0.isEmpty ? "none" : $0 }.joined(separator: ", ")))")
        }
    }

    // Each look, light and dark, from the view itself (the blurred background is the screen's, so it's left out).
    private static func drawPictures(_ start: StartMenuController, _ folder: URL, _ name: String, _ check: Check, _ note: (String) -> Void) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = start.view
            view.appearance = NSAppearance(named: appearance)
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return check(false, "\(name) drawn") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let colours = Set(stride(from: 0, to: bitmap.pixelsWide, by: 3).flatMap { x in
                stride(from: 0, to: bitmap.pixelsHigh, by: 3).compactMap { bitmap.colorAt(x: x, y: $0) }
            }.map { [$0.redComponent, $0.greenComponent, $0.blueComponent].map { Int($0 * 16) } })
            check(colours.count > 20, "\(name), \(look): drawn (\(colours.count) colours)")
            let url = folder.appendingPathComponent("start-\(name)-\(look).png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            note("picture: \(url.path)")
        }
        start.view.appearance = nil
    }

    static func windowChecks(_ check: Check) {
        let panel = StartMenuPanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        check(panel.styleMask.contains(.nonactivatingPanel) && panel.canBecomeKey && !panel.hidesOnDeactivate,
              "a panel that takes the keyboard without bringing RubberMAC forward")
        check(panel.level > .statusBar && panel.level < .popUpMenu, "above the Dock and the menu bar, below menus (level \(panel.level.rawValue))")
        check(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary),
              "on every desktop, full-screen apps' included")
        check(!panel.isVisible, "not on screen until opened")

        let laptop = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let (size, columns) = StartMenuView.size(for: laptop)
        let frame = StartMenuView.frame(of: size, in: laptop)
        check(columns == 7 && laptop.contains(frame) && abs(frame.midX - laptop.midX) <= 1 && abs(frame.midY - laptop.midY) <= 1,
              "centred on the screen (\(Int(frame.width)) × \(Int(frame.height)) on 1512 × 944, \(columns) across)")
        let small = NSRect(x: -1024, y: 200, width: 800, height: 560)
        let (smallSize, smallColumns) = StartMenuView.size(for: small)
        check(small.contains(StartMenuView.frame(of: smallSize, in: small)) && smallColumns < 7,
              "and fitted to a small screen left of the main one (\(Int(smallSize.width)) × \(Int(smallSize.height)), \(smallColumns) across)")
    }

    static func settingsChecks(_ check: Check) {
        let suite = "app.rubbermac.startmenu-selftest"
        let scratch = UserDefaults(suiteName: suite)!
        check(Settings.startMenuEnabled(in: scratch), "on unless turned off")
        scratch.set(false, forKey: Settings.startMenuKey)
        check(!Settings.startMenuEnabled(in: scratch), "and off once turned off")
        scratch.removePersistentDomain(forName: suite)
        check(StartMenu.shared.isEnabled == Settings.startMenuEnabled && !StartMenu.shared.wantsAccess,
              "the ⌘ tap follows the setting (now \(Settings.startMenuEnabled ? "on" : "off")), and Start needs no Accessibility of its own")

        let delegate = AppDelegate(lockWarning: LockWarning(timeoutOverride: nil))
        let rows = delegate.startMenuRows(SettingsFacts())
        check(rows.count == 1 && rows[0].title == "⌘ Alone Opens RubberMAC's Start, Not Spotlight's Apps"
              && rows[0].note == "Your own order, folders and pins; right-click an app to remove it", "the Keyboard page's row and its note")
        if case .toggle(let on)? = rows.first?.control {
            check(on == Settings.startMenuEnabled, "its switch shows the setting")
        } else {
            check(false, "it's a switch")
        }
        check(rows.first?.action.map { (rows[0].target as? NSObject)?.responds(to: $0) == true } == true, "and its target answers it (not pressed)")
        let keyboard = delegate.settingsPages().first { $0.id == "keyboard" }
        let titles = keyboard?.sections.flatMap { $0.rows.map(\.title) } ?? []
        let apps = titles.firstIndex { $0.hasPrefix("⌘ Alone Opens Apps") }
        check(apps.map { titles.indices.contains($0 + 1) && titles[$0 + 1] == rows.first?.title } == true, "right under ⌘ Alone Opens Apps")
    }
}
