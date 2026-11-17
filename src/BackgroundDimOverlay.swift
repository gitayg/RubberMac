import AppKit

// One click-through window per screen, ordered right below the window in front, so everything further back, the desktop
// too, is seen through black at the chosen strength, or blurred. It sits at the normal window level, so the menu bar,
// the Dock and every floating panel stay above it. Main thread.
final class BackgroundDimOverlays {
    // The blur radius at 100% strength, in the window server's units.
    static let maxBlurRadius = 50.0

    private(set) var windows: [CGDirectDisplayID: BackgroundDimWindow] = [:]
    // How often a window was put in a new place in the stack, for the self-test: one that's already right stays put.
    private(set) var reorders = 0

    var isShown: Bool { windows.values.contains { $0.isVisible } }

    func show(below front: CGWindowID, mode: BackgroundDimMode, strength: Double, except skipped: Set<CGDirectDisplayID>,
              ownPID: pid_t) {
        let screens = NSScreen.screens.compactMap { screen in screen.displayID.map { ($0, screen.frame) } }
        for gone in Set(windows.keys).subtracting(screens.map(\.0)) { windows.removeValue(forKey: gone)?.orderOut(nil) }
        for (display, frame) in screens {
            if skipped.contains(display) {
                windows[display]?.orderOut(nil)
                continue
            }
            let window = windows[display] ?? Self.makeWindow()
            windows[display] = window
            if window.frame != frame { window.setFrame(frame, display: false) }
            Self.style(window, mode, strength)
            guard !window.isVisible || !Self.isPlaced(CGWindowID(window.windowNumber), below: front, ownPID: ownPID) else { continue }
            window.order(.below, relativeTo: Int(front))
            reorders += 1
        }
    }

    func hide() {
        windows.values.forEach { $0.orderOut(nil) }
    }

    func removeAll() {
        hide()
        windows = [:]
    }

    static func makeWindow() -> BackgroundDimWindow {
        let window = BackgroundDimWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        window.animationBehavior = .none
        // On every desktop, but not over full-screen apps; left out of Mission Control's shuffle and window cycling.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return window
    }

    // Blur is the window server's own blur of what's behind the window, at a radius the strength sets, over an all but
    // clear background. Fading an NSVisualEffectView by the strength was measured first: at 60% it still showed 40% of
    // the sharp windows through the blur. Without the call, Blur dims.
    static func style(_ window: BackgroundDimWindow, _ mode: BackgroundDimMode, _ strength: Double) {
        let blur = mode == .blur && BackgroundDimWindow.canBlur
        let color = blur ? NSColor(white: 0, alpha: 0.01) : .black
        let alpha = blur ? 1 : CGFloat(strength)
        if window.backgroundColor != color { window.backgroundColor = color }
        if window.alphaValue != alpha { window.alphaValue = alpha }
        window.blurRadius = blur ? Int32((strength * maxBlurRadius).rounded()) : 0
    }

    // Right below the front window: the nearest ordinary window above it that isn't RubberMAC's own (another screen's
    // overlay, the Finder address bar) is the front one.
    static func isPlaced(_ overlay: CGWindowID, below front: CGWindowID, ownPID: pid_t) -> Bool {
        let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], overlay) as? [[String: Any]] ?? []
        return nearest(above.map { window in
            ((window[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0,
             (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
             (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0)
        }, ownPID: ownPID) == front
    }

    // Front to back, as the window server lists them.
    static func nearest(_ above: [(id: CGWindowID, pid: pid_t, layer: Int)], ownPID: pid_t) -> CGWindowID? {
        above.last { $0.layer == 0 && $0.pid != ownPID }?.id
    }
}
