import AppKit
import Synchronization

// An editable path field under the toolbar of the front Finder window: shows the folder's path, and a path pasted or
// typed into it, then Return, takes that window there.
final class FinderAddressBar {
    static let finder = "com.apple.finder"

    // true starts watching Finder and showing the strip; false hides everything and removes the observers.
    var isEnabled = false {
        didSet { if isEnabled != oldValue { isEnabled ? start() : stop() } }
    }
    // Set once Finder has said no, so the panel can offer the setting.
    private(set) var isDenied = false
    private(set) var lastOutcome: FinderPathPaste.Outcome?

    let panel = FinderAddressBarPanel()
    private let watcher = FinderAddressBarWatcher()
    private let queue = DispatchQueue(label: "finder address bar")
    private var tracked: FinderBrowserWindow?
    // Bumped by each folder read and by hiding; the queue skips reads that a newer one replaced, and an answer about
    // a window that lost the strip is dropped.
    private let reads = Atomic<Int>(0)

    var window: FinderBrowserWindow? { tracked }
    var isShown: Bool { panel.isVisible }

    init() {
        watcher.onChange = { [weak self] in self?.refresh($0) }
        panel.onCommit = { [weak self] in self?.commit() }
        panel.onCancel = { [weak self] in self?.cancel() }
        // Clicking back into Finder in the middle of typing leaves the folder's path, not half a path. Finder may
        // have changed windows meanwhile, so look again once the panel is no longer key.
        panel.onResignKey = { [weak self] in
            guard let self else { return }
            if panel.isEditing { panel.revert() }
            DispatchQueue.main.async { [weak self] in self?.refresh(.window) }
        }
    }

    deinit { if isEnabled { stop() } }

    func clearDenied() {
        isDenied = false
    }

    // ↩ in the field: a path goes there, by the same rules as pasting one with ⌘V in Finder.
    func commit() {
        guard let destination = FinderPathPaste.destination(from: panel.text) else { return panel.reject() }
        let inWindow = tracked != nil
        panel.finishEditing()
        handBack()
        queue.async { [weak self] in
            let outcome = FinderPathPaste.move(to: destination, inWindow: inWindow)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                lastOutcome = outcome
                switch outcome {
                case .moved, .selected:
                    isDenied = false
                    log("finder address bar: went to a typed \(outcome == .moved ? "folder" : "file's folder")")
                case .failed(let status):
                    isDenied = status == FinderWindow.notPermitted
                    log("finder address bar: couldn't move the window (\(status)), opening the path in a new one")
                    fallthrough
                case .openedNewWindow:
                    FinderPathPaste.openOnItsOwn(destination)
                }
                refresh(.window)
            }
        }
    }

    // Esc in the field.
    func cancel() {
        panel.revert()
        handBack()
    }

    func refresh(_ change: FinderAddressBarWatcher.Change) {
        guard isEnabled else { return }
        guard AX.isTrusted, let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == Self.finder
        else { return hide() }
        // While the field has the keyboard, Finder may no longer report its window as focused; the strip stays put.
        if change == .frame || panel.isKeyWindow, let moved = tracked?.moved() {
            tracked = moved
            return place(reorder: false)
        }
        watcher.follow(app.processIdentifier)
        guard let window = FinderBrowserWindow.focused(in: app.processIdentifier) else { return hide() }
        tracked = window
        watcher.watch(window.element)
        place(reorder: true)
        read(window.id)
    }

    private func start() {
        watcher.start()
        refresh(.window)
        log("finder address bar: on")
    }

    private func stop() {
        watcher.stop()
        hide()
        log("finder address bar: off")
    }

    private func hide() {
        reads.add(1, ordering: .relaxed)
        tracked = nil
        watcher.watch(nil)
        panel.orderOut(nil)
    }

    private func place(reorder: Bool) {
        guard let tracked, let primary = NSScreen.screens.first else { return hide() }
        panel.setFrame(FinderAddressBarLayout.strip(window: tracked.frame, top: tracked.top, primaryHeight: primary.frame.height),
                       display: true)
        guard reorder || !panel.isVisible else { return }
        // Just above Finder's window, rather than floating over other apps.
        panel.order(.above, relativeTo: Int(tracked.id))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    // The keyboard goes back to Finder's window: a panel that is put away is no longer key, and showing it again
    // doesn't make it key.
    private func handBack() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        place(reorder: true)
    }

    // Asks Finder which folder its front window shows, off the main thread, as each answer waits for Finder.
    private func read(_ id: CGWindowID) {
        let read = reads.add(1, ordering: .relaxed).newValue
        queue.async { [weak self] in
            guard self?.reads.load(ordering: .relaxed) == read else { return }
            var status = FinderWindow.permission(ask: true)
            var folder: URL?
            if status == noErr {
                do { folder = try FinderWindow.currentFolder() } catch { status = (error as? FinderWindow.Failure)?.status ?? OSStatus(errAEEventFailed) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, reads.load(ordering: .relaxed) == read, tracked?.id == id else { return }
                isDenied = status == FinderWindow.notPermitted
                panel.show(folder.map { FinderAddressBarLayout.shown($0) } ?? "",
                           placeholder: isDenied ? "Allow RubberMAC to control Finder to see the path" : "Paste or type a path")
            }
        }
    }
}
