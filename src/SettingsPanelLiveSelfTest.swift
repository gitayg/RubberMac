import AppKit
import Carbon.HIToolbox

// --selftest settings-live: the real panel under a real menu-bar icon, in the signed app. A click opens it and focus lands
// on the sidebar, ↓ moves the page, the permissions read for real without asking, Esc closes it and gives the front back,
// and a click on the icon closes it for good. Posts clicks and keys, then puts the pointer back, so it waits for an idle,
// ordinary desktop. Changes no setting; the pictures show only the panel.
extension SettingsPanel {
    static func liveSelfTestReport(folder: URL) -> String {
        guard AX.isTrusted else { return "skipped: accessibility not trusted" }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            return "skipped: the screen is locked"
        }
        // On a full-screen app's Space the menu bar is hidden, so there's no icon to click.
        if let spaces = SpaceWindows.spaces(), !spaces.current.isDisjoint(with: spaces.fullScreen) {
            return "skipped: a full-screen app's desktop is showing; switch to an ordinary desktop and run again"
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= 20 else { return "skipped: the Mac was in use \(Int(idle)) s ago; run it after 20 s without typing or the mouse" }

        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func pump(_ seconds: TimeInterval) {
            let until = Date(timeIntervalSinceNow: seconds)
            while let event = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        }
        func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
            let start = Date()
            while -start.timeIntervalSinceNow < seconds {
                if condition() { return true }
                pump(0.02)
            }
            return condition()
        }

        let delegate = AppDelegate(lockWarning: LockWarning(timeoutOverride: nil))
        delegate.setUpStatusItem()
        delegate.setUpSettingsPanel()
        let panel = delegate.settingsPanel
        let savedPage = Settings.settingsPage
        panel.start(on: nil)
        let saved = CGEvent(source: nil)?.location ?? .zero
        func finish() -> String {
            panel.close()
            pump(0.4)
            NSStatusBar.system.removeStatusItem(delegate.statusItem)
            Settings.settingsPage = savedPage
            CGWarpMouseCursorPosition(saved)
            return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
        }

        func iconPoint() -> CGPoint? {
            guard let frame = delegate.statusItem.button?.window?.frame, frame.width > 0,
                  NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return nil }
            return CGPoint(x: frame.midX, y: NSScreen.screens[0].frame.height - frame.midY)
        }
        let source = CGEventSource(stateID: .hidSystemState)
        func click(_ point: CGPoint) {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            pump(0.15)
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                pump(0.08)
            }
        }
        func press(_ key: Int) {
            for down in [true, false] {
                CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)?.post(tap: .cghidEventTap)
                pump(0.05)
            }
        }
        // From the window server, as ScreenCaptureKit would raise macOS's own question about capturing the screen.
        func picture(_ name: String) {
            guard let number = panel.root.window?.windowNumber, let image = SpaceWindows.picture(of: CGWindowID(number)) else {
                return lines.append("no picture of \(name)")
            }
            // Down the middle of the sidebar: search, rows, Quit. One colour there means something is painted over it.
            let bitmap = NSBitmapImageRep(cgImage: image)
            let colours = Set((0..<bitmap.pixelsHigh).compactMap { bitmap.colorAt(x: bitmap.pixelsWide / 8, y: $0) }.map {
                [$0.redComponent, $0.greenComponent, $0.blueComponent].map { Int($0 * 32) }
            })
            check(colours.count > 8, "\(name): the sidebar reaches the screen (\(colours.count) colours down it)")
            let url = folder.appendingPathComponent("live-\(name).png")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            lines.append("     picture: \(url.path)")
        }

        // The menu bar places a new icon a moment after it's made.
        pump(1)
        guard waitFor(5, { iconPoint() != nil }), let icon = iconPoint() else {
            check(false, "the icon came up in the menu bar")
            return finish()
        }
        // A full menu bar hides new icons, behind the notch on a laptop's screen.
        guard delegate.statusItem.button?.window?.occlusionState.contains(.visible) == true else {
            lines.append("skipped: the test's own menu-bar icon is hidden (a full menu bar, or behind the notch), "
                         + "at \(delegate.statusItem.button?.window?.frame ?? .zero)")
            return finish()
        }
        guard let previous = NSWorkspace.shared.frontmostApplication else {
            check(false, "something is in front to come back to")
            return finish()
        }

        click(icon)
        guard waitFor(3, { panel.isShown }) else {
            check(false, "a click on the icon opens the panel (icon at \(Int(icon.x)), \(Int(icon.y)))")
            return finish()
        }
        check(true, "a click on the icon opens the panel")
        pump(0.5)
        check(waitFor(2) { NSApp.isActive && panel.root.window?.isKeyWindow == true }, "it comes up as the key window")
        check(panel.root.window?.firstResponder === panel.sidebar.table, "focus is on the sidebar")
        if let frame = panel.root.window?.frame, let screen = panel.root.window?.screen {
            check(screen.frame.contains(frame), "it's all on the screen (\(Int(frame.width)) × \(Int(frame.height)) on a \(Int(screen.frame.width)) × \(Int(screen.frame.height)) screen)")
        }
        picture("first-page")

        let first = panel.shown
        press(kVK_DownArrow)
        check(waitFor(1.5) { panel.shown != first }, "↓ moves to the next page (\(first ?? "none") → \(panel.shown ?? "none"))")

        panel.choose(AppDelegate.permissionsPageID)
        let used = Settings.finderPathPasteEnabled || Settings.finderAddressBarEnabled
        check(waitFor(5) { delegate.permissionsChecked != nil && (!used || delegate.finderState != nil) }, "the Permissions page reads the permissions")
        let reading = delegate.permissionReading()
        check(reading.accessibility == AX.isTrusted && reading.screenRecording == ScreenText.hasPermission, "what it shows is what macOS says")
        lines.append("     \(reading.logLine)")
        let firstRead = delegate.permissionsChecked
        pump(1.1)
        delegate.checkPermissionsAgain()
        check(waitFor(5) { delegate.permissionsChecked != firstRead }, "Check Again reads them again")
        check(panel.isShown && NSApp.isActive, "reading them raises no question: the panel stays up and in front")
        pump(0.5)
        picture("permissions")

        panel.choose(AppDelegate.eyeCameraPageID)
        let installed = EyeCamera.isAvailable
        let eyeRows = { delegate.settingsPages().first { $0.id == AppDelegate.eyeCameraPageID }?.rows.map(\.title) ?? [] }
        check(waitFor(5) { panel.shown == AppDelegate.eyeCameraPageID && (!installed || eyeRows().contains("Recolour My Eyes on the Virtual Camera")) },
              "the Eye Color Camera page shows its controls (OBS Virtual Camera \(installed ? "found" : "not installed"))")
        if installed { check(waitFor(10) { delegate.eyeCamera.cameras.contains { !$0.virtual } }, "and lists a real camera to read from") }
        pump(0.5)
        picture("eye-camera")

        press(kVK_Escape)
        check(waitFor(2) { !panel.isShown }, "Esc closes it")
        if previous != NSRunningApplication.current {
            check(waitFor(2) { NSWorkspace.shared.frontmostApplication == previous }, "and the app that was in front comes back")
        }

        pump(0.5)
        click(icon)
        guard waitFor(3, { panel.isShown }) else {
            check(false, "it opens again")
            return finish()
        }
        pump(0.5)
        click(icon)
        check(waitFor(2) { !panel.isShown }, "a click on the icon closes it")
        pump(0.7)
        check(!panel.isShown, "and the same click doesn't open it again")
        return finish()
    }
}
