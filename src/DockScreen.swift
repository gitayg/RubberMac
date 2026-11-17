import AppKit

// Keeps the Dock on the screen you choose, instead of following the pointer to whichever screen's edge it touches.
// While a screen is chosen and two or more are connected, a pointer tap keeps the other screens' Dock edges from
// being pushed, and when the Dock is somewhere else (after screens connect, or right after choosing) a push on the
// chosen screen's edge brings it over. With "Displays have separate Spaces" off the Dock can't move, so it does nothing.
final class DockScreen: Feature {
    static let shared = DockScreen()

    struct Display: Equatable {
        let key: String
        let name: String
        let bounds: CGRect
    }

    // A bring the app does by itself (launch, screens changing) waits this long after the last one, so a Dock that
    // can't be read or moved doesn't keep pulling the pointer about.
    private static let autoBringGap: TimeInterval = 30
    // Rows of points at another screen's Dock edge the pointer is kept out of. On macOS 27 a hidden Dock comes up for
    // the pointer resting on either of the bottom two rows, not only the last (`--selftest dockscreen-live probe`), so
    // one row isn't enough; four leaves a margin.
    static let guardDepth: CGFloat = 4

    private let orientation = DockScreenOrientation()
    private lazy var holder = DockScreenGuard(edge: { [orientation] in orientation.current })
    private lazy var tap = EventTap(name: "dock screen", types: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged],
                                    location: .cghidEventTap, ownThread: true, handlers: [holder])
    private let queue = DispatchQueue(label: "dock screen", qos: .userInitiated)
    private var pendingBring: DispatchWorkItem?
    private var bringing = false
    private var lastAutoBring = Date.distantPast
    private var started = false

    var wantsAccess: Bool { Settings.dockScreen != nil }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.apply(bringAfter: 2, byUser: false) }
        apply(bringAfter: 3, byUser: false)
    }

    func restartTaps() {
        apply(bringAfter: 1, byUser: false)
    }

    // After the choice in the settings changed.
    func choiceChanged() {
        lastAutoBring = .distantPast
        apply(bringAfter: 0.3, byUser: true)
    }

    static func connectedDisplays() -> [Display] {
        NSScreen.screens.compactMap { screen in
            screen.displayID.map { Display(key: CameraArea.key(of: $0), name: screen.localizedName, bounds: CGDisplayBounds($0)) }
        }
    }

    // nil while the Dock is left to macOS: no screen chosen, the chosen one not connected, one screen, or the Dock
    // stuck to the main screen.
    static func layout(_ displays: [Display], chosen: String?, spansDisplays: Bool) -> DockScreenLayout? {
        guard let chosen, !spansDisplays, displays.count >= 2, let index = displays.firstIndex(where: { $0.key == chosen }) else { return nil }
        return DockScreenLayout(screens: displays.map(\.bounds), chosen: index, depth: guardDepth)
    }

    private func apply(bringAfter delay: TimeInterval, byUser: Bool) {
        orientation.refresh()
        var layout = Self.layout(Self.connectedDisplays(), chosen: Settings.dockScreen, spansDisplays: DockScreenDock.spansDisplays)
        if let found = layout.flatMap({ AX.isTrusted ? DockScreenDock.screen(among: $0.screens) : nil }), found != layout?.chosen {
            layout?.dockAt = found
        }
        if layout != holder.layout { holder.layout = layout }
        tap.update()
        guard layout?.dockAt != nil, byUser || -lastAutoBring.timeIntervalSinceNow > Self.autoBringGap else { return }
        pendingBring?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.bring(byUser: byUser, triesLeft: 5) }
        pendingBring = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // Pushes on the chosen screen's Dock edge until the Dock is there. Waits while a mouse button is held, as for a drag.
    private func bring(byUser: Bool, triesLeft: Int) {
        guard !bringing, AX.isTrusted, let layout = holder.layout, layout.dockAt != nil else { return }
        guard NSEvent.pressedMouseButtons == 0 else {
            if triesLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.bring(byUser: byUser, triesLeft: triesLeft - 1) }
            }
            return
        }
        let edge = FullScreenDock.dockEdge()
        let chosen = layout.chosen, screens = layout.screens
        let name = Self.connectedDisplays().first { $0.bounds == screens[chosen] }?.name ?? "the chosen screen"
        guard let point = DockScreenGeometry.pushPoint(on: chosen, edge: edge, screens: screens) else {
            log("dock screen: \(name)'s Dock edge runs into other screens all along, so the Dock can't be pushed there")
            return
        }
        bringing = true
        if !byUser { lastAutoBring = Date() }
        queue.async { [weak self] in
            let push = DockScreenDock.push(at: point, edge: edge) { DockScreenDock.screen(among: screens, edge: edge) == chosen }
            DispatchQueue.main.async {
                guard let self else { return }
                self.bringing = false
                log("dock screen: " + (push.arrived ? "brought the Dock to \(name)" : "the Dock didn't come to \(name)")
                    + " after \(push.pushes) pushes, \(push.milliseconds) ms" + (push.interrupted ? " (the pointer was moved away)" : ""))
                if push.arrived, var now = self.holder.layout, now.screens == screens {
                    now.dockAt = nil
                    self.holder.layout = now
                }
            }
        }
    }
}
