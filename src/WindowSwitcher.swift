import AppKit

// Windows-style Alt-Tab: one entry per window (a small picture of it, title, app icon), minimized windows included.
// Driven by AltTabRemap's event tap. All calls arrive on the main thread.
final class WindowSwitcher {
    private(set) var isActive = false

    // The window a release of Alt would switch to.
    var selection: SwitcherEntry? { isActive && entries.indices.contains(selected) ? entries[selected] : nil }

    // A quick Alt-Tab tap switches before this, so the panel never flashes.
    private static let showDelay: TimeInterval = 0.12

    // Right after a switch the system may still report the window being left as focused, so for this long
    // the window just switched to counts as the focused one.
    private static let settleTime: TimeInterval = 0.5

    private let panel = SwitcherPanel()
    private let pictures = WindowThumbnails()
    private let tracker = FocusTracker()
    // Kept across relaunches (updates restart the app), so the order still follows what was used.
    private var history = FocusHistory(ids: Settings.focusHistory) {
        didSet { if history.ids != oldValue.ids { Settings.focusHistory = history.ids } }
    }
    private var lastSwitch: (pid: pid_t, window: CGWindowID?, at: Date)?
    private var entries: [SwitcherEntry] = []
    private var selected = 0
    private var pendingShow: DispatchWorkItem?

    // Following focus is what lets Alt-Tab go back to the window used before; only needed while it's on.
    var tracksFocus = false {
        didSet {
            tracksFocus ? tracker.start() : tracker.stop()
            followSpaces(tracksFocus)
        }
    }
    private var spaceObserver: NSObjectProtocol?

    init() {
        tracker.onFocus = { [weak self] id in self?.history.focused(id) }
        // A click on a window in the grid switches to it, as letting go of Alt would.
        panel.onClick = { [weak self] index in
            guard let self, self.isActive, self.entries.indices.contains(index) else { return }
            self.selected = index
            self.commit()
        }
    }

    // Alt-Tab pressed: snapshot the windows, show the panel, select the next window (previous if reverse).
    func begin(reverse: Bool) {
        // A second begin means the Alt release was missed: start over with a fresh snapshot.
        if isActive { close() }
        let start = DispatchTime.now()
        let current = focusedNow()
        if let id = current?.window { history.focused(id) }
        entries = SwitcherSource.snapshot(recent: history.ids)
        log("switcher: \(entries.count) windows in \(Self.milliseconds(since: start)) ms")
        isActive = true
        pictures.refresh(entries.compactMap(\.windowID)) { [weak self] id, picture in
            guard let self, self.isActive else { return }
            self.panel.show(picture, for: id)
        }
        guard let index = SwitcherModel.initialSelection(count: entries.count, reverse: reverse,
                                                         currentFirst: entries.first?.pid == current?.pid) else { return }
        selected = index
        let show = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            self.pendingShow = nil
            self.panel.show(self.entries, selected: self.selected, pictures: self.pictures)
        }
        pendingShow = show
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: show)
    }

    // Tab pressed again while Alt is held. After a click switched, Alt is still held, so this starts over.
    func advance(reverse: Bool) {
        guard isActive else { return begin(reverse: reverse) }
        guard !entries.isEmpty else { return }
        selected = SwitcherModel.step(selected, count: entries.count, reverse: reverse)
        if panel.isShown { panel.select(selected) }
    }

    // Alt released: focus the selected window, unminimizing it if needed.
    func commit() {
        guard isActive else { return }
        let target = entries.indices.contains(selected) ? entries[selected] : nil
        close()
        guard let target else { return }
        lastSwitch = (target.pid, target.windowID, Date())
        if let id = target.windowID { history.focused(id) }
        WindowFocus.go(to: target)
    }

    // Escape pressed: close without switching.
    func cancel() {
        guard isActive else { return }
        close()
    }

    // Accessibility only lists the windows of the Space on screen, so after each switch of Space the windows are
    // listed in the background, which keeps a way to reach them once the screen has moved on. Not during the
    // switch's animation, when the apps are busy drawing.
    private func followSpaces(_ on: Bool) {
        if on, spaceObserver == nil {
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { SwitcherSource.warm(SwitcherSource.regularApps()) }
            }
            SwitcherSource.warm(SwitcherSource.regularApps())
        } else if !on, let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
    }

    private func focusedNow() -> (pid: pid_t, window: CGWindowID?)? {
        if let lastSwitch, -lastSwitch.at.timeIntervalSinceNow < Self.settleTime { return (lastSwitch.pid, lastSwitch.window) }
        return FocusTracker.focused()
    }

    private func close() {
        pendingShow?.cancel()
        pendingShow = nil
        panel.hide()
        entries = []
        isActive = false
    }

    static func selfTestReport() -> String {
        let start = DispatchTime.now()
        let entries = SwitcherSource.snapshot()
        let header = "windows: \(entries.count) in \(milliseconds(since: start)) ms, accessibility trusted: \(AX.isTrusted)"
        // Again in a warm process, as the running app takes them.
        let times = (0..<10).map { _ in
            let again = DispatchTime.now()
            _ = SwitcherSource.snapshot()
            return Double(DispatchTime.now().uptimeNanoseconds - again.uptimeNanoseconds) / 1_000_000
        }.sorted()
        let pids = Set(SwitcherSource.regularApps().map(\.pid))
        let serverTimes = (0..<10).map { _ in
            let again = DispatchTime.now()
            _ = SpaceWindows.spaces().flatMap { SpaceWindows.windows(of: pids, on: $0.user) }
            return Double(DispatchTime.now().uptimeNanoseconds - again.uptimeNanoseconds) / 1_000_000
        }.sorted()
        let timing = String(format: "snapshot again ×10: min %.1f, median %.1f, max %.1f ms; of which the window server's "
            + "Spaces: min %.2f, median %.2f, max %.2f ms", times[0], times[5], times[9], serverTimes[0], serverTimes[5], serverTimes[9])
        let lines = [timing] + entries.map {
            "\($0.appName)#\($0.windowID ?? 0)\($0.isMinimized ? " minimized" : "")\($0.isOnCurrentSpace ? "" : " other Space")"
        }
        let own = CommandLine.arguments.contains("--own-window") ? [ownWindowReport()] : []
        return ([header] + lines + [spacesReport()] + own).joined(separator: "\n")
    }

    static func milliseconds(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}
