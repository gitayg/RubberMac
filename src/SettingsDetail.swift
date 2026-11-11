import AppKit

// The right side of the panel: the page's title, its cards in a scroll view, or a note that nothing matches.
final class SettingsDetailView: NSView {
    static let margin: CGFloat = 20
    private static let headingHeight: CGFloat = 52
    private static let sectionGap: CGFloat = 18
    private static let sectionTitleGap: CGFloat = 6

    let scroll = NSScrollView()
    private let heading = NSTextField(labelWithString: "")
    private let empty = SettingsEmptyState()
    private var perform: SettingsRowView.Perform = { _, _, _, _ in }
    private var document: SettingsDocument?
    private var shown: SettingsPage?
    private var rowViews: [SettingsRowView] = []

    var onSliderReleased: () -> Void = {}

    var isDraggingSlider: Bool { rowViews.contains { ($0.customView as? SettingsSlider)?.isDragging == true } }
    var isShowingEmptyState: Bool { !empty.isHidden }
    var pageTitle: String { heading.stringValue }
    var visibleRows: [SettingsRowView] { rowViews }

    // How tall the panel would have to be to show the whole page without scrolling.
    var neededHeight: CGFloat { Self.headingHeight + (document?.frame.height ?? 0) }

    override var isOpaque: Bool { true }

    init(frame: NSRect, perform: @escaping SettingsRowView.Perform) {
        self.perform = perform
        super.init(frame: frame)
        wantsLayer = true
        heading.font = .boldSystemFont(ofSize: 20)
        heading.textColor = .labelColor
        heading.frame = NSRect(x: Self.margin, y: frame.height - Self.headingHeight + 10, width: frame.width - 2 * Self.margin, height: 28)
        heading.autoresizingMask = [.width, .minYMargin]
        scroll.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height - Self.headingHeight)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        empty.frame = bounds
        empty.autoresizingMask = [.width, .height]
        empty.isHidden = true
        [heading, scroll, empty].forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    // The bounds and not dirtyRect, which since macOS 14 can reach past the view, here over the sidebar.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    // `page` nil is the empty state. Scrolling stays where it was unless told otherwise.
    func show(_ page: SettingsPage?, query: String, crossfade: Bool, resetScroll: Bool) {
        let change = { [self] in
            guard let page else { return showEmpty(query) }
            empty.isHidden = true
            heading.isHidden = false
            scroll.isHidden = false
            heading.stringValue = page.title
            if !resetScroll, let shown, shown.hasSameShape(as: page), rowViews.count == page.rows.count {
                zip(rowViews, page.rows).forEach { $0.update(with: $1) }
                attachSliders()
                self.shown = page
            } else {
                let y = resetScroll || shown?.id != page.id ? 0 : scroll.contentView.bounds.minY
                rebuild(page)
                scrollTo(y)
            }
        }
        if crossfade && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.16
            layer?.add(fade, forKey: kCATransition)
        }
        change()
    }

    private func showEmpty(_ query: String) {
        shown = nil
        rowViews = []
        document = nil
        scroll.documentView = nil
        scroll.isHidden = true
        heading.isHidden = true
        empty.show(query: query)
        empty.isHidden = false
    }

    private func rebuild(_ page: SettingsPage) {
        let width = scroll.contentSize.width
        let cardWidth = width - 2 * Self.margin
        let document = SettingsDocument(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        var y: CGFloat = 4
        var rows: [SettingsRowView] = []
        for section in page.sections {
            if let title = section.title {
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: 13, weight: .semibold)
                label.textColor = .labelColor
                label.lineBreakMode = .byTruncatingTail
                label.frame = NSRect(x: Self.margin + 2, y: y, width: cardWidth - 2, height: 17)
                document.addSubview(label)
                y += 17 + Self.sectionTitleGap
            }
            let card = SettingsCardView(frame: NSRect(x: Self.margin, y: y, width: cardWidth, height: 0))
            var rowY: CGFloat = 0
            for (index, row) in section.rows.enumerated() {
                let view = SettingsRowView(row: row, width: cardWidth, perform: perform)
                view.frame.origin = NSPoint(x: 0, y: rowY)
                card.addSubview(view)
                rows.append(view)
                rowY += view.frame.height
                // Notes that follow each other read as one block of small print.
                if index < section.rows.count - 1, !(row.isNote && section.rows[index + 1].isNote) { card.separators.append(rowY) }
            }
            card.frame.size.height = rowY
            document.addSubview(card)
            y += rowY + Self.sectionGap
        }
        document.frame.size.height = max(y - Self.sectionGap + Self.margin, scroll.contentSize.height)
        scroll.documentView = document
        self.document = document
        rowViews = rows
        shown = page
        attachSliders()
    }

    private func attachSliders() {
        for slider in rowViews.compactMap({ $0.customView as? SettingsSlider }) {
            slider.onDragEnd = { [weak self] in self?.onSliderReleased() }
        }
    }

    private func scrollTo(_ y: CGFloat) {
        guard let document else { return }
        let top = max(0, min(y, document.frame.height - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

private final class SettingsDocument: NSView {
    override var isFlipped: Bool { true }
}

// Shown when nothing matches the search.
private final class SettingsEmptyState: NSView {
    private let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")!)
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.symbolConfiguration = .init(pointSize: 32, weight: .regular)
        icon.contentTintColor = .tertiaryLabelColor
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(query: String) {
        label.stringValue = "No settings match “\(query)”"
    }
}
