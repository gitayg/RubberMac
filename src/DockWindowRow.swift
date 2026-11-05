import AppKit

// One window in the Dock menu: a picture of it on the left (until there's one, where it is on the screens with its
// app icon), its title to the right and, under the title, whether it's minimized or on another desktop and how busy
// its process is.
final class DockWindowRow: NSView {
    static let padding: CGFloat = 6
    static let gap: CGFloat = 10
    static let textWidth: CGFloat = 220

    static func size(pictureWidth: CGFloat) -> NSSize {
        NSSize(width: pictureWidth + gap + textWidth + 2 * padding,
               height: (pictureWidth * SwitcherTileView.previewShape).rounded() + 2 * padding)
    }

    let windowID: CGWindowID?
    let pid: pid_t
    var onClick: () -> Void = {}
    private let box: NSRect
    private let pictureView = NSImageView()
    private let map: WindowMapView
    // The title, then the note and the usage when there are any.
    private var lines: [NSTextField] = []
    private var usage: NSTextField?

    var isHighlighted = false { didSet { layer?.backgroundColor = isHighlighted ? NSColor.controlAccentColor.cgColor : nil } }

    // screens and the window's place on them in AppKit coordinates.
    init(entry: SwitcherEntry, icon: NSImage?, picture: NSImage?, place: CGRect?, screens: [CGRect], pictureWidth: CGFloat) {
        let size = Self.size(pictureWidth: pictureWidth)
        let pad = Self.padding
        windowID = entry.windowID
        pid = entry.pid
        box = NSRect(x: pad, y: pad, width: pictureWidth, height: size.height - 2 * pad)
        map = WindowMapView(frame: box, window: place, screens: screens, icon: icon, picture: nil, dimmed: entry.isMinimized)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = 8

        addSubview(map)
        pictureView.imageScaling = .scaleAxesIndependently
        pictureView.wantsLayer = true
        pictureView.layer?.cornerRadius = 4
        pictureView.layer?.masksToBounds = true
        pictureView.layer?.borderWidth = 1
        pictureView.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        pictureView.alphaValue = entry.isMinimized ? 0.55 : 1
        addSubview(pictureView)
        if let picture { show(picture) } else { pictureView.isHidden = true }

        let notes = [entry.isMinimized ? "Minimized" : nil, entry.isOnCurrentSpace ? nil : "On another desktop"].compactMap { $0 }
        let title = NSTextField(labelWithString: entry.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingMiddle
        lines = [title]
        if !notes.isEmpty { lines.append(Self.greyLine(notes.joined(separator: " · "))) }
        lines.forEach(addSubview)
        arrangeLines()

        // The menu is never the key window, so the hover has to be tracked whether or not it is.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // The picture at its own shape, as large as the box allows; the map stays behind it, unseen.
    func show(_ picture: NSImage) {
        let scale = min(box.width / max(picture.size.width, 1), box.height / max(picture.size.height, 1))
        let size = NSSize(width: (picture.size.width * scale).rounded(), height: (picture.size.height * scale).rounded())
        pictureView.frame = NSRect(x: (box.midX - size.width / 2).rounded(), y: (box.midY - size.height / 2).rounded(),
                                   width: size.width, height: size.height)
        pictureView.image = picture
        pictureView.isHidden = false
        map.isHidden = true
    }

    // How busy the window's process is and the memory it holds, as a last line under the rest.
    func show(usage text: String) {
        if let usage {
            usage.stringValue = text
            return
        }
        let line = Self.greyLine(text)
        usage = line
        lines.append(line)
        addSubview(line)
        arrangeLines()
    }

    // The title and the lines under it, 17 points apart, centred on the row's height.
    private func arrangeLines() {
        let top = (bounds.height - 17) / 2 + CGFloat(lines.count - 1) * 17 / 2
        for (i, line) in lines.enumerated() {
            line.frame = NSRect(x: box.maxX + Self.gap, y: top - CGFloat(i) * 17, width: Self.textWidth, height: i == 0 ? 17 : 14)
        }
    }

    private static func greyLine(_ text: String) -> NSTextField {
        let line = NSTextField(labelWithString: text)
        line.font = .systemFont(ofSize: 11)
        line.textColor = NSColor.white.withAlphaComponent(0.6)
        line.lineBreakMode = .byTruncatingTail
        return line
    }

    // The whole row takes the click, not the picture or label under the pointer, and the first click counts even
    // though the menu never becomes the key window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
    }
}
