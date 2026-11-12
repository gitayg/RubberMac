import AppKit

// The Eye Color Camera's colours as a row of circles, like the accent colours in System Settings: one click picks a
// colour, and the name of the chosen one, or of the one under the pointer, shows under the row's title.
final class EyeColorSwatches: NSView {
    static let height: CGFloat = 48
    private static let padding: CGFloat = 12

    var onPick: ((String) -> Void)?
    private(set) var swatches: [EyeColorSwatch] = []
    private(set) var selected = ""
    private var hovered: String?
    private let title = NSTextField(labelWithString: "Colour")
    let name = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        title.font = .systemFont(ofSize: 13)
        title.textColor = .labelColor
        name.font = .systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        [title, name].forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    func show(colors: [String], selected: String) {
        if colors != swatches.map(\.colorName) {
            swatches.forEach { $0.removeFromSuperview() }
            swatches = colors.map { color in
                let swatch = EyeColorSwatch(colorName: color)
                swatch.target = self
                swatch.action = #selector(picked(_:))
                swatch.onHover = { [weak self] in self?.hovered = $0; self?.showName() }
                addSubview(swatch)
                return swatch
            }
            needsLayout = true
        }
        self.selected = selected
        swatches.forEach { $0.isChosen = $0.colorName == selected }
        showName()
    }

    @objc private func picked(_ sender: EyeColorSwatch) {
        show(colors: swatches.map(\.colorName), selected: sender.colorName)
        onPick?(sender.colorName)
    }

    private func showName() {
        name.stringValue = EyeCamera.title(for: hovered ?? selected)
    }

    override func layout() {
        super.layout()
        let size = EyeColorSwatch.size
        let right = bounds.width - Self.padding + EyeColorSwatch.inset
        let left = right - CGFloat(swatches.count) * size
        for (index, swatch) in swatches.enumerated() {
            swatch.frame = NSRect(x: left + CGFloat(index) * size, y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
        }
        let width = max(0, left - Self.padding - 8)
        title.frame = NSRect(x: Self.padding, y: 8, width: width, height: 17)
        name.frame = NSRect(x: Self.padding, y: 26, width: width, height: 14)
    }
}

// One colour: a filled circle with a hairline edge, so a pale or a dark colour still shows on the card, and a ring in
// the accent colour around the chosen one. VoiceOver reads it as a radio button with the colour's name.
final class EyeColorSwatch: NSButton {
    static let diameter: CGFloat = 18
    // Room around the circle for the ring that marks the chosen colour.
    static let inset: CGFloat = 4
    static let size = diameter + 2 * inset

    let colorName: String
    var onHover: ((String?) -> Void)?
    var isChosen = false {
        didSet {
            guard isChosen != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(isChosen)
        }
    }
    private var tracking: NSTrackingArea?

    init(colorName: String) {
        self.colorName = colorName
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        toolTip = EyeCamera.title(for: colorName)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(EyeCamera.title(for: colorName))
        setAccessibilityValue(false)
    }

    required init?(coder: NSCoder) { nil }

    var fill: NSColor? {
        EyeCamera.rgb(for: colorName).map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
    }

    private var circle: NSRect { bounds.insetBy(dx: Self.inset, dy: Self.inset) }

    override func draw(_ dirtyRect: NSRect) {
        (fill ?? .tertiaryLabelColor).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let edge = NSBezierPath(ovalIn: circle.insetBy(dx: 0.25, dy: 0.25))
        edge.lineWidth = 0.5
        NSColor.labelColor.withAlphaComponent(0.3).setStroke()
        edge.stroke()
        if isChosen {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }

    override func drawFocusRingMask() { NSBezierPath(ovalIn: circle).fill() }
    override var focusRingMaskBounds: NSRect { circle }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(colorName) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
}
