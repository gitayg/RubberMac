import AppKit

// One window in the switcher grid: a picture of it as big as the tile allows (until there's one, where it is on the
// screens with its app icon), and under it the app icon, the title and a small map of where the window is.
final class SwitcherTileView: NSView {
    static let padding: CGFloat = 10
    static let captionHeight: CGFloat = 30
    // Pictures are 16:10, the shape of most screens.
    static let previewShape: CGFloat = 0.625

    static func size(previewWidth: CGFloat) -> NSSize {
        NSSize(width: previewWidth + 2 * padding, height: (previewWidth * previewShape).rounded() + captionHeight + 2 * padding)
    }

    let windowID: CGWindowID?
    var onClick: () -> Void = {}
    private let preview: NSRect
    private let pictureView = NSImageView()
    private let map: WindowMapView
    private let titleLabel: NSTextField

    var isSelected = false { didSet { applyColors() } }

    // screens and the window's place on them in AppKit coordinates.
    init(entry: SwitcherEntry, icon: NSImage?, picture: NSImage?, place: CGRect?, screens: [CGRect], size: NSSize) {
        let pad = Self.padding
        windowID = entry.windowID
        preview = NSRect(x: pad, y: pad + Self.captionHeight, width: size.width - 2 * pad,
                         height: size.height - 2 * pad - Self.captionHeight)
        map = WindowMapView(frame: preview, window: place, screens: screens, icon: icon, picture: nil, dimmed: entry.isMinimized)
        titleLabel = NSTextField(labelWithString: entry.title)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = 10

        addSubview(map)
        pictureView.imageScaling = .scaleAxesIndependently
        pictureView.wantsLayer = true
        pictureView.layer?.cornerRadius = 6
        pictureView.layer?.masksToBounds = true
        pictureView.layer?.borderWidth = 1
        pictureView.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        pictureView.alphaValue = entry.isMinimized ? 0.55 : 1
        addSubview(pictureView)
        if let picture { show(picture) } else { pictureView.isHidden = true }

        if entry.isMinimized {
            let badge = NSTextField(labelWithString: "minimized")
            badge.font = .systemFont(ofSize: 10, weight: .medium)
            badge.textColor = .white
            badge.alignment = .center
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 4
            badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
            let fit = badge.fittingSize
            badge.frame = NSRect(x: preview.maxX - fit.width - 16, y: preview.maxY - fit.height - 8,
                                 width: fit.width + 10, height: fit.height + 2)
            addSubview(badge)
        }

        let line = pad + (Self.captionHeight - 18) / 2
        let iconView = NSImageView(frame: NSRect(x: pad, y: line, width: 18, height: 18))
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        let placeMap = WindowMapView(frame: NSRect(x: size.width - pad - 32, y: line, width: 32, height: 18), window: place,
                                   screens: screens, icon: nil, picture: nil, dimmed: entry.isMinimized)
        placeMap.isHidden = place == nil
        addSubview(placeMap)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.frame = NSRect(x: pad + 24, y: line, width: size.width - 2 * pad - 24 - (place == nil ? 0 : 38), height: 17)
        addSubview(titleLabel)

        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // The picture at its own shape, as large as the preview area allows; the map stays behind it, unseen.
    func show(_ picture: NSImage) {
        let scale = min(preview.width / max(picture.size.width, 1), preview.height / max(picture.size.height, 1))
        let size = NSSize(width: (picture.size.width * scale).rounded(), height: (picture.size.height * scale).rounded())
        pictureView.frame = NSRect(x: (preview.midX - size.width / 2).rounded(), y: (preview.midY - size.height / 2).rounded(),
                                   width: size.width, height: size.height)
        pictureView.image = picture
        pictureView.isHidden = false
        map.isHidden = true
    }

    // The whole tile takes the click, not the picture or label under the pointer, and the first click counts even
    // though the switcher never becomes the key window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }

    private func applyColors() {
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
    }
}
