import AppKit

// The apps that can use Atkinson Hyperlegible, as a row of their icons like the colour circles on the Eye Color Camera
// page: an app in full colour with a check is using it, a faded one isn't, and one click switches it. Under the title
// is the app under the pointer and what changes there, or which apps are using it.
final class FontAppIcons: NSView {
    static let height: CGFloat = 48
    private static let padding: CGFloat = 12

    struct App: Equatable {
        var id: String
        var name: String
        var whatChanges: String
        var isOn: Bool
        var icon: NSImage
    }

    var onToggle: ((String) -> Void)?
    private(set) var icons: [FontAppIcon] = []
    private var hovered: String?
    private let title = NSTextField(labelWithString: "Use It In")
    let name = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        title.font = .systemFont(ofSize: 13)
        title.textColor = .labelColor
        name.font = .systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        [title, name].forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ apps: [App]) {
        if apps.map(\.id) != icons.map(\.app.id) {
            icons.forEach { $0.removeFromSuperview() }
            icons = apps.map { app in
                let icon = FontAppIcon(app: app)
                icon.target = self
                icon.action = #selector(clicked(_:))
                icon.onHover = { [weak self] in self?.hovered = $0; self?.showName() }
                addSubview(icon)
                return icon
            }
            needsLayout = true
        }
        zip(icons, apps).forEach { $0.app = $1 }
        showName()
    }

    @objc private func clicked(_ sender: FontAppIcon) {
        onToggle?(sender.app.id)
    }

    private func showName() {
        if let app = icons.first(where: { $0.app.id == hovered })?.app {
            name.stringValue = "\(app.name): \(app.whatChanges)"
            return
        }
        let on = icons.filter(\.app.isOn).map(\.app.name)
        name.stringValue = on.isEmpty ? "Click an app to use it there" : "In \(ListFormatter.localizedString(byJoining: on))"
    }

    override func layout() {
        super.layout()
        let size = FontAppIcon.size
        let right = bounds.width - Self.padding + FontAppIcon.inset
        let left = right - CGFloat(icons.count) * size
        for (index, icon) in icons.enumerated() {
            icon.frame = NSRect(x: left + CGFloat(index) * size, y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
        }
        let width = max(0, left - Self.padding - 8)
        title.frame = NSRect(x: Self.padding, y: 8, width: width, height: 17)
        name.frame = NSRect(x: Self.padding, y: 26, width: width, height: 14)
    }
}

// One app: its icon, faded while the app isn't using the font, and with a check in the accent colour when it is, so
// it reads the same whether or not the panel is the active window. VoiceOver reads it as a checkbox with the app's name.
final class FontAppIcon: NSButton {
    static let iconSize: CGFloat = 26
    static let inset: CGFloat = 3
    static let size = iconSize + 2 * inset
    static let fadedAlpha: CGFloat = 0.35

    var app: FontAppIcons.App {
        didSet {
            guard app != oldValue else { return }
            toolTip = "\(app.name): \(app.whatChanges)"
            setAccessibilityLabel(app.name)
            setAccessibilityValue(app.isOn)
            needsDisplay = true
        }
    }
    var onHover: ((String?) -> Void)?
    private var tracking: NSTrackingArea?

    init(app: FontAppIcons.App) {
        self.app = app
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        toolTip = "\(app.name): \(app.whatChanges)"
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(app.name)
        setAccessibilityValue(app.isOn)
    }

    required init?(coder: NSCoder) { nil }

    private var iconRect: NSRect { bounds.insetBy(dx: Self.inset, dy: Self.inset) }

    // So the check sits at the icon's bottom right, as on a Dock icon.
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        app.icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: app.isOn ? 1 : Self.fadedAlpha)
        guard app.isOn else { return }
        let badge = NSRect(x: bounds.maxX - 13, y: bounds.minY + 1, width: 12, height: 12)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: badge).fill()
        NSColor.windowBackgroundColor.setStroke()
        let ring = NSBezierPath(ovalIn: badge.insetBy(dx: -0.5, dy: -0.5))
        ring.lineWidth = 1
        ring.stroke()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: badge.minX + 3, y: badge.midY + 0.2))
        check.line(to: NSPoint(x: badge.minX + 5.2, y: badge.minY + 3.2))
        check.line(to: NSPoint(x: badge.maxX - 2.8, y: badge.maxY - 3.2))
        check.lineWidth = 1.6
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        NSColor.white.setStroke()
        check.stroke()
    }

    override func drawFocusRingMask() { NSBezierPath(roundedRect: iconRect, xRadius: 6, yRadius: 6).fill() }
    override var focusRingMaskBounds: NSRect { iconRect }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(app.id) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
}
