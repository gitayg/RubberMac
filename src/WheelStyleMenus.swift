import AppKit

// --selftest wheelstyle menus: what the zoom finds in each running app's menus on this Mac, and whether each item takes
// the press a step makes, read through Accessibility the way the feature reads them. Reads only: no menu is opened,
// pressed or posted to.
enum WheelStyleMenus {
    // The apps the zoom is meant for; each must be found when it's running.
    static let expected: [String: String] = [
        "com.google.Chrome": "Google Chrome", "com.anthropic.claudefordesktop": "Claude", "com.apple.Terminal": "Terminal",
        "com.apple.Safari": "Safari", "com.apple.TextEdit": "TextEdit",
    ]

    static func report() -> String {
        guard AX.isTrusted else { return "skipped: accessibility not trusted" }
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        // The item lists Accessibility's press among its actions.
        func pressable(_ item: ZoomItem) -> Bool {
            var names: CFArray?
            guard let element = item.element, AXUIElementCopyActionNames(element, &names) == .success else { return false }
            return (names as? [String])?.contains(kAXPressAction) == true
        }
        func takes(_ item: ZoomItem) -> String { pressable(item) ? "pressable" : "NOT PRESSABLE" }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        var seen: Set<String> = []
        for app in apps {
            let id = app.bundleIdentifier ?? "?"
            let name = "\(app.localizedName ?? id) (\(id), pid \(app.processIdentifier))"
            if let reason = WheelZoom.leftAlone(id) {
                lines.append("\(name): left alone, \(reason)")
                continue
            }
            let start = ProcessInfo.processInfo.systemUptime
            let entries = ZoomMenus.read(app.processIdentifier) ?? []
            let took = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
            // Only items that look like a zoom are named: a Window menu lists window titles, which stay out of the report.
            let candidates = entries.filter { ZoomMenus.looksLikeZoom($0.item) }.map { "\($0.item.title) \($0.item.shortcut) [menu \($0.menu)]" }
            let menu = ZoomMenus.pick(entries)
            lines.append("\(name): \(entries.count) items read in \(took) ms; looks like zoom: "
                         + (candidates.isEmpty ? "nothing" : candidates.joined(separator: ", ")) + " → "
                         + (menu.map { "\($0.zoomIn.title) \($0.zoomIn.shortcut) \(takes($0.zoomIn)); \($0.zoomOut.title) \($0.zoomOut.shortcut) \(takes($0.zoomOut))" }
                            ?? "no zoom, ⌘ + wheel goes by untouched"))
            if let expectedName = expected[id] {
                seen.insert(id)
                check(menu.map { pressable($0.zoomIn) && pressable($0.zoomOut) } == true,
                      "\(expectedName) (pid \(app.processIdentifier)): Zoom In and Zoom Out found, each pressable through Accessibility")
            }
        }
        for (id, name) in expected.sorted(by: { $0.value < $1.value }) where !seen.contains(id) {
            lines.append("\(name) isn't running, so it wasn't read")
        }
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }
}
