import AppKit
import ServiceManagement

// What the pages depend on besides Settings, gathered so the self-test can build them under any condition.
struct SettingsFacts {
    var version = "0"
    var update = Updater.State.idle
    var login = SMAppService.Status.notRegistered
    var saverSummary = ""
    var displays: [Brightness.Display] = []
    var levels: [CGDirectDisplayID: Int] = [:]
    var camera: CameraArea?
    var cameraConnected = false
    var altTab = AltTabMode.apps
    var finderDenied = false
    var fixerAvailable = true
    var mice: [String] = []
    var setupName = ""
    var hasSavedLayout = false
    var needsAccess = false
    var permissions = PermissionCheck(accessibility: true, screenRecording: true, finder: .on, finderUsed: true)
    var permissionsChecked: Date?
    var eye = EyeFacts()

    var allSoftware: Bool { !displays.isEmpty && displays.allSatisfy { !$0.hardware } }
}

// The Eye Color Camera's side of the facts.
struct EyeFacts {
    var installed = false
    var isOn = false
    var status = "Off"
    var hasError = false
    var colors = ["blue"]
    var color = "blue"
    var strength = 0.6
    var cameras: [EyeCamera.Camera] = []
    var cameraIndex = 0
    var separateApp = false
    // On with a picture going to the virtual camera, which is what the preview shows.
    var isStreaming = false
    var previewAccess = EyePreview.Access.allowed
    var previewProblem: String?
}

extension AppDelegate {
    static let permissionsPageID = "permissions"
    static let eyeCameraPageID = "eyecamera"
    private static let settingsAppURL = "x-apple.systempreferences:com.apple.preference.security?"

    func setUpSettingsPanel() {
        settingsPanel.pages = { [weak self] in self?.settingsPages() ?? [] }
        settingsPanel.start(on: Settings.settingsPage)
        settingsPanel.onChoosePage = { Settings.settingsPage = $0 }
        settingsPanel.onOpen = { [weak self] in self?.refreshBrightnessRows() }
        settingsPanel.onClose = { [weak self] in self?.updateEyePreview() }
        settingsPanel.onShowPage = { [weak self] id in
            if id == Self.permissionsPageID { self?.readPermissions(logAlways: false) }
            if id == Self.eyeCameraPageID { self?.showingEyeCamera() }
            self?.updateEyePreview()
        }
        updater.onChange = { [weak self] in self?.settingsPanel.reloadIfShown() }
    }

    @objc func toggleSettingsPanel() {
        guard let button = statusItem.button else { return }
        settingsPanel.toggle(from: button)
    }

    // Levels come from the monitors in the background, so the page first shows the last ones and then corrects them.
    private func refreshBrightnessRows() {
        let software = brightness.allSoftware
        brightness.refresh { [weak self] in
            guard let self else { return }
            if sliders.map(\.displayID) == brightness.displays.map(\.id), software == brightness.allSoftware {
                sliders.forEach { $0.show(self.brightness.levels[$0.displayID]) }
            } else {
                settingsPanel.reloadIfShown()
            }
        }
    }

    // Lists the cameras so the page can offer them.
    private func showingEyeCamera() {
        guard EyeCamera.isAvailable else { return }
        eyeCamera.prepare()
        eyeSeparateApp = EyeCamera.separateAppRunning()
        settingsPanel.reloadIfShown()
    }

    // Only while someone can see it: the page open, with a picture going to the virtual camera.
    func updateEyePreview() {
        let wanted = settingsPanel.isShown && settingsPanel.shown == Self.eyeCameraPageID && eyeCamera.state == .on
            && EyePreview.access == .allowed
        if wanted { eyePreview.start() } else { eyePreview.stop() }
    }

    func currentFacts() -> SettingsFacts {
        var facts = SettingsFacts()
        facts.version = updater.current
        facts.update = updater.state
        facts.login = SMAppService.mainApp.status
        facts.saverSummary = saverSummary()
        facts.displays = brightness.displays
        facts.levels = brightness.levels
        facts.camera = Settings.cameraArea
        facts.cameraConnected = Settings.cameraArea.flatMap { WindowSnapper.screen(of: $0) } != nil
        facts.altTab = Settings.altTabMode
        facts.finderDenied = (Settings.finderPathPasteEnabled && finderPaste.isDenied)
            || (Settings.finderAddressBarEnabled && finderBar.isDenied)
        facts.fixerAvailable = TextFixer.isAvailable
        facts.mice = mice.mice
        facts.setupName = layouts.setupName
        facts.hasSavedLayout = layouts.hasSavedLayout
        facts.needsAccess = needsAccess
        facts.permissions = permissionReading()
        facts.permissionsChecked = permissionsChecked
        facts.eye = EyeFacts(installed: EyeCamera.isAvailable, isOn: eyeCamera.isOn,
                             status: eyeCamera.statusLine, hasError: eyeCamera.errorMessage != nil, colors: eyeCamera.colors,
                             color: eyeCamera.color, strength: eyeCamera.strength, cameras: eyeCamera.cameras,
                             cameraIndex: eyeCamera.cameraIndex, separateApp: eyeSeparateApp, isStreaming: eyeCamera.state == .on,
                             previewAccess: EyePreview.access, previewProblem: eyePreview.problem)
        return facts
    }

    func settingsPages() -> [SettingsPage] { settingsPages(currentFacts()) }

    func settingsPages(_ facts: SettingsFacts) -> [SettingsPage] {
        [generalPage(facts), screenSaverPage(facts), brightnessPage(facts), windowsPage(facts), keyboardPage(facts),
         writingPage(facts), eyeCameraPage(facts), mousePage(facts), layoutsPage(facts), permissionsPage(facts)]
    }

    private func generalPage(_ facts: SettingsFacts) -> SettingsPage {
        var updates = [SettingsRow(title: "Version \(facts.version)", note: nil, control: .none)]
        if case .available(let release) = facts.update {
            updates.append(button("Install \(release.version) and Relaunch", "Install", #selector(installUpdate), closes: true))
        }
        updates.append(button("Check for Updates", "Check", #selector(checkForUpdates), enabled: !facts.update.isBusy))
        updates.append(toggle("Install Updates Automatically", #selector(toggleAutoUpdate), on: Settings.autoUpdate))
        if let status = Self.updateStatus(facts.update) { updates.append(.note(status)) }
        let login = toggle("Open at Login", #selector(toggleLogin), on: facts.login == .enabled,
                           note: facts.login == .requiresApproval ? "Approve in System Settings › Login Items" : nil)
        return SettingsPage(id: "general", title: "General", symbol: "gearshape", tint: .systemGray, sections: [
            SettingsSection(title: nil, rows: [login]),
            SettingsSection(title: "Updates", rows: updates),
        ])
    }

    private func screenSaverPage(_ facts: SettingsFacts) -> SettingsPage {
        let seconds = Settings.warnSecondsChoices.map { secs in
            action("\(secs) seconds", #selector(setWarnSeconds(_:)), on: secs == Settings.warnSeconds, tag: secs)
        }
        let warning = [
            toggle("Warn Before Screen Saver", #selector(toggleWarn), on: Settings.warnEnabled),
            popup("Warning Time", seconds),
            toggle("Dim Screens \(Int(LockWarning.dimLead))s Before Warning", #selector(toggleDim), on: Settings.dimEnabled),
            SettingsRow.note(facts.saverSummary),
        ]
        return SettingsPage(id: "screensaver", title: "Screen Saver", symbol: "clock", tint: .systemTeal, sections: [
            SettingsSection(title: nil, rows: [button("Show Big Clock Now", "Show", #selector(showClock), closes: true)]),
            SettingsSection(title: "Pre-Lock Warning", rows: warning),
        ])
    }

    private func brightnessPage(_ facts: SettingsFacts) -> SettingsPage {
        sliders = facts.displays.map { display in
            BrightnessSliderView(id: display.id, name: display.name, level: facts.levels[display.id]) {
                [brightness] id, value in brightness.set(value, for: id)
            }
        }
        var rows = zip(facts.displays, sliders).map { display, slider in
            SettingsRow(title: display.name, note: nil, control: .custom(slider))
        }
        if facts.allSoftware { rows.append(.note("DisplayLink dock: monitors can't take brightness commands")) }
        var sections = [SettingsSection(title: facts.allSoftware ? "Brightness (software dimming)" : nil, rows: rows)]
        sections.append(SettingsSection(title: nil, rows: [
            toggle("Brightness Keys ⌃⌥⌘↑ / ⌃⌥⌘↓", #selector(toggleBrightnessKeys), on: Settings.brightnessKeysEnabled),
        ]))
        return SettingsPage(id: "brightness", title: "Brightness", symbol: "sun.max.fill", tint: .systemOrange,
                            sections: sections.filter { !$0.rows.isEmpty })
    }

    private func windowsPage(_ facts: SettingsFacts) -> SettingsPage {
        let grid = Settings.snapGrid
        let keys = SnapKeys.allCases.enumerated().map { index, keys in
            action(keys.title, #selector(setSnapKeys(_:)), on: keys == Settings.snapKeys, tag: index)
        }
        let marked = facts.camera.map { "Marked on \($0.name)\(facts.cameraConnected ? "" : " (not connected)")" }
        return SettingsPage(id: "windows", title: "Windows", symbol: "macwindow", tint: .systemBlue, sections: [
            SettingsSection(title: "Window Snapping", rows: [
                accessToggle("Snap to Grid, Maximize, Minimize", #selector(toggleSnap), on: Settings.snapEnabled, facts),
                popup("Grid", gridItems(current: grid)),
                popup("Keys", keys),
            ]),
            SettingsSection(title: "Camera", rows: [
                toggle("Keep Windows Clear of the Camera", #selector(toggleCameraAvoid), on: Settings.cameraAvoid,
                       closes: !Settings.cameraAvoid && facts.camera == nil),
                button("Mark Where the Camera Is…", "Mark", #selector(markCamera), note: marked, closes: true),
            ]),
            SettingsSection(title: nil, rows: [
                accessToggle("⌘M Minimizes All Windows (⌘⇧M Brings Back)", #selector(toggleMinimizeAll), on: Settings.minimizeAllEnabled, facts),
            ]),
            SettingsSection(title: "Dock", rows: [
                accessToggle("Bring Up the Dock in Full-Screen Apps", #selector(toggleFullScreenDock), on: Settings.fullScreenDockEnabled, facts,
                             note: "Moving the pointer to the edge is enough, no push needed"),
                accessToggle("Click an App in the Dock to Pick Its Window", #selector(toggleDockWindowMenu), on: Settings.dockWindowMenuEnabled, facts,
                             note: "With two or more windows, shows them to choose from"),
            ]),
        ])
    }

    private func keyboardPage(_ facts: SettingsFacts) -> SettingsPage {
        let altTabChoices = AltTabMode.allCases.enumerated().map { index, mode in
            action(mode.title, #selector(setAltTabMode(_:)), on: mode == facts.altTab, tag: index)
        }
        var habits = [popup("Alt-Tab", altTabChoices, closes: !facts.permissions.accessibility)]
        if facts.altTab == .windows {
            habits.append(toggle("⌘Tab Switches Windows Too", #selector(toggleCommandTab), on: Settings.commandTabWindows))
            if !facts.permissions.screenRecording {
                habits.append(button("Show Window Pictures in the Switcher…", "Allow", #selector(allowScreenReading), closes: true))
            }
        }
        habits += [
            accessToggle("Ctrl-C / X / V / Z: Copy, Cut, Paste, Undo", #selector(toggleClipboardKeys), on: Settings.clipboardKeysEnabled, facts,
                         note: "Ctrl stays Ctrl in terminals, VS Code and remote desktops"),
            accessToggle("Ctrl-←/→ by Word, Home/End to Line Start/End", #selector(toggleTextNav), on: Settings.textNavEnabled, facts),
            accessToggle("Left Alt-Shift Switches Language", #selector(toggleInputSwitch), on: Settings.inputSwitchEnabled, facts),
        ]
        var finder = [
            accessToggle("Paste a Path in Finder to Go There", #selector(toggleFinderPaste), on: Settings.finderPathPasteEnabled, facts,
                         note: "⌘V or Ctrl-V in a Finder window, no ⌘⇧G needed"),
            accessToggle("Delete Moves the Highlighted File to the Trash", #selector(toggleFinderTrash), on: Settings.finderTrashKeyEnabled, facts,
                         note: "In Finder; ⌘Z puts it back. Renaming and search keep their delete key"),
            accessToggle("Address Bar in Finder Windows", #selector(toggleFinderBar), on: Settings.finderAddressBarEnabled, facts,
                         note: "Shows the folder's path; paste or type one and press ↩"),
        ]
        if facts.finderDenied {
            finder.append(button("Let RubberMAC Move Finder Windows…", "Open", #selector(allowFinderControl), closes: true))
        }
        return SettingsPage(id: "keyboard", title: "Keyboard", symbol: "keyboard", tint: .systemGray, sections: [
            SettingsSection(title: "PC Keyboard Habits", rows: habits),
            SettingsSection(title: "Finder", rows: finder),
        ])
    }

    private func writingPage(_ facts: SettingsFacts) -> SettingsPage {
        var rows = [toggle("⌘⇧Space Opens a Pad That Fixes What You Write", #selector(toggleWritingPad), on: Settings.writingPadEnabled,
                           note: "↩ pastes the fixed text where you were typing")]
        if !facts.fixerAvailable { rows.append(.note("Fixing needs Apple Intelligence (System Settings)")) }
        if !facts.permissions.screenRecording {
            rows.append(button("Let the Pad Read the Screen You're Replying To…", "Allow", #selector(allowScreenReading), closes: true))
        }
        rows.append(button("Open Saved Replies", "Open", #selector(openReplies), closes: true))
        return SettingsPage(id: "writing", title: "Writing", symbol: "square.and.pencil", tint: .systemPink,
                            sections: [SettingsSection(title: nil, rows: rows)])
    }

    private func mousePage(_ facts: SettingsFacts) -> SettingsPage {
        var sections: [SettingsSection] = []
        let connected = facts.mice
        if connected.isEmpty { sections.append(SettingsSection(title: nil, rows: [.note("No mouse connected")])) }
        // Each mouse has its own card, so its name is the card's and the rows don't need it again.
        for mouse in connected {
            let pointer = ValueSliderView(position: mice.pointerSpeed(for: mouse).map(PointerSpeed.slider(for:)),
                                          unavailable: "Pointer speed  (unavailable)",
                                          describe: { "Pointer speed  \(PointerSpeed.speed(atSlider: $0))" },
                                          onChange: { [mice] in mice.setPointerSpeed(PointerSpeed.speed(atSlider: $0), for: mouse) })
            let wheel = ValueSliderView(position: WheelSpeed.slider(for: mice.wheelSpeed(for: mouse)), unavailable: "",
                                        describe: { "Wheel speed  ×\(WheelSpeed.multiplier(atSlider: $0))" },
                                        onChange: { [mice] in mice.setWheelSpeed(WheelSpeed.multiplier(atSlider: $0), for: mouse) })
            sections.append(SettingsSection(title: connected.count == 1 ? "Mouse: \(mouse)" : mouse, rows: [
                SettingsRow(title: "Pointer speed", note: nil, control: .custom(pointer)),
                SettingsRow(title: "Wheel speed", note: nil, control: .custom(wheel)),
            ]))
        }
        var rows: [SettingsRow] = []
        if !connected.isEmpty { rows.append(.note("Remembered for each mouse model")) }
        if connected.count > 1 { rows.append(.note("The wheel speed used is \(connected.last!)'s, connected last")) }
        rows.append(.note("System Settings stops pointer speed at 3; this goes to \(Int(PointerSpeed.maximum))"))
        rows.append(accessToggle("Hold the Wheel and Move to Scroll, One Direction at a Time", #selector(toggleWheelDrag),
                                 on: Settings.wheelDragScrollEnabled, facts, note: "A quick wheel click is still a middle click"))
        sections.append(SettingsSection(title: nil, rows: rows))
        return SettingsPage(id: "mouse", title: "Mouse", symbol: "computermouse.fill", tint: .systemIndigo, sections: sections)
    }

    private func layoutsPage(_ facts: SettingsFacts) -> SettingsPage {
        var rows = [
            accessToggle("Remember Layout per Monitor Setup", #selector(toggleLayouts), on: Settings.layoutsEnabled, facts),
            button("Save Layout Now", "Save", #selector(saveLayout)),
            button("Restore Layout Now", "Restore", #selector(restoreLayout), enabled: facts.hasSavedLayout),
        ]
        if !facts.setupName.isEmpty { rows.append(.note(facts.setupName)) }
        return SettingsPage(id: "layouts", title: "Window Layouts", symbol: "rectangle.3.group", tint: .systemPurple,
                            sections: [SettingsSection(title: nil, rows: rows)])
    }

    private func permissionsPage(_ facts: SettingsFacts) -> SettingsPage {
        let rows = facts.permissions.rows.map { row -> SettingsRow in
            // Only a real state goes on the right; "Checking…" and "macOS asks…" are sentences, not switch positions.
            let note = (row.isOn == nil ? [row.state] : []) + [row.note] + (row.hint.map { [$0] } ?? [])
            let selector: Selector
            switch row.kind {
            case .accessibility: selector = #selector(turnOnAccessibility)
            case .screenRecording: selector = #selector(turnOnScreenRecording)
            case .finder: selector = #selector(allowFinderControl)
            }
            return SettingsRow(title: row.title, note: note.joined(separator: "\n"),
                               control: .status(row.isOn == nil ? "" : row.state, isOn: row.isOn, button: row.offersTurnOn ? "Turn On…" : nil),
                               target: row.offersTurnOn ? self : nil, action: row.offersTurnOn ? selector : nil, closesPanel: row.offersTurnOn)
        }
        let checked = facts.permissionsChecked.map { PermissionCheck.checkedNote(at: $0, now: Date()) }
        return SettingsPage(id: Self.permissionsPageID, title: "Permissions", symbol: "hand.raised.fill", tint: .systemBlue, sections: [
            SettingsSection(title: nil, rows: rows),
            SettingsSection(title: nil, rows: [
                button("Changed a Switch in System Settings?", "Check Again", #selector(checkPermissionsAgain), note: checked),
            ]),
        ], needsAttention: facts.needsAccess)
    }

    // Recolours your eyes on OBS's virtual camera, which is all it needs installed.
    private func eyeCameraPage(_ facts: SettingsFacts) -> SettingsPage {
        let eye = facts.eye
        var rows: [SettingsRow]
        if !eye.installed {
            rows = [.note("Recolours your eyes live on video calls"),
                    .note("It sends the picture to OBS's virtual camera: install OBS, click Start Virtual Camera in it once, and allow its camera extension when macOS asks"),
                    button("Get OBS…", "Download", #selector(openOBSDownload), closes: true)]
        } else {
            rows = [toggle("Recolour My Eyes on the Virtual Camera", #selector(toggleEyeCamera), on: eye.isOn, note: eye.status)]
            if eye.hasError { rows.append(button("Show the Whole Error…", "Show", #selector(showEyeCameraError), closes: true)) }
            // The names ride along as the row's note, unseen, so searching for "hazel" finds the row. It sits above the
            // preview, so a colour is one click away and its effect shows right below.
            eyeSwatches.show(colors: eye.colors, selected: eye.color)
            eyeSwatches.onPick = { [eyeCamera] in eyeCamera.setColor($0) }
            rows.append(SettingsRow(title: "Colour", note: eye.colors.map(EyeCamera.title(for:)).joined(separator: "\n"),
                                    control: .custom(eyeSwatches)))
            rows += eyePreviewRows(eye)
            rows.append(popup("Strength", EyeCamera.strengths.enumerated().map { index, value in
                action("\(Int((value * 100).rounded()))%", #selector(setEyeStrength(_:)), on: abs(value - eye.strength) < 0.025, tag: index)
            }))
            var cameras: [NSMenuItem] = eye.cameras.map { camera in
                camera.virtual ? infoItem("\(camera.name) (virtual, can't be the input)")
                    : action(camera.name, #selector(setEyeCamera(_:)), on: camera.index == eye.cameraIndex, tag: camera.index)
            }
            if cameras.isEmpty { cameras = [infoItem("Looking for cameras…")] }
            rows.append(popup("Camera", cameras + [.separator(), action("Refresh List", #selector(refreshEyeCameras))]))
            rows.append(toggle("Turn On When RubberMAC Starts", #selector(toggleEyeCameraAtLaunch), on: Settings.eyeCameraAtLaunch))
            rows.append(.note("In Zoom, Meet or Teams, choose OBS Virtual Camera"))
            if eye.separateApp {
                rows.append(button("Quit the Separate camrelay App (It Uses the Same Camera)", "Quit", #selector(quitSeparateCamrelay)))
            }
        }
        return SettingsPage(id: Self.eyeCameraPageID, title: "Eye Color Camera", symbol: "eye.fill", tint: .systemCyan,
                            sections: [SettingsSection(title: nil, rows: rows)])
    }

    private func eyePreviewRows(_ eye: EyeFacts) -> [SettingsRow] {
        guard eye.isStreaming else { return [.note("Turn it on to see a preview of what others see")] }
        switch eye.previewAccess {
        case .allowed:
            if let problem = eye.previewProblem { return [.note(problem)] }
            return [SettingsRow(title: "Preview", note: nil, control: .custom(eyePreview.view)),
                    .note("What others see on the call, from OBS Virtual Camera")]
        case .notAsked:
            return [button("See What Others See", "Show", #selector(showEyePreview), note: "macOS asks once to let RubberMAC use the camera")]
        case .denied:
            return [button("Allow the Camera for the Preview…", "Open", #selector(allowEyePreviewCamera), closes: true)]
        }
    }

    // MARK: Rows

    private func toggle(_ title: String, _ selector: Selector, on: Bool, note: String? = nil, closes: Bool = false) -> SettingsRow {
        SettingsRow(title: title, note: note, control: .toggle(on: on), target: self, action: selector, closesPanel: closes)
    }

    // Without Accessibility, turning one of these on brings up macOS's question, so the panel gets out of the way.
    private func accessToggle(_ title: String, _ selector: Selector, on: Bool, _ facts: SettingsFacts, note: String? = nil) -> SettingsRow {
        toggle(title, selector, on: on, note: note, closes: !facts.permissions.accessibility)
    }

    private func button(_ title: String, _ label: String, _ selector: Selector, note: String? = nil, enabled: Bool = true,
                        closes: Bool = false) -> SettingsRow {
        SettingsRow(title: title, note: note, control: .button(label, enabled: enabled), target: self, action: selector, closesPanel: closes)
    }

    private func popup(_ title: String, _ items: [NSMenuItem], closes: Bool = false) -> SettingsRow {
        SettingsRow(title: title, note: nil, control: .popup(items), closesPanel: closes)
    }

    private func action(_ title: String, _ selector: Selector, on: Bool = false, tag: Int = 0) -> NSMenuItem {
        .action(title, selector, target: self, on: on, tag: tag)
    }

    // A line in a popup that can't be chosen.
    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // Grouped by column count; 2 × 2 is halves and quarters, 3 × 2 thirds and sixths.
    private func gridItems(current: SnapGrid) -> [NSMenuItem] {
        Settings.snapGridChoices.enumerated().flatMap { index, grid in
            let item = action("\(grid.columns) columns × \(grid.rows) row\(grid.rows == 1 ? "" : "s")",
                              #selector(setSnapGrid(_:)), on: grid == current, tag: index)
            return index > 0 && grid.rows == 1 ? [.separator(), item] : [item]
        }
    }

    private static func updateStatus(_ state: Updater.State) -> String? {
        switch state {
        case .idle: return nil
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .available(let release): return "\(release.version) is available"
        case .installing(let version): return "Installing \(version)…"
        case .failed(let reason): return "Last check failed: \(reason)"
        }
    }

    private func saverSummary() -> String {
        let timeout = Int(lockWarning.saverTimeout)
        if timeout == 0 { return "Screen saver is set to never start" }
        let after = timeout % 60 == 0 ? "\(timeout / 60) min" : "\(timeout)s"
        if timeout <= Settings.warnSeconds { return "Screen saver after \(after): too short to warn" }
        return "Screen saver after \(after) idle"
    }

    // MARK: Permissions

    func permissionReading() -> PermissionCheck {
        PermissionCheck(accessibility: AX.isTrusted, screenRecording: ScreenText.hasPermission, finder: finderState,
                        finderUsed: Settings.finderPathPasteEnabled || Settings.finderAddressBarEnabled)
    }

    // Finder's side is read off the main thread, as FinderWindow asks; reading never prompts.
    func readPermissions(logAlways: Bool) {
        let used = Settings.finderPathPasteEnabled || Settings.finderAddressBarEnabled
        guard used else { return finishPermissionRead(finder: nil, logAlways: logAlways) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = FinderWindow.permission(ask: false)
            DispatchQueue.main.async {
                self?.finishPermissionRead(finder: PermissionCheck.FinderState(status: status), logAlways: logAlways)
            }
        }
    }

    private func finishPermissionRead(finder: PermissionCheck.FinderState?, logAlways: Bool) {
        finderState = finder ?? finderState
        if finder == .on {
            finderPaste.clearDenied()
            finderBar.clearDenied()
        }
        permissionsChecked = Date()
        let line = permissionReading().logLine
        if logAlways || line != lastPermissionLine {
            log(line)
            lastPermissionLine = line
        }
        settingsPanel.reloadIfShown()
    }

    @objc func checkPermissionsAgain() {
        restartTaps()
        readPermissions(logAlways: true)
    }

    @objc func turnOnAccessibility() {
        AX.requestAccess()
        NSWorkspace.shared.open(URL(string: Self.settingsAppURL + "Privacy_Accessibility")!)
    }

    @objc func turnOnScreenRecording() {
        Settings.screenRecordingAsked = true
        ScreenText.requestPermission()
        NSWorkspace.shared.open(URL(string: Self.settingsAppURL + "Privacy_ScreenCapture")!)
    }
}
