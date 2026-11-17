import AppKit

// What one tile shows: an app, or a folder with its apps' icons in it.
struct StartMenuTile {
    enum Kind {
        case app(StartMenuApp)
        case folder(StartMenuFolder, [StartMenuApp])
    }

    let kind: Kind

    var name: String {
        switch kind {
        case .app(let app): return app.name
        case .folder(let folder, _): return folder.name
        }
    }
}

protocol StartMenuGridOwner: AnyObject {
    func grid(_ grid: StartMenuGrid, clicked index: Int)
    func grid(_ grid: StartMenuGrid, menuFor index: Int) -> NSMenu?
    func grid(_ grid: StartMenuGrid, beganDragging index: Int)
    func grid(_ grid: StartMenuGrid, draggedTo screenPoint: NSPoint)
    func gridEndedDrag(_ grid: StartMenuGrid)
    func grid(_ grid: StartMenuGrid, allows drop: StartMenuGrid.Drop) -> Bool
    func grid(_ grid: StartMenuGrid, accepts drop: StartMenuGrid.Drop) -> Bool
}

// A grid of tiles, drawn by the grid itself rather than a view per tile. A click opens a tile, a drag moves it; while
// something is dragged over it, it shows where it would land: a bar between tiles, or a ring round the tile it would
// make a folder with.
final class StartMenuGrid: NSView, NSDraggingSource {
    enum Kind: Equatable {
        case pins, main, results
        case folder(String)
    }

    enum Drop: Equatable {
        case before(Int)
        case onto(Int)
    }

    static let cell = NSSize(width: 104, height: 104)
    static let iconSize: CGFloat = 60
    static let dragType = NSPasteboard.PasteboardType("app.rubbermac.start.tile")
    private static let dragDistance: CGFloat = 4

    var kind: Kind {
        didSet { registerForDrops() }
    }
    var tiles: [StartMenuTile] = [] {
        didSet { needsDisplay = true }
    }
    var columns = 7
    var selected: Int? {
        didSet { if selected != oldValue { needsDisplay = true } }
    }
    // The tile being dragged, drawn faint where it was.
    private(set) var lifted: Int?
    private(set) var drop: Drop?
    private var dropBar: NSRect?
    private var pressed: (index: Int, point: NSPoint)?
    weak var owner: StartMenuGridOwner?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        registerForDrops()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var rows: Int { (tiles.count + columns - 1) / columns }
    var height: CGFloat { CGFloat(rows) * Self.cell.height }

    private func registerForDrops() {
        if kind == .results { unregisterDraggedTypes() } else { registerForDraggedTypes([Self.dragType]) }
    }

    func frame(of index: Int) -> NSRect {
        Self.frame(of: index, columns: columns)
    }

    static func frame(of index: Int, columns: Int) -> NSRect {
        NSRect(x: CGFloat(index % columns) * cell.width, y: CGFloat(index / columns) * cell.height,
               width: cell.width, height: cell.height)
    }

    static func iconFrame(in cell: NSRect) -> NSRect {
        NSRect(x: cell.midX - iconSize / 2, y: cell.minY + 8, width: iconSize, height: iconSize)
    }

    func index(at point: NSPoint) -> Int? {
        guard point.x >= 0, point.y >= 0, point.x < CGFloat(columns) * Self.cell.width else { return nil }
        let index = Int(point.y / Self.cell.height) * columns + Int(point.x / Self.cell.width)
        return index < tiles.count ? index : nil
    }

    // Where a drop at the point would land, best first: onto the tile under it when over the middle of its icon, else
    // before the tile whose near half it's over, or at the end past the last one. The bar shows where.
    static func drops(at point: NSPoint, columns: Int, count: Int, allowsOnto: Bool) -> [(drop: Drop, bar: NSRect?)] {
        let column = min(max(Int((point.x / cell.width).rounded(.down)), 0), columns - 1)
        let row = max(Int((point.y / cell.height).rounded(.down)), 0)
        let index = row * columns + column
        func bar(atRightOf frame: NSRect) -> NSRect { NSRect(x: frame.maxX - 1.5, y: frame.minY + 6, width: 3, height: iconSize + 10) }
        func bar(atLeftOf frame: NSRect) -> NSRect { NSRect(x: frame.minX - 1.5, y: frame.minY + 6, width: 3, height: iconSize + 10) }
        guard index < count else {
            // Past the last tile: on its row the bar goes after it, on a row of its own at the start of that row.
            let last = count - 1
            if count > 0, row == last / columns { return [(.before(count), bar(atRightOf: frame(of: last, columns: columns)))] }
            return [(.before(count), bar(atLeftOf: frame(of: count, columns: columns)))]
        }
        let cell = frame(of: index, columns: columns)
        var drops: [(drop: Drop, bar: NSRect?)] = []
        if allowsOnto, iconFrame(in: cell).insetBy(dx: 10, dy: 10).contains(point) { drops.append((.onto(index), nil)) }
        drops.append(point.x < cell.midX ? (.before(index), bar(atLeftOf: cell)) : (.before(index + 1), bar(atRightOf: cell)))
        return drops
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for index in tiles.indices {
            let cell = frame(of: index)
            guard cell.intersects(dirtyRect) else { continue }
            if index == selected {
                NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: cell.insetBy(dx: 4, dy: 2), xRadius: 12, yRadius: 12).fill()
            }
            if drop == .onto(index) {
                NSColor.labelColor.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: Self.iconFrame(in: cell).insetBy(dx: -6, dy: -6), xRadius: 16, yRadius: 16).fill()
            }
            Self.drawTile(tiles[index], in: cell, alpha: index == lifted ? 0.3 : 1)
        }
        if let dropBar {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: dropBar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    static func drawTile(_ tile: StartMenuTile, in cell: NSRect, alpha: CGFloat) {
        let icon = iconFrame(in: cell)
        switch tile.kind {
        case .app(let app):
            StartMenuIcons.icon(app.path).draw(in: icon, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        case .folder(_, let apps):
            drawFolder(apps, in: icon, alpha: alpha)
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha), .paragraphStyle: style,
        ]
        let label = NSRect(x: cell.minX + 4, y: icon.maxY + 5, width: cell.width - 8, height: cell.maxY - icon.maxY - 7)
        (tile.name as NSString).draw(with: label, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    // A rounded square with up to nine of its apps' icons, as Launchpad drew a folder.
    private static func drawFolder(_ apps: [StartMenuApp], in frame: NSRect, alpha: CGFloat) {
        NSColor.labelColor.withAlphaComponent(0.12 * alpha).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14).fill()
        let inset: CGFloat = 7, gap: CGFloat = 3
        let side = (frame.width - 2 * inset - 2 * gap) / 3
        for (index, app) in apps.prefix(9).enumerated() {
            let mini = NSRect(x: frame.minX + inset + CGFloat(index % 3) * (side + gap),
                              y: frame.minY + inset + CGFloat(index / 3) * (side + gap), width: side, height: side)
            StartMenuIcons.icon(app.path).draw(in: mini, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        }
    }

    // MARK: Clicks and drags

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        pressed = index(at: point).map { ($0, point) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed, kind != .results else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressed.point.x, point.y - pressed.point.y) > Self.dragDistance else { return }
        self.pressed = nil
        beginDrag(pressed.index, with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let pressed, index(at: convert(event.locationInWindow, from: nil)) == pressed.index else { return }
        owner?.grid(self, clicked: pressed.index)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        index(at: convert(event.locationInWindow, from: nil)).flatMap { owner?.grid(self, menuFor: $0) }
    }

    private func beginDrag(_ index: Int, with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(String(index), forType: Self.dragType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let cell = frame(of: index)
        let tile = tiles[index]
        dragging.setDraggingFrame(cell, contents: NSImage(size: cell.size, flipped: true) { bounds in
            Self.drawTile(tile, in: bounds, alpha: 1)
            return true
        })
        lifted = index
        needsDisplay = true
        owner?.grid(self, beganDragging: index)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        owner?.grid(self, draggedTo: screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        lifted = nil
        needsDisplay = true
        owner?.gridEndedDrag(self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        autoscroll(sender)
        return update(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        show(nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let drop else { return false }
        show(nil)
        return owner?.grid(self, accepts: drop) ?? false
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let target = Self.drops(at: point, columns: columns, count: tiles.count, allowsOnto: kind == .main)
            .first { owner?.grid(self, allows: $0.drop) == true }
        show(target)
        return target == nil ? [] : .move
    }

    private func show(_ target: (drop: Drop, bar: NSRect?)?) {
        guard target?.drop != drop || target?.bar != dropBar else { return }
        drop = target?.drop
        dropBar = target?.bar
        needsDisplay = true
    }

    // Near the top or bottom of the scrolled area, it scrolls on, so a tile can be taken anywhere in a long list.
    private func autoscroll(_ sender: NSDraggingInfo) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let point = clip.convert(sender.draggingLocation, from: nil)
        let edge: CGFloat = 36
        let step: CGFloat = point.y < clip.bounds.minY + edge ? -12 : point.y > clip.bounds.maxY - edge ? 12 : 0
        guard step != 0, let document = clip.documentView else { return }
        let y = min(max(clip.bounds.minY + step, 0), max(document.frame.height - clip.bounds.height, 0))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
}
