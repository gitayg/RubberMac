import AppKit

// --selftest previews: the saved focus order is kept within a boot and dropped after one; the switcher drawn off
// screen with made-up windows and pictures (saved as a PNG to look at); and, with Screen Recording allowed, a picture
// taken of every window the switcher lists. Reports counts and timings, never titles or pictures of real windows.
extension WindowThumbnails {
    static func selfTestReport(png: URL) -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }

        let boot = Settings.bootTime
        check(Settings.focusHistory(from: ["boot": boot, "ids": [3, 1, 2]], boot: boot) == [3, 1, 2],
              "the focus order saved in this boot is read back")
        check(Settings.focusHistory(from: ["boot": boot - 60, "ids": [3, 1, 2]], boot: boot).isEmpty,
              "one saved before a reboot is dropped (window IDs start over)")
        check(Settings.focusHistory(from: nil, boot: boot).isEmpty, "nothing saved yet reads as no history")
        lines.append("the running app has saved \(Settings.focusHistory.count) windows' focus order this boot")

        // Every window fits on the screen, with nothing to scroll to, up to 80 of them on a 14-inch screen.
        let space = NSSize(width: 1512 * 0.96 - 24, height: 949 * 0.96 - 24)
        let overflow = (1...80).filter { count in
            let (tile, columns, visibleRows) = SwitcherPanel.layout(count: count, fitting: space)
            let rows = (count + columns - 1) / columns
            return visibleRows < rows || CGFloat(columns) * tile.width > space.width || CGFloat(rows) * tile.height > space.height
        }
        check(overflow.isEmpty, "1 to 80 windows all fit on screen without scrolling (overflowing: \(overflow.prefix(5)))")
        let fifteen = SwitcherPanel.layout(count: 15, fitting: space)
        check(fifteen.tile.width > 270 && fifteen.columns * ((15 + fifteen.columns - 1) / fifteen.columns) >= 15,
              "15 windows get pictures \(Int(fifteen.tile.width - 2 * SwitcherTileView.padding)) points wide in \(fifteen.columns) columns")

        NSApp.setActivationPolicy(.accessory)
        let me = getpid()
        // Made-up windows placed on the real main screen, in Accessibility coordinates.
        let screen = NSScreen.screens.first?.frame.size ?? NSSize(width: 1512, height: 982)
        let (w, h, top) = (screen.width, screen.height, CGFloat(33))
        let fake: [(String, String, CGRect, Bool, Bool)] = [
            ("Microsoft Teams", "Chat", CGRect(x: 0, y: top, width: w / 2, height: h - top), false, true),
            ("Microsoft Teams", "Meeting", CGRect(x: w * 0.58, y: h * 0.18, width: w * 0.34, height: h * 0.5), false, true),
            ("Microsoft Outlook", "Inbox", CGRect(x: 0, y: top, width: w, height: h - top), false, true),
            ("Finder", "Downloads", CGRect(x: w * 0.2, y: h * 0.3, width: w * 0.4, height: h * 0.4), true, true),
            ("Notes", "Right half, no picture yet", CGRect(x: w / 2, y: top, width: w / 2, height: h - top), false, false),
            ("Safari", "A wide page", CGRect(x: w * 0.05, y: h * 0.1, width: w * 0.9, height: h * 0.6), false, true),
            ("Terminal", "Small, top right", CGRect(x: w * 0.65, y: top, width: w * 0.35, height: h * 0.35), false, true),
            ("Calendar", "Bottom left, no picture yet", CGRect(x: 0, y: h * 0.55, width: w * 0.45, height: h * 0.45), false, false),
            ("Microsoft Outlook", "Message", CGRect(x: w * 0.25, y: h * 0.15, width: w * 0.5, height: h * 0.7), false, true),
        ]
        let entries = fake.enumerated().map { i, item in
            SwitcherEntry(window: AX.app(me), pid: me, windowID: CGWindowID(900_000 + i), appName: item.0, title: item.1,
                          isMinimized: item.3, frame: item.2)
        }
        let pictures = WindowThumbnails()
        for (i, item) in fake.enumerated() where item.4 {
            pictures.pictures[CGWindowID(900_000 + i)] = sample(item.2.size, hue: CGFloat(i) / CGFloat(fake.count))
        }
        let panel = SwitcherPanel()
        let view = panel.makeContent(entries, selected: 1, fitting: NSScreen.screens.first?.visibleFrame.size ?? screen,
                                     pictures: pictures)
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: png)
        }
        check(FileManager.default.fileExists(atPath: png.path), "drew the switcher with pictures: \(png.path)")

        // A click on the fourth tile, wherever on it (picture, title, map), picks the fourth window.
        var clicked: [Int] = []
        panel.onClick = { clicked.append($0) }
        func tiles(in view: NSView) -> [SwitcherTileView] {
            view.subviews.flatMap { ($0 as? SwitcherTileView).map { [$0] } ?? tiles(in: $0) }
        }
        let fourth = tiles(in: view)[3]
        let spots = [NSPoint(x: fourth.bounds.midX, y: fourth.bounds.maxY - 30), NSPoint(x: 40, y: 20),
                     NSPoint(x: fourth.bounds.maxX - 20, y: 20)].map { fourth.convert($0, to: view) }
        let hits = spots.map { view.hitTest($0) }
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        hits.forEach { $0?.mouseDown(with: down) }
        check(hits.allSatisfy { $0 === fourth } && clicked == [3, 3, 3],
              "a click on a window's picture, title or map picks that window (picked \(clicked))")

        let listed = SwitcherSource.snapshot()
        let screens = NSScreen.screens.map(\.frame)
        let primaryHeight = screens.first?.height ?? 0
        let placed = listed.filter { entry in
            entry.frame.map { WindowMapView.appKit($0, primaryHeight: primaryHeight) }
                .map { place in screens.contains { $0.intersects(place) } } == true
        }
        let open = listed.filter { !$0.isMinimized && $0.isOnCurrentSpace }
        check(!open.isEmpty && open.allSatisfy { entry in placed.contains { $0.windowID == entry.windowID } },
              "every open window's place is on a screen: \(placed.count) of \(listed.count) listed have one")
        guard ScreenText.hasPermission else {
            lines.append("skipped real pictures: Screen Recording not allowed")
            return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
        }
        let real = WindowThumbnails()
        var got: Set<CGWindowID> = []
        let start = Date()
        var last = start
        real.refresh(listed.compactMap(\.windowID)) { id, _ in got.insert(id); last = Date() }
        // Done when every window has one, or nothing more came for a second (a window may have none to give).
        let until = Date(timeIntervalSinceNow: 10)
        while got.count < listed.count && Date() < until && (got.isEmpty || -last.timeIntervalSinceNow < 1) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        let ms = Int(last.timeIntervalSince(start) * 1000)
        let minimized = listed.filter(\.isMinimized)
        let openGot = open.filter { $0.windowID.map(got.contains) == true }.count
        let minimizedGot = minimized.filter { $0.windowID.map(got.contains) == true }.count
        check(openGot == open.count, "a picture of each open window: \(openGot) of \(open.count) (the last came \(ms) ms after asking)")
        lines.append("minimized windows with a picture: \(minimizedGot) of \(minimized.count)")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    // A stand-in window: a coloured page with a title bar and a few lines of "text".
    private static func sample(_ size: NSSize, hue: CGFloat) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            NSColor(calibratedHue: hue, saturation: 0.25, brightness: 0.95, alpha: 1).setFill()
            rect.fill()
            NSColor(calibratedHue: hue, saturation: 0.6, brightness: 0.6, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.08).fill()
            NSColor.darkGray.setFill()
            for line in 0..<6 {
                NSRect(x: rect.width * 0.08, y: rect.height * (0.2 + 0.11 * CGFloat(line)),
                       width: rect.width * (line % 2 == 0 ? 0.7 : 0.5), height: rect.height * 0.04).fill()
            }
            return true
        }
    }
}
