import AppKit
import ApplicationServices
import Carbon.HIToolbox

// --selftest spotlightfilter-probe: measures what ⌘1 does in Spotlight's search bar, which process shows it in
// Accessibility, and what that process announces when the bar opens. Opens the bar four times for a few seconds each
// and closes it with Esc (only while it holds the keyboard), so it waits for an idle, ordinary desktop like
// spotlightkeys-live. Spotlight's bar belongs to whatever owns its layer-23 window, found by opening it once.
enum SpotlightFilterProbe {
    static func report() -> String {
        guard AX.isTrusted else { return "skipped: accessibility not trusted" }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            return "skipped: the screen is locked"
        }
        if let spaces = SpaceWindows.spaces(), !spaces.current.isDisjoint(with: spaces.fullScreen) {
            return "skipped: a full-screen app's desktop is showing"
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= 20 else { return "skipped: the Mac was in use \(Int(idle)) s ago" }
        guard SpotlightKeys.spotlightWindows().isEmpty else { return "skipped: Spotlight is already open" }
        guard let shortcut = Spotlight.searchShortcut() else { return "skipped: Spotlight's shortcut is off" }
        var out: [String] = []
        func say(_ line: String) { out.append(line) }
        let campo = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.campo").first
        let siriApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Siri").first
        say("running: com.apple.campo pid \(campo?.processIdentifier ?? 0) \(campo?.bundleURL?.path ?? "-"); "
            + "com.apple.Siri pid \(siriApp?.processIdentifier ?? 0) \(siriApp?.bundleURL?.path ?? "-")")
        let previous = NSWorkspace.shared.frontmostApplication
        say("frontmost before: \(previous?.bundleIdentifier ?? "-") pid \(previous?.processIdentifier ?? 0)")

        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        var t0 = Date()
        func ms() -> Int { Int(-t0.timeIntervalSinceNow * 1000) }
        func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Int? {
            let start = Date()
            while -start.timeIntervalSinceNow < seconds {
                if condition() { return Int(-start.timeIntervalSinceNow * 1000) }
                pump(0.01)
            }
            return condition() ? Int(seconds * 1000) : nil
        }
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ key: Int, _ down: Bool, _ flags: CGEventFlags, flagsChanged: Bool = false) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            if flagsChanged { event?.type = .flagsChanged }
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        func press(_ key: Int, _ flags: CGEventFlags = []) {
            post(key, true, flags)
            post(key, false, flags)
        }
        func type(_ text: String) {
            for unit in text.utf16 {
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    var chars = [unit]
                    event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &chars)
                    event?.post(tap: .cghidEventTap)
                }
                pump(0.03)
            }
        }
        // The shortcut's key alone: a posted lone ⌘ would reach RubberMAC's own ⌘ tap and open Start.
        func openBar() {
            t0 = Date()
            Spotlight.openSearch(shortcut)
        }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        func focusedAppPid() -> pid_t? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value) == .success,
                  let value else { return nil }
            var p: pid_t = 0
            return AXUIElementGetPid(value as! AXUIElement, &p) == .success ? p : nil
        }
        // The process that owns the bar: whatever owns its layer-23 window, found by opening it once.
        func ownerPids() -> [Int] {
            Set((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { $0[kCGWindowOwnerName as String] as? String == "Siri" && $0[kCGWindowLayer as String] as? Int == Spotlight.windowLayer }
                .compactMap { $0[kCGWindowOwnerPID as String] as? Int }).sorted()
        }
        openBar()
        let discoveredAt = waitFor(2) { !ownerPids().isEmpty }
        let owners = ownerPids()
        let focusedThen = waitFor(1.5) { owners.contains(Int(focusedAppPid() ?? 0)) }
        say("discovery open: window \(discoveredAt.map { "at \($0) ms" } ?? "not within 2 s"), layer-23 owner pids \(owners), "
            + "focused pid \(focusedAppPid() ?? 0)\(focusedThen.map { " (the owner's after \($0) ms)" } ?? "")")
        var discoverySteps: [String] = []
        for i in 1...5 where !SpotlightKeys.spotlightWindows().isEmpty {
            guard owners.contains(Int(focusedAppPid() ?? 0)) else { discoverySteps.append("Esc \(i) not sent: focused pid \(focusedAppPid() ?? 0)"); break }
            press(kVK_Escape)
            let closed = waitFor(0.6) { SpotlightKeys.spotlightWindows().isEmpty }
            discoverySteps.append("Esc \(i): " + (closed.map { "closed after \($0) ms" } ?? "still open"))
        }
        say("discovery close: " + discoverySteps.joined(separator: " | "))
        pump(0.4)
        guard owners.count == 1, let owner = owners.first else { return (out + ["stopped: no single owner pid"]).joined(separator: "\n") }
        let pid = pid_t(owner)
        let ownerApp = NSRunningApplication(processIdentifier: pid)
        say("spotlight ui: pid \(pid) \(ownerApp?.bundleIdentifier ?? "?") \(ownerApp?.bundleURL?.path ?? "?") "
            + "activationPolicy \(ownerApp?.activationPolicy.rawValue ?? -1); same as com.apple.campo: \(pid == campo?.processIdentifier)")
        let appElement = AX.app(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
        }
        func focusedElement() -> AXUIElement? {
            attr(appElement, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement }
        }
        func describe(_ e: AXUIElement) -> String {
            var parts: [String] = [(attr(e, kAXRoleAttribute) as? String) ?? "?"]
            for (key, name) in [("sub", kAXSubroleAttribute), ("id", kAXIdentifierAttribute), ("title", kAXTitleAttribute),
                                ("desc", kAXDescriptionAttribute), ("help", kAXHelpAttribute),
                                ("placeholder", kAXPlaceholderValueAttribute), ("roleDesc", kAXRoleDescriptionAttribute)] {
                if let s = attr(e, name) as? String, !s.isEmpty { parts.append("\(key)=\"\(s.prefix(50))\"") }
            }
            if let v = attr(e, kAXValueAttribute) {
                if let s = v as? String { parts.append("value=\"\(s.prefix(50))\"") } else if let n = v as? NSNumber { parts.append("value=\(n)") }
            }
            for (key, name) in [("selected", kAXSelectedAttribute), ("focused", kAXFocusedAttribute), ("enabled", kAXEnabledAttribute)] {
                if let n = attr(e, name) as? NSNumber, key != "enabled" || !n.boolValue { parts.append("\(key)=\(n.boolValue)") }
            }
            var actions: CFArray?
            if AXUIElementCopyActionNames(e, &actions) == .success, let names = actions as? [String] {
                let shown = names.filter { $0 != "AXScrollToVisible" && $0 != "AXShowMenu" }
                if !shown.isEmpty { parts.append("actions=\(shown.joined(separator: ","))") }
            }
            return parts.joined(separator: " ")
        }
        func dump(_ title: String) -> [String] {
            var lines: [String] = []
            var count = 0
            func walk(_ e: AXUIElement, _ depth: Int) {
                guard count < 400 else { return }
                count += 1
                lines.append(String(repeating: "  ", count: depth) + describe(e))
                guard depth < 14, let children = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
                for child in children.prefix(12) { walk(child, depth + 1) }
                if children.count > 12 { lines.append(String(repeating: "  ", count: depth + 1) + "… +\(children.count - 12) more") }
            }
            let windows = (attr(appElement, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            for window in windows { walk(window, 0) }
            say("--- tree \(title) at \(ms()) ms: \(windows.count) window(s), \(count) nodes")
            out += lines
            return lines
        }
        func diff(_ a: [String], _ b: [String], _ title: String) {
            let removed = a.filter { !b.contains($0) }
            let added = b.filter { !a.contains($0) }
            say("--- diff \(title): -\(removed.count) +\(added.count)")
            for line in removed.prefix(40) { say("- " + line) }
            for line in added.prefix(40) { say("+ " + line) }
        }
        func fieldState() -> String {
            guard let f = focusedElement() else { return "no focused element" }
            return describe(f)
        }
        func windowsOnScreen() -> Bool { !SpotlightKeys.spotlightWindows().isEmpty }
        func closeAll(_ label: String) {
            var steps: [String] = []
            for i in 1...5 where windowsOnScreen() {
                guard waitFor(1, { focusedAppPid() == pid }) != nil else {
                    steps.append("Esc \(i) not sent: focused pid \(focusedAppPid() ?? 0)")
                    break
                }
                press(kVK_Escape)
                let closed = waitFor(0.6) { !windowsOnScreen() }
                steps.append("Esc \(i): " + (closed.map { "closed after \($0) ms" } ?? "still open, focused \(fieldState())"))
            }
            say("close \(label): " + (steps.isEmpty ? "already closed" : steps.joined(separator: " | ")))
            pump(0.4)
        }
        func waitOpen(_ label: String) -> Bool {
            let window = waitFor(2) { windowsOnScreen() }
            let windowAt = ms()
            let focus = waitFor(1.5) { focusedAppPid() == pid }
            let focusAt = ms()
            let field = waitFor(1.5) {
                guard let f = focusedElement(), let role = attr(f, kAXRoleAttribute) as? String else { return false }
                return role == kAXTextFieldRole || role == "AXSearchField" || role == kAXTextAreaRole
            }
            let ownerPids = Set((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { $0[kCGWindowOwnerName as String] as? String == "Siri" }.compactMap { $0[kCGWindowOwnerPID as String] as? Int })
            say("open \(label): window \(window != nil ? "on screen at \(windowAt) ms" : "not within 2 s"), "
                + "focused app = Siri \(focus != nil ? "at \(focusAt) ms" : "no (focused pid \(focusedAppPid() ?? 0))"), "
                + "text field focused \(field != nil ? "at \(ms()) ms" : "no"); CGWindow owner pids \(ownerPids.sorted())")
            return window != nil
        }


        // What Siri's process announces.
        var events: [String] = []
        let recorder = Recorder { name, element in
            events.append("\(ms()) ms \(name) \((self.role(element)))")
        }
        var created: AXObserver?
        let made = AXObserverCreate(pid, { _, element, notification, context in
            guard let context else { return }
            Unmanaged<Recorder>.fromOpaque(context).takeUnretainedValue().handle(notification as String, element)
        }, &created)
        var registered: [String] = []
        if made == .success, let created {
            for name in [kAXWindowCreatedNotification, kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
                         kAXMainWindowChangedNotification, kAXApplicationActivatedNotification, kAXApplicationDeactivatedNotification,
                         kAXValueChangedNotification, kAXUIElementDestroyedNotification, kAXSelectedChildrenChangedNotification,
                         kAXTitleChangedNotification, kAXLayoutChangedNotification] {
                let r = AXObserverAddNotification(created, appElement, name as CFString, Unmanaged.passUnretained(recorder).toOpaque())
                registered.append("\(name)=\(r.rawValue)")
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        }
        say("observer: create \(made.rawValue); add " + registered.joined(separator: " "))
        func flushEvents(_ label: String) {
            say("notifications \(label): \(events.count)")
            for e in events.prefix(40) { say("  " + e) }
            if events.count > 40 { say("  … +\(events.count - 40) more") }
            events.removeAll()
        }

        // 1. Open, type "te", ⌘1, ⌘1 again, ⌘1 again, close step by step.
        openBar()
        if waitOpen("1") {
            flushEvents("open 1")
            let a = dump("A just opened")
            guard focusedAppPid() == pid else {
                say("typing skipped: focused pid \(focusedAppPid() ?? 0)")
                closeAll("1")
                return out.joined(separator: "\n")
            }
            type("te")
            pump(0.4)
            say("after typing te: \(fieldState())")
            let b = dump("B typed te")
            flushEvents("typing")
            if focusedAppPid() == pid {
                let sig = { self.signature(appElement) }
                let before = sig()
                t0 = Date()
                press(kVK_ANSI_1, .maskCommand)
                let changed = waitFor(1.5) { sig() != before }
                say("⌘1 #1: tree changed \(changed.map { "after \($0) ms" } ?? "not within 1.5 s"); field \(fieldState())")
                pump(0.5)
                let c = dump("C after ⌘1")
                diff(b, c, "B → C (⌘1)")
                flushEvents("⌘1 #1")
                let before2 = sig()
                t0 = Date()
                guard focusedAppPid() == pid else { say("second ⌘1 skipped"); closeAll("1"); return out.joined(separator: "\n") }
                press(kVK_ANSI_1, .maskCommand)
                let changed2 = waitFor(1.5) { sig() != before2 }
                say("⌘1 #2: tree changed \(changed2.map { "after \($0) ms" } ?? "not within 1.5 s"); field \(fieldState())")
                pump(0.5)
                let d = dump("D after second ⌘1")
                diff(c, d, "C → D (second ⌘1)")
                diff(b, d, "B → D (does the second ⌘1 go back?)")
                flushEvents("⌘1 #2")
                if focusedAppPid() == pid { press(kVK_ANSI_1, .maskCommand) }
                pump(0.6)
                say("⌘1 #3: field \(fieldState())")
                _ = dump("E after third ⌘1")
            } else {
                say("⌘1 not sent: focused app is pid \(focusedAppPid() ?? 0), not Siri")
            }
            _ = a
        } else {
            say("open 1 failed")
        }
        closeAll("1")
        flushEvents("close 1")

        // 2. Reopen: is the filter remembered? Then look for a control to press instead of ⌘1.
        openBar()
        if waitOpen("2") {
            flushEvents("open 2")
            let f = dump("F reopened")
            say("reopened field: \(fieldState())")
            var candidates: [AXUIElement] = []
            func collect(_ e: AXUIElement, _ depth: Int) {
                guard depth < 14, candidates.count < 20 else { return }
                var actions: CFArray?
                if AXUIElementCopyActionNames(e, &actions) == .success, (actions as? [String])?.contains(kAXPressAction) == true {
                    candidates.append(e)
                }
                for child in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(30) { collect(child, depth + 1) }
            }
            for window in (attr(appElement, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { collect(window, 0) }
            say("pressable: \(candidates.count)")
            for (i, c) in candidates.enumerated() { say("  [\(i)] \(describe(c))") }
            let appsButton = candidates.first { e in
                [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXHelpAttribute].contains { name in
                    ((attr(e, name) as? String) ?? "").localizedCaseInsensitiveContains("app")
                }
            }
            if let appsButton {
                t0 = Date()
                let r = AXUIElementPerformAction(appsButton, kAXPressAction as CFString)
                pump(0.6)
                say("pressed \(describe(appsButton)): result \(r.rawValue); field \(fieldState())")
                let g = dump("G after AX press")
                diff(f, g, "F → G (AX press)")
                flushEvents("AX press")
            } else {
                say("no pressable control mentions apps")
            }
        }
        closeAll("2")
        flushEvents("close 2")

        // 3. ⌘1 the moment Spotlight's process has the keyboard (never before: an early ⌘1 would land in the user's app).
        openBar()
        let shown = waitFor(2) { windowsOnScreen() }
        let windowAt = ms()
        let focused = waitFor(1.5) { focusedAppPid() == pid }
        let focusAt = ms()
        if shown != nil, focused != nil {
            let before = signature(appElement)
            press(kVK_ANSI_1, .maskCommand)
            let sentAt = ms()
            let changed = waitFor(1.5) { signature(appElement) != before }
            say("open 3: window at \(windowAt) ms, Spotlight focused at \(focusAt) ms, ⌘1 sent at \(sentAt) ms, "
                + "took effect \(changed.map { "\($0) ms later" } ?? "not within 1.5 s"); field \(fieldState())")
            _ = dump("H ⌘1 as soon as focused")
        } else {
            say("open 3: window \(shown != nil), focused \(focused != nil); ⌘1 not sent")
        }
        closeAll("3")
        flushEvents("open 3")

        if let created { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes) }

        pump(0.3)
        say("frontmost after: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
        if windowsOnScreen() { say("note: Spotlight was left open") }
        return out.joined(separator: "\n")
    }

    static func role(_ e: AXUIElement) -> String {
        var value: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &value) == .success ? (value as? String ?? "?") : "?"
        var id: CFTypeRef?
        let i = AXUIElementCopyAttributeValue(e, kAXIdentifierAttribute as CFString, &id) == .success ? " id=\(id as? String ?? "")" : ""
        return r + i
    }

    // A cheap fingerprint of the bar: its windows' sizes and the focused element's value and placeholder.
    static func signature(_ app: AXUIElement) -> String {
        var parts: [String] = []
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success {
            for w in (value as? [AXUIElement]) ?? [] {
                parts.append(AX.frame(of: w).map { "\(Int($0.width))x\(Int($0.height))" } ?? "?")
                var kids: CFTypeRef?
                if AXUIElementCopyAttributeValue(w, kAXChildrenAttribute as CFString, &kids) == .success {
                    parts.append("\((kids as? [AXUIElement])?.count ?? 0)")
                }
            }
        }
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused {
            let f = focused as! AXUIElement
            for name in [kAXValueAttribute, kAXPlaceholderValueAttribute, kAXDescriptionAttribute] {
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(f, name as CFString, &v) == .success { parts.append("\(v as? String ?? "")") }
            }
        }
        return parts.joined(separator: "|")
    }

    final class Recorder {
        let onEvent: (String, AXUIElement) -> Void
        init(_ onEvent: @escaping (String, AXUIElement) -> Void) { self.onEvent = onEvent }
        func handle(_ name: String, _ element: AXUIElement) { onEvent(name, element) }
    }
}

// --selftest spotlightfilter-typing [external]: whether a first letter typed 40, 60, 80 or 100 ms after the shortcut
// (s, a, f, 60 ms apart) survives Spotlight's switch to apps, three times each. With the feature on in this process
// its keyboard tap can't see these keys (a tap never sees its own process's), so this measures the switch alone and
// when the ⌘1 goes out; "external" leaves the feature to spotlightfilter-host in another process, whose tap does see
// them. Keys only while Spotlight holds the keyboard, read from the system without asking Spotlight, so they go out
// on time. Gated like the probe.
extension SpotlightFilterProbe {
    static func typingReport(external: Bool) -> String {
        guard AX.isTrusted else { return "skipped: accessibility not trusted" }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else { return "skipped: the screen is locked" }
        if let spaces = SpaceWindows.spaces(), !spaces.current.isDisjoint(with: spaces.fullScreen) { return "skipped: a full-screen app's desktop is showing" }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= 20 else { return "skipped: the Mac was in use \(Int(idle)) s ago" }
        guard SpotlightKeys.spotlightWindows().isEmpty else { return "skipped: Spotlight is already open" }
        guard let shortcut = Spotlight.searchShortcut() else { return "skipped: Spotlight's shortcut is off" }
        guard let ui = NSRunningApplication.runningApplications(withBundleIdentifier: SpotlightFilter.uiBundleID).first else { return "skipped: no \(SpotlightFilter.uiBundleID)" }
        let pid = ui.processIdentifier
        var out: [String] = []
        func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: s)) }
        func waitFor(_ s: TimeInterval, _ c: () -> Bool) -> Bool {
            let start = Date()
            while -start.timeIntervalSinceNow < s { if c() { return true }; pump(0.002) }
            return c()
        }
        let source = CGEventSource(stateID: .hidSystemState)
        func holds() -> Bool {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
                  let value else { return false }
            var focused: pid_t = 0
            return AXUIElementGetPid(value as! AXUIElement, &focused) == .success && focused == pid
        }
        let appElement = AX.app(pid)
        AXUIElementSetMessagingTimeout(appElement, 1)
        func value() -> String {
            var e: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &e) == .success, let e else { return "?" }
            return AX.string(e as! AXUIElement, kAXValueAttribute) ?? "?"
        }
        func back() -> Bool {
            func find(_ element: AXUIElement, _ depth: Int) -> Bool {
                if AX.string(element, kAXRoleAttribute) == kAXButtonRole, AX.string(element, kAXDescriptionAttribute) == "Back" { return true }
                guard depth < 4 else { return false }
                var children: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success else { return false }
                return ((children as? [AXUIElement]) ?? []).prefix(8).contains { find($0, depth + 1) }
            }
            return AX.windows(of: pid).contains { find($0, 0) }
        }
        // Key-downs this process posts, the shortcut's included, to set against the ones the host's tap saw.
        var posted = 0
        func key(_ code: Int) {
            posted += 1
            for down in [true, false] {
                let ev = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
                ev?.flags = []
                ev?.post(tap: .cghidEventTap)
            }
        }
        func close() {
            for _ in 1...4 where holds() {
                key(kVK_Escape)
                _ = waitFor(0.8) { !holds() }
            }
            _ = waitFor(3) { SpotlightKeys.spotlightWindows().isEmpty }
            pump(0.6)
        }
        let feature: SpotlightFilter? = external ? nil : SpotlightFilter()
        feature?.isOn = { true }
        feature?.start()
        guard external || feature?.watcher != nil else { return "FAIL couldn't watch" }
        func presses() -> Int { feature?.watcher?.openings.presses ?? 0 }
        var tally: [Int: (kept: Int, trials: Int)] = [:]
        for delay in [40, 60, 80, 100] {
            for _ in 1...3 {
                let before = presses()
                let t0 = Date()
                func ms() -> Int { Int(-t0.timeIntervalSinceNow * 1000) }
                Spotlight.openSearch(shortcut)
                posted += 1
                var pressedAt: Int?
                while ms() < delay {
                    if pressedAt == nil, presses() > before { pressedAt = ms() }
                    pump(0.002)
                }
                var typed: [String] = []
                for code in [kVK_ANSI_S, kVK_ANSI_A, kVK_ANSI_F] {
                    if holds() { key(code); typed.append("\(ms())") } else { typed.append("held") }
                    let until = Date(timeIntervalSinceNow: 0.06)
                    while Date() < until {
                        if pressedAt == nil, presses() > before { pressedAt = ms() }
                        pump(0.002)
                    }
                }
                _ = waitFor(1) { back() }
                pump(0.5)
                if pressedAt == nil, presses() > before { pressedAt = -1 }
                let v = value()
                let full = v.count == 3
                let entry = tally[delay] ?? (0, 0)
                tally[delay] = (entry.kept + (full ? 1 : 0), entry.trials + 1)
                let press = external ? "by the host" : pressedAt.map { $0 < 0 ? "after the keys" : "at \($0) ms" } ?? "not sent"
                out.append("first key \(delay) ms: ⌘1 \(press)\(external ? "" : " (\(presses() - before))"); "
                           + "keys at \(typed.joined(separator: ",")); apps only \(back()); field \"\(v)\" \(full ? "all kept" : "LOST")")
                close()
            }
        }
        feature?.isOn = { false }
        feature?.apply()
        out.append("key-downs posted: \(posted)")
        out.append("tally: " + tally.sorted { $0.key < $1.key }.map { "\($0.key) ms \($0.value.kept)/\($0.value.trials) all kept" }.joined(separator: ", "))
        if !SpotlightKeys.spotlightWindows().isEmpty { out.append("note: Spotlight was left open") }
        return out.joined(separator: "\n")
    }
}
