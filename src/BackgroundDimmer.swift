import AppKit

// Dims or blurs every window but the one in front, so it stands out. Follows focus by events; a slow check every couple
// of seconds catches anything they miss.
final class BackgroundDimmer: Feature {
    static let shared = BackgroundDimmer()

    // Window raises can land after the notification that announced them, so each change is looked at again shortly after.
    static let settle: TimeInterval = 0.3
    private static let pollInterval: TimeInterval = 2

    let overlays = BackgroundDimOverlays()
    let watcher: BackgroundDimWatcher
    private(set) var target = BackgroundDimFront.Target.none
    // How often the front window was looked up, for the self-test.
    private(set) var updates = 0

    private let ownPID: pid_t
    private let mode: () -> BackgroundDimMode
    private let strength: () -> Double
    private var poll: Timer?
    private var pending = false
    private var settling: DispatchWorkItem?

    init(ownPID: pid_t = getpid(), mode: @escaping () -> BackgroundDimMode = { Settings.backgroundDimMode },
         strength: @escaping () -> Double = { Settings.backgroundDimStrength }) {
        self.ownPID = ownPID
        self.mode = mode
        self.strength = strength
        watcher = BackgroundDimWatcher(ownPID: ownPID)
        watcher.onChange = { [weak self] in self?.changed() }
        watcher.onScreens = { [weak self] in
            self?.overlays.removeAll()
            self?.changed()
        }
    }

    var wantsAccess: Bool { mode() != .off }
    var isOn: Bool { watcher.isRunning }

    func start() {
        refresh()
    }

    func restartTaps() {
        watcher.restart()
        if isOn { changed() }
    }

    // After the mode or the strength changed.
    func refresh() {
        let mode = mode()
        guard mode != .off else { return stop() }
        if !isOn {
            log("background windows: \(mode.rawValue)")
            watcher.start()
            poll = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.update() }
            poll?.tolerance = Self.pollInterval / 4
        }
        update()
    }

    func stop() {
        guard isOn else { return }
        log("background windows: left as they are")
        watcher.stop()
        poll?.invalidate()
        poll = nil
        settling?.cancel()
        overlays.removeAll()
        target = .none
    }

    // Many notifications come at once (a window closing moves the focus too); one look serves them all.
    private func changed() {
        if !pending {
            pending = true
            DispatchQueue.main.async { [weak self] in
                self?.pending = false
                self?.update()
            }
        }
        settling?.cancel()
        let again = DispatchWorkItem { [weak self] in self?.update() }
        settling = again
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: again)
    }

    func update() {
        guard isOn else { return }
        updates += 1
        let (target, element) = BackgroundDimFront.current(ownPID: ownPID, last: watcher.app)
        switch target {
        case .none: overlays.hide()
        case .below(let id):
            overlays.show(below: id, mode: mode(), strength: strength(), except: BackgroundDimFront.fullScreenDisplays(), ownPID: ownPID)
        }
        watcher.watch(element)
        self.target = target
    }
}
