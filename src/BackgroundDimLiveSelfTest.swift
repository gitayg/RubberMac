import AppKit
import ScreenCaptureKit

// --selftest dimmer-live [folder/]: the real thing, around a helper copy of the app with windows of its own, gently
// (20% dim) and for a few seconds. Dims with your front window in front, then the helper's; checks where the overlay
// sits in the window server's stack: right below the front window, with every other window and the desktop behind it,
// the menu bar, the Dock and a floating panel above. A click on a dimmed window goes through to it and the dimming
// follows, as it does a focus change inside the app, a sheet, a move and resize (no reorder), a RubberMAC window in
// front (no change), Blur, minimizing and closing. With Screen Recording it also reads the pixels, and a folder as the
// last argument gets the pictures. Clicks once on the helper's window and puts the pointer back, so it waits for an
// idle, ordinary desktop. Moves no window of yours and changes no setting.
extension BackgroundDimmer {
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

        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func pump(_ seconds: TimeInterval) {
            let until = Date(timeIntervalSinceNow: seconds)
            while let event = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        }
        // Milliseconds until the condition held, nil if it didn't in time.
        func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Int? {
            let start = Date()
            while -start.timeIntervalSinceNow < seconds {
                if condition() { return Int(-start.timeIntervalSinceNow * 1000) }
                pump(0.005)
            }
            return condition() ? Int(seconds * 1000) : nil
        }
        func ms(_ value: Int?) -> String { value.map { "after \($0) ms" } ?? "not within the time" }

        // Without focusHistory: a running RubberMAC rewrites its Alt-Tab order whenever any window gets focus.
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        func settings() -> (stored: NSDictionary, focus: Any?) {
            var all = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
            let focus = all.removeValue(forKey: "focusHistory")
            return (all as NSDictionary, focus)
        }
        let stored = settings()
        let me = getpid()
        // Your app: the one in front, or with the test itself in front (as open leaves it), the one with the topmost window.
        let previous = BackgroundDimFront.frontApp(ownPID: me, last: 0).flatMap { NSRunningApplication(processIdentifier: $0) }
        let savedMouse = CGEvent(source: nil)?.location ?? .zero
        let pictures = CommandLine.arguments.last.flatMap { $0.hasSuffix("/") ? $0 : nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dimmer-live-\(me)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func tell(_ command: String) { FileManager.default.createFile(atPath: folder.path + "/" + command, contents: nil) }

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.arguments = ["--selftest", "dimmer", "helper", folder.path]
        var helper: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { app, _ in
            DispatchQueue.main.async { helper = app }
        }

        var mode = BackgroundDimMode.dim
        var strength = 0.2
        let dimmer = BackgroundDimmer(mode: { mode }, strength: { strength })
        var ownWindow: NSWindow?

        func overlays() -> [BackgroundDimWindow] { Array(dimmer.overlays.windows.values) }
        func stack() -> [(id: CGWindowID, pid: pid_t, layer: Int, owner: String, alpha: Double)] {
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).map {
                (($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0, ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
                 ($0[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0, $0[kCGWindowOwnerName as String] as? String ?? "",
                 ($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
            }
        }
        func placed(below id: CGWindowID) -> Bool {
            let shown = overlays()
            return !shown.isEmpty && shown.allSatisfy { $0.isVisible && BackgroundDimOverlays.isPlaced(CGWindowID($0.windowNumber), below: id, ownPID: me) }
        }
        // The front window is really on top, with nothing ordinary but RubberMAC's own above it.
        func onTop(_ id: CGWindowID) -> Bool { stack().first { $0.layer == 0 && $0.pid != me }?.id == id }
        // On top with the overlay right behind it, and no second look still to come, before counting moves.
        func settled(_ id: CGWindowID) {
            _ = waitFor(2) { placed(below: id) && onTop(id) }
            pump(BackgroundDimmer.settle + 0.1)
        }
        // Where each window is in the stack, front to back, with the topmost ordinary windows: for when a check fails.
        func order(_ named: [(String, CGWindowID?)]) -> String {
            let list = stack()
            let marks = Set(overlays().map { CGWindowID($0.windowNumber) })
            let top = list.filter { $0.layer == 0 }.prefix(4).map { marks.contains($0.id) ? "overlay" : $0.pid == me ? "own" : "\($0.owner) \($0.id)" }
            return named.map { name, id in "\(name) " + (id.flatMap { id in list.firstIndex { $0.id == id } }.map(String.init) ?? "-") }
                .joined(separator: ", ") + ", overlay " + (list.firstIndex { marks.contains($0.id) }.map(String.init) ?? "-")
                + "; top: " + top.joined(separator: ", ")
        }
        // In front of every overlay, or behind them all.
        func positions() -> (clear: Set<CGWindowID>, dimmed: Set<CGWindowID>) {
            let list = stack()
            let marks = Set(overlays().map { CGWindowID($0.windowNumber) })
            let indices = list.indices.filter { marks.contains(list[$0].id) }
            guard let first = indices.first, let last = indices.last else { return ([], Set(list.map(\.id))) }
            return (Set(list[..<first].map(\.id)), Set(list[(last + 1)...].map(\.id)))
        }

        func finish() -> String {
            dimmer.stop()
            ownWindow?.close()
            tell("quit")
            if let previous {
                AXUIElementSetAttributeValue(AX.app(previous.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }
            CGWarpMouseCursorPosition(savedMouse)
            pump(0.5)
            let leftOver = stack().contains { $0.pid == me && $0.layer == 0 }
            check(dimmer.overlays.windows.isEmpty && !leftOver, "turned off, its overlays are gone from the screen")
            check(helper.map { _ in waitFor(3) { helper?.isTerminated == true } != nil } ?? true, "the helper app quit")
            try? FileManager.default.removeItem(at: folder)
            let after = settings()
            check(stored.stored.isEqual(after.stored), "no stored setting changed"
                  + ((after.focus as AnyObject?)?.isEqual(stored.focus) == true ? "" : " (a running RubberMAC noted the focus changes in its Alt-Tab order)"))
            return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
        }

        guard waitFor(8, { helper != nil && FileManager.default.fileExists(atPath: folder.path + "/ids") }) != nil, let helper,
              let text = try? String(contentsOfFile: folder.path + "/ids", encoding: .utf8) else {
            check(false, "the helper app starts with its windows")
            return finish()
        }
        let ids = text.split(separator: " ").compactMap { CGWindowID($0) }
        let pid = helper.processIdentifier
        func element(_ id: CGWindowID) -> AXUIElement? { AX.windows(of: pid).first { AX.windowID(of: $0) == id } }
        guard ids.count == 3, waitFor(3, { element(ids[0]) != nil && element(ids[1]) != nil }) != nil,
              let frontElement = element(ids[0]) else {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(AX.app(pid), kAXWindowsAttribute as CFString, &value)
            let seen = AX.windows(of: pid).map { AX.windowID(of: $0).map(String.init) ?? "no id" }
            check(false, "the helper app starts with its windows (\(ids)); Accessibility sees \(seen), error \(error.rawValue)")
            return finish()
        }
        let (front, back, panel) = (ids[0], ids[1], ids[2])

        // Spots inside the helper's windows, in the window server's coordinates (top-left origin).
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let origin = NSScreen.screens.first?.visibleFrame.origin ?? .zero
        func spot(_ frame: NSRect, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 20, _ height: CGFloat = 20) -> CGRect {
            CGRect(x: origin.x + frame.minX + x, y: primary - (origin.y + frame.minY + y) - height, width: width, height: height)
        }
        let frontWhite = spot(helperFront, 100, 80)
        let backWhite = spot(helperBack, 150, 60)
        let backStripes = spot(helperBack, 260, 60, 40, 10)
        let canRead = CGPreflightScreenCaptureAccess()
        // The lightest, darkest and mean brightness (0–1) of a part of the screen as it's shown.
        func brightness(_ rect: CGRect, _ name: String) -> (low: Double, high: Double, mean: Double)? {
            guard canRead else { return nil }
            var image: CGImage?
            var done = false
            Task {
                image = try? await SCScreenshotManager.captureImage(in: rect)
                done = true
            }
            _ = waitFor(3) { done }
            guard let image else { return nil }
            if let pictures {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: pictures + "dimmer-\(name).png"))
            }
            let width = image.width, height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let values = stride(from: 0, to: pixels.count, by: 4).map {
                (0.299 * Double(pixels[$0]) + 0.587 * Double(pixels[$0 + 1]) + 0.114 * Double(pixels[$0 + 2])) / 255
            }
            return (values.min() ?? 0, values.max() ?? 0, values.reduce(0, +) / Double(values.count))
        }
        func describe(_ b: (low: Double, high: Double, mean: Double)?) -> String {
            b.map { String(format: "%.2f–%.2f, mean %.2f", $0.low, $0.high, $0.mean) } ?? "unread"
        }
        // 1. Turned on with your app in front: right below a window of another process, one this test didn't make.
        if let previous, previous.processIdentifier != pid {
            AXUIElementSetAttributeValue(AX.app(previous.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            _ = waitFor(2) { NSWorkspace.shared.frontmostApplication == previous }
        }
        let yours = previous.flatMap { AX.focusedWindow(of: $0.processIdentifier) }.flatMap(AX.windowID)
        let yoursOrdinary = yours.flatMap { (CGWindowListCopyWindowInfo([.optionIncludingWindow], $0) as? [[String: Any]])?.first }
            .map { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 && ($0[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true } == true
        dimmer.start()
        if let previous, let yours, yoursOrdinary, NSWorkspace.shared.frontmostApplication == previous {
            let at = waitFor(1) { placed(below: yours) }
            check(at != nil, "turned on with \(previous.localizedName ?? "your app") in front: right below its window (\(ms(at)))")
        } else {
            lines.append("note your app has no ordinary window in front, so the test dims only around the helper's")
        }
        dimmer.stop()

        // The helper in front, undimmed, for the pictures to compare with.
        AX.focus(frontElement, pid: pid)
        _ = waitFor(2) { AX.focusedWindow(of: pid).flatMap(AX.windowID) == front && NSWorkspace.shared.frontmostApplication == helper }
        pump(0.2)
        let before = (front: brightness(frontWhite, "front-before"), white: brightness(backWhite, "back-before"),
                      stripes: brightness(backStripes, "stripes-before"))
        lines.append("note pixels: \(canRead ? "front \(describe(before.front)), behind \(describe(before.white)), stripes \(describe(before.stripes))" : "Screen Recording is off, so the pixels aren't read")")

        // 2. On again, now with the helper's front window in front.
        dimmer.refresh()
        let switched = waitFor(2) { placed(below: front) }
        check(switched != nil, "turned on with the helper in front: the overlay goes right below its window (\(ms(switched)))")
        let screens = NSScreen.screens.count
        let frames = NSScreen.screens.map(\.frame)
        check(overlays().count == screens && overlays().allSatisfy { $0.isVisible && frames.contains($0.frame) },
              "one overlay on each of the \(screens) screens, covering all of it")
        let marks = Set(overlays().map { CGWindowID($0.windowNumber) })
        let shown = stack().filter { marks.contains($0.id) }
        check(!shown.isEmpty && shown.allSatisfy { $0.layer == 0 && abs($0.alpha - 0.2) < 0.01 }, "at the normal window level, black at 20%")
        var place = positions()
        let others = stack().filter { $0.layer == 0 && $0.pid != me && $0.id != front }
        check(place.clear.contains(front) && place.dimmed.contains(back), "the front window is clear, the helper's other window dimmed")
        check(others.allSatisfy { place.dimmed.contains($0.id) }, "every other window on the screen is behind it: \(others.count) windows of \(Set(others.map(\.pid)).count) apps")
        check(place.clear.contains(panel), "the helper's floating panel stays clear")
        let desktop = stack().filter { $0.layer < 0 }
        let dock = stack().filter { $0.layer == Int(CGWindowLevelForKey(.dockWindow)) }
        let bar = stack().filter { $0.layer == Int(CGWindowLevelForKey(.mainMenuWindow)) || $0.layer == Int(CGWindowLevelForKey(.statusWindow)) }
        check(!desktop.isEmpty && desktop.allSatisfy { place.dimmed.contains($0.id) },
              "the desktop is behind it: \(Set(desktop.map(\.owner)).sorted().joined(separator: ", "))")
        check(!bar.isEmpty && (bar + dock).allSatisfy { place.clear.contains($0.id) },
              "the menu bar (\(bar.count) windows) stays above it" + (dock.isEmpty ? "; the Dock is hidden now" : ", and the Dock (\(dock.count))"))
        let dimmedPixels = (front: brightness(frontWhite, "front-dim"), white: brightness(backWhite, "back-dim"))
        if canRead, let a = before.white?.mean, let b = dimmedPixels.white?.mean, let c = dimmedPixels.front?.mean, let d = before.front?.mean {
            check(abs(b - a * 0.8) < 0.05 && abs(c - d) < 0.02,
                  String(format: "on screen: the window behind went from %.2f to %.2f (80%% would be %.2f), the front one stayed %.2f", a, b, a * 0.8, c))
        }

        // 3. A click on the dimmed window goes through the overlay to it.
        var hidden = false
        let click = spot(helperBack, 150, 150, 0, 0).origin
        let reordersBefore = dimmer.overlays.reorders
        // Only if the helper's window is what's under the spot, apart from the overlay, so no click can land on yours.
        // A running RubberMAC's brightness and pre-lock dimming windows cover the screen and let clicks through too.
        let throughLevels = [ScreenOverlay.brightnessLevel.rawValue, ScreenOverlay.dimLevel.rawValue]
        let under = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).first { window -> Bool in
            let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let through = owner == me || (throughLevels.contains((window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0)
                && NSRunningApplication(processIdentifier: owner)?.bundleIdentifier == Bundle.main.bundleIdentifier)
            return !through && (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.contains(click) == true
        }
        if let under, (under[kCGWindowNumber as String] as? NSNumber)?.uint32Value == back {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: click, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            let clicked = waitFor(2) {
                if !dimmer.overlays.isShown { hidden = true }
                return AX.focusedWindow(of: pid).flatMap(AX.windowID) == back && placed(below: back)
            }
            place = positions()
            check(clicked != nil && place.dimmed.contains(front), "a click on the dimmed window brings it forward, and the dimming follows (\(ms(clicked)))")
            check(!hidden && dimmer.overlays.reorders - reordersBefore == screens, "without the overlay going off in between: moved once per screen")
        } else {
            check(false, "the spot to click is on the helper's window; not clicked, it's under "
                  + (under.map { "\($0[kCGWindowOwnerName as String] as? String ?? "?")'s window \($0[kCGWindowNumber as String] ?? "?") at layer \($0[kCGWindowLayer as String] ?? "?")" } ?? "nothing"))
        }

        // 4. Focus moving inside the app.
        AX.raise(frontElement)
        let raised = waitFor(2) { placed(below: front) }
        check(raised != nil, "another of the app's windows gets focus: the overlay follows (\(ms(raised)))")

        // 5. A sheet on the front window.
        tell("sheet")
        let sheetID = waitFor(2) { FileManager.default.fileExists(atPath: folder.path + "/sheetid") }.flatMap { _ in
            (try? String(contentsOfFile: folder.path + "/sheetid", encoding: .utf8)).flatMap { CGWindowID($0) }
        }
        _ = waitFor(1) { sheetID.map { id in stack().contains { $0.id == id } } == true }
        pump(BackgroundDimmer.settle + 0.1)
        place = positions()
        check(sheetID.map { place.clear.contains($0) } == true && place.clear.contains(front) && place.dimmed.contains(back),
              "with a sheet open, the sheet and its window are clear (\(dimmer.target == .below(front) ? "focus reads as the window" : "target \(dimmer.target)"); "
              + order([("sheet", sheetID), ("front", front), ("back", back)]) + ")")
        tell("endsheet")
        _ = waitFor(1) { sheetID.map { id in !stack().contains { $0.id == id } } == true }

        // 6. Moving and resizing the front window.
        settled(front)
        let reorders = dimmer.overlays.reorders
        if let frame = AX.frame(of: frontElement) {
            AX.setFrame(frontElement, CGRect(x: frame.minX + 40, y: frame.minY + 30, width: frame.width - 60, height: frame.height - 40))
        }
        pump(BackgroundDimmer.settle + 0.1)
        check(placed(below: front) && dimmer.overlays.reorders == reorders, "moving and resizing it moves no overlay and it stays right behind"
              + " (\(dimmer.overlays.reorders - reorders) moves; " + order([("front", front), ("back", back)]) + ")")

        // 7. One of RubberMAC's own windows in front.
        let own = NSWindow(contentRect: NSRect(x: origin.x + 1000, y: origin.y + 120, width: 260, height: 160), styleMask: [.titled],
                           backing: .buffered, defer: false)
        own.isReleasedWhenClosed = false
        ownWindow = own
        own.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let ownFront = waitFor(2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == me }
        pump(BackgroundDimmer.settle + 0.1)
        place = positions()
        check(ownFront != nil && dimmer.target == .below(front) && placed(below: front) && place.clear.contains(CGWindowID(own.windowNumber)),
              "a RubberMAC window in front isn't dimmed and doesn't count: the overlay stays behind the helper's window"
              + (ownFront == nil ? " (RubberMAC didn't come to the front)" : "")
              + " (target \(dimmer.target); " + order([("own", CGWindowID(own.windowNumber)), ("front", front), ("back", back)]) + ")")
        strength = 0.3
        dimmer.refresh()
        let tuned = overlays().allSatisfy { abs($0.alphaValue - 0.3) < 0.001 } && placed(below: front)
        strength = 0.2
        dimmer.stop()
        dimmer.refresh()
        let restarted = waitFor(1) { placed(below: front) }
        check(tuned && restarted != nil, "with it in front, a new strength shows at once, and turning on there goes behind the app that was in front")
        own.close()
        ownWindow = nil

        // 8. Your app in front again, then the helper's.
        if let previous, previous.processIdentifier != pid {
            AXUIElementSetAttributeValue(AX.app(previous.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            _ = waitFor(2) { NSWorkspace.shared.frontmostApplication == previous }
            let yours = AX.focusedWindow(of: previous.processIdentifier).flatMap(AX.windowID)
            let ordinary = yours.flatMap { (CGWindowListCopyWindowInfo([.optionIncludingWindow], $0) as? [[String: Any]])?.first }
                .map { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 } == true
            let at = waitFor(2) { ordinary ? placed(below: yours!) : !dimmer.overlays.isShown }
            check(at != nil, "switching to \(previous.localizedName ?? "your app"): " + (ordinary ? "right below its window" : "no ordinary window, no effect")
                  + " (\(ms(at)))")
        }
        AX.focus(frontElement, pid: pid)
        let back8 = waitFor(2) { placed(below: front) && onTop(front) }
        check(back8 != nil, "and back to the helper (\(ms(back8)); " + order([("front", front), ("back", back)]) + ")")

        // What one look costs, with the overlay up.
        let timing = Date()
        for _ in 0..<50 { dimmer.update() }
        let perUpdate = -timing.timeIntervalSinceNow / 50 * 1_000_000
        lines.append(String(format: "note one look at the front window and the stack takes %.0f µs", perUpdate))

        // 9. Blur.
        mode = .blur
        strength = 0.6
        settled(front)
        let restyled = dimmer.overlays.reorders
        dimmer.refresh()
        pump(0.3)
        check(overlays().allSatisfy { $0.blurRadius == 30 && $0.alphaValue == 1 } && placed(below: front) && dimmer.overlays.reorders == restyled,
              "Blur at 60%: the same overlay, now blurring at radius 30, in the same place (radius \(overlays().map(\.blurRadius)), "
              + "\(dimmer.overlays.reorders - restyled) moves; " + order([("front", front), ("back", back)]) + ")")
        let blurred = (front: brightness(frontWhite, "front-blur"), stripes: brightness(backStripes, "stripes-blur"))
        if canRead, let a = before.stripes, let b = blurred.stripes, let c = blurred.front?.mean, let d = before.front?.mean {
            check(b.high - b.low < (a.high - a.low) * 0.2 && abs(c - d) < 0.02,
                  String(format: "on screen: the stripes behind went from %.2f–%.2f to %.2f–%.2f, the front window stayed %.2f", a.low, a.high, b.low, b.high, c)
                  + " (" + order([("front", front), ("back", back)]) + ")")
        }
        mode = .dim
        strength = 0.2
        dimmer.refresh()

        // 10. Minimizing the front window.
        AX.setMinimized(frontElement, true)
        let minimized = waitFor(3) { placed(below: back) || !dimmer.overlays.isShown }
        check(minimized != nil, "minimizing it: " + (placed(below: back) ? "the window that gets focus is the front one" : "no window has focus, no effect")
              + " (\(ms(minimized)))")

        // 11. Closing the app's windows.
        tell("closeall")
        let closed = waitFor(3) { !dimmer.overlays.isShown }
        check(closed != nil && dimmer.target == .none, "closing them all: nothing has focus, no effect (\(ms(closed)))")
        lines.append("note Accessibility notifications: " + dimmer.watcher.received.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

        // Idle, on with nothing to do.
        var start = rusage(), end = rusage()
        getrusage(RUSAGE_SELF, &start)
        let looks = dimmer.updates
        pump(4)
        getrusage(RUSAGE_SELF, &end)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        let used = seconds(end.ru_utime) + seconds(end.ru_stime) - seconds(start.ru_utime) - seconds(start.ru_stime)
        lines.append(String(format: "note idle for 4 s it looked %d times and the whole process used %.1f ms of CPU", dimmer.updates - looks, used * 1000))
        return finish()
    }
}
