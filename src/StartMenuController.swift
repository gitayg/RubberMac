import AppKit

// Start itself: what's in it, what clicks, keys, drags and the right-click menu do, and when it opens and closes.
// Everything outside RubberMAC that it touches goes through System, which the self-tests swap out.
final class StartMenuController: NSObject, StartMenuGridOwner, NSSearchFieldDelegate, NSWindowDelegate, NSMenuDelegate {
    struct System {
        var roots = StartMenuApps.roots
        var store = StartMenuStore(url: StartMenuStore.defaultURL)
        var open: (URL) -> Void = StartMenuController.openApp
        var showInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        var trash: (URL, @escaping (StartMenuTrash.Outcome) -> Void) -> Void = StartMenuTrash.moveToTrash
        var searchStarts: () -> Void = { InputPerApp.shared.prepareForSearch() }
        var searchEnds: () -> Void = { InputPerApp.shared.searchEnded() }
        var pointer: () -> NSPoint = { NSEvent.mouseLocation }
    }

    struct Selection: Equatable {
        var kind: StartMenuGrid.Kind
        var index: Int
    }

    enum Direction {
        case left, right, up, down
    }

    let system: System
    let view = StartMenuView(frame: NSRect(x: 0, y: 0, width: 790, height: 640))
    private(set) var panel: StartMenuPanel?
    private(set) var isShown = false
    private(set) var apps: [StartMenuApp] = []
    private var byPath: [String: StartMenuApp] = [:]
    private(set) var layout = StartMenuLayout()
    private var loaded = false
    private(set) var query = ""
    private(set) var results: [StartMenuApp] = []
    private(set) var openFolder: String?
    private(set) var selection: Selection?
    private(set) var columns = 7
    // While a dialog of Start's is up, or its menu, or a tile is being dragged, the window losing the keyboard to them
    // doesn't close it.
    private(set) var asking = false
    private var menuShown = false
    // The right-click menu last shown, for the live self-test to choose from.
    private(set) var lastMenu: NSMenu?
    private var dragging: Selection?
    private var draggedOutOfFolder = false
    private var monitor: Any?
    private var spaceObserver: NSObjectProtocol?
    // The app in front when Start opened, given the front back if Start's question brought RubberMAC forward.
    private var previous: NSRunningApplication?
    // What happened and why, for the live self-test to tell.
    var trace: (String) -> Void = { _ in }

    init(system: System = System()) {
        self.system = system
        super.init()
        view.onCommand = { [weak self] in self?.command($0) ?? false }
        view.search.delegate = self
        view.folder.name.delegate = self
        view.folder.onClose = { [weak self] in self?.closeFolder() }
        [view.pinned, view.main, view.folder.grid].forEach { $0.owner = self }
    }

    static func openApp(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { DispatchQueue.main.async { log("start: couldn't open \(url.lastPathComponent) (error \((error as NSError).code))") } }
        }
    }

    // MARK: Opening and closing

    func toggle() {
        isShown ? close() : show()
    }

    // On the screen with the pointer, with the search field taking the typing.
    func show() {
        guard !isShown else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(system.pointer(), $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let (size, columns) = StartMenuView.size(for: screen.visibleFrame)
        self.columns = columns
        view.setFrameSize(size)
        query = ""
        results = []
        selection = nil
        openFolder = nil
        view.search.stringValue = ""
        refresh()
        scrollToTop()
        let panel = self.panel ?? makePanel()
        panel.setFrame(StartMenuView.frame(of: size, in: screen.visibleFrame), display: false)
        isShown = true
        previous = NSWorkspace.shared.frontmostApplication
        system.searchStarts()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view.search)
        panel.invalidateShadow()
        watch()
    }

    // openedApp: an app was opened (or Finder brought forward), so the search didn't just end where it started.
    func close(openedApp: Bool = false) {
        guard isShown, let panel else { return }
        isShown = false
        unwatch()
        if let sheet = panel.attachedSheet { panel.endSheet(sheet) }
        // Ends editing a folder's name, which keeps what was typed.
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        openFolder = nil
        // A sheet makes RubberMAC the active app; with Start gone it would leave the keyboard with nothing.
        if !openedApp, NSApp.isActive, let previous, previous != NSRunningApplication.current { previous.activate() }
        if !openedApp { system.searchEnds() }
    }

    private func makePanel() -> StartMenuPanel {
        let panel = StartMenuPanel(content: view)
        panel.delegate = self
        self.panel = panel
        return panel
    }

    // A click in another app or on the desktop, or a move to another desktop, closes Start.
    private func watch() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.trace("closed by a click in another app")
            self?.close()
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            self?.trace("closed by a move to another desktop")
            self?.close()
        }
    }

    private func unwatch() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        monitor = nil
        spaceObserver = nil
    }

    var isWatching: Bool { monitor != nil || spaceObserver != nil }

    // Another app's window, or one of RubberMAC's, took the keyboard.
    func windowDidResignKey(_ notification: Notification) {
        guard isShown, !asking, !menuShown, dragging == nil else { return }
        trace("closed on losing the keyboard to \(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "another app")")
        close()
    }

    // MARK: What's shown

    // Reads the apps again and fits the order to them: gone apps go, new ones join at the end. Saved when that changed
    // it, which includes the first time.
    func refresh() {
        apps = StartMenuApps.scan(system.roots)
        byPath = Dictionary(apps.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let stored = loaded ? layout : system.store.load()
        loaded = true
        layout = (stored ?? StartMenuLayout()).fitted(to: apps.map(\.path))
        if layout != stored { save() }
        if let openFolder, layout.folder(openFolder) == nil { self.openFolder = nil }
        if !query.isEmpty { results = StartMenuSearch.results(searchable, query) }
        reload()
    }

    // Every app in the user's order, folders' apps where their folder is.
    var searchable: [StartMenuApp] { layout.allApps.compactMap { byPath[$0] } }

    private func save() {
        do {
            try system.store.save(layout)
        } catch {
            log("start: couldn't save the order (error \((error as NSError).code))")
        }
    }

    func reload() {
        view.pinned.tiles = layout.pins.compactMap { byPath[$0] }.map { StartMenuTile(kind: .app($0)) }
        view.main.kind = query.isEmpty ? .main : .results
        view.main.tiles = query.isEmpty ? layout.items.compactMap(tile) : results.map { StartMenuTile(kind: .app($0)) }
        view.arrange(columns: columns, searching: !query.isEmpty,
                     emptyText: !query.isEmpty && results.isEmpty ? "No apps match “\(query)”" : nil)
        showFolder()
        showSelection()
    }

    private func tile(_ item: StartMenuItem) -> StartMenuTile? {
        switch item {
        case .app(let path): return byPath[path].map { StartMenuTile(kind: .app($0)) }
        case .folder(let folder): return StartMenuTile(kind: .folder(folder, folder.apps.compactMap { byPath[$0] }))
        }
    }

    private func showFolder() {
        // A folder that dissolved (its last but one app taken out) is closed with it.
        guard let id = openFolder, let folder = layout.folder(id) else {
            openFolder = nil
            view.folder.isHidden = true
            return
        }
        view.folder.grid.kind = .folder(id)
        view.folder.grid.tiles = folder.apps.compactMap { byPath[$0] }.map { StartMenuTile(kind: .app($0)) }
        if view.folder.name.currentEditor() == nil { view.folder.name.stringValue = folder.name }
        view.folder.isHidden = draggedOutOfFolder
        view.folder.arrange()
    }

    var visibleGrids: [StartMenuGrid] {
        if openFolder != nil { return [view.folder.grid] }
        return [view.pinned, view.main].filter { !$0.isHidden && !$0.tiles.isEmpty }
    }

    func grid(_ kind: StartMenuGrid.Kind) -> StartMenuGrid {
        switch kind {
        case .pins: return view.pinned
        case .main, .results: return view.main
        case .folder: return view.folder.grid
        }
    }

    private func showSelection() {
        if let selection, !grid(selection.kind).tiles.indices.contains(selection.index) || grid(selection.kind).kind != selection.kind {
            self.selection = nil
        }
        for grid in [view.pinned, view.main, view.folder.grid] {
            grid.selected = selection?.kind == grid.kind ? selection?.index : nil
        }
        if let selection {
            let grid = grid(selection.kind)
            grid.scrollToVisible(grid.frame(of: selection.index).insetBy(dx: 0, dy: -12))
        }
    }

    private func scrollToTop() {
        view.scroll.contentView.scroll(to: .zero)
        view.scroll.reflectScrolledClipView(view.scroll.contentView)
    }

    // MARK: Keys

    // The keys the search field hands on: arrows move the selection, ↩ opens it, Esc closes a folder, then Start.
    @discardableResult
    func command(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveLeft(_:)): moveSelection(.left)
        case #selector(NSResponder.moveRight(_:)): moveSelection(.right)
        case #selector(NSResponder.moveUp(_:)): moveSelection(.up)
        case #selector(NSResponder.moveDown(_:)): moveSelection(.down)
        case #selector(NSResponder.insertNewline(_:)): activateSelection()
        case #selector(NSResponder.cancelOperation(_:)): openFolder == nil ? close() : closeFolder()
        default: return false
        }
        return true
    }

    // Left and right go through the tiles in order, up and down to the row above or below, the pinned row included.
    func moveSelection(_ direction: Direction) {
        let rows: [[Selection]] = visibleGrids.flatMap { grid in
            stride(from: 0, to: grid.tiles.count, by: grid.columns).map { start in
                (start..<min(start + grid.columns, grid.tiles.count)).map { Selection(kind: grid.kind, index: $0) }
            }
        }
        let all = rows.flatMap { $0 }
        guard let first = all.first else { return }
        guard let selection, let row = rows.firstIndex(where: { $0.contains(selection) }),
              let column = rows[row].firstIndex(of: selection), let position = all.firstIndex(of: selection) else {
            return select(first)
        }
        switch direction {
        case .left: if position > 0 { select(all[position - 1]) }
        case .right: if position + 1 < all.count { select(all[position + 1]) }
        case .up: if row > 0 { select(rows[row - 1][min(column, rows[row - 1].count - 1)]) }
        case .down: if row + 1 < rows.count { select(rows[row + 1][min(column, rows[row + 1].count - 1)]) }
        }
    }

    private func select(_ selection: Selection) {
        self.selection = selection
        showSelection()
    }

    func activateSelection() {
        guard let selection else { return }
        let grid = grid(selection.kind)
        guard grid.tiles.indices.contains(selection.index) else { return }
        activate(grid.tiles[selection.index])
    }

    private func activate(_ tile: StartMenuTile) {
        switch tile.kind {
        case .app(let app):
            system.open(app.url)
            close(openedApp: true)
        case .folder(let folder, _):
            open(folder: folder.id)
        }
    }

    func search(_ text: String) {
        query = text.trimmingCharacters(in: .whitespaces)
        openFolder = nil
        results = query.isEmpty ? [] : StartMenuSearch.results(searchable, query)
        selection = results.isEmpty ? nil : Selection(kind: .results, index: 0)
        reload()
        scrollToTop()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === view.search else { return }
        search(view.search.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === view.folder.name else { return command(selector) }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            view.folder.name.stringValue = openFolder.flatMap { layout.folder($0)?.name } ?? ""
            panel?.makeFirstResponder(view.search)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            panel?.makeFirstResponder(view.search)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === view.folder.name, let id = openFolder else { return }
        trace("folder name typed: \(view.folder.name.stringValue)")
        rename(id, to: view.folder.name.stringValue)
    }

    // MARK: Folders

    func open(folder id: String) {
        guard layout.folder(id) != nil else { return }
        openFolder = id
        draggedOutOfFolder = false
        selection = nil
        reload()
    }

    func closeFolder() {
        guard let id = openFolder else { return }
        panel?.makeFirstResponder(view.search)
        openFolder = nil
        selection = layout.items.firstIndex { if case .folder(let folder) = $0 { folder.id == id } else { false } }
            .map { Selection(kind: .main, index: $0) }
        reload()
    }

    func rename(_ id: String, to name: String) {
        let before = layout
        layout.rename(id, to: name)
        guard layout != before else { return }
        save()
        reload()
    }

    // MARK: Clicks and drags

    func grid(_ grid: StartMenuGrid, clicked index: Int) {
        guard grid.tiles.indices.contains(index) else { return }
        activate(grid.tiles[index])
    }

    func grid(_ grid: StartMenuGrid, menuFor index: Int) -> NSMenu? {
        guard grid.tiles.indices.contains(index), case .app(let app) = grid.tiles[index].kind else { return nil }
        trace("menu asked for on \(grid.kind) \(index)")
        let menu = menu(for: app)
        lastMenu = menu
        return menu
    }

    func grid(_ grid: StartMenuGrid, beganDragging index: Int) {
        dragging = Selection(kind: grid.kind, index: index)
        draggedOutOfFolder = false
        trace("drag began on \(grid.kind) \(index)")
    }

    // Dragged past the edge of an open folder's card, the folder steps aside so the app can be dropped on the grid.
    func grid(_ grid: StartMenuGrid, draggedTo screenPoint: NSPoint) {
        guard case .folder = grid.kind, !view.folder.isHidden, let window = view.window else { return }
        let point = view.folder.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard !view.folder.card.frame.contains(point) else { return }
        draggedOutOfFolder = true
        view.folder.isHidden = true
    }

    func gridEndedDrag(_ grid: StartMenuGrid) {
        trace("drag ended")
        dragging = nil
        guard draggedOutOfFolder else { return }
        draggedOutOfFolder = false
        openFolder = nil
        reload()
    }

    func grid(_ grid: StartMenuGrid, allows drop: StartMenuGrid.Drop) -> Bool {
        guard let from = dragging.flatMap(place), let to = target(grid.kind, drop) else { return false }
        return layout.allows(from, to: to)
    }

    func grid(_ grid: StartMenuGrid, accepts drop: StartMenuGrid.Drop) -> Bool {
        guard let from = dragging.flatMap(place), let to = target(grid.kind, drop) else { return false }
        return move(from, to: to)
    }

    // A drag's whole effect on the order, as a drop makes it.
    @discardableResult
    func move(_ from: StartMenuPlace, to: StartMenuDrop) -> Bool {
        guard layout.move(from, to: to) else { return false }
        save()
        selection = nil
        reload()
        return true
    }

    private func place(_ selection: Selection) -> StartMenuPlace? {
        switch selection.kind {
        case .pins: return .pin(selection.index)
        case .main: return .main(selection.index)
        case .folder(let id): return .folder(id, selection.index)
        case .results: return nil
        }
    }

    private func target(_ kind: StartMenuGrid.Kind, _ drop: StartMenuGrid.Drop) -> StartMenuDrop? {
        switch (kind, drop) {
        case (.pins, .before(let index)): return .pin(index)
        case (.main, .before(let index)): return .main(index)
        case (.main, .onto(let index)): return .onto(index)
        case (.folder(let id), .before(let index)): return .folder(id, index)
        default: return nil
        }
    }

    // MARK: Right-click menu

    func menu(for app: StartMenuApp) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = app.path
            menu.addItem(item)
        }
        add("Open", #selector(openFromMenu(_:)))
        add(layout.isPinned(app.path) ? "Unpin" : "Pin to Top", #selector(pinFromMenu(_:)))
        menu.addItem(.separator())
        add("Show in Finder", #selector(showInFinderFromMenu(_:)))
        // An app under /System is read-only; nothing can trash it.
        if !app.isSystem {
            menu.addItem(.separator())
            add("Move to Trash…", #selector(trashFromMenu(_:)))
        }
        menu.delegate = self
        return menu
    }

    // The open menu takes the keyboard from Start's window, which mustn't close Start.
    func menuWillOpen(_ menu: NSMenu) {
        trace("menu opens")
        menuShown = true
    }

    func menuDidClose(_ menu: NSMenu) {
        trace("menu closed")
        menuShown = false
        if isShown { panel?.makeKey() }
    }

    private func app(of item: NSMenuItem) -> StartMenuApp? {
        (item.representedObject as? String).flatMap { byPath[$0] }
    }

    @objc func openFromMenu(_ sender: NSMenuItem) {
        guard let app = app(of: sender) else { return }
        system.open(app.url)
        close(openedApp: true)
    }

    @objc func pinFromMenu(_ sender: NSMenuItem) {
        guard let app = app(of: sender) else { return }
        if layout.isPinned(app.path) { layout.unpin(app.path) } else { layout.pin(app.path) }
        save()
        reload()
    }

    // Finder comes forward with the app highlighted, so this counts as going to another app.
    @objc func showInFinderFromMenu(_ sender: NSMenuItem) {
        guard let app = app(of: sender) else { return }
        system.showInFinder(app.url)
        close(openedApp: true)
    }

    @objc func trashFromMenu(_ sender: NSMenuItem) {
        guard let app = app(of: sender) else { return }
        confirmTrash(app)
    }

    // MARK: Move to Trash

    // A sheet on Start's window: a free-standing alert would open below Start, which sits above other windows.
    func confirmTrash(_ app: StartMenuApp) {
        guard isShown, let panel, !app.isSystem else { return }
        asking = true
        StartMenuTrash.confirmation(for: app).beginSheetModal(for: panel) { [weak self] response in
            guard let self else { return }
            asking = false
            trace("asked to move \(app.name) to the Trash: \(response == .alertFirstButtonReturn ? "yes" : "no")")
            if isShown { panel.makeFirstResponder(view.search) }
            guard response == .alertFirstButtonReturn else { return }
            trash(app)
        }
    }

    private func trash(_ app: StartMenuApp) {
        log("start: moving \(app.name) to the Trash")
        system.trash(app.url) { [weak self] outcome in
            guard let self else { return }
            trace("moving to the Trash: \(outcome)")
            switch outcome {
            case .trashed:
                log("start: \(app.name) moved to the Trash")
                refresh()
            case .cancelled:
                log("start: moving \(app.name) to the Trash was cancelled")
            case .failed(let message):
                log("start: couldn't move \(app.name) to the Trash: \(message)")
                guard isShown, let panel else { return }
                asking = true
                StartMenuTrash.failure(for: app, message).beginSheetModal(for: panel) { [weak self] _ in self?.asking = false }
            }
        }
    }
}
