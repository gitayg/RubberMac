import AppKit

// Clicking a running app's Dock icon: with two or more windows, a menu of them opens beside the icon instead of the
// app coming forward, and picking one goes to that window. With fewer, the click goes on to the Dock as before.
// Main thread, but for listing the windows.
final class DockWindowPicker {
    let clicks = DockClicks()
    let keys = DockMenuKeys()

    var isEnabled = false {
        didSet {
            clicks.isEnabled = isEnabled
            keys.isEnabled = isEnabled
            if isEnabled { DockItems.refresh() } else { close() }
        }
    }

    var isShown: Bool { shown != nil }

    private let menu = DockWindowMenu()
    private let pictures = WindowThumbnails()
    // The press being decided: its icon, its app's windows once listed, and where it was let go once it is.
    private var pending: (item: DockItems.Item, windows: [SwitcherEntry]?, release: CGPoint?)?
    private(set) var shown: (item: DockItems.Item, windows: [SwitcherEntry])?
    private var activation: NSObjectProtocol?
    // Per process of the shown windows: which copy of the app it is, when there are several, and its last sample.
    // Only touched on usageQueue, where the samples are taken.
    private var usage: [pid_t: (copy: String?, last: ProcessUsage.Sample)] = [:]
    private let usageQueue = DispatchQueue(label: "dock menu usage", qos: .utility)
    private var usageTimer: Timer?
    // Counts menus opened and closed, so figures measured for a menu that has since closed are dropped.
    private var generation = 0

    init() {
        clicks.onPress = { [weak self] in self?.pressed($0) }
        clicks.onRelease = { [weak self] in self?.released($0, at: $1) }
        clicks.onHandedOn = { [weak self] in self?.pending = nil }
        clicks.onOtherClick = { [weak self] in self?.clicked(at: $0) }
        keys.onEscape = { [weak self] in self?.close() }
        menu.onPick = { [weak self] in self?.pick($0) }
    }

    private func pressed(_ item: DockItems.Item) {
        // A second click on the icon whose menu is open closes it.
        if shown?.item.url == item.url {
            close()
            pending = nil
            return
        }
        close()
        pending = (item, nil, nil)
        let apps = Self.apps(at: item.url)
        let recent = Settings.focusHistory
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let windows = SwitcherSource.snapshot(of: apps, recent: recent)
            DispatchQueue.main.async { self?.listed(windows, for: item) }
        }
    }

    private func released(_ item: DockItems.Item, at point: CGPoint) {
        guard pending?.item == item else { return }
        pending?.release = point
        decide()
    }

    private func listed(_ windows: [SwitcherEntry], for item: DockItems.Item) {
        guard pending?.item == item else { return }
        pending?.windows = windows
        decide()
    }

    private func decide() {
        guard let (item, windows, release) = pending, let windows, let release else { return }
        pending = nil
        guard windows.count >= 2 else { return clicks.handOn(at: release) }
        open(windows, for: item)
    }

    private func open(_ windows: [SwitcherEntry], for item: DockItems.Item) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        menu.show(windows, pictures: pictures, near: WindowMapView.appKit(item.frame, primaryHeight: primaryHeight),
                  edge: FullScreenDock.dockEdge())
        shown = (item, windows)
        generation += 1
        keys.isOpen.store(true, ordering: .relaxed)
        log("dock menu: \(windows.count) windows")
        pictures.refresh(windows.compactMap(\.windowID)) { [weak self] id, picture in
            guard let self, self.shown != nil else { return }
            self.menu.show(picture, for: id)
        }
        showUsage(of: windows)
        // Another app coming forward, by ⌘Tab or a click, leaves the menu behind.
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.close() }
    }

    private func pick(_ index: Int) {
        guard let windows = shown?.windows, windows.indices.contains(index) else { return }
        close()
        WindowFocus.go(to: windows[index])
    }

    // point in screen coordinates (origin at the top left of the primary screen).
    private func clicked(at point: CGPoint) {
        guard shown != nil else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        if menu.frame?.contains(CGPoint(x: point.x, y: primaryHeight - point.y)) != true { close() }
    }

    func close() {
        guard shown != nil else { return }
        shown = nil
        menu.hide()
        keys.isOpen.store(false, ordering: .relaxed)
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        usageTimer?.invalidate()
        usageTimer = nil
        generation += 1
    }

    // Each process's memory at once and its CPU from a second on, updated every second while the menu shows. With
    // windows from several copies of the app, each row also says which copy it's from. Measured off the main thread:
    // a copy of an Electron app can have a hundred processes under it, and walking them takes milliseconds.
    private func showUsage(of windows: [SwitcherEntry]) {
        var appNames: [pid_t: String] = [:]
        for window in windows where appNames[window.pid] == nil { appNames[window.pid] = window.appName }
        let generation = generation
        usageQueue.async { [weak self] in
            guard let self else { return }
            self.usage = [:]
            var texts: [(pid_t, String)] = []
            for (pid, appName) in appNames {
                guard let sample = ProcessUsage.sample(pid) else { continue }
                let copy = appNames.count > 1
                    ? ProcessUsage.arguments(of: pid).map { ProcessUsage.copyName(arguments: $0, appName: appName) } : nil
                self.usage[pid] = (copy, sample)
                texts.append((pid, ProcessUsage.text(copy: copy, cpu: nil, memoryBytes: sample.memoryBytes)))
            }
            self.show(texts, generation: generation)
        }
        // In the common modes, so it keeps ticking while the list is scrolled.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateUsage() }
        RunLoop.main.add(timer, forMode: .common)
        usageTimer = timer
    }

    private func updateUsage() {
        let generation = generation
        usageQueue.async { [weak self] in
            guard let self else { return }
            var texts: [(pid_t, String)] = []
            for (pid, (copy, earlier)) in self.usage {
                guard let later = ProcessUsage.sample(pid) else { continue }
                self.usage[pid] = (copy, later)
                let cpu = ProcessUsage.cpuPercent(from: earlier, to: later)
                texts.append((pid, ProcessUsage.text(copy: copy, cpu: cpu, memoryBytes: later.memoryBytes)))
            }
            self.show(texts, generation: generation)
        }
    }

    // From usageQueue: hands the figures to the menu, unless it has closed since they were asked for.
    private func show(_ texts: [(pid_t, String)], generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation, self.shown != nil else { return }
            for (pid, text) in texts { self.menu.show(usage: text, for: pid) }
        }
    }

    // The running copies of the app an icon stands for.
    static func apps(at url: URL) -> [SwitcherSource.App] {
        let path = url.resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier > 0 && $0.bundleURL?.resolvingSymlinksInPath().path == path }
            .map { SwitcherSource.App(pid: $0.processIdentifier, name: $0.localizedName ?? "", isHidden: $0.isHidden) }
    }
}
