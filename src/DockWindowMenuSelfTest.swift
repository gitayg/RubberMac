import AppKit

// --selftest dockmenu-ui [png]: the Dock's window menu with made-up windows, never real ones, and needing no
// permission. How large the rows are for 1 to 40 windows, where the menu sits for each Dock edge and icon position,
// the menu drawn off screen (saved as a PNG to look at), each copy's usage on its rows and fitting the smallest ones,
// clicks on its rows, and a picture arriving late.
extension DockWindowMenu {
    static func selfTestReport(png: URL) -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }

        NSApp.setActivationPolicy(.accessory)
        let me = getpid()
        let app = AX.app(me)
        func entries(_ count: Int) -> [SwitcherEntry] {
            (0..<count).map { i in
                SwitcherEntry(window: app, pid: me, windowID: CGWindowID(910_000 + i), appName: "Made Up", title: "Window \(i + 1)",
                              isMinimized: false, frame: CGRect(x: 100, y: 100, width: 800, height: 500))
            }
        }
        func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            view.subviews.flatMap { ($0 as? T).map { [$0] } ?? views(type, in: $0) }
        }

        // A 14-inch screen with the menu bar on top and the Dock below its 1512×919 visible area.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let bottomVisible = CGRect(x: 0, y: 30, width: 1512, height: 919)
        let bottomIcon = CGRect(x: 745, y: 4, width: 22, height: 22)
        let room = Self.room(near: bottomIcon, edge: .bottom, screen: screen, visible: bottomVisible)
        let pictures = WindowThumbnails()
        let menu = DockWindowMenu()
        let smallest = DockWindowRow.size(pictureWidth: smallestPicture).height
        let fitAtSmallest = Int((room.height - 2 * inset) / smallest)
        var wrong: [Int] = []
        var widths: [Int: CGFloat] = [:]
        var scrolls: Int?
        for count in 1...40 {
            let content = menu.makeContent(entries(count), pictures: pictures, fitting: room)
            let (width, _) = layout(count: count, fitting: room)
            widths[count] = width
            guard let scroll = views(NSScrollView.self, in: content).first, let list = scroll.documentView else {
                wrong.append(count)
                continue
            }
            let rows = views(DockWindowRow.self, in: list)
            let shown = scroll.contentView.bounds
            let allShown = rows.allSatisfy { shown.contains($0.frame) }
            let rowHeight = DockWindowRow.size(pictureWidth: width).height
            // As large as allowed: one point wider and the rows would no longer all fit (or it's already the largest).
            let largest = width == largestPicture
                || CGFloat(count) * DockWindowRow.size(pictureWidth: width + 1).height > room.height - 2 * inset
            let inRoom = content.frame.width <= room.width && content.frame.height <= room.height
            let ok: Bool
            if count <= fitAtSmallest {
                ok = rows.count == count && allShown && largest && width >= smallestPicture && inRoom
            } else {
                // Past what fits, the smallest pictures and as many whole rows as fit, the rest scrolled to.
                ok = rows.count == count && !allShown && width == smallestPicture && inRoom
                    && list.frame.height > scroll.frame.height
                    && room.height - 2 * inset - scroll.frame.height < rowHeight
            }
            if !ok { wrong.append(count) }
            if !allShown && scrolls == nil { scrolls = count }
        }
        check(wrong.isEmpty, "1 to 40 windows in a \(Int(room.width))×\(Int(room.height)) room above a bottom Dock: every row shows "
              + "up to \(fitAtSmallest), past that the list scrolls (scrolling starts at \(scrolls.map(String.init) ?? "none"); "
              + "wrong: \(wrong.prefix(8)))")
        check(scrolls == fitAtSmallest + 1, "scrolling starts right after the \(fitAtSmallest) rows that fit at the smallest pictures")
        check(widths[3] == largestPicture && widths[1] == largestPicture,
              "1 and 3 windows get the full \(Int(largestPicture))-point pictures (3 got \(Int(widths[3] ?? 0)))")
        check(zip(widths.keys.sorted(), widths.keys.sorted().dropFirst()).allSatisfy { widths[$0]! >= widths[$1]! },
              "pictures only shrink as windows are added: "
              + [1, 6, 7, 10, 14, 15, 40].map { "\($0)→\(Int(widths[$0] ?? 0))" }.joined(separator: " "))

        // The rows past the bottom can be scrolled to: at the end of the list the last row shows whole and the first is gone.
        let long = menu.makeContent(entries(30), pictures: pictures, fitting: room)
        if let scroll = views(NSScrollView.self, in: long).first, let list = scroll.documentView {
            let rows = views(DockWindowRow.self, in: list)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: list.frame.height - scroll.contentView.bounds.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            let end = scroll.contentView.bounds
            check(rows.count == 30 && end.contains(rows[29].frame) && !end.intersects(rows[0].frame),
                  "30 windows' list scrolls to its last row (shown from \(Int(end.minY)) to \(Int(end.maxY)) of \(Int(list.frame.height)))")
        } else {
            check(false, "30 windows' list scrolls to its last row (no scroll view)")
        }

        // Each Dock edge, with the icon at both ends and in the middle, for a short list and a scrolling one.
        let edges: [(FullScreenDock.Edge, CGRect, [CGRect])] = [
            (.bottom, bottomVisible, [4, 745, 1486].map { CGRect(x: $0, y: 4, width: 22, height: 22) }),
            (.left, CGRect(x: 30, y: 0, width: 1482, height: 949), [4, 480, 920].map { CGRect(x: 4, y: $0, width: 22, height: 22) }),
            (.right, CGRect(x: 0, y: 0, width: 1482, height: 949), [4, 480, 920].map { CGRect(x: 1486, y: $0, width: 22, height: 22) }),
        ]
        var misplaced: [String] = []
        var placed = 0
        for (edge, visible, icons) in edges {
            for (n, icon) in icons.enumerated() {
                for count in [2, 30] {
                    let room = Self.room(near: icon, edge: edge, screen: screen, visible: visible)
                    let size = menu.makeContent(entries(count), pictures: pictures, fitting: room).frame.size
                    let frame = place(size, near: icon, edge: edge, screen: screen, visible: visible)
                    let beside: Bool
                    let centred: Bool
                    switch edge {
                    case .bottom: (beside, centred) = (frame.minY >= icon.maxY + gap - 0.5, abs(frame.midX - icon.midX) <= 1)
                    case .left: (beside, centred) = (frame.minX >= icon.maxX + gap - 0.5, abs(frame.midY - icon.midY) <= 1)
                    case .right: (beside, centred) = (frame.maxX <= icon.minX - gap + 0.5, abs(frame.midY - icon.midY) <= 1)
                    }
                    // Only the middle icon leaves room to centre on, and beside a side Dock only for a short list.
                    let mustCentre = n == 1 && (edge == .bottom || count == 2)
                    let onScreen = screen.contains(frame) && frame.maxY <= visible.maxY
                    placed += 1
                    if !(onScreen && !frame.intersects(icon) && beside && (centred || !mustCentre)) {
                        misplaced.append("\(edge.rawValue) icon at \(Int(icon.minX)),\(Int(icon.minY)) with \(count): \(frame)")
                    }
                }
            }
        }
        check(misplaced.isEmpty, "\(placed) placements (bottom, left and right Docks; icon at both ends and the middle; 2 and 30 "
              + "windows): on screen under the menu bar, clear of the icon, on its side and centred on it where there's room"
              + (misplaced.isEmpty ? "" : "; wrong: " + misplaced.prefix(3).joined(separator: "; ")))

        // Made-up windows: pictures drawn in code, one with none yet, one minimized, one on another desktop. The first
        // three are from one copy of the app, the last two from another (a pid past the largest a process can have).
        let otherCopy: pid_t = 100_001
        let fake: [(String, CGSize?, Bool, Bool)] = [
            ("Quarterly plan", CGSize(width: 1440, height: 900), false, true),
            ("A rather long title for a window about the trip, the bookings and what still needs paying", CGSize(width: 1200, height: 900),
             false, true),
            ("No picture yet", nil, false, true),
            ("Put away for later", CGSize(width: 1000, height: 700), true, true),
            ("Tall and narrow, elsewhere", CGSize(width: 600, height: 900), false, false),
        ]
        let made = fake.enumerated().map { i, item in
            var entry = SwitcherEntry(window: app, pid: i < 3 ? me : otherCopy, windowID: CGWindowID(920_000 + i), appName: "Made Up", title: item.0,
                                      isMinimized: item.2, frame: CGRect(x: 200 + 60 * i, y: 120, width: 700, height: 480))
            entry.isOnCurrentSpace = item.3
            return entry
        }
        let withPictures = WindowThumbnails()
        for (i, item) in fake.enumerated() {
            if let size = item.1 { withPictures.pictures[CGWindowID(920_000 + i)] = sample(WindowThumbnails.fitted(size), hue: CGFloat(i) / 5) }
        }
        var picked: [Int] = []
        menu.onPick = { picked.append($0) }
        let view = menu.makeContent(made, pictures: withPictures, fitting: room)
        let rows = views(DockWindowRow.self, in: view)

        // Each copy's usage, first before it's measured and then measured, on every row of that copy and only those.
        func texts(_ row: DockWindowRow) -> [String] { row.subviews.compactMap { ($0 as? NSTextField)?.stringValue } }
        let teams = ProcessUsage.text(copy: "Teams", cpu: 12, memoryBytes: 1_288_490_189)
        let work = ProcessUsage.text(copy: "Work", cpu: 3, memoryBytes: 734_003_200)
        menu.show(usage: ProcessUsage.text(copy: "Teams", cpu: nil, memoryBytes: 1_288_490_189), for: me)
        menu.show(usage: ProcessUsage.text(copy: "Work", cpu: nil, memoryBytes: 734_003_200), for: otherCopy)
        menu.show(usage: teams, for: me)
        menu.show(usage: work, for: otherCopy)
        let usageWrong = rows.enumerated().filter { i, row in
            let shown = texts(row)
            let mine = i < 3 ? teams : work
            return shown.filter { $0 == mine }.count != 1 || shown.contains(i < 3 ? work : teams)
                || shown.contains { $0.contains("CPU …") }
        }.map(\.offset)
        check(rows.count == 5 && usageWrong.isEmpty,
              "each copy's usage, updated once measured, is on every row of that copy and only those (\"\(teams)\" on rows 0 to 2, "
              + "\"\(work)\" on 3 and 4; wrong rows: \(usageWrong))")

        if rows.count > 1 { rows[1].isHighlighted = true }
        try? FileManager.default.removeItem(at: png)
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: png)
            check(FileManager.default.fileExists(atPath: png.path),
                  "drew 5 made-up windows from two copies of the app (the second hovered): \(png.path), "
                  + "\(bitmap.pixelsWide)×\(bitmap.pixelsHigh) pixels")
        } else {
            check(false, "drew 5 made-up windows")
        }
        if rows.count > 1 { rows[1].isHighlighted = false }

        // At the smallest pictures, the title, a note and the usage, or the title and the usage, all fit in the row,
        // one under another, centred on it, and a long usage line shows in full.
        let longest = ProcessUsage.text(copy: "Enterprise-Europe", cpu: 1234, memoryBytes: 13_207_024_435)
        var squeezed: [String] = []
        for minimized in [true, false] {
            let entry = SwitcherEntry(window: app, pid: me, windowID: CGWindowID(930_000), appName: "Made Up",
                                      title: "A title that is long enough to be cut in the middle of the row",
                                      isMinimized: minimized, frame: nil)
            let row = DockWindowRow(entry: entry, icon: nil, picture: nil, place: nil, screens: [screen], pictureWidth: smallestPicture)
            row.show(usage: ProcessUsage.text(copy: "Enterprise-Europe", cpu: nil, memoryBytes: 13_207_024_435))
            row.show(usage: longest)
            let labels = row.subviews.compactMap { $0 as? NSTextField }.sorted { $0.frame.minY > $1.frame.minY }
            let expected = minimized ? 3 : 2
            let inside = labels.allSatisfy { row.bounds.contains($0.frame) }
            let apart = zip(labels, labels.dropFirst()).allSatisfy { $0.frame.minY >= $1.frame.maxY }
            let block = (labels.first?.frame.maxY ?? 0) - (labels.last?.frame.minY ?? 0)
            let centred = abs((labels.first?.frame.maxY ?? 0) - block / 2 - row.bounds.midY) <= 1.5
            let usageLine = labels.last
            let whole = (usageLine?.intrinsicContentSize.width ?? .infinity) <= DockWindowRow.textWidth
            if !(labels.count == expected && usageLine?.stringValue == longest && inside && apart && centred && whole) {
                squeezed.append("\(expected) lines: \(labels.count) labels, " + labels.map { "\(Int($0.frame.minY))…\(Int($0.frame.maxY))" }
                    .joined(separator: " ") + " in a \(Int(row.bounds.height))-point row, usage \(usageLine?.stringValue == longest ? "" : "not ")"
                    + "last, \(Int(usageLine?.intrinsicContentSize.width ?? 0)) of \(Int(DockWindowRow.textWidth)) points wide")
            }
        }
        check(squeezed.isEmpty, "at the smallest \(Int(smallestPicture))-point pictures (\(Int(DockWindowRow.size(pictureWidth: smallestPicture).height))"
              + "-point rows) the usage line sits inside the row under the title and note, centred, and \"\(longest)\" fits whole"
              + (squeezed.isEmpty ? "" : "; wrong: " + squeezed.joined(separator: "; ")))

        // A click on row k, wherever on it (picture, title, the empty end), picks window k.
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        var stray: [String] = []
        for (k, row) in rows.enumerated() {
            let box = DockWindowRow.padding + (row.bounds.width - DockWindowRow.textWidth - DockWindowRow.gap - 2 * DockWindowRow.padding) / 2
            let spots = [NSPoint(x: box, y: row.bounds.midY), NSPoint(x: row.bounds.maxX - DockWindowRow.textWidth / 2, y: row.bounds.midY + 8),
                         NSPoint(x: row.bounds.maxX - 3, y: 3)]
            for spot in spots {
                let hit = view.hitTest(row.convert(spot, to: view))
                if hit !== row { stray.append("row \(k) at \(Int(spot.x)),\(Int(spot.y)) hit \(hit.map { "\(type(of: $0))" } ?? "nothing")") }
                hit?.mouseDown(with: down)
            }
        }
        let expected = rows.indices.flatMap { [$0, $0, $0] }
        check(rows.count == 5 && stray.isEmpty && picked == expected,
              "a click on a row's picture, title or empty end picks that row (picked \(picked))"
              + (stray.isEmpty ? "" : "; " + stray.prefix(3).joined(separator: "; ")))

        // The third row had no picture; one arrives.
        let late = sample(WindowThumbnails.fitted(CGSize(width: 1280, height: 800)), hue: 0.55)
        let third = rows.count > 2 ? rows[2] : nil
        func showsPicture(_ row: DockWindowRow?) -> (picture: Bool, map: Bool) {
            guard let row else { return (false, true) }
            let picture = row.subviews.compactMap { $0 as? NSImageView }.contains { !$0.isHidden && $0.image === late }
            let map = row.subviews.contains { $0 is WindowMapView && !$0.isHidden }
            return (picture, map)
        }
        let before = showsPicture(third)
        menu.show(late, for: CGWindowID(920_002))
        let after = showsPicture(third)
        let othersKept = rows.enumerated().filter { $0.offset != 2 }
            .allSatisfy { !$0.element.subviews.compactMap { $0 as? NSImageView }.contains { $0.image === late } }
        check(!before.picture && before.map && after.picture && !after.map && othersKept,
              "a picture arriving late replaces the third row's map with it, and only that row's")

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
