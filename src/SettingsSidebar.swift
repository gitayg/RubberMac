import AppKit

// The left side of the panel: search, the pages as a source list with coloured tiles, and Quit.
final class SettingsSidebar: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate {
    private static let inset: CGFloat = 10
    private static let rowHeight: CGFloat = 30

    let search = NSSearchField()
    let table = NSTableView()
    let quit = NSButton(title: "Quit RubberMAC", target: NSApp, action: #selector(NSApplication.terminate(_:)))
    private(set) var pages: [SettingsPage] = []
    private let scroll = NSScrollView()
    private var selecting = false

    var onSelect: (String) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .sidebar
        blendingMode = .behindWindow
        state = .active

        search.frame = NSRect(x: Self.inset, y: frame.height - Self.inset - 28, width: frame.width - 2 * Self.inset, height: 28)
        search.autoresizingMask = [.width, .minYMargin]
        search.placeholderString = "Search"
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.focusRingType = .none

        let column = NSTableColumn(identifier: .init("page"))
        column.width = frame.width
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = Self.rowHeight
        table.backgroundColor = .clear
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self

        let bottom = Self.inset + 22
        scroll.frame = NSRect(x: 0, y: bottom + Self.inset, width: frame.width, height: search.frame.minY - bottom - 2 * Self.inset)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = table
        table.sizeLastColumnToFit()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        quit.controlSize = .small
        quit.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        quit.sizeToFit()
        quit.frame.origin = NSPoint(x: Self.inset, y: Self.inset)
        quit.autoresizingMask = [.maxYMargin]

        [search, scroll, quit].forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    // Only touches the rows when the list has changed: reloading from inside a click on a row breaks the click.
    func show(_ pages: [SettingsPage], selected: String?) {
        let unchanged = self.pages.map(\.id) == pages.map(\.id) && self.pages.map(\.needsAttention) == pages.map(\.needsAttention)
        self.pages = pages
        selecting = true
        if !unchanged { table.reloadData() }
        select(selected)
        selecting = false
    }

    private func select(_ id: String?) {
        guard let id, let index = pages.firstIndex(where: { $0.id == id }) else { return }
        table.selectRowIndexes([index], byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    // ↑ and ↓ from the search field: the table handles them itself when it has the keyboard.
    func move(by step: Int) {
        let row = table.selectedRow + step
        guard pages.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        SettingsSidebarRow(page: pages[row], width: tableColumn?.width ?? tableView.bounds.width, height: Self.rowHeight)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, pages.indices.contains(table.selectedRow) else { return }
        onSelect(pages[table.selectedRow].id)
    }
}

// A page in the sidebar: a small coloured tile with a white symbol, its name, and a dot when it wants attention.
final class SettingsSidebarRow: NSTableCellView {
    private static let tile: CGFloat = 20

    let needsAttention: Bool

    init(page: SettingsPage, width: CGFloat, height: CGFloat) {
        needsAttention = page.needsAttention
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let tile = SettingsTile(symbol: page.symbol, tint: page.tint, size: Self.tile)
        tile.frame.origin = NSPoint(x: 4, y: ((height - Self.tile) / 2).rounded())
        let label = NSTextField(labelWithString: page.title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.sizeToFit()
        label.frame = NSRect(x: 4 + Self.tile + 8, y: ((height - label.frame.height) / 2).rounded(),
                             width: width - 4 - Self.tile - 8 - 20, height: label.frame.height)
        label.autoresizingMask = [.width]
        textField = label
        addSubview(tile)
        addSubview(label)
        if needsAttention {
            let dot = SettingsAttentionDot(frame: NSRect(x: width - 16, y: ((height - 8) / 2).rounded(), width: 8, height: 8))
            dot.autoresizingMask = [.minXMargin]
            addSubview(dot)
        }
    }

    required init?(coder: NSCoder) { nil }
}

private final class SettingsTile: NSView {
    private let tint: NSColor

    init(symbol: String, tint: NSColor, size: CGFloat) {
        self.tint = tint
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        let image = NSImageView(frame: bounds)
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        image.contentTintColor = .white
        image.imageAlignment = .alignCenter
        image.autoresizingMask = [.width, .height]
        addSubview(image)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        tint.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
}

private final class SettingsAttentionDot: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
