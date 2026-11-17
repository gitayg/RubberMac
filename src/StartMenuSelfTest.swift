import AppKit

// --selftest startmenu [folder]: Start with nothing on screen. Which apps are found (in scratch folders, then this Mac's
// own, read only), the user's order (new apps at the end, gone ones gone, folders made, taken apart and dissolved, pins),
// start.json written and read back, search, where a drop lands, the keys, the right-click menu and its Move to Trash
// question, the settings row, the window's kind and place, and Start drawn in light and dark to PNGs in the folder.
// Uses scratch files and a stand-in for opening and trashing; leaves start.json and every stored setting as they were.
extension StartMenu {
    typealias Check = (Bool, String) -> Void

    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func note(_ text: String) { lines.append("     \(text)") }

        NSApp.setActivationPolicy(.accessory)
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        // Less the focus order, which the running RubberMAC writes whenever a window comes forward.
        func settings() -> NSDictionary? {
            UserDefaults.standard.persistentDomain(forName: domain).map { $0.filter { $0.key != "focusHistory" } as NSDictionary }
        }
        let stored = settings()
        let realStore = try? Data(contentsOf: StartMenuStore.defaultURL)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("startmenu-selftest-\(UUID().uuidString.prefix(8))")
        let args = CommandLine.arguments
        let folder = args.firstIndex(of: "startmenu").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("startmenu-selftest-pictures")

        scanChecks(scratch, check, note)
        layoutChecks(check)
        storeChecks(scratch, check)
        searchChecks(check)
        dropChecks(check)
        controllerChecks(scratch, pictures: folder, check, note)
        windowChecks(check)
        settingsChecks(check)
        try? FileManager.default.removeItem(at: scratch)

        check((try? Data(contentsOf: StartMenuStore.defaultURL)) == realStore, "the real start.json is as it was (\(realStore.map { "\($0.count) bytes" } ?? "none"))")
        let after = settings()
        check(stored?.isEqual(after) ?? (after == nil), "no stored setting changed")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    // A made-up app: a folder with an Info.plist, enough for Finder and the scan to call it an app.
    static func makeScratchApp(_ url: URL) {
        let contents = url.appendingPathComponent("Contents")
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleName": url.deletingPathExtension().lastPathComponent, "CFBundlePackageType": "APPL"]
        info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
    }

    // MARK: Finding apps

    private static func scanChecks(_ scratch: URL, _ check: Check, _ note: (String) -> Void) {
        let fm = FileManager.default
        let root = scratch.appendingPathComponent("Applications")
        let home = scratch.appendingPathComponent("Home Applications")
        let elsewhere = scratch.appendingPathComponent("Elsewhere")
        for path in ["Alpha.app", "Utilities/Beta.app", "Vendor/Tools/Gamma.app", "A/B/C/Too Deep.app", "Kit.bundle/Contents/Inside.app",
                     ".Secret.app", "Café Menu.app", "Visual Studio Code.app"] {
            makeScratchApp(root.appendingPathComponent(path))
        }
        makeScratchApp(home.appendingPathComponent("Epsilon.app"))
        makeScratchApp(elsewhere.appendingPathComponent("Delta.app"))
        try? fm.createSymbolicLink(at: root.appendingPathComponent("Alias.app"), withDestinationURL: root.appendingPathComponent("Alpha.app"))
        try? fm.createSymbolicLink(at: root.appendingPathComponent("Linked Folder"), withDestinationURL: elsewhere)
        try? fm.createSymbolicLink(at: root.appendingPathComponent("Linked Delta.app"), withDestinationURL: elsewhere.appendingPathComponent("Delta.app"))
        try? "not an app".write(to: root.appendingPathComponent("Readme.txt"), atomically: true, encoding: .utf8)
        for path in ["Flagged.app", "Flagged Folder"] {
            makeScratchApp(root.appendingPathComponent(path == "Flagged.app" ? path : "\(path)/Omega.app"))
            var hidden = URLResourceValues()
            hidden.isHidden = true
            var url = root.appendingPathComponent(path)
            try? url.setResourceValues(hidden)
        }

        let found = StartMenuApps.scan([root, home, scratch.appendingPathComponent("Missing")])
        let names = found.map(\.name)
        check(names == ["Alpha", "Beta", "Café Menu", "Epsilon", "Gamma", "Linked Delta", "Visual Studio Code"],
              "scratch folders: apps at the top, in Utilities and two folders down, in the second folder, by name (\(names.joined(separator: ", ")))")
        check(!names.contains("Too Deep") && !names.contains("Inside") && !names.contains("Secret") && !names.contains("Delta")
              && !names.contains("Flagged") && !names.contains("Omega"),
              "not three folders down, inside a package, hidden (by name or by Finder's flag), or through a link to a folder")
        check(!names.contains("Alias"), "a link to an app already listed isn't listed twice")
        check(found.first { $0.name == "Linked Delta" }?.path == root.appendingPathComponent("Linked Delta.app").path,
              "a link to an app elsewhere is listed by the link's own path, as Safari's is")
        check(found.allSatisfy { !$0.isSystem }, "none of them is a system app")

        let start = Date()
        let real = StartMenuApps.scan()
        let ms = Int(-start.timeIntervalSinceNow * 1000)
        let counts = StartMenuApps.roots.map { root in "\(root.path): \(real.filter { $0.path.hasPrefix(root.path + "/") }.count)" }
        note("this Mac: \(real.count) apps in \(ms) ms (\(counts.joined(separator: ", ")))")
        check(real.count > 20 && ms < 2000, "this Mac's apps are found, in under 2 s")
        let terminal = real.first { $0.path == "/System/Applications/Utilities/Terminal.app" }
        check(terminal?.name == "Terminal" && terminal?.isSystem == true, "Terminal, from /System/Applications/Utilities, as a system app")
        if fm.fileExists(atPath: "/Applications/Safari.app") {
            let safari = real.first { $0.path == "/Applications/Safari.app" }
            check(safari?.name == "Safari" && safari?.isSystem == true, "Safari, by its link in /Applications, as a system app")
        }
        check(real.contains { $0.path.hasPrefix("/Applications/") && !$0.isSystem }, "apps in /Applications that can go to the Trash")
        check(!real.contains { $0.path.dropLast(4).contains(".app/") }, "nothing from inside an app")
        check(Set(real.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }).count == real.count, "no app twice")
        check(real.map(\.name) == real.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "A to Z")
    }

    // MARK: The order

    private static func layoutChecks(_ check: Check) {
        typealias L = StartMenuLayout
        func apps(_ layout: L) -> [String] {
            layout.items.map { item in
                switch item {
                case .app(let path): return path
                case .folder(let folder): return "[" + folder.apps.joined(separator: ",") + "]"
                }
            }
        }
        func folder(_ apps: [String], id: String = "f") -> StartMenuItem { .folder(StartMenuFolder(id: id, name: "Work", apps: apps)) }

        check(apps(L().fitted(to: ["a", "b", "c"])) == ["a", "b", "c"], "the first time, every app in the order given (A to Z)")
        var layout = L(pins: [], items: [.app("c"), .app("a"), .app("b")])
        check(apps(layout.fitted(to: ["a", "b", "c", "d"])) == ["c", "a", "b", "d"], "a newly installed app goes at the end")
        check(apps(layout.fitted(to: ["a", "c"])) == ["c", "a"], "a removed app vanishes")
        check(apps(L(items: [folder(["a", "b"]), .app("c")]).fitted(to: ["a", "c"])) == ["a", "c"],
              "a folder left with one app becomes that app, in its place")
        check(apps(L(items: [folder(["a", "b"]), .app("c")]).fitted(to: ["c"])) == ["c"], "and one left with none goes")
        check(L(pins: ["x", "a", "a"], items: []).fitted(to: ["a"]).pins == ["a"], "pins of removed apps go, and each app is pinned once")
        check(apps(L(items: [.app("a"), folder(["a", "b"])]).fitted(to: ["a", "b"])) == ["a", "b"], "an app is in one place only")

        layout = L(items: ["a", "b", "c", "d"].map { .app($0) })
        var moved = layout
        check(moved.move(.main(0), to: .main(3)) && apps(moved) == ["b", "c", "a", "d"], "drag to reorder: forward (\(apps(moved)))")
        moved = layout
        check(moved.move(.main(3), to: .main(0)) && apps(moved) == ["d", "a", "b", "c"], "and back (\(apps(moved)))")
        moved = layout
        check(!moved.move(.main(1), to: .main(1)) && !moved.move(.main(1), to: .main(2)) && moved == layout, "a drop where it was changes nothing")

        moved = L(items: ["a", "b", "c"].map { .app($0) })
        check(moved.move(.main(0), to: .onto(2)) && apps(moved) == ["b", "[c,a]"], "an app dropped onto another makes a folder of the two there (\(apps(moved)))")
        if case .folder(let made)? = moved.items.last {
            check(made.name == "Folder", "named \"Folder\"")
        } else {
            check(false, "named \"Folder\"")
        }
        moved = L(items: [folder(["a", "b"]), .app("c")])
        check(moved.move(.main(1), to: .onto(0)) && apps(moved) == ["[a,b,c]"], "onto a folder, it joins the folder")
        moved = L(items: [folder(["a", "b"]), .app("c")])
        check(!moved.move(.main(0), to: .onto(1)) && !layout.allows(.main(0), to: .onto(0)), "a folder can't go into a folder, nor an app onto itself")

        moved = L(items: [folder(["a", "b", "c"]), .app("d")])
        check(moved.move(.folder("f", 2), to: .main(2)) && apps(moved) == ["[a,b]", "d", "c"], "dragged out of a folder, it's on the grid again")
        moved = L(items: [folder(["a", "b"]), .app("c")])
        check(moved.move(.folder("f", 0), to: .main(2)) && apps(moved) == ["b", "c", "a"], "a folder left with one app dissolves into it (\(apps(moved)))")
        moved = L(items: [folder(["a", "b", "c"]), .app("d")])
        check(moved.move(.folder("f", 0), to: .onto(1)) && apps(moved) == ["[b,c]", "[d,a]"], "out of a folder onto another app: a new folder")
        moved = L(items: [folder(["a", "b", "c"])])
        check(moved.move(.folder("f", 0), to: .folder("f", 3)) && apps(moved) == ["[b,c,a]"], "reordered inside a folder")
        check(!moved.move(.folder("f", 0), to: .onto(0)), "dropped back onto its own folder: nothing")

        moved = L(pins: ["a", "b", "c"], items: [])
        check(moved.move(.pin(2), to: .pin(0)) && moved.pins == ["c", "a", "b"], "pins keep their own order, by dragging")
        moved = L(pins: ["a"], items: [.app("a"), .app("b")])
        check(!moved.move(.main(1), to: .pin(0)) && !moved.move(.pin(0), to: .main(0)), "between the pinned row and the grid: nothing")
        moved.pin("b")
        moved.pin("b")
        check(moved.pins == ["a", "b"] && moved.isPinned("b"), "pinning adds to the end, once")
        moved.unpin("a")
        check(moved.pins == ["b"] && moved.items.count == 2, "unpinning leaves the app on the grid")

        moved = L(items: [folder(["a", "b"])])
        moved.rename("f", to: "  Games  ")
        check(moved.folder("f")?.name == "Games", "a folder's name is what's typed, trimmed")
        moved.rename("f", to: " ")
        check(moved.folder("f")?.name == "Folder", "and \"Folder\" when nothing is")
        let before = L(items: ["a", "b"].map { .app($0) })
        check(before.allows(.main(0), to: .onto(1)) && before == L(items: ["a", "b"].map { .app($0) }), "asking whether a drop is allowed changes nothing")
    }

    private static func storeChecks(_ scratch: URL, _ check: Check) {
        let store = StartMenuStore(url: scratch.appendingPathComponent("Support/ScreenTools/start.json"))
        check(store.load() == nil, "no start.json yet: nothing read")
        let layout = StartMenuLayout(pins: ["/Applications/A.app"],
                                     items: [.app("/Applications/A.app"),
                                             .folder(StartMenuFolder(id: "x", name: "Tools", apps: ["/Applications/B.app", "/Applications/C.app"]))])
        do {
            try store.save(layout)
            check(store.load() == layout, "saved and read back the same, its folder made")
            let text = (try? String(contentsOf: store.url, encoding: .utf8)) ?? ""
            check(text.contains("\"app\" : \"/Applications/A.app\"") && text.contains("\"folder\"") && text.contains("\"pins\""),
                  "start.json reads plainly: {\"app\": path} and {\"folder\": …}")
        } catch {
            check(false, "saved (\(error.localizedDescription))")
        }
        try? "{ not json".write(to: store.url, atomically: true, encoding: .utf8)
        check(store.load() == nil, "a damaged start.json is read as none, so Start comes up A to Z")
        check(StartMenuStore.defaultURL.path.hasSuffix("Library/Application Support/ScreenTools/start.json"), "the real one is in RubberMAC's data folder")
    }

    // MARK: Search

    private static func searchChecks(_ check: Check) {
        let names = ["Visual Studio Code", "TextEdit", "Terminal", "Café Menu", "Microsoft Word", "QuickTime Player", "System Settings"]
        let apps = names.map { StartMenuApp(path: "/Applications/\($0).app", name: $0, isSystem: false) }
        func found(_ query: String) -> [String] { StartMenuSearch.results(apps, query).map(\.name) }
        check(found("code") == ["Visual Studio Code"], "\"code\" finds Visual Studio Code")
        check(found("CODE") == ["Visual Studio Code"] && found("Visual studio  c") == ["Visual Studio Code"], "in any case, across words")
        check(found("code VIS") == ["Visual Studio Code"] && found("studio x").isEmpty, "each word typed starts a word of the name, in any order")
        check(found("ode").isEmpty && found("isual").isEmpty, "but not from the middle of a word")
        check(found("cafe") == ["Café Menu"] && found("CAFÉ") == ["Café Menu"] && found("menu") == ["Café Menu"], "accents don't matter")
        check(found("edit") == ["TextEdit"] && found("time") == ["QuickTime Player"], "a capital inside a word starts one (TextEdit, QuickTime)")
        check(found("s") == ["System Settings", "Visual Studio Code"], "names that start with it come first (\(found("s")))")
        check(found("te") == ["TextEdit", "Terminal"], "otherwise in the given order")
        check(found("").isEmpty && found("   ").isEmpty, "nothing typed finds nothing")
    }

    // MARK: Drops

    private static func dropChecks(_ check: Check) {
        typealias G = StartMenuGrid
        func drops(_ x: CGFloat, _ y: CGFloat, onto: Bool = true) -> [G.Drop] {
            G.drops(at: NSPoint(x: x, y: y), columns: 4, count: 6, allowsOnto: onto).map(\.drop)
        }
        check(drops(150, 38) == [.onto(1), .before(1)], "over the middle of a tile's icon: onto it, else before it")
        check(drops(150, 38, onto: false) == [.before(1)], "where folders can't be made, just before it")
        check(drops(110, 50) == [.before(1)] && drops(200, 50) == [.before(2)], "nearer a tile's left edge before it, its right edge after it")
        check(drops(10, 150) == [.before(4)], "the second row")
        check(drops(300, 150) == [.before(6)] && drops(50, 300) == [.before(6)] && drops(-5, 10) == [.before(0)],
              "past the last tile, at the end; left of the first, at the start")
        let bar = G.drops(at: NSPoint(x: 300, y: 150), columns: 4, count: 6, allowsOnto: true).first?.bar
        check(bar.map { abs($0.midX - G.frame(of: 5, columns: 4).maxX) < 1 } == true, "the bar for the end stands after the last tile")
        let grid = StartMenuGrid(kind: .main)
        grid.columns = 4
        grid.tiles = (0..<6).map { StartMenuTile(kind: .app(StartMenuApp(path: "/x/\($0).app", name: "\($0)", isSystem: false))) }
        check(grid.index(at: NSPoint(x: 10, y: 10)) == 0 && grid.index(at: NSPoint(x: 120, y: 110)) == 5
              && grid.index(at: NSPoint(x: 500, y: 10)) == nil && grid.index(at: NSPoint(x: 230, y: 110)) == nil,
              "a click finds its tile, and none past the edge or the last one")
    }
}
