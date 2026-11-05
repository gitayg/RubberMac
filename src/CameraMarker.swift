import AppKit

// Translucent overlays on every screen where the user drags a box around the webcam on its stand, so window
// snapping can keep clear of it. The box comes back in AppKit global coordinates with the screen it was drawn on.
final class CameraMarker {
    private var windows: [NSWindow] = []
    private var done: (((screen: NSScreen, box: NSRect)?) -> Void)?
    private var previous: NSRunningApplication?

    var isShowing: Bool { !windows.isEmpty }

    func show(current: NSRect?, done: @escaping ((screen: NSScreen, box: NSRect)?) -> Void) {
        guard !isShowing else { return }
        self.done = done
        windows = NSScreen.screens.map { screen in
            let frame = screen.frame
            let window = MarkerWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

            let view = MarkerView(frame: NSRect(origin: .zero, size: frame.size))
            view.labelTop = screen.visibleFrame.maxY - frame.minY
            if let current, current.intersects(frame) {
                view.hint = current.intersection(frame).offsetBy(dx: -frame.minX, dy: -frame.minY)
            }
            view.onBox = { [weak self] box in self?.finish((screen, box)) }
            view.onCancel = { [weak self] in self?.finish(nil) }
            // Cursor updates, unlike cursor rects, also reach the overlays that aren't key.
            view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect],
                                                owner: view))
            window.contentView = view
            window.makeFirstResponder(view)
            return window
        }
        // An accessory app's borderless windows only get Esc once the app is active and one of them is key.
        previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        windows.forEach { $0.orderFrontRegardless() }
        (windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first)?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
    }

    private func finish(_ result: (screen: NSScreen, box: NSRect)?) {
        guard let done else { return }
        self.done = nil
        let closing = windows
        windows = []
        closing.forEach { $0.orderOut(nil) }
        // The mouse-up or Esc that got us here is still being dispatched to one of these windows; outlive it.
        DispatchQueue.main.async { _ = closing }
        NSCursor.arrow.set()
        // Back to the app the user was in, so the next ⌘-arrow snaps its window.
        previous?.activate()
        previous = nil
        done(result)
    }
}

// Borderless windows can't become key by default, and without that Esc never arrives.
private final class MarkerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// Dims one screen, shows the instruction and the previously marked area, and lets the user drag a new box on it.
private final class MarkerView: NSView {
    var hint: NSRect?
    var labelTop: CGFloat = 0
    var onBox: (NSRect) -> Void = { _ in }
    var onCancel: () -> Void = {}
    private var start: NSPoint?
    private var box: NSRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel() } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        start = point(of: event)
        box = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let end = point(of: event)
        box = NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        needsDisplay = true
    }

    // A click or a tiny drag is dropped, so the user just tries again.
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        start = nil
        if let box, box.width >= 8, box.height >= 8, let window {
            onBox(window.convertToScreen(box))
        } else {
            box = nil
            needsDisplay = true
        }
    }

    // Clamped to this screen: the drag stays captured by this window even when the mouse leaves it.
    private func point(of event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil)
        return NSPoint(x: min(max(p.x, 0), bounds.maxX), y: min(max(p.y, 0), bounds.maxY))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        // Top-centre, because the camera stands in front of the bottom middle of its screen.
        let text = NSAttributedString(string: "Drag a box around the camera and its stand · Esc cancels", attributes: [
            .font: NSFont.systemFont(ofSize: 19, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        let plate = NSRect(x: ((bounds.width - size.width) / 2 - 20).rounded(), y: (labelTop - size.height - 44).rounded(),
                           width: size.width + 40, height: size.height + 20)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 12, yRadius: 12).fill()
        text.draw(at: NSPoint(x: plate.minX + 20, y: plate.minY + 10))

        if let hint {
            let dashed = NSBezierPath(rect: hint)
            dashed.lineWidth = 2
            dashed.setLineDash([10, 6], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.85).setStroke()
            dashed.stroke()
        }
        if let box {
            NSColor.systemYellow.withAlphaComponent(0.2).setFill()
            NSBezierPath(rect: box).fill()
            let border = NSBezierPath(rect: box)
            border.lineWidth = 2
            NSColor.systemYellow.setStroke()
            border.stroke()
        }
    }
}
