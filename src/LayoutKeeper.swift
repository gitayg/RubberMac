import AppKit

// Remembers where windows were for each monitor setup and puts them back after re-docking.
final class LayoutKeeper {
    static let saveInterval: TimeInterval = 30
    static let settleDelay: TimeInterval = 3

    // Turning this on starts periodic saves and restore-on-display-change; off stops both.
    var isEnabled = false {
        didSet { if isEnabled != oldValue { isEnabled ? start() : stop() } }
    }

    // Human-readable name of the current monitor setup, e.g. "DELL P2425H (1) + DELL P2425H (2)".
    var setupName: String { DisplaySetup.currentName() }

    // Whether a layout has been saved for the current monitor setup.
    var hasSavedLayout: Bool { store.snapshots[DisplaySetup.currentKey()] != nil }

    private let store: LayoutStore
    private var saveTimer: Timer?
    private var settle: DispatchWorkItem?
    private var knownKey = ""
    // Setups seen since the displays started changing; nil while they are stable.
    private var episode: Set<String>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(store: LayoutStore = LayoutStore()) {
        self.store = store
    }

    deinit { if isEnabled { stop() } }

    func saveNow() {
        guard AX.isTrusted else { AX.requestAccess(); return }
        save(explicit: true)
    }

    // Returns how many windows were moved.
    @discardableResult
    func restoreNow() -> Int {
        guard AX.isTrusted else { AX.requestAccess(); return 0 }
        return restore(reason: "restore")
    }

    static func selfTestReport() -> String {
        let store = LayoutStore()
        let key = DisplaySetup.currentKey()
        let capture = LayoutWindows.snapshot()
        let date = ISO8601DateFormatter()
        var lines = [
            "layouts: setup \"\(DisplaySetup.currentName())\"",
            "  key \(key)",
            "  accessibility \(AX.isTrusted ? "granted" : "NOT granted")",
            "  a save now would capture \(capture.count) windows from \(Set(capture.map(\.bundleID)).count) apps"
                + " (\(capture.filter(\.minimized).count) minimized)",
            "  \(store.snapshots.count) saved setups in \(store.url.path):",
        ]
        for (k, s) in store.snapshots.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(k == key ? "* current" : "- other  ") \"\(s.name)\" saved \(date.string(from: s.savedAt)),"
                         + " \(s.windows.count) windows, key \(k)")
        }
        return lines.joined(separator: "\n")
    }

    private func start() {
        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        let changed: (Notification) -> Void = { [weak self] _ in self?.displaysChanged() }
        observers = [
            (nc, nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: changed)),
            // A Mac can be undocked while asleep; a save timer firing late on wake must not record the reshuffle.
            (ws, ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: changed)),
            (ws, ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: changed)),
        ]
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
        resumeSaving()
        log("layouts: on, \(store.snapshots.count) saved setups, current has \(hasSavedLayout ? "one" : "none")")
    }

    private func stop() {
        observers.forEach { center, token in center.removeObserver(token) }
        observers = []
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
        saveTimer?.invalidate()
        saveTimer = nil
        settle?.cancel()
        settle = nil
        episode = nil
        log("layouts: off")
    }

    private func resumeSaving() {
        knownKey = DisplaySetup.currentKey()
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveInterval, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard episode == nil, AX.isTrusted else { return }
        // A setup change nobody told us about: treat it as one rather than saving macOS's reshuffle.
        guard DisplaySetup.currentKey() == knownKey else { displaysChanged(); return }
        save(explicit: false)
    }

    // Display changes arrive in bursts while macOS moves windows around, so stop saving at once
    // and look again only after nothing has changed for a few seconds.
    fileprivate func displaysChanged() {
        guard isEnabled else { return }
        if episode == nil {
            saveTimer?.invalidate()
            saveTimer = nil
            episode = [knownKey]
            log("layouts: displays changing, saving paused")
        }
        episode?.insert(DisplaySetup.currentKey())
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settled() }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func settled() {
        let now = DisplaySetup.currentKey()
        let changed = DisplaySetup.changed(seen: episode ?? [], now: now)
        episode = nil
        settle = nil
        if !changed {
            log("layouts: displays settled on the same setup, nothing to restore")
        } else if store.snapshots[now] == nil {
            log("layouts: displays settled on \(setupName), no saved layout for it yet")
        } else if AX.isTrusted {
            restore(reason: "re-dock restore")
        }
        resumeSaving()
    }

    private func save(explicit: Bool) {
        let key = DisplaySetup.currentKey()
        guard !key.isEmpty else { return }
        let previous = store.snapshots[key]?.windows
        let windows = LayoutWindows.snapshot()
        if !explicit && windows == previous { return }
        do {
            guard try store.put(LayoutSnapshot(name: setupName, savedAt: Date(), windows: windows), for: key) else {
                if explicit || previous != nil { log("layouts: save skipped, no windows visible (kept \(previous?.count ?? 0))") }
                return
            }
            if explicit || windows.count != previous?.count { log("layouts: saved \(windows.count) windows for \(setupName)") }
        } catch {
            log("layouts: save failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func restore(reason: String) -> Int {
        guard let snapshot = store.snapshots[DisplaySetup.currentKey()] else {
            log("layouts: \(reason): nothing saved for \(setupName)")
            return 0
        }
        let r = LayoutWindows.restore(snapshot, screens: WindowSnapper.screenAreas().map(\.frame))
        log("layouts: \(reason) on \(setupName): moved \(r.moved) of \(snapshot.windows.count) saved, \(r.alreadyThere) already there,"
            + " \(r.offScreen) off-screen, \(r.minimized) minimized, \(r.unmatched) not open")
        return r.moved
    }
}

// Quartz calls this before and after each display reconfiguration.
private func displayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    let keeper = Unmanaged<LayoutKeeper>.fromOpaque(info).takeUnretainedValue()
    if Thread.isMainThread { keeper.displaysChanged() } else { DispatchQueue.main.async { keeper.displaysChanged() } }
}
