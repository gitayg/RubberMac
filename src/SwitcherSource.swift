import AppKit
import ApplicationServices

struct SwitcherEntry: SwitcherOrderable {
    let window: AXUIElement
    let pid: pid_t
    let windowID: CGWindowID?
    let appName: String
    let title: String
    let isMinimized: Bool
    // In Accessibility coordinates (origin at the top left of the primary screen).
    let frame: CGRect?
    // False for a window on a Space the screen isn't showing (another desktop or a full-screen app).
    var isOnCurrentSpace = true
}

// Collects the switchable windows of every regular app, on every Space, in switch order.
enum SwitcherSource {
    struct App {
        let pid: pid_t
        let name: String
        let isHidden: Bool
    }

    // A hung app would otherwise block each AX call for the 6 s default.
    private static let timeout: Float = 0.25

    // recent: window IDs in the order they last had focus, most recent first.
    static func snapshot(recent: [CGWindowID] = []) -> [SwitcherEntry] {
        snapshot(of: regularApps(), recent: recent)
    }

    // Any thread: the windows of just these apps, in switch order.
    static func snapshot(of apps: [App], recent: [CGWindowID]) -> [SwitcherEntry] {
        SwitcherModel.ordered(collect(apps), recent: recent, zOrder: zOrder())
    }

    // Main thread: who's running. Some listed apps have no process behind them (pid -1; seen for Preview and QuickTime).
    static func regularApps() -> [App] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier > 0 && $0.processIdentifier != me }
            .map { App(pid: $0.processIdentifier, name: $0.localizedName ?? "", isHidden: $0.isHidden) }
    }

    // Off the main thread: lists the windows so the elements of windows on other Spaces are found before Alt-Tab.
    static func warm(_ apps: [App]) {
        DispatchQueue.global(qos: .utility).async { _ = collect(apps) }
    }

    // Any thread. Accessibility only lists the current Space's windows (and minimized and hidden ones); the window
    // server knows the windows on every Space, and the ones Accessibility left out are reached through SpaceElements.
    static func collect(_ apps: [App]) -> [SwitcherEntry] {
        let spaces = SpaceWindows.spaces()
        let server = spaces.flatMap { SpaceWindows.windows(of: Set(apps.map(\.pid)), on: $0.user) } ?? []
        let byApp = Dictionary(grouping: server, by: \.pid)
        // One app per thread, so the slowest app sets the cost rather than the sum of them all.
        var perApp = [[SwitcherEntry]](repeating: [], count: apps.count)
        perApp.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: apps.count) { i in
                out[i] = entries(of: apps[i], server: byApp[apps[i].pid] ?? [], current: spaces?.current)
            }
        }
        SpaceElements.keep(pids: Set(apps.map(\.pid)), windows: Set(server.map(\.id)))
        return perApp.flatMap { $0 }
    }

    private static func zOrder() -> [CGWindowID] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        return SwitcherModel.layerZeroIDs(info as? [[String: Any]] ?? [])
    }

    // AX.windows(of:) builds its own app element, which can't carry our timeout, so ask directly.
    // server: the app's windows on every user Space; current: the Spaces on screen (nil without the window server).
    private static func entries(of app: App, server: [SpaceWindows.Window], current: Set<UInt64>?) -> [SwitcherEntry] {
        let element = AX.app(app.pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        let spacesOf = Dictionary(server.map { ($0.id, Set($0.spaces)) }, uniquingKeysWith: { first, _ in first })
        func onCurrentSpace(_ id: CGWindowID?) -> Bool {
            guard let current, let id, let spaces = spacesOf[id] else { return true }
            return !spaces.isDisjoint(with: current)
        }

        var listed: [CGWindowID: AXUIElement] = [:]
        var result: [SwitcherEntry] = windows.compactMap { window in
            AXUIElementSetMessagingTimeout(window, timeout)
            let id = AX.windowID(of: window)
            if let id { listed[id] = window }
            let (subrole, minimized, title, frame) = attributes(of: window)
            guard SwitcherModel.keeps(subrole: subrole, minimized: minimized, appHidden: app.isHidden) else { return nil }
            return SwitcherEntry(window: window, pid: app.pid, windowID: id, appName: app.name,
                                 title: SwitcherModel.displayTitle(title, appName: app.name), isMinimized: minimized,
                                 frame: frame, isOnCurrentSpace: onCurrentSpace(id))
        }
        SpaceElements.remember(pid: app.pid, listed)

        // A window left out on the current Space is closed: Accessibility lists all the others there.
        guard let current else { return result }
        var missing: [CGWindowID: Bool] = [:]
        for window in server where listed[window.id] == nil && Set(window.spaces).isDisjoint(with: current) {
            let orderedIn = SpaceWindows.isOrderedIn(window.id) ?? true
            guard let element = SpaceElements.element(pid: app.pid, window: window.id) else {
                missing[window.id] = orderedIn
                continue
            }
            AXUIElementSetMessagingTimeout(element, timeout)
            let (subrole, minimized, title, frame) = attributes(of: element)
            // No longer answering: closed, or shown again as a new element.
            if subrole == nil && AX.string(element, kAXRoleAttribute) == nil {
                SpaceElements.forget(pid: app.pid, window: window.id)
                missing[window.id] = orderedIn
                continue
            }
            // A hidden app's windows aren't ordered in, so there the rule is the one for windows Accessibility lists.
            let keeps = app.isHidden ? SwitcherModel.keeps(subrole: subrole, minimized: minimized, appHidden: true)
                : SwitcherModel.keepsElsewhere(subrole: subrole, minimized: minimized, orderedIn: orderedIn)
            guard keeps else { continue }
            result.append(SwitcherEntry(window: element, pid: app.pid, windowID: window.id, appName: app.name,
                                        title: SwitcherModel.displayTitle(title, appName: app.name),
                                        isMinimized: minimized, frame: frame, isOnCurrentSpace: false))
        }
        if !missing.isEmpty && SpaceWindows.canFindElements { SpaceElements.find(pid: app.pid, missing) }
        return result
    }

    // One round trip for all the attributes; a failed one comes back as an AXError value, not the type asked for.
    private static func attributes(of window: AXUIElement)
        -> (subrole: String?, minimized: Bool, title: String?, frame: CGRect?) {
        let names = [kAXSubroleAttribute, kAXMinimizedAttribute, kAXTitleAttribute, kAXPositionAttribute,
                     kAXSizeAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(window, names, [], &values) == .success,
              let list = values as? [AnyObject], list.count == 5 else { return (nil, false, nil, nil) }
        var origin = CGPoint.zero, size = CGSize.zero
        let hasFrame = CFGetTypeID(list[3]) == AXValueGetTypeID() && CFGetTypeID(list[4]) == AXValueGetTypeID()
            && AXValueGetValue(list[3] as! AXValue, .cgPoint, &origin) && AXValueGetValue(list[4] as! AXValue, .cgSize, &size)
        return (list[0] as? String, (list[1] as? NSNumber)?.boolValue ?? false, list[2] as? String,
                hasFrame ? CGRect(origin: origin, size: size) : nil)
    }
}
