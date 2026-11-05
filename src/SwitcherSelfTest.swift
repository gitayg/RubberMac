import AppKit

// --selftest switch: on real windows, switches away from a window and checks the next Alt-Tab comes back to it.
// The hard case is switching into an app with several windows: activating it raises all of them. It moves focus
// between the user's windows and puts it back. Logs app names and window numbers only.
extension WindowSwitcher {
    static func switchSelfTestReport() -> String {
        guard AX.isTrusted else { return "accessibility not trusted" }
        let switcher = WindowSwitcher()
        switcher.tracksFocus = true
        let windows = SwitcherSource.snapshot()
        guard let originalID = FocusTracker.focused()?.window,
              let original = windows.first(where: { $0.windowID == originalID }) else {
            return "no listed window has focus (frontmost: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"))"
        }

        // Only windows a focus can bring up without unhiding, unminimizing or switching Space.
        let visible = windows.filter { entry in
            !entry.isMinimized && entry.isOnCurrentSpace && NSRunningApplication(processIdentifier: entry.pid)?.isHidden != true
        }
        let counts = Dictionary(grouping: visible, by: \.pid).mapValues(\.count)
        let crowded = visible.first { counts[$0.pid, default: 0] > 1 }?.pid
        guard let start = ([original] + visible).first(where: { $0.pid != crowded }) else {
            return "needs windows from at least two apps"
        }
        let targets = visible.filter { $0.pid == crowded } + visible.filter { $0.pid != crowded && $0.pid != start.pid }
        guard !targets.isEmpty else { return "needs windows from at least two apps" }

        func settle(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        func focus(_ entry: SwitcherEntry) {
            AX.focus(entry.window, pid: entry.pid)
            settle(0.6)
        }
        func back() -> SwitcherEntry? {
            switcher.begin(reverse: false)
            defer { switcher.cancel() }
            return switcher.selection
        }
        var failures = 0
        func verdict(_ entry: SwitcherEntry?) -> String {
            if entry?.windowID != start.windowID { failures += 1 }
            return "\(entry.map(name) ?? "nothing") — \(entry?.windowID == start.windowID ? "back" : "WRONG")"
        }

        var lines = ["start: \(name(start)); app with several windows: "
            + (crowded.map { pid in visible.filter { $0.pid == pid }.map(name).joined(separator: ", ") } ?? "none, so the raise case isn't covered")]
        focus(start)

        for target in targets.prefix(4) {
            focus(target)
            lines.append("focused \(name(target)), then alt-tab: \(verdict(back()))")
            focus(start)
        }

        for delay in [0, 0.1, 0.3, 1.0] {
            switcher.begin(reverse: false)
            let away = switcher.selection
            switcher.commit()
            settle(delay)
            lines.append("alt-tab to \(away.map(name) ?? "nothing"), again after \(Int(delay * 1000)) ms: \(verdict(back()))")
            focus(start)
        }

        focus(original)
        lines.append(failures == 0 ? "PASS" : "FAIL: \(failures) wrong")
        return lines.joined(separator: "\n")
    }

    private static func name(_ entry: SwitcherEntry) -> String {
        "\(entry.appName)#\(entry.windowID ?? 0)\(entry.isMinimized ? " (minimized)" : "")"
    }
}

// --selftest windows, the part about Spaces: what the window server and Accessibility each report per app, so a
// window missing from the switcher can be traced. App names, window numbers and element numbers only, never titles.
extension WindowSwitcher {
    static func spacesReport() -> String {
        var lines: [String] = []
        let spaces = SpaceWindows.spaces()
        lines.append("private api: list \(SpaceWindows.canList), elements \(SpaceWindows.canFindElements), focus \(SpaceWindows.canFocus)")
        if let spaces {
            lines.append("spaces: current \(spaces.current.sorted()), user \(spaces.user.sorted()), full screen \(spaces.fullScreen.sorted())")
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier > 0 && $0.processIdentifier != me }
        let pids = Set(apps.map(\.processIdentifier))
        var start = DispatchTime.now()
        let server = spaces.flatMap { SpaceWindows.windows(of: pids, on: $0.user) } ?? []
        lines.append("window server: \(server.count) layer-0 windows on user Spaces of \(apps.count) regular apps in \(milliseconds(since: start)) ms")
        let sizes = Dictionary((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap {
            window -> (CGWindowID, CGSize)? in
            guard let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return (id, rect.size)
        }, uniquingKeysWith: { first, _ in first })

        for app in apps.sorted(by: { ($0.localizedName ?? "") < ($1.localizedName ?? "") }) {
            let pid = app.processIdentifier
            let name = app.localizedName ?? "?"
            let element = AX.app(pid)
            AXUIElementSetMessagingTimeout(element, 0.25)
            start = DispatchTime.now()
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
            let ms = milliseconds(since: start)
            let axWindows = value as? [AXUIElement] ?? []
            let ws = server.filter { $0.pid == pid }
            lines.append("\(name) pid \(pid): hidden \(app.isHidden), AXWindows \(error.rawValue) count \(axWindows.count) in \(ms) ms, window server \(ws.count)")
            var seen = Set<CGWindowID>()
            for window in axWindows {
                AXUIElementSetMessagingTimeout(window, 0.25)
                let id = AX.windowID(of: window)
                if let id { seen.insert(id) }
                let subrole = AX.string(window, kAXSubroleAttribute) ?? "nil"
                let minimized = AX.bool(window, kAXMinimizedAttribute) ?? false
                let spacesOf = ws.first { $0.id == id }?.spaces ?? []
                let kept = SwitcherModel.keeps(subrole: subrole, minimized: minimized, appHidden: app.isHidden)
                lines.append("  ax \(id ?? 0) \(subrole) minimized \(minimized) spaces \(spacesOf) kept \(kept)")
            }
            for window in ws where !seen.contains(window.id) {
                let size = sizes[window.id].map { "\(Int($0.width))x\(Int($0.height))" } ?? "?"
                let kind = window.spaces.isEmpty ? "no space"
                    : window.spaces.contains { spaces?.current.contains($0) == true } ? "current space"
                    : window.spaces.contains { spaces?.fullScreen.contains($0) == true } ? "full-screen space" : "other space"
                let orderedIn = SpaceWindows.isOrderedIn(window.id).map { "\($0)" } ?? "?"
                lines.append("  ws \(window.id) \(size) spaces \(window.spaces) \(kind) on screen \(window.isOnScreen) ordered in \(orderedIn) — not in AXWindows")
            }
            let missing = Set(ws.filter { !seen.contains($0.id) }.map(\.id))
            guard CommandLine.arguments.contains("--brute-force"), SpaceWindows.canFindElements, !ws.isEmpty else { continue }
            lines.append(contentsOf: bruteForce(pid: pid, missing: missing, listed: seen))
        }
        return lines.joined(separator: "\n")
    }

    // Every element number up to the limit, timed, noting each window element and the errors for the rest.
    private static func bruteForce(pid: pid_t, missing: Set<CGWindowID>, listed: Set<CGWindowID>) -> [String] {
        var lines: [String] = []
        var errors: [Int32: Int] = [:]
        var found: [String] = []
        var foundMissing = Set<CGWindowID>()
        var at1000 = 0
        var limit: UInt64 = 5000
        let start = DispatchTime.now()
        var last: UInt64 = 0
        var live = 0
        var number: UInt64 = 0
        while number < limit {
            defer { number += 1 }
            // Look further in apps whose live elements already reach past the middle.
            if number == limit - 1, last > limit / 2, limit < 20000 { limit *= 4 }
            if number == 1000 { at1000 = milliseconds(since: start) }
            guard let element = SpaceWindows.element(pid: pid, number: number) else { errors[-1, default: 0] += 1; continue }
            AXUIElementSetMessagingTimeout(element, 0.25)
            var role: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            guard error == .success else {
                errors[error.rawValue, default: 0] += 1
                if error == .cannotComplete { lines.append("  brute force: element \(number) timed out, stopping"); break }
                continue
            }
            last = number
            live += 1
            guard role as? String == kAXWindowRole as String else { continue }
            let id = AX.windowID(of: element)
            let subrole = AX.string(element, kAXSubroleAttribute) ?? "nil"
            let minimized = AX.bool(element, kAXMinimizedAttribute) ?? false
            if let id, missing.contains(id) { foundMissing.insert(id) }
            let note = id.map(missing.contains) == true ? " (missing one)" : id.map(listed.contains) == true ? " (in AXWindows)" : ""
            found.append("element \(number) → window \(id ?? 0) \(subrole) minimized \(minimized)\(note)")
        }
        let total = milliseconds(since: start)
        lines.append("  brute force 0..<\(limit): \(total) ms (first 1000 in \(at1000) ms), \(live) live, highest \(last), errors \(errors.sorted { $0.key < $1.key })")
        lines.append(contentsOf: found.map { "    \($0)" })
        if !missing.isEmpty { lines.append("  missing windows found: \(foundMissing.sorted()) of \(missing.sorted())") }
        return lines
    }
}

// --selftest windows --own-window: a transparent window of our own stands in for one on another Space. It's hidden
// with its app, moved to another desktop (the screen stays on the current one), hidden there, then closed, and each
// time the report says what the window server and Accessibility make of it and whether the switcher lists it.
// Nothing of the user's is touched.
extension WindowSwitcher {
    static func ownWindowReport() -> String {
        guard let spaces = SpaceWindows.spaces(),
              let other = spaces.user.subtracting(spaces.current).subtracting(spaces.fullScreen).sorted().first else {
            return "own window: needs a second desktop"
        }
        func settle(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        // Accessibility calls into our own app need the main thread free to answer them.
        func offMain<T>(_ body: @escaping @Sendable () -> T) -> T {
            nonisolated(unsafe) var result: T?
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { result = body(); done.signal() }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
            return result!
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        // Self-tests exit before the app runs; until it has finished launching it doesn't answer Accessibility.
        NSApp.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 420, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        settle(0.5)
        let id = CGWindowID(window.windowNumber)
        var lines = ["own window \(id), spaces: current \(spaces.current.sorted()), user \(spaces.user.sorted()), other desktop \(other)",
                     "active \(NSApp.isActive), frontmost \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")"]
        var failures = 0
        // What the switcher would list of our own app.
        func listed() -> SwitcherEntry? {
            let me = SwitcherSource.App(pid: pid, name: "RubberMAC", isHidden: NSApp.isHidden)
            return offMain { SwitcherSource.collect([me]).first { $0.windowID == id } }
        }
        func state(_ step: String, expect: (listed: Bool, current: Bool)) {
            let spacesOf = SpaceWindows.windows(of: [pid], on: spaces.user)?.first { $0.id == id }?.spaces ?? []
            let ax = offMain { () -> String in
                let app = AX.app(pid)
                AXUIElementSetMessagingTimeout(app, 1)
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                let element = (value as? [AXUIElement] ?? []).first { AX.windowID(of: $0) == id }
                return "AXWindows lists it \(element != nil)\(element.map { " as \(AX.string($0, kAXSubroleAttribute) ?? "nil")" } ?? "")"
            }
            let entry = listed()
            let ok = (entry != nil) == expect.listed && (entry.map { $0.isOnCurrentSpace == expect.current } ?? true)
            if !ok { failures += 1 }
            let shown = entry.map { "listed\($0.isOnCurrentSpace ? "" : " on another Space")\($0.isMinimized ? " minimized" : "")" } ?? "not listed"
            lines.append("\(step): spaces \(spacesOf), ordered in \(SpaceWindows.isOrderedIn(id).map { "\($0)" } ?? "?"), \(ax); "
                + "switcher: \(shown) — \(ok ? "ok" : "WRONG")")
        }
        func hide(_ hidden: Bool) {
            hidden ? NSApp.hide(nil) : NSApp.unhideWithoutActivation()
            settle(0.5)
        }

        state("on this desktop", expect: (true, true))
        hide(true)
        state("app hidden on this desktop", expect: (true, true))
        hide(false)
        SpaceWindows.move(id, to: other)
        settle(0.5)
        state("moved to the other desktop, element known", expect: (true, false))
        SpaceElements.clear()
        let start = DispatchTime.now()
        state("element forgotten", expect: (false, false))
        while SpaceElements.isSearching { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        lines.append("background search took \(milliseconds(since: start)) ms")
        state("after the search", expect: (true, false))
        hide(true)
        state("app hidden on the other desktop", expect: (true, false))
        hide(false)
        window.orderOut(nil)
        settle(0.5)
        state("closed on the other desktop", expect: (false, false))
        lines.append(failures == 0 ? "own window: PASS" : "own window: FAIL: \(failures) wrong")
        return lines.joined(separator: "\n")
    }
}
