import AppKit

// The windows Bring Back looks at, through Accessibility: each app's ordinary windows on the desktop showing now (one
// per screen with separate Spaces). Windows on other desktops are left as they are: kAXWindowsAttribute doesn't list
// them (the live self-test measures it), and the window server's list of what's on the current desktops is checked too,
// for an app whose Accessibility lists more.
enum WindowResetMover {
    struct App {
        let pid: pid_t
        let name: String
    }

    // An app name and a frame, never a title: the note and the log name apps only.
    struct Window {
        let element: AXUIElement
        let app: String
        let frame: CGRect
    }

    struct Outcome: Equatable {
        var checked = 0
        // The app of each window found lost; once moved, of each now on screen and of each still lost (too big for an
        // app that won't shrink it, or an app that won't let it move).
        var lost: [String] = []
        var moved: [String] = []
        var stuck: [String] = []
    }

    // A hung app would otherwise hold each question for the 6 s default.
    private static let timeout: Float = 1

    // Apps with a Dock icon that aren't hidden (a hidden app's windows show on no desktop). Not RubberMAC itself:
    // Accessibility calls into it need its main thread free.
    static func appsInUse() -> [App] {
        let me = getpid()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isHidden, app.processIdentifier != me else { return nil }
            return App(pid: app.processIdentifier, name: app.localizedName ?? app.bundleIdentifier ?? "An app")
        }
    }

    static func ordinaryWindows(of apps: [App]) -> [Window] {
        let showing = onCurrentDesktops(Set(apps.map(\.pid)))
        var result: [Window] = []
        for app in apps {
            let element = AX.app(app.pid)
            AXUIElementSetMessagingTimeout(element, timeout)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else { continue }
            for window in value as? [AXUIElement] ?? [] {
                AXUIElementSetMessagingTimeout(window, timeout)
                guard isOrdinary(window), let frame = AX.frame(of: window), frame.width > 0, frame.height > 0 else { continue }
                if let showing, let id = AX.windowID(of: window), !showing.contains(id) { continue }
                result.append(Window(element: window, app: app.name, frame: frame))
            }
        }
        return result
    }

    // apply false only counts, for the live self-test's look at your windows.
    static func bringBack(_ windows: [Window], screens: [ScreenArea], apply: Bool) -> Outcome {
        var outcome = Outcome(checked: windows.count)
        for window in windows {
            guard let target = WindowResetGeometry.fixed(window.frame, screens: screens) else { continue }
            outcome.lost.append(window.app)
            guard apply else { continue }
            AX.setFrame(window.element, target)
            if WindowResetGeometry.problem(AX.frame(of: window.element) ?? window.frame, screens: screens) == nil {
                outcome.moved.append(window.app)
            } else {
                outcome.stuck.append(window.app)
            }
        }
        return outcome
    }

    // A standard window: not a sheet, panel or dialog, and neither minimized nor full screen.
    private static func isOrdinary(_ window: AXUIElement) -> Bool {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute, "AXFullScreen"]
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(window, names as CFArray, [], &values) == .success,
              let list = values as? [AnyObject], list.count == names.count else { return false }
        return list[0] as? String == kAXWindowRole && list[1] as? String == kAXStandardWindowSubrole
            && (list[2] as? NSNumber)?.boolValue != true && (list[3] as? NSNumber)?.boolValue != true
    }

    // The window server's windows on the Spaces showing now; nil when it can't say.
    private static func onCurrentDesktops(_ pids: Set<pid_t>) -> Set<CGWindowID>? {
        guard let spaces = SpaceWindows.spaces(), let windows = SpaceWindows.windows(of: pids, on: spaces.current) else { return nil }
        return Set(windows.map(\.id))
    }
}

extension WindowResetMover.Outcome {
    var note: String {
        guard !lost.isEmpty else { return "All windows were on screen" }
        let text = moved.isEmpty ? "No window could be moved" : "Moved \(moved.count) window\(moved.count == 1 ? "" : "s")"
        return stuck.isEmpty ? text : "\(text); \(stuck.count) wouldn't move or shrink (\(Self.names(stuck)))"
    }

    var logLine: String {
        guard !lost.isEmpty else { return "window reset: all \(checked) windows on the desktop showing were on screen" }
        var line = "window reset: moved \(moved.count) of \(checked) windows"
        if !moved.isEmpty { line += " (\(Self.names(moved)))" }
        if !stuck.isEmpty { line += "; \(stuck.count) wouldn't move or shrink (\(Self.names(stuck)))" }
        return line
    }

    private static func names(_ apps: [String]) -> String {
        Set(apps).sorted().joined(separator: ", ")
    }
}
