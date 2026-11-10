import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let lockWarning: LockWarning
    private let hotKeys = HotKeys()
    private let altTab = AltTabRemap(switcher: WindowSwitcher())
    private let clipboard = ClipboardKeys()
    private let windowKeys = WindowKeys()
    private let textNav = TextNavKeys()
    private let minimizeAll = MinimizeAllKeys()
    private let inputSwitch = InputSwitchKeys()
    private let finderPaste = FinderPathPaste()
    private let padKeys = WritingPadKeys()
    private let dockPicker = DockWindowPicker()
    // inputSwitch goes first: it only watches, and must see keys a later handler swallows. finderPaste comes after
    // clipboard, so a Ctrl-V reaches it as ⌘V.
    private lazy var keyboardTap = EventTap(name: "keyboard", types: [.keyDown, .keyUp, .flagsChanged],
                                            location: .cghidEventTap, ownThread: true,
                                            handlers: [inputSwitch, dockPicker.keys, padKeys, windowKeys, minimizeAll, altTab, clipboard, finderPaste, textNav])
    private let finderBar = FinderAddressBar()
    private let fullScreenDock = FullScreenDock()
    private lazy var pointerTap = EventTap(name: "pointer", types: [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged],
                                           location: .cgSessionEventTap, ownThread: true, handlers: [fullScreenDock, dockPicker.clicks])
    private let wheelDrag = WheelDragScroll()
    private let wheelSpeed = WheelSpeed()
    private let mice = MouseProfiles()
    // At session level, so it also sees scrolling that mouse drivers like Logi Options+ post themselves.
    private lazy var mouseTap = EventTap(name: "mouse", types: [.scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged],
                                         location: .cgSessionEventTap, handlers: [wheelDrag, wheelSpeed])
    private let brightness = Brightness()
    private let layouts = LayoutKeeper()
    private let updater = Updater()
    private let cameraMarker = CameraMarker()
    private let writing = WritingAssistant()
    private let eyeCamera = EyeCamera()
    private var statusItem: NSStatusItem!
    private var iconEyeColor: String?
    private var sliders: [BrightnessSliderView] = []

    init(lockWarning: LockWarning) {
        self.lockWarning = lockWarning
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.image()
        eyeCamera.onChange = { [weak self] in self?.updateStatusIcon() }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        log("accessibility: \(AX.isTrusted ? "granted" : "not granted")")
        lockWarning.start()
        applyHotKeys()
        windowKeys.isEnabled = Settings.snapEnabled
        windowKeys.keys = Settings.snapKeys
        windowKeys.grid = Settings.snapGrid
        altTab.mode = Settings.altTabMode
        altTab.commandTab = Settings.commandTabWindows
        clipboard.isEnabled = Settings.clipboardKeysEnabled
        textNav.isEnabled = Settings.textNavEnabled
        minimizeAll.isEnabled = Settings.minimizeAllEnabled
        inputSwitch.isEnabled = Settings.inputSwitchEnabled
        finderPaste.isEnabled = Settings.finderPathPasteEnabled
        finderBar.isEnabled = Settings.finderAddressBarEnabled
        padKeys.isEnabled = Settings.writingPadEnabled
        padKeys.onPress = { [writing] in writing.toggle() }
        dockPicker.isEnabled = Settings.dockWindowMenuEnabled
        keyboardTap.update()
        fullScreenDock.isEnabled = Settings.fullScreenDockEnabled
        pointerTap.update()
        wheelDrag.isEnabled = Settings.wheelDragScrollEnabled
        mice.onChange = { [weak self] in self?.applyWheelSpeed() }
        mice.start()
        applyWheelSpeed()
        layouts.isEnabled = Settings.layoutsEnabled
        brightness.refresh { [brightness] in
            let hardware = brightness.displays.filter(\.hardware).count
            log("brightness: \(brightness.displays.count) screens, \(hardware) on DDC, the rest software")
        }
        // After launch has finished, since the question waits for an answer.
        DispatchQueue.main.async { [weak self] in self?.askForPermissionsDue() }
        if Settings.writingPadEnabled && ScreenText.hasPermission { ScreenText.warmUp() }
        updater.start()
        if Settings.eyeCameraAtLaunch && EyeCamera.python() != nil { eyeCamera.start() }

        // Posted when any app's Accessibility permission changes; start the keyboard tap once granted.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.accessibility.api"),
                                                            object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self?.keyboardTap.update()
                self?.mouseTap.update()
                self?.pointerTap.update()
                self?.finderBar.refresh(.window)
                self?.askForScreenRecordingIfDue()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.brightness.refresh {}
        }
    }

    /// Shows the eye colour as a dot on the menu-bar icon while the Eye Color Camera is on.
    private func updateStatusIcon() {
        let shown = eyeCamera.isOn ? eyeCamera.color : nil
        guard shown != iconEyeColor else { return }
        iconEyeColor = shown
        let color = shown.flatMap(EyeCamera.rgb(for:)).map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
        statusItem.button?.image = StatusIcon.image(eyeColor: color)
    }

    func applicationWillTerminate(_ notification: Notification) {
        eyeCamera.shutdown()
    }

    private var needsAccess: Bool {
        (Settings.snapEnabled || Settings.altTabMode != .off || Settings.clipboardKeysEnabled
            || Settings.textNavEnabled || Settings.minimizeAllEnabled || Settings.inputSwitchEnabled || Settings.finderPathPasteEnabled
            || Settings.finderAddressBarEnabled || Settings.fullScreenDockEnabled || Settings.dockWindowMenuEnabled || Settings.writingPadEnabled || Settings.layoutsEnabled || Settings.wheelDragScrollEnabled || mice.wheelSpeed != 1) && !AX.isTrusted
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(action("Show Big Clock Now", #selector(showClock)))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Pre-Lock Warning"))
        menu.addItem(action("Warn Before Screen Saver", #selector(toggleWarn), on: Settings.warnEnabled))
        menu.addItem(.submenu("Warning Time: \(Settings.warnSeconds)s", Settings.warnSecondsChoices.map { secs in
            action("\(secs) seconds", #selector(setWarnSeconds(_:)), on: secs == Settings.warnSeconds, tag: secs)
        }))
        menu.addItem(action("Dim Screens \(Int(LockWarning.dimLead))s Before Warning", #selector(toggleDim),
                            on: Settings.dimEnabled))
        menu.addItem(.note(saverSummary()))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: brightness.allSoftware ? "Brightness (software dimming)" : "Brightness"))
        sliders = brightness.displays.map { display in
            BrightnessSliderView(id: display.id, name: display.name, level: brightness.levels[display.id]) {
                [brightness] id, value in brightness.set(value, for: id)
            }
        }
        for slider in sliders {
            let row = NSMenuItem()
            row.view = slider
            menu.addItem(row)
        }
        if brightness.allSoftware { menu.addItem(.note("DisplayLink dock: monitors can't take brightness commands")) }
        menu.addItem(action("Brightness Keys ⌃⌥⌘↑ / ⌃⌥⌘↓", #selector(toggleBrightnessKeys),
                            on: Settings.brightnessKeysEnabled))
        brightness.refresh { [weak self] in
            guard let self else { return }
            sliders.forEach { $0.show(self.brightness.levels[$0.displayID]) }
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Window Snapping"))
        menu.addItem(action("Snap to Grid, Maximize, Minimize", #selector(toggleSnap), on: Settings.snapEnabled))
        let grid = Settings.snapGrid
        menu.addItem(.submenu("Grid: \(grid.columns) × \(grid.rows)", gridItems(current: grid)))
        menu.addItem(.submenu("Keys", SnapKeys.allCases.enumerated().map { index, keys in
            action(keys.title, #selector(setSnapKeys(_:)), on: keys == Settings.snapKeys, tag: index)
        }))
        menu.addItem(action("Keep Windows Clear of the Camera", #selector(toggleCameraAvoid), on: Settings.cameraAvoid))
        menu.addItem(action("Mark Where the Camera Is…", #selector(markCamera)))
        if let camera = Settings.cameraArea {
            menu.addItem(.note("Marked on \(camera.name)\(WindowSnapper.screen(of: camera) == nil ? " (not connected)" : "")"))
        }
        menu.addItem(action("⌘M Minimizes All Windows (⌘⇧M Brings Back)", #selector(toggleMinimizeAll),
                            on: Settings.minimizeAllEnabled))
        menu.addItem(action("Bring Up the Dock in Full-Screen Apps", #selector(toggleFullScreenDock),
                            on: Settings.fullScreenDockEnabled))
        menu.addItem(.note("Moving the pointer to the edge is enough, no push needed"))
        menu.addItem(action("Click an App in the Dock to Pick Its Window", #selector(toggleDockWindowMenu),
                            on: Settings.dockWindowMenuEnabled))
        menu.addItem(.note("With two or more windows, shows them to choose from"))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "PC Keyboard Habits"))
        menu.addItem(.submenu("Alt-Tab: \(Settings.altTabMode.title)", AltTabMode.allCases.enumerated().map { index, mode in
            action(mode.title, #selector(setAltTabMode(_:)), on: mode == Settings.altTabMode, tag: index)
        }))
        if Settings.altTabMode == .windows {
            menu.addItem(action("⌘Tab Switches Windows Too", #selector(toggleCommandTab), on: Settings.commandTabWindows))
            if !ScreenText.hasPermission {
                menu.addItem(action("Show Window Pictures in the Switcher…", #selector(allowScreenReading)))
            }
        }
        menu.addItem(action("Ctrl-C / X / V / Z: Copy, Cut, Paste, Undo", #selector(toggleClipboardKeys),
                            on: Settings.clipboardKeysEnabled))
        menu.addItem(.note("Ctrl stays Ctrl in terminals, VS Code and remote desktops"))
        menu.addItem(action("Ctrl-←/→ by Word, Home/End to Line Start/End", #selector(toggleTextNav),
                            on: Settings.textNavEnabled))
        menu.addItem(action("Left Alt-Shift Switches Language", #selector(toggleInputSwitch),
                            on: Settings.inputSwitchEnabled))
        menu.addItem(action("Paste a Path in Finder to Go There", #selector(toggleFinderPaste),
                            on: Settings.finderPathPasteEnabled))
        menu.addItem(.note("⌘V or Ctrl-V in a Finder window, no ⌘⇧G needed"))
        menu.addItem(action("Address Bar in Finder Windows", #selector(toggleFinderBar), on: Settings.finderAddressBarEnabled))
        menu.addItem(.note("Shows the folder's path; paste or type one and press ↩"))
        if (Settings.finderPathPasteEnabled && finderPaste.isDenied) || (Settings.finderAddressBarEnabled && finderBar.isDenied) {
            menu.addItem(action("Let RubberMAC Move Finder Windows…", #selector(allowFinderControl)))
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Writing"))
        menu.addItem(action("⌘⇧Space Opens a Pad That Fixes What You Write", #selector(toggleWritingPad),
                            on: Settings.writingPadEnabled))
        menu.addItem(.note("↩ pastes the fixed text where you were typing"))
        if !TextFixer.isAvailable { menu.addItem(.note("Fixing needs Apple Intelligence (System Settings)")) }
        if !ScreenText.hasPermission {
            menu.addItem(action("Let the Pad Read the Screen You're Replying To…", #selector(allowScreenReading)))
        }
        menu.addItem(action("Open Saved Replies", #selector(openReplies)))

        menu.addItem(.separator())
        let connected = mice.mice
        menu.addItem(.sectionHeader(title: connected.count == 1 ? "Mouse: \(connected[0])" : "Mouse"))
        if connected.isEmpty { menu.addItem(.note("No mouse connected")) }
        for mouse in connected {
            let prefix = connected.count == 1 ? "" : "\(mouse): "
            menu.addItem(sliderRow(ValueSliderView(position: mice.pointerSpeed(for: mouse).map(PointerSpeed.slider(for:)),
                                                   unavailable: "\(prefix)Pointer speed  (unavailable)",
                                                   describe: { "\(prefix)Pointer speed  \(PointerSpeed.speed(atSlider: $0))" },
                                                   onChange: { [mice] in mice.setPointerSpeed(PointerSpeed.speed(atSlider: $0), for: mouse) })))
            menu.addItem(sliderRow(ValueSliderView(position: WheelSpeed.slider(for: mice.wheelSpeed(for: mouse)), unavailable: "",
                                                   describe: { "\(prefix)Wheel speed  ×\(WheelSpeed.multiplier(atSlider: $0))" },
                                                   onChange: { [mice] in mice.setWheelSpeed(WheelSpeed.multiplier(atSlider: $0), for: mouse) })))
        }
        if !connected.isEmpty { menu.addItem(.note("Remembered for each mouse model")) }
        if connected.count > 1 { menu.addItem(.note("The wheel speed used is \(connected.last!)'s, connected last")) }
        menu.addItem(.note("System Settings stops pointer speed at 3; this goes to \(Int(PointerSpeed.maximum))"))
        menu.addItem(action("Hold the Wheel and Move to Scroll, One Direction at a Time", #selector(toggleWheelDrag),
                            on: Settings.wheelDragScrollEnabled))
        menu.addItem(.note("A quick wheel click is still a middle click"))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Eye Color Camera"))
        eyeCameraItems().forEach { menu.addItem($0) }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Window Layouts"))
        menu.addItem(action("Remember Layout per Monitor Setup", #selector(toggleLayouts), on: Settings.layoutsEnabled))
        menu.addItem(action("Save Layout Now", #selector(saveLayout)))
        menu.addItem(action("Restore Layout Now", #selector(restoreLayout), enabled: layouts.hasSavedLayout))
        if !layouts.setupName.isEmpty { menu.addItem(.note(layouts.setupName)) }

        if needsAccess {
            menu.addItem(.separator())
            menu.addItem(action("Grant Accessibility Access…", #selector(grantAccess)))
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Version \(updater.current)"))
        if case .available(let release) = updater.state {
            menu.addItem(action("Install \(release.version) and Relaunch", #selector(installUpdate)))
        }
        menu.addItem(action("Check for Updates", #selector(checkForUpdates), enabled: !updater.isBusy))
        menu.addItem(action("Install Updates Automatically", #selector(toggleAutoUpdate), on: Settings.autoUpdate))
        if let status = updateStatus() { menu.addItem(.note(status)) }

        menu.addItem(.separator())
        let login = SMAppService.mainApp.status
        menu.addItem(action("Open at Login", #selector(toggleLogin), on: login == .enabled))
        if login == .requiresApproval { menu.addItem(.note("Approve in System Settings › Login Items")) }
        menu.addItem(.action("Quit RubberMAC", #selector(NSApplication.terminate(_:)), target: NSApp))
    }

    private func action(_ title: String, _ selector: Selector, on: Bool = false, tag: Int = 0,
                        enabled: Bool = true) -> NSMenuItem {
        .action(title, selector, target: self, on: on, tag: tag, enabled: enabled)
    }

    // Grouped by column count; 2 × 2 is halves and quarters, 3 × 2 thirds and sixths.
    private func gridItems(current: SnapGrid) -> [NSMenuItem] {
        Settings.snapGridChoices.enumerated().flatMap { index, grid in
            let item = action("\(grid.columns) columns × \(grid.rows) row\(grid.rows == 1 ? "" : "s")",
                              #selector(setSnapGrid(_:)), on: grid == current, tag: index)
            return index > 0 && grid.rows == 1 ? [.separator(), item] : [item]
        }
    }

    // Recolours your eyes on the virtual camera through camrelay, run as a helper.
    private func eyeCameraItems() -> [NSMenuItem] {
        guard EyeCamera.python() != nil else {
            return [.note("Recolours your eyes live on video calls"),
                    action("Set Up camrelay…", #selector(openCamrelayProject))]
        }
        eyeCamera.prepare()
        var items: [NSMenuItem] = [action("Recolour My Eyes on the Virtual Camera", #selector(toggleEyeCamera),
                                          on: eyeCamera.isOn, enabled: !eyeCamera.isCalibrating),
                                   .note(eyeCamera.statusLine)]
        if eyeCamera.errorMessage != nil { items.append(action("Show the Whole Error…", #selector(showEyeCameraError))) }
        items.append(.submenu("Colour: \(eyeCamera.color.capitalized)", eyeCamera.colors.enumerated().map { index, name in
            action(name.capitalized, #selector(setEyeColor(_:)), on: name == eyeCamera.color, tag: index)
        }))
        items.append(.submenu("Strength: \(Int((eyeCamera.strength * 100).rounded()))%",
                              EyeCamera.strengths.enumerated().map { index, value in
            action("\(Int((value * 100).rounded()))%", #selector(setEyeStrength(_:)),
                   on: abs(value - eyeCamera.strength) < 0.025, tag: index)
        }))
        var cameras: [NSMenuItem] = eyeCamera.cameras.map { camera -> NSMenuItem in
            if camera.virtual { return NSMenuItem.note("\(camera.name) (virtual, can't be the input)") }
            return action(camera.name, #selector(setEyeCamera(_:)), on: camera.index == eyeCamera.cameraIndex, tag: camera.index)
        }
        if cameras.isEmpty { cameras = [NSMenuItem.note("Looking for cameras…")] }
        items.append(.submenu("Camera: \(eyeCamera.cameraName ?? "…")",
                              cameras + [.separator(), action("Refresh List", #selector(refreshEyeCameras))]))
        items.append(action("Calibrate…", #selector(calibrateEyeCamera), enabled: !eyeCamera.isCalibrating))
        items.append(action("Turn On When RubberMAC Starts", #selector(toggleEyeCameraAtLaunch), on: Settings.eyeCameraAtLaunch))
        items.append(.note("In Zoom, Meet or Teams, choose OBS Virtual Camera"))
        if EyeCamera.separateAppRunning() {
            items.append(action("Quit the Separate camrelay App (It Uses the Same Camera)", #selector(quitSeparateCamrelay)))
        }
        return items
    }

    private func sliderRow(_ view: NSView) -> NSMenuItem {
        let row = NSMenuItem()
        row.view = view
        return row
    }

    private func updateStatus() -> String? {
        switch updater.state {
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

    // MARK: Actions

    @objc private func showClock() {
        let saver = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: saver, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func toggleWarn() {
        Settings.warnEnabled.toggle()
        lockWarning.refresh()
    }

    @objc private func setWarnSeconds(_ sender: NSMenuItem) {
        Settings.warnSeconds = sender.tag
        lockWarning.refresh()
    }

    @objc private func toggleDim() {
        Settings.dimEnabled.toggle()
        lockWarning.refresh()
    }

    @objc private func toggleBrightnessKeys() {
        Settings.brightnessKeysEnabled.toggle()
        applyHotKeys()
    }

    @objc private func toggleSnap() {
        Settings.snapEnabled.toggle()
        windowKeys.isEnabled = Settings.snapEnabled
        keyboardTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc private func setSnapKeys(_ sender: NSMenuItem) {
        Settings.snapKeys = SnapKeys.allCases[sender.tag]
        windowKeys.keys = Settings.snapKeys
    }

    @objc private func setSnapGrid(_ sender: NSMenuItem) {
        Settings.snapGrid = Settings.snapGridChoices[sender.tag]
        windowKeys.grid = Settings.snapGrid
    }

    // Turning it on with nothing marked yet asks where the camera is first; marking turns it on.
    @objc private func toggleCameraAvoid() {
        guard Settings.cameraAvoid || Settings.cameraArea != nil else { markCamera(); return }
        Settings.cameraAvoid.toggle()
    }

    @objc private func markCamera() {
        let current = Settings.cameraArea.flatMap { camera in WindowSnapper.screen(of: camera).map { camera.box(on: $0.frame) } }
        cameraMarker.show(current: current) { marked in
            guard let marked, let id = marked.screen.displayID else { return }
            let camera = CameraArea(display: CameraArea.key(of: id), name: marked.screen.localizedName,
                                    box: marked.box, on: marked.screen.frame)
            Settings.cameraArea = camera
            Settings.cameraAvoid = true
            log("camera: marked on \(camera.name), x \(camera.x) y \(camera.y) width \(camera.width) height \(camera.height) of the screen")
        }
    }

    @objc private func toggleFullScreenDock() {
        Settings.fullScreenDockEnabled.toggle()
        fullScreenDock.isEnabled = Settings.fullScreenDockEnabled
        pointerTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc private func toggleDockWindowMenu() {
        Settings.dockWindowMenuEnabled.toggle()
        dockPicker.isEnabled = Settings.dockWindowMenuEnabled
        keyboardTap.update()
        pointerTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc private func toggleMinimizeAll() {
        Settings.minimizeAllEnabled.toggle()
        minimizeAll.isEnabled = Settings.minimizeAllEnabled
        keyboardTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc private func toggleTextNav() {
        Settings.textNavEnabled.toggle()
        textNav.isEnabled = Settings.textNavEnabled
        keyboardTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc private func toggleInputSwitch() {
        Settings.inputSwitchEnabled.toggle()
        inputSwitch.isEnabled = Settings.inputSwitchEnabled
        keyboardTap.update()
        if needsAccess { AX.requestAccess() }
    }

    private func applyWheelSpeed() {
        wheelSpeed.multiplier = mice.wheelSpeed
        mouseTap.update()
    }

    @objc private func toggleWheelDrag() {
        Settings.wheelDragScrollEnabled.toggle()
        wheelDrag.isEnabled = Settings.wheelDragScrollEnabled
        mouseTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc private func setAltTabMode(_ sender: NSMenuItem) {
        Settings.altTabMode = AltTabMode.allCases[sender.tag]
        altTab.mode = Settings.altTabMode
        keyboardTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc private func toggleCommandTab() {
        Settings.commandTabWindows.toggle()
        altTab.commandTab = Settings.commandTabWindows
    }

    @objc private func toggleClipboardKeys() {
        Settings.clipboardKeysEnabled.toggle()
        clipboard.isEnabled = Settings.clipboardKeysEnabled
        keyboardTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc private func toggleFinderPaste() {
        Settings.finderPathPasteEnabled.toggle()
        finderPaste.isEnabled = Settings.finderPathPasteEnabled
        keyboardTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc private func toggleFinderBar() {
        Settings.finderAddressBarEnabled.toggle()
        finderBar.isEnabled = Settings.finderAddressBarEnabled
        if needsAccess { AX.requestAccess() }
    }

    // Once refused, the system doesn't ask again; the switch is under Automation in System Settings.
    @objc private func allowFinderControl() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    @objc private func toggleWritingPad() {
        Settings.writingPadEnabled.toggle()
        padKeys.isEnabled = Settings.writingPadEnabled
        keyboardTap.update()
        applyHotKeys()
    }

    // The request puts RubberMAC in the list; the switch itself is only in System Settings.
    @objc private func allowScreenReading() {
        Settings.screenRecordingAsked = true
        guard PermissionRequest.screenRecording.ask() else { return }
        ScreenText.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    private func askForPermissionsDue() {
        if needsAccess {
            if PermissionRequest.accessibility.ask() { AX.requestAccess() }
        } else {
            askForScreenRecordingIfDue()
        }
    }

    // Once, unprompted, and after Accessibility so that the two questions don't pile up. The menu still offers it.
    private func askForScreenRecordingIfDue() {
        guard PermissionRequest.screenRecordingDue(hasPermission: ScreenText.hasPermission,
                                                   alreadyAsked: Settings.screenRecordingAsked,
                                                   accessibilityDone: !needsAccess) else { return }
        allowScreenReading()
    }

    @objc private func openReplies() {
        try? FileManager.default.createDirectory(at: ReplyStore.folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(ReplyStore.folder)
    }

    @objc private func toggleEyeCamera() {
        eyeCamera.toggle()
    }

    @objc private func setEyeColor(_ sender: NSMenuItem) {
        guard eyeCamera.colors.indices.contains(sender.tag) else { return }
        eyeCamera.setColor(eyeCamera.colors[sender.tag])
    }

    @objc private func setEyeStrength(_ sender: NSMenuItem) {
        guard EyeCamera.strengths.indices.contains(sender.tag) else { return }
        eyeCamera.setStrength(EyeCamera.strengths[sender.tag])
    }

    @objc private func setEyeCamera(_ sender: NSMenuItem) {
        eyeCamera.setCamera(sender.tag)
    }

    @objc private func refreshEyeCameras() {
        eyeCamera.refreshCameras()
    }

    @objc private func calibrateEyeCamera() {
        eyeCamera.calibrate()
    }

    @objc private func toggleEyeCameraAtLaunch() {
        Settings.eyeCameraAtLaunch.toggle()
    }

    @objc private func showEyeCameraError() {
        guard let message = eyeCamera.errorMessage else { return }
        let alert = NSAlert()
        alert.messageText = "Eye Color Camera"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quitSeparateCamrelay() {
        EyeCamera.quitSeparateApp()
    }

    @objc private func openCamrelayProject() {
        NSWorkspace.shared.open(EyeCamera.projectURL)
    }

    @objc private func toggleLayouts() {
        Settings.layoutsEnabled.toggle()
        layouts.isEnabled = Settings.layoutsEnabled
        if needsAccess { AX.requestAccess() }
    }

    @objc private func saveLayout() {
        layouts.saveNow()
    }

    @objc private func restoreLayout() {
        layouts.restoreNow()
    }

    @objc private func grantAccess() {
        if PermissionRequest.accessibility.ask() { AX.requestAccess() }
    }

    @objc private func checkForUpdates() {
        updater.check(manual: true)
    }

    @objc private func installUpdate() {
        if case .available(let release) = updater.state { updater.install(release) }
    }

    @objc private func toggleAutoUpdate() {
        Settings.autoUpdate.toggle()
        if Settings.autoUpdate, case .available(let release) = updater.state { updater.install(release) }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func applyHotKeys() {
        hotKeys.unregisterAll()
        if Settings.brightnessKeysEnabled {
            let modifiers = controlKey | optionKey | cmdKey
            hotKeys.register(keyCode: kVK_UpArrow, modifiers: modifiers) { [brightness] in brightness.stepAll(1) }
            hotKeys.register(keyCode: kVK_DownArrow, modifiers: modifiers) { [brightness] in brightness.stepAll(-1) }
        }
        if Settings.writingPadEnabled {
            hotKeys.register(keyCode: kVK_Space, modifiers: cmdKey | shiftKey) { [writing] in writing.toggle() }
        }
    }
}
