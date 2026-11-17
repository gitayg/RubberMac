import AppKit

// The small level window, one per screen: a symbol and a bar of 16 segments, centred low on the screen. It never
// takes focus or clicks, shows on every Space (full-screen ones too) and fades out a moment after the last change.
final class LevelOverlayWindows {
    static let size = NSSize(width: 300, height: 56)
    static let shownFor: TimeInterval = 1.5
    static let fadeFor: TimeInterval = 0.3
    // Above RubberMAC's own software dimming, so the level reads at full strength on a dimmed screen.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue)

    private var panels: [CGDirectDisplayID: LevelOverlayPanel] = [:]

    func show(symbol: String, level: Double, on screen: NSScreen) {
        guard let id = screen.displayID else { return }
        let panel = panel(for: id)
        panel.content.show(symbol: symbol, level: level)
        panel.setFrame(Self.frame(screen: screen.frame, visible: screen.visibleFrame), display: true)
        panel.generation += 1
        let generation = panel.generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shownFor) { [weak panel] in
            guard let panel, panel.generation == generation else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.fadeFor
                panel.animator().alphaValue = 0
            }, completionHandler: {
                if panel.generation == generation { panel.orderOut(nil) }
            })
        }
    }

    func hideAll() {
        for panel in panels.values {
            panel.generation += 1
            panel.orderOut(nil)
        }
    }

    // The screen's window, made the first time; a change on the same screen updates it in place.
    func panel(for id: CGDirectDisplayID) -> LevelOverlayPanel {
        if let panel = panels[id] { return panel }
        let panel = LevelOverlayPanel()
        panels[id] = panel
        return panel
    }

    // Centred across the screen, a tenth of its height above the Dock (or the bottom edge when the Dock hides).
    static func frame(screen: CGRect, visible: CGRect) -> CGRect {
        CGRect(x: (screen.midX - size.width / 2).rounded(), y: (visible.minY + screen.height / 10).rounded(),
               width: size.width, height: size.height)
    }
}

final class LevelOverlayPanel: NSPanel {
    let content = LevelOverlayView(frame: NSRect(origin: .zero, size: LevelOverlayWindows.size))
    var generation = 0

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: LevelOverlayWindows.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        level = LevelOverlayWindows.level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        alphaValue = 0
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class LevelOverlayView: NSVisualEffectView {
    let icon = NSImageView()
    let bar = LevelBarView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        // Without it the material goes flat whenever RubberMAC isn't the active app, which is always.
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        icon.symbolConfiguration = .init(pointSize: 20, weight: .semibold)
        icon.contentTintColor = .labelColor
        icon.frame = NSRect(x: 16, y: 0, width: 32, height: frame.height)
        bar.frame = NSRect(x: 60, y: (frame.height - 8) / 2, width: frame.width - 60 - 22, height: 8)
        addSubview(icon)
        addSubview(bar)
    }

    required init?(coder: NSCoder) { nil }

    func show(symbol: String, level: Double) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        bar.level = level
    }
}

// 16 segments, filled up to the level; a level between two segments fills part of the next, so quarter steps show.
final class LevelBarView: NSView {
    static let gap: CGFloat = 3

    var level: Double = 0 {
        didSet { needsDisplay = true }
    }

    // Each segment's rectangle, left to right.
    var segments: [NSRect] {
        let count = CGFloat(LevelSteps.segments)
        let width = (bounds.width - Self.gap * (count - 1)) / count
        return (0..<LevelSteps.segments).map { NSRect(x: CGFloat($0) * (width + Self.gap), y: 0, width: width, height: bounds.height) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let filled = min(max(level, 0), 1) * Double(LevelSteps.segments)
        for (index, segment) in segments.enumerated() {
            NSColor.labelColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: segment, xRadius: 1.5, yRadius: 1.5).fill()
            let part = min(max(filled - Double(index), 0), 1)
            guard part > 0 else { continue }
            NSColor.labelColor.setFill()
            var lit = segment
            lit.size.width *= CGFloat(part)
            NSBezierPath(roundedRect: lit, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
