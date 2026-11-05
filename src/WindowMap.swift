import AppKit

// Where a window is: the screens in their arrangement, shrunk to fit, with the window drawn at its place on them,
// filled with its picture once there is one, else with its app icon. A window with no known frame shows the icon alone.
final class WindowMapView: NSView {
    var picture: NSImage? { didSet { needsDisplay = true } }

    private let icon: NSImage?
    private let place: CGRect?
    private let screens: [CGRect]
    private let dimmed: Bool

    // window and screens in AppKit coordinates (origin at the bottom left of the primary screen).
    init(frame: NSRect, window: CGRect?, screens: [CGRect], icon: NSImage?, picture: NSImage?, dimmed: Bool) {
        self.place = window
        self.screens = screens
        self.icon = icon
        self.picture = picture
        self.dimmed = dimmed
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // A window frame from Accessibility (origin at the top left of the primary screen) in AppKit coordinates.
    static func appKit(_ frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let world = screens.reduce(CGRect.null) { $0.union($1) }
        guard let place, !world.isNull, world.width > 0, world.height > 0 else {
            icon?.draw(in: NSRect(x: bounds.midX - 16, y: bounds.midY - 16, width: 32, height: 32))
            return
        }
        let scale = min(bounds.width / world.width, bounds.height / world.height)
        let origin = CGPoint(x: bounds.midX - world.width * scale / 2, y: bounds.midY - world.height * scale / 2)
        func map(_ rect: CGRect) -> CGRect {
            CGRect(x: origin.x + (rect.minX - world.minX) * scale, y: origin.y + (rect.minY - world.minY) * scale,
                   width: rect.width * scale, height: rect.height * scale).integral
        }

        for screen in screens {
            let shape = NSBezierPath(roundedRect: map(screen).insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            NSColor.white.withAlphaComponent(0.08).setFill()
            shape.fill()
            NSColor.white.withAlphaComponent(0.3).setStroke()
            shape.stroke()
        }

        let spot = map(place).intersection(bounds)
        guard !spot.isEmpty else { return }
        let alpha: CGFloat = dimmed ? 0.45 : 1
        let shape = NSBezierPath(roundedRect: spot, xRadius: 2, yRadius: 2)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if let picture {
            picture.draw(in: spot, from: .zero, operation: .sourceOver, fraction: alpha)
        } else {
            NSColor.white.withAlphaComponent(0.28 * alpha).setFill()
            spot.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.75 * alpha).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        // On the window's bottom-right corner, kept inside the map.
        let side: CGFloat = picture == nil ? min(48, max(14, (min(spot.width, spot.height) * 0.5).rounded())) : 18
        let corner = picture == nil ? CGPoint(x: spot.midX - side / 2, y: spot.midY - side / 2)
            : CGPoint(x: spot.maxX - side + 4, y: spot.minY - 4)
        let at = CGPoint(x: min(max(corner.x, bounds.minX), bounds.maxX - side),
                         y: min(max(corner.y, bounds.minY), bounds.maxY - side))
        icon?.draw(in: NSRect(origin: at, size: CGSize(width: side, height: side)), from: .zero, operation: .sourceOver,
                   fraction: alpha)
    }
}
