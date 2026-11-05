import AppKit

// A vertical menu of one app's windows beside its Dock icon: a picture of each window with its title. A click on a
// row picks that window. It never takes the focus; the picker closes it on Esc or a click elsewhere.
final class DockWindowMenu {
    // Widths of a row's picture: as large as lets every window fit on the screen, down to the smallest, which scrolls.
    static let largestPicture: CGFloat = 200
    static let smallestPicture: CGFloat = 80
    // Between the icon and the menu, and between the menu and the screen's edges.
    static let gap: CGFloat = 8
    static let margin: CGFloat = 8
    static let inset: CGFloat = 6

    var onPick: (Int) -> Void = { _ in }

    private var panel: NSPanel?
    private var rows: [DockWindowRow] = []

    var isShown: Bool { panel?.isVisible == true }
    // On screen while shown, in AppKit coordinates; a click inside it doesn't close it.
    var frame: CGRect? { isShown ? panel?.frame : nil }

    // icon: the Dock icon's frame in AppKit coordinates; edge: the screen edge the Dock is on.
    func show(_ entries: [SwitcherEntry], pictures: WindowThumbnails, near icon: CGRect, edge: FullScreenDock.Edge) {
        let centre = CGPoint(x: icon.midX, y: icon.midY)
        guard !entries.isEmpty,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(centre) }) ?? NSScreen.main
        else { return hide() }
        let room = Self.room(near: icon, edge: edge, screen: screen.frame, visible: screen.visibleFrame)
        let content = makeContent(entries, pictures: pictures, fitting: room)
        // Read before the panel takes the view, which sizes it to the panel's current frame.
        let size = content.frame.size
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.contentView = content
        panel.setFrame(Self.place(size, near: icon, edge: edge, screen: screen.frame, visible: screen.visibleFrame), display: true)
        panel.orderFrontRegardless()
    }

    // A picture that came in after the menu opened.
    func show(_ picture: NSImage, for id: CGWindowID) {
        rows.filter { $0.windowID == id }.forEach { $0.show(picture) }
    }

    // How busy a process is, on each of its windows' rows.
    func show(usage: String, for pid: pid_t) {
        rows.filter { $0.pid == pid }.forEach { $0.show(usage: usage) }
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        rows = []
    }

    // The part of the screen the menu may cover: under the menu bar, inside the margins, and on the icon's side of it.
    static func room(near icon: CGRect, edge: FullScreenDock.Edge, screen: CGRect, visible: CGRect) -> NSSize {
        let area = bounds(screen: screen, visible: visible)
        switch edge {
        case .bottom: return NSSize(width: area.width, height: area.maxY - (icon.maxY + gap))
        case .left: return NSSize(width: area.maxX - (icon.maxX + gap), height: area.height)
        case .right: return NSSize(width: icon.minX - gap - area.minX, height: area.height)
        }
    }

    // Beside the icon on the screen's side of it, centred on it, then moved along the edge as needed to stay on screen.
    static func place(_ size: NSSize, near icon: CGRect, edge: FullScreenDock.Edge, screen: CGRect, visible: CGRect) -> CGRect {
        let area = bounds(screen: screen, visible: visible)
        var origin: CGPoint
        switch edge {
        case .bottom: origin = CGPoint(x: icon.midX - size.width / 2, y: icon.maxY + gap)
        case .left: origin = CGPoint(x: icon.maxX + gap, y: icon.midY - size.height / 2)
        case .right: origin = CGPoint(x: icon.minX - gap - size.width, y: icon.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        return CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }

    // The screen less its menu bar, inside the margins. The Dock's own strip is left in: the icon's side keeps the
    // menu off it.
    private static func bounds(screen: CGRect, visible: CGRect) -> CGRect {
        CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: min(screen.maxY, visible.maxY) - screen.minY)
            .insetBy(dx: margin, dy: margin)
    }

    // The picture width and how many rows show at once for this many windows in this room: the largest pictures that
    // let every row show, down to the smallest, past which the list scrolls.
    static func layout(count: Int, fitting room: NSSize) -> (pictureWidth: CGFloat, visibleRows: Int) {
        let count = max(1, count)
        let space = NSSize(width: room.width - 2 * inset, height: room.height - 2 * inset)
        let byWidth = space.width - DockWindowRow.size(pictureWidth: 0).width
        // Row heights are rounded to whole points, so the widest that fits is found by trying each width in turn.
        var width = min(largestPicture, byWidth).rounded(.down)
        while width > smallestPicture && CGFloat(count) * DockWindowRow.size(pictureWidth: width).height > space.height {
            width -= 1
        }
        width = max(width, smallestPicture)
        let fit = Int(space.height / DockWindowRow.size(pictureWidth: width).height)
        return (width, max(1, min(count, fit)))
    }

    // Builds the panel's view without showing it, so it can also be rendered off screen.
    func makeContent(_ entries: [SwitcherEntry], pictures: WindowThumbnails, fitting room: NSSize) -> NSView {
        let inset = Self.inset
        let (width, visibleRows) = Self.layout(count: entries.count, fitting: room)
        let row = DockWindowRow.size(pictureWidth: width)
        let size = NSSize(width: row.width + 2 * inset, height: CGFloat(visibleRows) * row.height + 2 * inset)

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .vibrantDark)
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let scroll = NSScrollView(frame: NSRect(x: inset, y: inset, width: row.width, height: CGFloat(visibleRows) * row.height))
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        let list = TopDownView(frame: NSRect(x: 0, y: 0, width: row.width, height: CGFloat(entries.count) * row.height))
        var icons: [pid_t: NSImage] = [:]
        let screens = NSScreen.screens.map(\.frame)
        let primaryHeight = screens.first?.height ?? 0
        rows = entries.enumerated().map { i, entry in
            if icons[entry.pid] == nil { icons[entry.pid] = NSRunningApplication(processIdentifier: entry.pid)?.icon }
            let view = DockWindowRow(entry: entry, icon: icons[entry.pid], picture: pictures.picture(of: entry.windowID),
                                     place: entry.frame.map { WindowMapView.appKit($0, primaryHeight: primaryHeight) },
                                     screens: screens, pictureWidth: width)
            view.onClick = { [weak self] in self?.onPick(i) }
            view.frame.origin = NSPoint(x: 0, y: CGFloat(i) * row.height)
            list.addSubview(view)
            return view
        }
        scroll.documentView = list
        background.addSubview(scroll)
        return background
    }

    static func makePanel() -> NSPanel {
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

private final class TopDownView: NSView {
    override var isFlipped: Bool { true }
}
