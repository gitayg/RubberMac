import AppKit
import Carbon.HIToolbox

// Start's window contents: the search field, the pinned row and the grid of all apps (or what the search found), a
// line of hints, and an open folder on top. It lays things out; StartMenuController decides what's in them.
final class StartMenuView: NSView {
    static let padding: CGFloat = 28
    private static let top: CGFloat = 20
    private static let searchHeight: CGFloat = 30
    private static let titleHeight: CGFloat = 26
    private static let hintHeight: CGFloat = 30
    private static let radius: CGFloat = 18

    var onCommand: (Selector) -> Bool = { _ in false }

    let background = NSVisualEffectView()
    let search = NSSearchField()
    let scroll = NSScrollView()
    let content = StartMenuFlippedView()
    let pinnedTitle = StartMenuView.title("Pinned")
    let allTitle = StartMenuView.title("All Apps")
    let pinned = StartMenuGrid(kind: .pins)
    let main = StartMenuGrid(kind: .main)
    let empty = NSTextField(labelWithString: "")
    let hint = NSTextField(labelWithString: "Drag to arrange, or onto another app to make a folder  ·  Right-click an app for more")
    let folder = StartMenuFolderView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.autoresizingMask = [.width, .height]
        addSubview(background)

        search.placeholderString = "Search Apps"
        search.font = .systemFont(ofSize: 15)
        search.controlSize = .large
        search.focusRingType = .none
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        addSubview(search)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = content
        addSubview(scroll)
        [pinnedTitle, pinned, allTitle, main, empty].forEach(content.addSubview)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.font = .systemFont(ofSize: 13)

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        addSubview(hint)

        folder.isHidden = true
        addSubview(folder)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    // The window's size for a screen's free area (inside the menu bar and the Dock), and how many columns fit.
    static func size(for area: NSRect) -> (size: NSSize, columns: Int) {
        let columns = max(4, min(7, Int((area.width - 120 - 2 * padding) / StartMenuGrid.cell.width)))
        let height = max(min(area.height - 100, 700), 360)
        return (NSSize(width: CGFloat(columns) * StartMenuGrid.cell.width + 2 * padding, height: height), columns)
    }

    // Centred in the free area of the screen.
    static func frame(of size: NSSize, in area: NSRect) -> NSRect {
        NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
               width: size.width, height: size.height)
    }

    // Puts everything in place for the window's size and what's showing: pins (when there are any and nothing is
    // searched for), the grid, and the empty-search line.
    func arrange(columns: Int, searching: Bool, emptyText: String?) {
        background.frame = bounds
        background.maskImage = Self.mask(radius: Self.radius)
        let width = bounds.width - 2 * Self.padding
        search.frame = NSRect(x: Self.padding, y: bounds.height - Self.top - Self.searchHeight, width: width, height: Self.searchHeight)
        hint.frame = NSRect(x: Self.padding, y: 8, width: width, height: 16)
        let scrollTop = search.frame.minY - 14
        scroll.frame = NSRect(x: Self.padding - 8, y: Self.hintHeight, width: width + 16, height: scrollTop - Self.hintHeight)
        folder.frame = bounds

        let gridWidth = CGFloat(columns) * StartMenuGrid.cell.width
        let showPins = !searching && !pinned.tiles.isEmpty
        var y: CGFloat = 0
        pinnedTitle.isHidden = !showPins
        pinned.isHidden = !showPins
        allTitle.isHidden = !showPins
        if showPins {
            pinnedTitle.frame = NSRect(x: 12, y: y, width: gridWidth, height: Self.titleHeight - 6)
            y += Self.titleHeight
            pinned.columns = columns
            pinned.frame = NSRect(x: 8, y: y, width: gridWidth, height: pinned.height)
            y += pinned.height + 10
            allTitle.frame = NSRect(x: 12, y: y, width: gridWidth, height: Self.titleHeight - 6)
            y += Self.titleHeight
        }
        main.columns = columns
        // At least to the bottom, so a tile dropped below the last row still lands at the end.
        let mainHeight = max(main.height, scroll.frame.height - y)
        main.frame = NSRect(x: 8, y: y, width: gridWidth, height: mainHeight)
        empty.isHidden = emptyText == nil
        empty.stringValue = emptyText ?? ""
        empty.frame = NSRect(x: 8, y: 60, width: gridWidth, height: 20)
        content.frame = NSRect(x: 0, y: 0, width: scroll.frame.width, height: y + mainHeight)
    }

    private static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // RubberMAC has no main menu, so the search field's ⌘ keys are answered here; ⌘W closes, as in any window.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        // By key position, so these still work with the keyboard set to another language.
        switch Int(event.keyCode) {
        case kVK_ANSI_W: return onCommand(#selector(NSResponder.cancelOperation(_:)))
        case kVK_ANSI_A: return edit(#selector(NSText.selectAll(_:)))
        case kVK_ANSI_C: return edit(#selector(NSText.copy(_:)))
        case kVK_ANSI_X: return edit(#selector(NSText.cut(_:)))
        case kVK_ANSI_V: return edit(#selector(NSText.paste(_:)))
        case kVK_ANSI_Z: return edit(Selector(("undo:")))
        default: return super.performKeyEquivalent(with: event)
        }
    }

    // The search field's and a folder name's text editing, normally reached through the Edit menu.
    private func edit(_ action: Selector) -> Bool {
        guard window?.firstResponder is NSTextView else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }

    override func cancelOperation(_ sender: Any?) {
        _ = onCommand(#selector(NSResponder.cancelOperation(_:)))
    }
}

final class StartMenuFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// An open folder: the rest of Start dimmed, and a card in the middle with the folder's name, which can be edited, and
// its apps. A click on the dimmed part closes it; dragging an app out past the card's edge takes it out of the folder.
final class StartMenuFolderView: NSView {
    private static let nameHeight: CGFloat = 44
    private static let inset: CGFloat = 18

    var onClose: () -> Void = {}

    let card = StartMenuCard()
    let name = NSTextField(string: "")
    let grid = StartMenuGrid(kind: .folder(""))
    private let scroll = NSScrollView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(card)
        name.isBordered = false
        name.drawsBackground = false
        name.isEditable = true
        name.alignment = .center
        name.font = .systemFont(ofSize: 19, weight: .semibold)
        name.focusRingType = .none
        name.cell?.isScrollable = true
        name.placeholderString = StartMenuLayout.folderName
        card.addSubview(name)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = grid
        card.addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()
    }

    // The card fits the folder's apps, up to five across.
    func arrange() {
        let columns = max(3, min(5, grid.tiles.count))
        grid.columns = columns
        let gridSize = NSSize(width: CGFloat(columns) * StartMenuGrid.cell.width, height: max(grid.height, StartMenuGrid.cell.height))
        let size = NSSize(width: gridSize.width + 2 * Self.inset,
                          height: min(gridSize.height + Self.nameHeight + 2 * Self.inset, bounds.height - 40))
        card.frame = NSRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded(),
                            width: size.width, height: size.height)
        name.frame = NSRect(x: Self.inset, y: size.height - Self.inset - 28, width: gridSize.width, height: 28)
        scroll.frame = NSRect(x: Self.inset, y: Self.inset, width: gridSize.width, height: size.height - Self.nameHeight - 2 * Self.inset)
        grid.frame = NSRect(origin: .zero, size: gridSize)
    }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onClose() }
    }

    // While open it takes every click, so nothing under it is reached.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : super.hitTest(point) ?? self
    }
}

final class StartMenuCard: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        NSColor.windowBackgroundColor.setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}
