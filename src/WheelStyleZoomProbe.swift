import AppKit
import Carbon.HIToolbox

// --selftest wheelzoom-probe: what ⌘ + wheel would find in Claude right now, with no UI and nothing pressed: the app in
// front, every running Claude, each one's zoom items as Accessibility reads them (with the actions and enabled state
// each shows), and what the cache answers over time.
extension WheelStyle {

    // How much of a Claude window Accessibility shows: Chromium builds the web page's tree only once asked.
    static func treeSummary(_ pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var value: CFTypeRef?
        var manual: CFTypeRef?
        let manualError = AXUIElementCopyAttributeValue(app, "AXManualAccessibility" as CFString, &manual)
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return "no windows" }
        var parts: [String] = ["AXManualAccessibility \(manualError.rawValue) \(manual.map { "\($0)" } ?? "-")"]
        for window in windows {
            var nodes = 0, webAreas = 0, texts = 0
            var sample: [String] = []
            func walk(_ element: AXUIElement, _ depth: Int) {
                nodes += 1
                guard nodes < 4000, depth < 40 else { return }
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                let name = role as? String ?? ""
                if name == "AXWebArea" { webAreas += 1 }
                if name == "AXStaticText" {
                    texts += 1
                    if sample.count < 3, let frame = AX.frame(of: element), frame.height > 0 { sample.append("\(Int(frame.width))x\(Int(frame.height))") }
                }
                var children: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                for child in (children as? [AXUIElement]) ?? [] { walk(child, depth + 1) }
            }
            walk(window, 0)
            parts.append("window \(AX.frame(of: window).map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"): \(nodes) nodes, \(webAreas) web areas, \(texts) texts \(sample)")
        }
        return parts.joined(separator: "; ")
    }
    static func zoomProbeReport() -> String {
        var lines: [String] = []
        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        let front = NSWorkspace.shared.frontmostApplication
        lines.append("front: \(front?.bundleIdentifier ?? "-") pid \(front?.processIdentifier ?? 0)")
        lines.append("secure input: \(IsSecureEventInputEnabled() ? "on" : "off")")
        let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        func sourceID(_ source: TISInputSource?) -> String {
            guard let source, let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "-" }
            return Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String
        }
        lines.append("input source: \(sourceID(source)), latin layout: \(sourceID(ascii))")
        let claudes = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.anthropic.claudefordesktop" }
        let formatter = ISO8601DateFormatter()
        for app in claudes {
            let pid = app.processIdentifier
            lines.append("claude pid \(pid): launched \(app.launchDate.map { formatter.string(from: $0) } ?? "-"), active \(app.isActive), "
                         + "finished launching \(app.isFinishedLaunching), path \(app.bundleURL?.path ?? "-")")
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 1)
            var bar: CFTypeRef?
            let barError = AXUIElementCopyAttributeValue(element, kAXMenuBarAttribute as CFString, &bar)
            var count = 0
            if barError == .success, let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() {
                var children: CFTypeRef?
                AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
                count = (children as? [AXUIElement])?.count ?? 0
            }
            lines.append("  menu bar: AX error \(barError.rawValue), \(count) top menus")
            let start = ProcessInfo.processInfo.systemUptime
            let entries = ZoomMenus.read(pid) ?? []
            let took = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
            lines.append("  read: \(entries.count) items in \(took) ms")
            for entry in entries where ZoomMenus.looksLikeZoom(entry.item) {
                let item = entry.item
                var actions: CFArray?
                var enabled: CFTypeRef?
                if let element = item.element {
                    AXUIElementCopyActionNames(element, &actions)
                    AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
                }
                lines.append("    menu \(entry.menu): \"\(item.title)\" key \(item.key.map { "\"\($0)\"" } ?? "nil") modifiers \(item.modifiers), "
                             + "actions \((actions as? [String]) ?? []), enabled \(enabled.map { "\($0)" } ?? "-")")
            }
            lines.append("  tree: \(treeSummary(pid))")
            if let menu = ZoomMenus.pick(entries) {
                lines.append("  pick: \(menu.zoomIn.title) \(menu.zoomIn.shortcut) / \(menu.zoomOut.title) \(menu.zoomOut.shortcut)")
            } else {
                lines.append("  pick: none")
            }
        }
        if claudes.isEmpty { lines.append("no Claude running") }

        // The cache as the wheel sees it, for the app in front.
        if let front {
            let cache = ZoomMenuCache()
            var reports: [String] = []
            cache.report = { reports.append($0) }
            func describe(_ lookup: ZoomLookup) -> String {
                switch lookup {
                case .reading: return "reading"
                case .none: return "none"
                case .found(let menu): return "found \(menu.zoomIn.shortcut)/\(menu.zoomOut.shortcut)"
                }
            }
            var seen: [String] = []
            let start = Date()
            for wait in [0.0, 0.05, 0.1, 0.25, 0.5, 1.0] {
                pump(wait)
                seen.append("\(Int(-start.timeIntervalSinceNow * 1000)) ms \(describe(cache.lookup(front.processIdentifier)))")
            }
            lines.append("cache for front pid \(front.processIdentifier): " + seen.joined(separator: ", "))
            lines += reports.map { "  report: \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}
