import AppKit

extension WindowReset {
    static let sectionTitle = "Lost Windows"
    static let bringBackTitle = "Bring Windows Back Onto the Screens"
    static let bringBackAbout = "For windows mostly off the screens, or too big for theirs"
    static let otherDesktops = "Only this desktop's; for another desktop, switch to it and press again"
    static let forgetTitle = "Forget an App's Window Sizes…"
    static let forgetAbout = "For an app whose windows open in the wrong place or size; if it's open, it quits and opens again"
    static let containersNote = "Apps like Photos and Preview keep theirs where only Full Disk Access lets RubberMAC look"
    static let fullDiskAccessTitle = "Turn On Full Disk Access…"
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

extension AppDelegate {
    // From the values given rather than WindowReset's, so the self-test can build each state.
    func windowResetSections(_ facts: SettingsFacts, bringBackNote: String?, forgetNote: String?, bringingBack: Bool,
                             forgetting: Bool) -> [SettingsSection] {
        [SettingsSection(title: WindowReset.sectionTitle, rows: [
            // Without Accessibility the press brings up macOS's question, so the panel gets out of the way.
            button(WindowReset.bringBackTitle, "Bring Back", #selector(bringWindowsBack),
                   note: (bringBackNote ?? WindowReset.bringBackAbout) + "\n" + WindowReset.otherDesktops,
                   enabled: !bringingBack, closes: !facts.permissions.accessibility),
            button(WindowReset.forgetTitle, "Choose", #selector(chooseAppToForget(_:)), note: forgetNote ?? WindowReset.forgetAbout,
                   enabled: !forgetting),
        ])]
    }

    @objc func bringWindowsBack() {
        guard AX.isTrusted else { AX.requestAccess(); return }
        WindowReset.shared.bringBack { [weak self] in self?.settingsPanel.reloadIfShown() }
    }

    // The list drops down from the button, made when it's pressed: it reads the preferences files.
    @objc func chooseAppToForget(_ sender: Any?) {
        let places = WindowResetSavedFrames.realPlaces()
        let menu = windowResetMenu(WindowResetSavedFrames.scan(places, resolve: WindowResetSavedFrames.installedApp),
                                   containersRead: places.containers != nil)
        if let button = sender as? NSView {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 4 : -4), in: button)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    func windowResetMenu(_ scan: WindowResetSavedFrames.Scan, containersRead: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for app in scan.apps {
            let item = action(app.name, #selector(forgetAppWindowSizes(_:)))
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if scan.apps.isEmpty { menu.addItem(infoItem("No app has saved window sizes")) }
        // A sandboxed app keeps its window sizes in its container, which macOS opens only to Full Disk Access.
        if !containersRead || scan.refused {
            menu.addItem(.separator())
            menu.addItem(infoItem(WindowReset.containersNote))
            menu.addItem(action(WindowReset.fullDiskAccessTitle, #selector(openFullDiskAccessSettings)))
        }
        return menu
    }

    @objc func forgetAppWindowSizes(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? WindowResetSavedFrames.App else { return }
        let isOpen = !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
        // A menu-bar app isn't in front by itself, and the question would open behind.
        NSApp.activate(ignoringOtherApps: true)
        guard WindowResetForget.confirmation(for: app, isOpen: isOpen).runModal() == .alertFirstButtonReturn else { return }
        WindowReset.shared.forget(app, isOpen: isOpen) { [weak self] in self?.settingsPanel.reloadIfShown() }
        settingsPanel.reloadIfShown()
    }

    @objc func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(WindowReset.fullDiskAccessURL)
    }
}
