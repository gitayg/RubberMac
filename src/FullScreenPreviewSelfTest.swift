import AppKit
import ScreenCaptureKit

// --selftest previews-fullscreen: live, so run it hands-off on an ordinary desktop. Opens three striped windows of its
// own and puts each in full screen over the one before, so the first two Spaces aren't showing: ScreenCaptureKit takes
// no picture of the first there, and the switcher's pictures still have one, with the stripes in it; the second window
// asks not to be captured, and gets none. Then takes them out of full screen and closes them. Reports sizes and flags,
// never pictures.
extension WindowThumbnails {
    static func fullScreenSelfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func finish() -> String { (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n") }
        guard ScreenText.hasPermission else { return "skipped: Screen Recording not allowed" }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            return "skipped: the screen is locked"
        }
        guard let spaces = SpaceWindows.spaces(), spaces.current.isDisjoint(with: spaces.fullScreen) else {
            return "skipped: a full-screen app's desktop is showing; switch to an ordinary desktop and run again"
        }
        func pump(_ seconds: TimeInterval) {
            let until = Date(timeIntervalSinceNow: seconds)
            while Date() < until {
                if let event = NSApp.nextEvent(matching: .any, until: min(until, Date(timeIntervalSinceNow: 0.02)),
                                               inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            }
        }
        func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
            let until = Date(timeIntervalSinceNow: seconds)
            while Date() < until { if condition() { return true }; pump(0.1) }
            return condition()
        }
        // Whether the window is in a full-screen Space, and whether that Space is showing.
        func place(_ window: NSWindow) -> (fullScreen: Bool, showing: Bool) {
            guard let spaces = SpaceWindows.spaces(),
                  let server = SpaceWindows.windows(of: [getpid()], on: spaces.user)?.first(where: { $0.id == CGWindowID(window.windowNumber) })
            else { return (false, false) }
            let on = Set(server.spaces)
            return (!on.isDisjoint(with: spaces.fullScreen), !on.isDisjoint(with: spaces.current))
        }

        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        NSApp.activate(ignoringOtherApps: true)
        let windows = (0..<3).map { i -> NSWindow in
            let window = NSWindow(contentRect: NSRect(x: 200 + i * 60, y: 300, width: 500, height: 350),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Full-screen preview test \(i + 1)"
            window.collectionBehavior = [.fullScreenPrimary]
            if i == 1 { window.sharingType = .none }
            // Black and white stripes: a blank picture is one colour, a true one isn't, in full screen too.
            let content = NSView(frame: window.contentView?.bounds ?? .zero)
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.white.cgColor
            for k in 0..<8 {
                let stripe = NSView(frame: NSRect(x: CGFloat(k) * 500 / 8, y: 0, width: 500 / 16, height: 350))
                stripe.wantsLayer = true
                stripe.layer?.backgroundColor = NSColor.black.cgColor
                stripe.autoresizingMask = [.width, .height, .minXMargin, .maxXMargin]
                content.addSubview(stripe)
            }
            window.contentView = content
            window.makeKeyAndOrderFront(nil)
            return window
        }
        pump(0.5)
        defer {
            for window in windows.reversed() where window.styleMask.contains(.fullScreen) {
                window.makeKeyAndOrderFront(nil)
                pump(1)
                window.toggleFullScreen(nil)
                _ = waitFor(8) { !window.styleMask.contains(.fullScreen) }
                pump(1)
            }
            windows.forEach { $0.close() }
            previous?.activate()
            pump(0.5)
        }

        var inPlace = true
        for (i, window) in windows.enumerated() {
            if i > 0 {
                window.makeKeyAndOrderFront(nil)
                pump(1.5)
            }
            window.toggleFullScreen(nil)
            inPlace = waitFor(8) { place(window) == (true, true) } && inPlace
            pump(1)
        }
        inPlace = inPlace && place(windows[0]) == (true, false) && place(windows[1]) == (true, false)
        check(inPlace, "set up: three windows in full screen, the last one's Space covering the first two")
        guard inPlace else { return finish() }
        let id = CGWindowID(windows[0].windowNumber)
        let protected = CGWindowID(windows[1].windowNumber)

        var direct: String?
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
                  let window = content.windows.first(where: { $0.windowID == id }) else { direct = "not listed"; return }
            let config = SCStreamConfiguration()
            config.width = 600
            config.height = 338
            do {
                _ = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                               configuration: config)
                direct = "a picture"
            } catch { direct = "error \((error as NSError).code)" }
        }
        _ = waitFor(5) { direct != nil }
        check(direct != "a picture", "ScreenCaptureKit alone takes no picture of it (\(direct ?? "no answer in 5 s"))")

        let pictures = WindowThumbnails()
        var taken: [CGWindowID: NSImage] = [:]
        pictures.refresh([id, protected]) { id, picture in taken[id] = picture }
        _ = waitFor(5) { taken[id] != nil }
        pump(1.5)
        let got = taken[id]
        let image = got?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        check(image.map { !isBlank($0) } == true,
              "the switcher still gets a picture of it, with the stripes (\(image.map { "\($0.width)×\($0.height)" } ?? "none"))")
        check(image.map { $0.width <= Int(size.width * 2) && $0.height <= Int(size.height * 2) } == true,
              "and only as big as the switcher shows it")
        check(!SpaceWindows.allowsCapture(protected) && SpaceWindows.allowsCapture(id),
              "the window server reports which of the two asked not to be captured")
        check(taken[protected] == nil, "the window that asked not to be captured gets no picture")
        return finish()
    }

    // Whether a picture is all one colour, as one of a window that isn't drawn would be.
    private static func isBlank(_ image: CGImage) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let first = rep.colorAt(x: 0, y: 0) else { return true }
        for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 7) where rep.colorAt(x: x, y: y) != first { return false }
        }
        return true
    }
}
