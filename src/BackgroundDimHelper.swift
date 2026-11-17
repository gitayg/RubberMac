import AppKit

// --selftest dimmer helper <folder>: the other app the live test dims around, so no window of yours is touched. Three
// windows: the front one (white), one behind it (white on its left half, black and white stripes on its right, so a blur
// shows), and a floating panel. It writes their window numbers to <folder>/ids and takes commands as files there:
// sheet (opens a sheet on the front window, its number to <folder>/sheetid), endsheet, closeall, quit. Quits by itself
// after a minute. A regular app, with a Dock icon while it runs: as an accessory app, Accessibility lists only one of its
// windows.
extension BackgroundDimmer {
    static let helperFront = NSRect(x: 100, y: 300, width: 360, height: 240)
    static let helperBack = NSRect(x: 380, y: 200, width: 440, height: 300)
    static let helperPanel = NSRect(x: 880, y: 380, width: 200, height: 120)

    static func runHelper(folder: String) -> Never {
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let origin = NSScreen.screens.first?.visibleFrame.origin ?? .zero
        func window(_ frame: NSRect, _ title: String, panel: Bool = false) -> NSWindow {
            let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
            let window = panel
                ? NSPanel(contentRect: rect, styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
                : NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.title = title
            window.backgroundColor = .white
            (window as? NSPanel)?.isFloatingPanel = true
            return window
        }
        let back = window(helperBack, "Dimmer test: behind")
        back.contentView = HelperStripes()
        let panel = window(helperPanel, "Panel", panel: true)
        let front = window(helperFront, "Dimmer test: front")
        for window in [back, panel, front] { window.orderFrontRegardless() }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        try? "\(front.windowNumber) \(back.windowNumber) \(panel.windowNumber)".write(toFile: folder + "/ids", atomically: true, encoding: .utf8)

        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            func take(_ command: String) -> Bool {
                (try? FileManager.default.removeItem(atPath: folder + "/" + command)) != nil
            }
            if take("sheet") {
                front.beginSheet(sheet)
                try? "\(sheet.windowNumber)".write(toFile: folder + "/sheetid", atomically: true, encoding: .utf8)
            }
            if take("endsheet") { front.endSheet(sheet) }
            if take("closeall") { [front, back, panel].forEach { $0.close() } }
            if take("quit") || -started.timeIntervalSinceNow > 60 { exit(0) }
        }
        NSApp.run()
        exit(0)
    }
}

// White on the left half, 2-point black and white stripes on the right.
private final class HelperStripes: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        NSColor.black.setFill()
        for x in stride(from: bounds.midX, to: bounds.maxX, by: 4) {
            NSRect(x: x, y: bounds.minY, width: 2, height: bounds.height).fill()
        }
    }
}
