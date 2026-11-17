import AppKit

// Puts new windows on their screen: the pointer's for a window the user just opened (with the switch on), the app's
// chosen one for any new window of an app with a rule. An app is observed only for a few seconds after the user
// launches or switches to it, or for as long as it runs if it has a rule; with one screen, not at all. Main thread.
final class OpenOnScreenMover {
    // Apps place a new window right after making it, so it's looked at a moment later.
    static let settle: TimeInterval = 0.3
    // After a move, when to look whether the app put it back, and how many times to move it again if it did.
    static let recheck: TimeInterval = 0.5
    static let retries = 1
    // While a mouse button is down, it's looked at again this often, this many times.
    static let heldStep: TimeInterval = 0.25
    static let heldLooks = 8
    // An app just launched may not answer Accessibility yet: asked again this often, this many times.
    static let observeStep: TimeInterval = 0.5
    static let observeTries = 10

    struct System {
        var screens: () -> [OpenOnScreenPlan.Screen] = OpenOnScreenPlan.connectedScreens
        var pointer: () -> CGPoint = OpenOnScreenPlan.pointer
        var lastInput: () -> Date = OpenOnScreenOpenings.lastInput
        var newestWindow: () -> CGWindowID = OpenOnScreenOpenings.newestWindow
        var mouseDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }
        var showsFullScreen: (OpenOnScreenPlan.Screen) -> Bool = OpenOnScreenPlan.showsFullScreen
        // Ordinary apps, not RubberMAC itself.
        var accepts: (NSRunningApplication) -> Bool = {
            $0.activationPolicy == .regular && $0.processIdentifier > 0 && $0.processIdentifier != getpid() && $0.bundleIdentifier != nil
        }
    }

    var system: System
    // Told every decision, for the self-test.
    var onDecision: ((NSRunningApplication, CGWindowID, OpenOnScreenPlan.Outcome) -> Void)?
    private(set) var switchOn = false
    private(set) var rules: [OpenOnScreenRule] = []
    private(set) var observers: [pid_t: OpenOnScreenObserver] = [:]
    private var openings = OpenOnScreenOpenings()
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var expiry: DispatchWorkItem?
    private var changingUntil = Date.distantPast

    init(system: System = System()) {
        self.system = system
    }

    var isRunning: Bool { !tokens.isEmpty }

    // After either setting changed: observes what it now has to, and nothing more.
    func configure(switchOn: Bool, rules: [OpenOnScreenRule]) {
        let turnedOn = switchOn && !self.switchOn
        self.switchOn = switchOn
        self.rules = rules
        guard switchOn || !rules.isEmpty else { return stop() }
        if tokens.isEmpty { listen() }
        // Switches aren't counted while it's off, so the windows made meanwhile are all older than the next one.
        if turnedOn || !switchOn { openings = OpenOnScreenOpenings(newest: system.newestWindow()) }
        refreshObservers()
    }

    func stop() {
        tokens.forEach { center, token in center.removeObserver(token) }
        tokens = []
        observers = [:]
        openings = OpenOnScreenOpenings()
        expiry?.cancel()
        expiry = nil
    }

    // Once Accessibility is on: observers made before it get nothing.
    func restart() {
        guard isRunning else { return }
        observers = [:]
        refreshObservers()
    }

    func launched(_ app: NSRunningApplication) {
        guard system.accepts(app), system.screens().count >= 2 else { return }
        let now = Date()
        let watch = switchOn ? openings.launched(app.processIdentifier, at: app.launchDate ?? now, now: now, lastInput: system.lastInput()) : nil
        guard watch != nil || rule(for: app) != nil else { return }
        observe(app, since: 0, triesLeft: Self.observeTries)
        scheduleExpiry()
    }

    func activated(_ app: NSRunningApplication) {
        guard switchOn, system.screens().count >= 2 else { return }
        let watch = openings.activated(app.processIdentifier, now: Date(), lastInput: system.lastInput(), newest: system.newestWindow())
        guard let watch, system.accepts(app) else { return }
        observe(app, since: watch.since, triesLeft: Self.observeTries)
        scheduleExpiry()
    }

    func terminated(_ app: NSRunningApplication) {
        observers[app.processIdentifier] = nil
        openings.ended(app.processIdentifier)
    }

    private func listen() {
        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ act: @escaping (OpenOnScreenMover, NSRunningApplication) -> Void) -> (NotificationCenter, NSObjectProtocol) {
            (workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                act(self, app)
            })
        }
        tokens = [on(NSWorkspace.didLaunchApplicationNotification) { $0.launched($1) },
                  on(NSWorkspace.didActivateApplicationNotification) { $0.activated($1) },
                  on(NSWorkspace.didTerminateApplicationNotification) { $0.terminated($1) }]
        let center = NotificationCenter.default
        tokens.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
            [weak self] _ in self?.screensChanged()
        }))
        openings = OpenOnScreenOpenings(newest: system.newestWindow())
    }

    // Window Layouts puts windows back once the screens have been still for a while; until then nothing is moved.
    private func screensChanged() {
        changingUntil = Date(timeIntervalSinceNow: LayoutKeeper.settleDelay)
        openings = OpenOnScreenOpenings(newest: system.newestWindow())
        refreshObservers()
    }

    // An observer for each running app with a rule while two or more screens are connected, and none it doesn't need.
    private func refreshObservers() {
        let twoScreens = system.screens().count >= 2
        for (pid, observer) in observers where !twoScreens || (openings.watches[pid] == nil && rule(for: observer.app) == nil) {
            observers[pid] = nil
        }
        guard twoScreens else { return }
        let newest = system.newestWindow()
        for app in NSWorkspace.shared.runningApplications where observers[app.processIdentifier] == nil && system.accepts(app) && rule(for: app) != nil {
            observe(app, since: newest, triesLeft: 0)
        }
    }

    private func rule(for app: NSRunningApplication) -> OpenOnScreenRule? {
        rules.first { $0.app == app.bundleIdentifier }
    }

    private func observe(_ app: NSRunningApplication, since: CGWindowID, triesLeft: Int) {
        guard AX.isTrusted, !app.isTerminated else { return }
        let pid = app.processIdentifier
        if let observer = observers[pid] {
            observer.since = min(observer.since, since)
        } else if let observer = OpenOnScreenObserver(app, since: since, onWindow: { [weak self] in self?.appeared($0, id: $1, app: app) }) {
            observers[pid] = observer
        } else {
            guard triesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.observeStep) { [weak self] in
                guard let self, self.openings.watches[pid] != nil || self.rule(for: app) != nil else { return }
                self.observe(app, since: since, triesLeft: triesLeft - 1)
            }
            return
        }
        observers[pid]?.scan()
    }

    private func appeared(_ window: AXUIElement, id: CGWindowID, app: NSRunningApplication) {
        let opening = openings.appeared(app.processIdentifier, window: id, at: Date())
        if opening { scheduleExpiry() }
        guard opening || rule(for: app) != nil else { return report(app, id, .leave(.notOpening)) }
        let since = observers[app.processIdentifier]?.since ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle) { [weak self] in
            self?.place(window, id: id, app: app, opening: opening, since: since, heldAt: nil, looks: 0)
        }
    }

    // `since`: the app's windows numbered up to it were open before.
    private func place(_ window: AXUIElement, id: CGWindowID, app: NSRunningApplication, opening: Bool, since: CGWindowID, heldAt: CGRect?,
                       looks: Int) {
        guard let facts = Self.facts(of: window) else { return }
        var context = OpenOnScreenPlan.Context(screens: system.screens(), pointer: system.pointer(), rule: rule(for: app)?.screen, opening: opening)
        context.mouseDown = system.mouseDown()
        context.heldAt = heldAt
        context.screensChanging = Date() < changingUntil
        context.showsFullScreen = system.showsFullScreen
        context.isTabOfOlderWindow = { Self.hasTabBar(window) && Self.sharesFrame(id, of: app.processIdentifier, olderThan: since) }
        var outcome = OpenOnScreenPlan.decide(facts, context)
        if outcome == .wait && looks >= Self.heldLooks { outcome = .leave(.dragged) }
        report(app, id, outcome)
        switch outcome {
        case .wait:
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.heldStep) { [weak self] in
                self?.place(window, id: id, app: app, opening: opening, since: since, heldAt: heldAt ?? facts.frame, looks: looks + 1)
            }
        case .move(let target, let frame):
            let screen = context.screens[target]
            AX.setFrame(window, frame)
            log("open on screen: moved a new \(app.localizedName ?? "app") window to \(screen.name)"
                + (context.rule == screen.key ? ", the screen chosen for it" : ""))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.recheck) { [weak self] in
                self?.verify(window, frame, on: screen.key, app: app, retriesLeft: Self.retries)
            }
        case .leave:
            break
        }
    }

    // An app that puts its window back where it wanted it gets it moved once more, and then its way.
    private func verify(_ window: AXUIElement, _ frame: CGRect, on key: String, app: NSRunningApplication, retriesLeft: Int) {
        let screens = system.screens()
        guard let now = AX.frame(of: window), let target = screens.firstIndex(where: { $0.key == key }),
              OpenOnScreenPlan.screen(of: now, screens) != target else { return }
        guard retriesLeft > 0, !system.mouseDown() else {
            return log("open on screen: \(app.localizedName ?? "an app") put its new window back on another screen, so it stays there")
        }
        AX.setFrame(window, frame)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recheck) { [weak self] in
            self?.verify(window, frame, on: key, app: app, retriesLeft: retriesLeft - 1)
        }
    }

    private func report(_ app: NSRunningApplication, _ id: CGWindowID, _ outcome: OpenOnScreenPlan.Outcome) {
        onDecision?(app, id, outcome)
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard let next = openings.watches.values.map(\.until).min() else { return }
        let work = DispatchWorkItem { [weak self] in self?.expire() }
        expiry = work
        // Just after the soonest one is over.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(next.timeIntervalSinceNow, 0) + 0.05, execute: work)
    }

    private func expire() {
        for pid in openings.expire(Date()) {
            if let observer = observers[pid], rule(for: observer.app) == nil { observers[pid] = nil }
        }
        scheduleExpiry()
    }

    private static func hasTabBar(_ window: AXUIElement) -> Bool {
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children) == .success else { return false }
        return ((children as? [AXUIElement]) ?? []).contains { AX.string($0, kAXRoleAttribute) == kAXTabGroupRole }
    }

    // A window's tabs are windows of their own, all the same size in the same place; only the chosen one is on screen.
    private static func sharesFrame(_ id: CGWindowID, of pid: pid_t, olderThan since: CGWindowID) -> Bool {
        let windows = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { info -> (CGWindowID, CGRect)? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid, (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
            else { return nil }
            return (number, bounds)
        }
        guard let own = windows.first(where: { $0.0 == id })?.1 else { return false }
        return windows.contains { $0.0 <= since && $0.1 == own }
    }

    private static func facts(of window: AXUIElement) -> OpenOnScreenPlan.Window? {
        AXUIElementSetMessagingTimeout(window, OpenOnScreenObserver.timeout)
        guard let frame = AX.frame(of: window) else { return nil }
        return OpenOnScreenPlan.Window(role: AX.string(window, kAXRoleAttribute), subrole: AX.string(window, kAXSubroleAttribute),
                                       fullScreen: AX.bool(window, "AXFullScreen") == true,
                                       minimized: AX.bool(window, kAXMinimizedAttribute) == true, frame: frame)
    }
}
