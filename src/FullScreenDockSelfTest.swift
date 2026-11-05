import AppKit
import ScreenCaptureKit

// --selftest dock [dir/]: a full-screen window of its own, and the pointer flicked down to the bottom edge the way a
// hand does it, first without the helper (the Dock should stay hidden: that's the problem) and then with it (the
// Dock should come up). With a dir, saves the bottom of the screen after each as a PNG there. Puts the pointer back.
extension FullScreenDock {
    static func selfTestReport() -> String {
        guard AX.isTrusted else { return "skipped: accessibility not trusted" }
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        guard dockEdge() == .bottom else { return "skipped: the Dock isn't at the bottom" }

        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.collectionBehavior = [.fullScreenPrimary]
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        pump(0.5)
        window.toggleFullScreen(nil)
        pump(2.0)
        let saved = CGEvent(source: nil)?.location ?? .zero
        defer {
            window.toggleFullScreen(nil)
            pump(1.5)
            window.close()
            CGWarpMouseCursorPosition(saved)
        }
        guard window.styleMask.contains(.fullScreen) else {
            check(false, "the test window went full screen")
            return finish(lines, failures)
        }

        let bounds = CGDisplayBounds(CGMainDisplayID())
        let source = CGEventSource(stateID: .hidSystemState)
        func move(to point: CGPoint, deltaY: Int64 = 0) {
            let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventDeltaY, value: deltaY)
            event?.post(tap: .cghidEventTap)
        }
        // From the middle down to the last row of pixels in five quick steps, and no further.
        func flick() {
            move(to: CGPoint(x: bounds.midX, y: bounds.midY))
            pump(1.0)
            let top = bounds.maxY - 150
            for step in 1...5 {
                move(to: CGPoint(x: bounds.midX, y: min(bounds.maxY - 1, top + CGFloat(step) * 30)), deltaY: 30)
                pump(0.012)
            }
            pump(1.2)
        }

        lines.append("front window full screen: \(frontIsFullScreen())")
        flick()
        let without = dockIsShown()
        snap("dock-1-without")
        check(!without, "without the helper, a quick move to the bottom edge leaves the Dock hidden (shown: \(without))")

        let helper = FullScreenDock()
        helper.isEnabled = true
        let tap = EventTap(name: "pointer test", types: [.mouseMoved], location: .cgSessionEventTap, ownThread: true, handlers: [helper])
        tap.update()
        defer { helper.isEnabled = false; tap.update() }
        flick()
        let with = dockIsShown()
        snap("dock-2-with")
        check(with, "with it, the same move brings the Dock up (shown: \(with))")
        move(to: CGPoint(x: bounds.midX, y: bounds.midY))
        pump(1.0)
        check(!dockIsShown(), "and it goes away again when the pointer leaves")

        check(edge(at: CGPoint(x: bounds.midX, y: bounds.maxY - 1)) == .bottom && edge(at: CGPoint(x: bounds.midX, y: bounds.midY)) == nil
              && edge(at: CGPoint(x: bounds.minX, y: bounds.midY)) == .left, "edges: bottom, left, and none in the middle")
        return finish(lines, failures)
    }

    private static func finish(_ lines: [String], _ failures: Int) -> String {
        (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    // The bottom 160 points of the main screen, when the last argument is a folder (ends in /).
    private static func snap(_ name: String) {
        guard let folder = CommandLine.arguments.last, folder.hasSuffix("/") else { return }
        let screen = CGDisplayBounds(CGMainDisplayID())
        var image: CGImage?
        var done = false
        Task { image = try? await SCScreenshotManager.captureImage(in: CGRect(x: 0, y: screen.maxY - 160, width: screen.width, height: 160)); done = true }
        let until = Date(timeIntervalSinceNow: 3)
        while !done && Date() < until { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        guard let image else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: folder + name + ".png"))
    }
}
