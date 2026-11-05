import AppKit

// The Alt-Tab grid: a dark HUD centred on the screen under the mouse, its tiles as big as fits on most of that
// screen. Clicking a tile picks that window; the panel never takes the focus.
final class SwitcherPanel {
    // Widths of a tile's picture: as large as lets every window fit, down to the smallest, which scrolls.
    static let largestPreview: CGFloat = 300
    static let smallestPreview: CGFloat = 60
    private static let inset: CGFloat = 12
    // The share of the screen the grid may cover.
    private static let coverage: CGFloat = 0.96
    private static let hintHeight: CGFloat = 26

    var onClick: (Int) -> Void = { _ in }

    private var panel: NSPanel?
    private var tiles: [SwitcherTileView] = []
    private var selected = 0

    var isShown: Bool { panel?.isVisible == true }

    func show(_ entries: [SwitcherEntry], selected: Int, pictures: WindowThumbnails? = nil) {
        let mouse = NSEvent.mouseLocation
        guard !entries.isEmpty,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let area = screen.visibleFrame
        let content = makeContent(entries, selected: selected, fitting: area.size, pictures: pictures)
        let size = content.frame.size
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = content
        panel.setFrame(NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func select(_ index: Int) {
        guard tiles.indices.contains(index) else { return }
        if tiles.indices.contains(selected) { tiles[selected].isSelected = false }
        selected = index
        tiles[index].isSelected = true
        tiles[index].scrollToVisible(tiles[index].bounds)
    }

    func show(_ picture: NSImage, for id: CGWindowID) {
        tiles.filter { $0.windowID == id }.forEach { $0.show(picture) }
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        tiles = []
    }

    // The tile size and columns for this many windows in this space: the largest pictures that fit them all, found by
    // trying every column count.
    static func layout(count: Int, fitting space: NSSize) -> (tile: NSSize, columns: Int, rows: Int) {
        let count = max(1, count)
        let pad = 2 * SwitcherTileView.padding
        func fits(_ width: CGFloat, columns: Int) -> Bool {
            let tile = SwitcherTileView.size(previewWidth: width)
            return CGFloat(columns) * tile.width <= space.width && CGFloat((count + columns - 1) / columns) * tile.height <= space.height
        }
        var best = (width: smallestPreview, columns: max(1, min(count, Int(space.width / SwitcherTileView.size(previewWidth: smallestPreview).width))))
        for columns in 1...count {
            let rows = CGFloat((count + columns - 1) / columns)
            let byHeight = (space.height / rows - SwitcherTileView.captionHeight - pad) / SwitcherTileView.previewShape
            var width = min(largestPreview, space.width / CGFloat(columns) - pad, byHeight).rounded(.down)
            // Tile heights are rounded to whole points, which can tip a row over; step back until it fits.
            while width > best.width && !fits(width, columns: columns) { width -= 1 }
            if width > best.width { best = (width, columns) }
        }
        let tile = SwitcherTileView.size(previewWidth: best.width)
        let rows = (count + best.columns - 1) / best.columns
        return (tile, best.columns, max(1, min(rows, Int(space.height / tile.height))))
    }

    // Builds the panel's view without showing it, so it can also be rendered off screen.
    func makeContent(_ entries: [SwitcherEntry], selected: Int, fitting limit: NSSize, pictures: WindowThumbnails? = nil) -> NSView {
        let inset = Self.inset
        // Without Screen Recording the tiles can only show icons; a line under them says how to get pictures.
        let hint = pictures != nil && !ScreenText.hasPermission ? Self.hintHeight : 0
        let space = NSSize(width: limit.width * Self.coverage - 2 * inset,
                           height: limit.height * Self.coverage - 2 * inset - hint)
        let (tile, columns, visibleRows) = Self.layout(count: entries.count, fitting: space)
        let rows = (entries.count + columns - 1) / columns
        let size = NSSize(width: max(CGFloat(columns) * tile.width, hint > 0 ? 520 : 0) + 2 * inset,
                          height: CGFloat(visibleRows) * tile.height + 2 * inset + hint)

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .vibrantDark)
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true

        if hint > 0 {
            let label = NSTextField(labelWithString: "To see what's in each window, allow Screen Recording: "
                                    + "RubberMAC menu → Show Window Pictures in the Switcher…")
            label.font = .systemFont(ofSize: 12)
            label.textColor = NSColor.white.withAlphaComponent(0.75)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: inset, y: inset, width: size.width - 2 * inset, height: 16)
            background.addSubview(label)
        }
        let scroll = NSScrollView(frame: NSRect(x: (size.width - CGFloat(columns) * tile.width) / 2, y: inset + hint,
                                                width: CGFloat(columns) * tile.width,
                                                height: CGFloat(visibleRows) * tile.height))
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        let grid = FlippedView(frame: NSRect(x: 0, y: 0, width: scroll.frame.width, height: CGFloat(rows) * tile.height))
        var icons: [pid_t: NSImage] = [:]
        let screens = NSScreen.screens.map(\.frame)
        let primaryHeight = screens.first?.height ?? 0
        // The last row is centred, as on Windows.
        let lastRowStart = (rows - 1) * columns
        let lastRowShift = CGFloat(columns - (entries.count - lastRowStart)) * tile.width / 2
        tiles = entries.enumerated().map { i, entry in
            if icons[entry.pid] == nil { icons[entry.pid] = NSRunningApplication(processIdentifier: entry.pid)?.icon }
            let view = SwitcherTileView(entry: entry, icon: icons[entry.pid], picture: pictures?.picture(of: entry.windowID),
                                        place: entry.frame.map { WindowMapView.appKit($0, primaryHeight: primaryHeight) },
                                        screens: screens, size: tile)
            view.onClick = { [weak self] in self?.onClick(i) }
            view.frame.origin = NSPoint(x: CGFloat(i % columns) * tile.width + (i >= lastRowStart ? lastRowShift : 0),
                                        y: CGFloat(i / columns) * tile.height)
            grid.addSubview(view)
            return view
        }
        scroll.documentView = grid
        background.addSubview(scroll)

        self.selected = selected
        select(selected)
        return background
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
