import AppKit
import ScreenCaptureKit

// --selftest dockmenu [nolive] [dir/]: the click handling with made-up icons (what's held back, what's handed on, a
// drag handed on as press then move, a press held still handed on); which running apps' Dock icons are matched to
// their app; then, with a helper copy of this app (its own Dock icon, three windows): a click without the picker
// brings it forward (the old way), and with it opens the menu instead; a second click, Esc or a click elsewhere closes
// it, picking a row goes to that window, and with one window left the click goes on to the Dock. With a dir, saves a
// picture of the open menu there. Puts the pointer back.
extension DockWindowPicker {
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func finish() -> String { (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n") }
        // Through AppKit's event loop, as the running app has: the Dock's request to come forward and clicks on the
        // menu's rows arrive as events, which running the run loop alone never hands over.
        func pump(_ seconds: TimeInterval) {
            let until = Date(timeIntervalSinceNow: seconds)
            while let event = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        }

        // The handler alone, with an icon at a made-up place.
        let icon = DockItems.Item(url: URL(fileURLWithPath: "/Applications/Made Up.app"), frame: CGRect(x: 100, y: 930, width: 40, height: 50))
        let clicks = DockClicks()
        clicks.isEnabled = true
        clicks.itemAt = { icon.frame.contains($0) ? icon : nil }
        var posted: [CGEvent] = []
        clicks.post = { posted.append($0) }
        var pressed = 0, released: [CGPoint] = [], drags = 0, others: [CGPoint] = []
        clicks.onPress = { _ in pressed += 1 }
        clicks.onRelease = { released.append($1) }
        clicks.onHandedOn = { drags += 1 }
        clicks.onOtherClick = { others.append($0) }
        func mouse(_ type: CGEventType, _ point: CGPoint, _ flags: CGEventFlags = []) -> CGEvent {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
            event.flags = flags
            return event
        }
        let on = CGPoint(x: 120, y: 955), off = CGPoint(x: 600, y: 400)
        let click = [clicks.handle(.leftMouseDown, mouse(.leftMouseDown, on)), clicks.handle(.leftMouseUp, mouse(.leftMouseUp, on))]
        pump(0.05)
        check(click.allSatisfy { $0 == nil } && pressed == 1 && released == [on] && posted.isEmpty,
              "a click on a running app's icon is held back, and the picker hears of the press and the release")
        let elsewhere = clicks.handle(.leftMouseDown, mouse(.leftMouseDown, off))
        let command = clicks.handle(.leftMouseDown, mouse(.leftMouseDown, on, .maskCommand))
        _ = clicks.handle(.leftMouseUp, mouse(.leftMouseUp, on, .maskCommand))
        pump(0.05)
        check(elsewhere != nil && command != nil && others == [off, on] && pressed == 1,
              "a click elsewhere, and a ⌘-click on the icon, go on as they were (and count as clicks elsewhere)")
        posted = []
        let held = clicks.handle(.leftMouseDown, mouse(.leftMouseDown, on))
        let wobble = clicks.handle(.leftMouseDragged, mouse(.leftMouseDragged, CGPoint(x: on.x + 2, y: on.y - 2)))
        let away = CGPoint(x: on.x + 3, y: on.y - 20)
        let drag = clicks.handle(.leftMouseDragged, mouse(.leftMouseDragged, away))
        let later = clicks.handle(.leftMouseDragged, mouse(.leftMouseDragged, CGPoint(x: away.x, y: away.y - 20)))
        let letGo = clicks.handle(.leftMouseUp, mouse(.leftMouseUp, away))
        pump(0.05)
        let replay = posted.map { ($0.type, $0.location) }
        check(held == nil && wobble == nil && drag == nil && later != nil && letGo != nil && drags == 1 && released == [on]
              && replay.count == 2 && replay[0].0 == .leftMouseDown && replay[0].1 == on && replay[1].0 == .leftMouseDragged
              && replay[1].1 == away,
              "dragging the icon hands it on once it has moved 4 points: the press where it was, then the move")
        check(posted.allSatisfy { clicks.handle($0.type, $0) != nil }, "what it hands on goes through it untouched")
        posted = []
        drags = 0
        let still = clicks.handle(.leftMouseDown, mouse(.leftMouseDown, on))
        pump(0.4)
        let early = posted.count
        pump(0.4)
        let after = clicks.handle(.leftMouseUp, mouse(.leftMouseUp, on))
        pump(0.05)
        check(still == nil && early == 0 && posted.map(\.type) == [.leftMouseDown] && posted.first?.location == on && after != nil
              && drags == 1 && released == [on],
              "a press held still for 0.6 s is handed on (so the Dock can open its own menu), and its release follows it")
        posted = []
        clicks.handOn(at: on)
        check(posted.map(\.type) == [.leftMouseDown, .leftMouseUp] && posted.allSatisfy { $0.location == on && clicks.handle($0.type, $0) != nil },
              "a click handed on to the Dock is a press and a release where it was made, which go through")

        guard !CommandLine.arguments.contains("nolive") else { return finish() }
        guard AX.isTrusted else { return (lines + ["skipped the live part: accessibility not trusted"]).joined(separator: "\n") }
        // Behind the lock screen the Dock never comes up and no app comes forward.
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            return (lines + ["skipped the live part: the screen is locked"]).joined(separator: "\n")
        }
        // On a full-screen app's Space the helper's windows open on a desktop instead, where Accessibility doesn't list them.
        if let spaces = SpaceWindows.spaces(), !spaces.current.isDisjoint(with: spaces.fullScreen) {
            return (lines + ["skipped the live part: a full-screen app's desktop is showing; switch to an ordinary desktop and run again"])
                .joined(separator: "\n")
        }
        // A running RubberMAC with its own Dock menu on takes the clicks on the icon before the test's picker.
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() }
        guard copies.isEmpty || !Settings.dockWindowMenuEnabled else {
            return (lines + ["skipped the live part: RubberMAC is running with its Dock menu on; quit it, or turn that off, and run again"])
                .joined(separator: "\n")
        }

        // Every running app's icon should lead to its app.
        DockItems.refresh()
        let running = dockIcons().filter { AX.bool($0.element, "AXIsApplicationRunning") == true }
        let unmatched = running.filter { apps(at: $0.url).isEmpty }
        check(!running.isEmpty && unmatched.isEmpty,
              "each running app's Dock icon leads to its app: \(running.count - unmatched.count) of \(running.count)"
                + (unmatched.isEmpty ? "" : " (not: \(unmatched.map { $0.url.deletingPathExtension().lastPathComponent }))"))

        // The windows belong to a helper: another copy of this app, with an icon of its own in the Dock, as an app the
        // menu is used on would be. It takes commands as files in a folder of its own.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dock-menu-test-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func tell(_ command: String) {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(command).path, contents: nil)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.arguments = ["--selftest", "dockmenu-helper", folder.path]
        var helper: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { app, _ in
            DispatchQueue.main.async { helper = app }
        }
        let screen = CGDisplayBounds(CGMainDisplayID())
        let saved = CGEvent(source: nil)?.location ?? .zero
        defer {
            tell("quit")
            CGWarpMouseCursorPosition(saved)
            pump(1)
            try? FileManager.default.removeItem(at: folder)
        }
        func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Int? {
            let start = Date()
            while -start.timeIntervalSinceNow < seconds {
                if condition() { return Int(-start.timeIntervalSinceNow * 1000) }
                pump(0.02)
            }
            return condition() ? Int(seconds * 1000) : nil
        }
        let own = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        func helperIcon() -> CGRect? { dockIcons().first { $0.url.resolvingSymlinksInPath().path == own }?.frame }
        guard waitFor(10, { helper != nil && helperIcon() != nil && AX.windows(of: helper!.processIdentifier).count == 3 }) != nil,
              let helper else {
            check(false, "the helper started with an icon in the Dock and 3 windows (started: \(helper != nil), "
                  + "icon: \(helperIcon() != nil), windows: \(helper.map { AX.windows(of: $0.processIdentifier).count } ?? 0))")
            return finish()
        }
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ point: CGPoint, deltaY: Int64 = 0) {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            if deltaY != 0 { event?.setIntegerValueField(.mouseEventDeltaY, value: deltaY) }
            event?.post(tap: .cghidEventTap)
        }
        // Brings up the hidden Dock as a hand does, by moving the pointer down to the edge, and gives the icon's middle.
        func reveal() -> CGPoint? {
            guard let x = helperIcon()?.midX else { return nil }
            post(.mouseMoved, CGPoint(x: x, y: screen.midY))
            pump(0.3)
            for step in 0...10 {
                post(.mouseMoved, CGPoint(x: x, y: min(screen.maxY - 1, screen.maxY - 121 + CGFloat(step) * 12)), deltaY: 12)
                pump(0.02)
            }
            guard waitFor(1.5, { helperIcon().map { $0.maxY <= screen.maxY } == true }) != nil, let frame = helperIcon() else { return nil }
            pump(0.2)
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        func press(_ point: CGPoint) {
            post(.leftMouseDown, point)
            pump(0.08)
            post(.leftMouseUp, point)
        }
        // While in front, the helper hands the front back to the app that had it.
        func stepAside() {
            guard helper.isActive else { return }
            tell("aside")
            _ = waitFor(1.5) { !helper.isActive }
        }
        func focusedWindow() -> CGWindowID? { AX.focusedWindow(of: helper.processIdentifier).flatMap(AX.windowID(of:)) }
        func why() -> String {
            "(helper in front: \(helper.isActive), icon at \(helperIcon().map { "\($0)" } ?? "-"), pointer \(CGEvent(source: nil)?.location ?? .zero))"
        }

        stepAside()
        guard let control = reveal() else {
            check(false, "set up: the Dock came up with the helper's icon on screen \(why())")
            return finish()
        }
        press(control)
        let came = waitFor(2) { helper.isActive }
        check(came != nil, "without the picker, clicking the icon brings the app forward\(came.map { " (after \($0) ms)" } ?? "")")

        let picker = DockWindowPicker()
        picker.isEnabled = true
        let tap = EventTap(name: "dock clicks test", types: [.leftMouseDown, .leftMouseUp, .leftMouseDragged],
                           location: .cgSessionEventTap, ownThread: true, handlers: [picker.clicks])
        let keyTap = EventTap(name: "dock keys test", types: [.keyDown, .keyUp], location: .cghidEventTap, ownThread: true,
                              handlers: [picker.keys])
        tap.update()
        keyTap.update()
        defer {
            picker.isEnabled = false
            tap.update()
            keyTap.update()
        }
        // Clicks the icon with the helper behind; gives how long the menu took to open, or why it didn't.
        func open(_ what: String) -> Int? {
            stepAside()
            guard let at = reveal() else {
                check(false, "the Dock came up \(what) \(why())")
                return nil
            }
            press(at)
            let shown = waitFor(2) { picker.isShown }
            if shown == nil { check(false, "the menu opened \(what) \(why())") }
            return shown
        }

        guard let shownAfter = open("the first time") else { return finish() }
        pump(0.3)
        let listed = picker.shown?.windows ?? []
        check(listed.count == 3 && !helper.isActive,
              "with it, the same click opens a menu of the 3 windows (after \(shownAfter) ms) and the app stays behind (in front: \(helper.isActive))")
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let iconTop = primaryHeight - (picker.shown?.item.frame.minY ?? 0)
        let menuFrame = panelFrame()
        let shownRows = rows()
        check(menuFrame.map { menu in menu.minY >= iconTop && NSScreen.screens.contains { $0.frame.contains(menu) }
                  && shownRows.count == 3 && shownRows.allSatisfy { !$0.isEmpty && menu.contains($0) } } == true,
              "the menu sits above the icon, on the screen, with all 3 rows in it (menu \(menuFrame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "-"), icon top \(Int(iconTop)))")
        // Each row's CPU and memory: memory at once, CPU once the first second has been measured.
        let measured = waitFor(2.5) {
            let shown = usageLines()
            return shown.count == 3 && shown.allSatisfy { $0.range(of: #"^CPU \d+% · \d"#, options: .regularExpression) != nil }
        }
        let shownUsage = usageLines()
        check(measured != nil, "each row shows the app's CPU and memory, measured \(measured.map { "after \($0) ms more" } ?? "in time") "
              + "(\(shownUsage.count) of 3 rows: \(shownUsage.first ?? "-"))")
        let picture = snap(menuFrame, primaryHeight: primaryHeight)
        if !picture.isEmpty { lines.append(picture) }

        if let at = helperIcon().map({ CGPoint(x: $0.midX, y: $0.midY) }) {
            press(at)
            let closed = waitFor(1) { !picker.isShown }
            pump(0.5)
            check(closed != nil && !helper.isActive, "clicking the icon again closes it, and the app still stays behind")
        }

        if open("again for Esc") != nil {
            CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
            check(waitFor(1) { !picker.isShown } != nil, "Esc closes it")
        }

        if open("again for a click elsewhere") != nil, let frame = picker.shown?.windows.first?.frame {
            press(CGPoint(x: frame.midX, y: frame.minY + 12))
            check(waitFor(1) { !picker.isShown } != nil, "a click elsewhere (on one of the windows) closes it")
        }

        if open("again for picking") != nil, let entries = picker.shown?.windows, entries.count == 3 {
            pump(0.3)
            let targets = rows()
            if targets.count == 3, let id = entries[1].windowID {
                let row = targets[1]
                let start = Date()
                press(CGPoint(x: row.midX, y: primaryHeight - row.midY))
                let went = waitFor(3) { helper.isActive && focusedWindow() == id }
                check(!picker.isShown && went != nil,
                      "clicking the second row closes the menu and goes to that window\(went.map { " (after \($0) ms)" } ?? "")"
                        + (went == nil ? " (menu open: \(picker.isShown), helper in front: \(helper.isActive), its focused window is "
                            + "the second: \(focusedWindow() == id), \(Int(-start.timeIntervalSinceNow * 1000)) ms)" : ""))
            } else { check(false, "the open menu has 3 rows on screen (\(targets.count))") }
        }

        tell("close")
        _ = waitFor(2) { AX.windows(of: helper.processIdentifier).count == 1 }
        stepAside()
        if let at = reveal() {
            press(at)
            let came = waitFor(2) { helper.isActive }
            check(came != nil && !picker.isShown,
                  "with one window left, the click goes on to the Dock and the app comes forward\(came.map { " (after \($0) ms)" } ?? "")")
        } else { check(false, "the Dock came up for the one-window click \(why())") }
        stepAside()
        return finish()
    }

    // --selftest dockmenu-helper <folder>: three windows, an icon in the Dock, and commands from the test as files in
    // the folder: aside (hand the front back to the app that had it), close (all but the first window), quit.
    static func runHelper(folder: String) -> Never {
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let previous = NSWorkspace.shared.frontmostApplication
        let windows = (0..<3).map { i in
            let window = NSWindow(contentRect: NSRect(x: 200 + i * 60, y: 380 + i * 40, width: 420, height: 300),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Dock menu test \(i + 1)"
            window.backgroundColor = NSColor(calibratedHue: CGFloat(i) / 3, saturation: 0.5, brightness: 0.9, alpha: 1)
            window.orderFrontRegardless()
            return window
        }
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            func take(_ command: String) -> Bool {
                (try? FileManager.default.removeItem(atPath: folder + "/" + command)) != nil
            }
            if take("aside"), NSApp.isActive { previous?.activate() }
            if take("close") { windows.dropFirst().forEach { $0.close() } }
            if take("quit") || -started.timeIntervalSinceNow > 120 { exit(0) }
        }
        NSApp.run()
        exit(0)
    }

    private static func dockIcons() -> [(element: AXUIElement, url: URL, frame: CGRect)] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
        var lists: CFTypeRef?
        AXUIElementCopyAttributeValue(AX.app(dock.processIdentifier), kAXChildrenAttribute as CFString, &lists)
        return (lists as? [AXUIElement] ?? []).flatMap { list -> [(AXUIElement, URL, CGRect)] in
            var items: CFTypeRef?
            AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &items)
            return (items as? [AXUIElement] ?? []).compactMap { item in
                var url: CFTypeRef?
                guard AX.string(item, kAXSubroleAttribute) == "AXApplicationDockItem",
                      AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &url) == .success, let url = url as? URL,
                      let frame = AX.frame(of: item) else { return nil }
                return (item, url, frame)
            }
        }
    }

    // The open menu's rows on screen, top to bottom, in AppKit coordinates.
    private static func rows() -> [CGRect] {
        func rows(in view: NSView) -> [DockWindowRow] {
            view.subviews.flatMap { ($0 as? DockWindowRow).map { [$0] } ?? rows(in: $0) }
        }
        return NSApp.windows.filter { $0.isVisible && $0.level == .popUpMenu }.flatMap { window in
            window.contentView.map(rows(in:))?.map { window.convertToScreen($0.convert($0.bounds, to: nil)) } ?? []
        }.sorted { $0.maxY > $1.maxY }
    }

    // The CPU and memory line of each row of the open menu.
    private static func usageLines() -> [String] {
        func labels(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? labels(in: $0) }
        }
        return NSApp.windows.filter { $0.isVisible && $0.level == .popUpMenu }
            .flatMap { $0.contentView.map(labels(in:)) ?? [] }
            .map(\.stringValue).filter { $0.hasPrefix("CPU ") || $0.contains(" · CPU ") }
    }

    private static func panelFrame() -> CGRect? {
        NSApp.windows.first { $0.isVisible && $0.level == .popUpMenu }?.frame
    }

    // The open menu, saved as dock-menu.png when the last argument is a folder (ends in /).
    // That part of the screen, full size. Completion handlers, not async: the async forms trap when ScreenCaptureKit hands
    // back neither image nor error.
    private static func snap(_ frame: CGRect?, primaryHeight: CGFloat) -> String {
        guard let frame, let folder = CommandLine.arguments.last, folder.hasSuffix("/") else { return "" }
        var result: (CGImage?, Error?)?
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
            guard let display = content?.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                return DispatchQueue.main.async { result = (nil, error) }
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
            config.width = Int(frame.width * CGFloat(filter.pointPixelScale))
            config.height = Int(frame.height * CGFloat(filter.pointPixelScale))
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                DispatchQueue.main.async { result = (image, error) }
            }
        }
        let until = Date(timeIntervalSinceNow: 3)
        while result == nil && Date() < until { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        guard let image = result?.0 else { return "no picture of the menu: \(result?.1.map { "\($0)" } ?? "none came")" }
        let url = URL(fileURLWithPath: folder + "dock-menu.png")
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        return "a picture of the open menu: \(url.path)"
    }
}
