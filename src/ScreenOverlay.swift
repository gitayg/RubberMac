import AppKit

// Click-through black windows that darken whole screens. Unlike DDC or gamma tables this reaches
// DisplayLink monitors too: their driver streams the ordinary window pixels to the dock.
final class ScreenOverlay {
    // Above everything except the screen saver; the order keeps the lock warning readable.
    static let brightnessLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
    static let warningLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 2)
    static let dimLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 3)

    private let level: NSWindow.Level
    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    init(level: NSWindow.Level) {
        self.level = level
    }

    // darkness 0 (clear) ... 1 (black); a duration fades to it.
    func set(_ darkness: CGFloat, on screen: NSScreen, duration: TimeInterval = 0) {
        guard let id = screen.displayID else { return }
        if darkness <= 0 {
            windows.removeValue(forKey: id)?.orderOut(nil)
            return
        }
        let window = windows[id] ?? makeWindow()
        windows[id] = window
        window.setFrame(screen.frame, display: false)
        if !window.isVisible {
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            window.animator().alphaValue = darkness
        }
    }

    func clear() {
        windows.values.forEach { $0.orderOut(nil) }
        windows = [:]
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = level
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return window
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
