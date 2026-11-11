import AppKit
import Carbon.HIToolbox

// The settings panel that drops down from the menu-bar icon: a sidebar of pages and the chosen page's settings, as in
// System Settings. It only shows what `pages` gives it and sends each control's action to the row's own target.
final class SettingsPanel: NSObject, NSPopoverDelegate, NSSearchFieldDelegate {
    static let size = NSSize(width: 700, height: 540)
    static let sidebarWidth: CGFloat = 210
    // Long enough for the two halves of one click: a transient popover closes on the press before the button hears it.
    private static let closedByClick: TimeInterval = 0.2

    var pages: () -> [SettingsPage] = { [] }
    var onChoosePage: (String) -> Void = { _ in }
    var onShowPage: (String) -> Void = { _ in }
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}

    let root = SettingsRootView(frame: NSRect(origin: .zero, size: size))
    private(set) lazy var sidebar = SettingsSidebar(frame: NSRect(x: 0, y: 0, width: Self.sidebarWidth, height: Self.size.height))
    private(set) lazy var detail = SettingsDetailView(
        frame: NSRect(x: Self.sidebarWidth, y: 0, width: Self.size.width - Self.sidebarWidth, height: Self.size.height),
        perform: { [weak self] in self?.perform($0, target: $1, sender: $2, closesPanel: $3) })
    private let popover = NSPopover()
    private var previous: NSRunningApplication?
    private var closedAt = Date.distantPast
    private var renderPending = false

    private(set) var chosen: String?
    private(set) var shown: String?
    private(set) var query = ""
    private(set) var returnsFocus = true

    var isShown: Bool { popover.isShown }

    override init() {
        super.init()
        sidebar.autoresizingMask = [.height]
        detail.autoresizingMask = [.width, .height]
        root.addSubview(sidebar)
        root.addSubview(detail)
        root.onClose = { [weak self] in self?.close() }
        root.onFind = { [weak self] in self?.focusSearch() }
        sidebar.onSelect = { [weak self] in self?.choose($0) }
        sidebar.search.target = self
        sidebar.search.action = #selector(searchChanged)
        sidebar.search.delegate = self
        detail.onSliderReleased = { [weak self] in self?.sliderReleased() }

        let controller = NSViewController()
        controller.view = root
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.becameActive()
        }
    }

    func start(on page: String?) {
        chosen = page
    }

    // A click on the icon closes the panel if it's open; if the same click has just closed it, it stays closed.
    func toggle(from button: NSView) {
        guard Self.clickOpens(isShown: popover.isShown, sinceClosed: -closedAt.timeIntervalSinceNow) else {
            if popover.isShown { close() }
            return
        }
        open(from: button)
    }

    static func clickOpens(isShown: Bool, sinceClosed: TimeInterval) -> Bool {
        !isShown && sinceClosed >= closedByClick
    }

    private func open(from button: NSView) {
        previous = NSWorkspace.shared.frontmostApplication
        returnsFocus = true
        query = ""
        sidebar.search.stringValue = ""
        let room = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? Self.size.height
        let content = NSSize(width: Self.size.width, height: min(Self.size.height, room - 24))
        popover.contentSize = content
        root.setFrameSize(content)
        // Before it shows, so the sliders and permissions come up right, then again as their readings arrive.
        reload(resetScroll: true)
        onOpen()
        showCurrentPage()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close(returningFocus: Bool = true) {
        returnsFocus = returningFocus
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidShow(_ notification: Notification) {
        root.window?.makeKey()
        root.window?.makeFirstResponder(sidebar.table)
    }

    func popoverWillClose(_ notification: Notification) {
        closedAt = Date()
    }

    func popoverDidClose(_ notification: Notification) {
        onClose()
        // Esc, ⌘W or the icon leave RubberMAC in front with nothing to show for it; the app the user was in comes back.
        if returnsFocus, NSApp.isActive, previous != NSRunningApplication.current { previous?.activate() }
    }

    private func becameActive() {
        guard popover.isShown else { return }
        root.window?.makeKey()
        reload()
        showCurrentPage()
    }

    private func showCurrentPage() {
        if let shown { onShowPage(shown) }
    }

    func reloadIfShown() {
        if popover.isShown { reload() }
    }

    func reload(crossfade: Bool = false, resetScroll: Bool = false) {
        guard !detail.isDraggingSlider else { renderPending = true; return }
        renderPending = false
        let visible = pages().compactMap { $0.filtered(query) }
        shown = visible.contains { $0.id == chosen } ? chosen : visible.first?.id
        sidebar.show(visible, selected: shown)
        detail.show(visible.first { $0.id == shown }, query: query, crossfade: crossfade, resetScroll: resetScroll)
    }

    private func sliderReleased() {
        if renderPending { reload() }
    }

    func choose(_ id: String) {
        chosen = id
        onChoosePage(id)
        reload(crossfade: true, resetScroll: true)
        showCurrentPage()
    }

    func search(for text: String) {
        guard text != query else { return }
        query = text
        reload(resetScroll: true)
        showCurrentPage()
    }

    @objc private func searchChanged() {
        search(for: sidebar.search.stringValue)
    }

    func focusSearch() {
        root.window?.makeFirstResponder(sidebar.search)
    }

    private func perform(_ action: Selector, target: AnyObject?, sender: Any, closesPanel: Bool) {
        if closesPanel { close(returningFocus: false) }
        NSApp.sendAction(action, to: target, from: sender)
        if !closesPanel { reload() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            sidebar.move(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            sidebar.move(by: 1)
            return true
        case #selector(NSResponder.cancelOperation(_:)) where query.isEmpty:
            close()
            return true
        default:
            return false
        }
    }
}

// The panel's top view: the keys RubberMAC has no main menu to answer.
final class SettingsRootView: NSView {
    var onClose: () -> Void = {}
    var onFind: () -> Void = {}

    override func cancelOperation(_ sender: Any?) {
        onClose()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        // By key position, so these still work with the keyboard set to another language.
        switch Int(event.keyCode) {
        case kVK_ANSI_F:
            onFind()
            return true
        case kVK_ANSI_W:
            onClose()
            return true
        case kVK_ANSI_A: return edit(#selector(NSText.selectAll(_:)))
        case kVK_ANSI_C: return edit(#selector(NSText.copy(_:)))
        case kVK_ANSI_X: return edit(#selector(NSText.cut(_:)))
        case kVK_ANSI_V: return edit(#selector(NSText.paste(_:)))
        default: return super.performKeyEquivalent(with: event)
        }
    }

    // The search field's text editing, normally reached through the Edit menu.
    private func edit(_ action: Selector) -> Bool {
        guard window?.firstResponder is NSTextView else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}
