import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    let lockWarning: LockWarning
    private let hotKeys = HotKeys()
    private let altTab = AltTabRemap(switcher: WindowSwitcher())
    private let clipboard = ClipboardKeys()
    private let windowKeys = WindowKeys()
    private let textNav = TextNavKeys()
    private let minimizeAll = MinimizeAllKeys()
    private let inputSwitch = InputSwitchKeys()
    let finderPaste = FinderPathPaste()
    let finderTrash = FinderTrashKey()
    private let padKeys = WritingPadKeys()
    private let dockPicker = DockWindowPicker()
    // inputSwitch goes first: it only watches, and must see keys a later handler swallows. finderPaste comes after
    // clipboard, so a Ctrl-V reaches it as ⌘V.
    private lazy var keyboardTap = EventTap(name: "keyboard", types: [.keyDown, .keyUp, .flagsChanged],
                                            location: .cghidEventTap, ownThread: true,
                                            handlers: [inputSwitch, dockPicker.keys, padKeys, windowKeys, minimizeAll, altTab, clipboard, finderPaste, finderTrash, textNav])
    let finderBar = FinderAddressBar()
    private let fullScreenDock = FullScreenDock()
    private lazy var pointerTap = EventTap(name: "pointer", types: [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged],
                                           location: .cgSessionEventTap, ownThread: true, handlers: [fullScreenDock, dockPicker.clicks])
    private let wheelDrag = WheelDragScroll()
    private let wheelSpeed = WheelSpeed()
    let mice = MouseProfiles()
    // At session level, so it also sees scrolling that mouse drivers like Logi Options+ post themselves.
    private lazy var mouseTap = EventTap(name: "mouse", types: [.scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged],
                                         location: .cgSessionEventTap, handlers: [wheelDrag, wheelSpeed])
    let brightness = Brightness()
    let layouts = LayoutKeeper()
    let updater = Updater()
    private let cameraMarker = CameraMarker()
    private let writing = WritingAssistant()
    let eyeCamera = EyeCamera()
    private var iconEyeColor: String?
    var statusItem: NSStatusItem!
    var sliders: [BrightnessSliderView] = []
    let settingsPanel = SettingsPanel()
    // The last reading of Finder control and when the permissions were last read, for the Permissions page.
    var finderState: PermissionCheck.FinderState?
    var permissionsChecked: Date?
    var lastPermissionLine = ""
    // Whether the separate camrelay app is running, read when the Eye Color Camera page is shown rather than each render.
    var eyeSeparateApp = false

    init(lockWarning: LockWarning) {
        self.lockWarning = lockWarning
    }

    func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.image()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleSettingsPanel)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpSettingsPanel()
        eyeCamera.onChange = { [weak self] in
            self?.updateStatusIcon()
            if self?.settingsPanel.shown == Self.eyeCameraPageID { self?.settingsPanel.reloadIfShown() }
        }

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
        finderTrash.isEnabled = Settings.finderTrashKeyEnabled
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
                self?.restartTaps()
                self?.askForScreenRecordingIfDue()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.brightness.refresh { self?.settingsPanel.reloadIfShown() }
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

    // Starts whichever taps are wanted but aren't running, as they can't start until Accessibility is on.
    func restartTaps() {
        keyboardTap.update()
        mouseTap.update()
        pointerTap.update()
        finderBar.refresh(.window)
    }

    var needsAccess: Bool {
        (Settings.snapEnabled || Settings.altTabMode != .off || Settings.clipboardKeysEnabled
            || Settings.textNavEnabled || Settings.minimizeAllEnabled || Settings.inputSwitchEnabled || Settings.finderPathPasteEnabled || Settings.finderTrashKeyEnabled
            || Settings.finderAddressBarEnabled || Settings.fullScreenDockEnabled || Settings.dockWindowMenuEnabled || Settings.writingPadEnabled || Settings.layoutsEnabled || Settings.wheelDragScrollEnabled || mice.wheelSpeed != 1) && !AX.isTrusted
    }

    // MARK: Actions

    @objc func showClock() {
        let saver = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: saver, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func toggleWarn() {
        Settings.warnEnabled.toggle()
        lockWarning.refresh()
    }

    @objc func setWarnSeconds(_ sender: NSMenuItem) {
        Settings.warnSeconds = sender.tag
        lockWarning.refresh()
    }

    @objc func toggleDim() {
        Settings.dimEnabled.toggle()
        lockWarning.refresh()
    }

    @objc func toggleBrightnessKeys() {
        Settings.brightnessKeysEnabled.toggle()
        applyHotKeys()
    }

    @objc func toggleSnap() {
        Settings.snapEnabled.toggle()
        windowKeys.isEnabled = Settings.snapEnabled
        keyboardTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc func setSnapKeys(_ sender: NSMenuItem) {
        Settings.snapKeys = SnapKeys.allCases[sender.tag]
        windowKeys.keys = Settings.snapKeys
    }

    @objc func setSnapGrid(_ sender: NSMenuItem) {
        Settings.snapGrid = Settings.snapGridChoices[sender.tag]
        windowKeys.grid = Settings.snapGrid
    }

    // Turning it on with nothing marked yet asks where the camera is first; marking turns it on.
    @objc func toggleCameraAvoid() {
        guard Settings.cameraAvoid || Settings.cameraArea != nil else { markCamera(); return }
        Settings.cameraAvoid.toggle()
    }

    @objc func markCamera() {
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

    @objc func toggleFullScreenDock() {
        Settings.fullScreenDockEnabled.toggle()
        fullScreenDock.isEnabled = Settings.fullScreenDockEnabled
        pointerTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc func toggleDockWindowMenu() {
        Settings.dockWindowMenuEnabled.toggle()
        dockPicker.isEnabled = Settings.dockWindowMenuEnabled
        keyboardTap.update()
        pointerTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc func toggleMinimizeAll() {
        Settings.minimizeAllEnabled.toggle()
        minimizeAll.isEnabled = Settings.minimizeAllEnabled
        keyboardTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc func toggleTextNav() {
        Settings.textNavEnabled.toggle()
        textNav.isEnabled = Settings.textNavEnabled
        keyboardTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc func toggleInputSwitch() {
        Settings.inputSwitchEnabled.toggle()
        inputSwitch.isEnabled = Settings.inputSwitchEnabled
        keyboardTap.update()
        if needsAccess { AX.requestAccess() }
    }

    private func applyWheelSpeed() {
        wheelSpeed.multiplier = mice.wheelSpeed
        mouseTap.update()
    }

    @objc func toggleWheelDrag() {
        Settings.wheelDragScrollEnabled.toggle()
        wheelDrag.isEnabled = Settings.wheelDragScrollEnabled
        mouseTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc func setAltTabMode(_ sender: NSMenuItem) {
        Settings.altTabMode = AltTabMode.allCases[sender.tag]
        altTab.mode = Settings.altTabMode
        keyboardTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc func toggleCommandTab() {
        Settings.commandTabWindows.toggle()
        altTab.commandTab = Settings.commandTabWindows
    }

    @objc func toggleClipboardKeys() {
        Settings.clipboardKeysEnabled.toggle()
        clipboard.isEnabled = Settings.clipboardKeysEnabled
        keyboardTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc func toggleFinderPaste() {
        Settings.finderPathPasteEnabled.toggle()
        finderPaste.isEnabled = Settings.finderPathPasteEnabled
        keyboardTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc func toggleFinderTrash() {
        Settings.finderTrashKeyEnabled.toggle()
        finderTrash.isEnabled = Settings.finderTrashKeyEnabled
        keyboardTap.update()
        if needsAccess { AX.requestAccess() }
    }

    @objc func toggleFinderBar() {
        Settings.finderAddressBarEnabled.toggle()
        finderBar.isEnabled = Settings.finderAddressBarEnabled
        if needsAccess { AX.requestAccess() }
    }

    // Once refused, the system doesn't ask again; the switch is under Automation in System Settings.
    @objc func allowFinderControl() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    @objc func toggleWritingPad() {
        Settings.writingPadEnabled.toggle()
        padKeys.isEnabled = Settings.writingPadEnabled
        keyboardTap.update()
        applyHotKeys()
    }

    // The request puts RubberMAC in the list; the switch itself is only in System Settings.
    @objc func allowScreenReading() {
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

    // Once, unprompted, and after Accessibility so that the two questions don't pile up. The panel still offers it.
    private func askForScreenRecordingIfDue() {
        guard PermissionRequest.screenRecordingDue(hasPermission: ScreenText.hasPermission,
                                                   alreadyAsked: Settings.screenRecordingAsked,
                                                   accessibilityDone: !needsAccess) else { return }
        allowScreenReading()
    }

    @objc func openReplies() {
        try? FileManager.default.createDirectory(at: ReplyStore.folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(ReplyStore.folder)
    }

    @objc func toggleEyeCamera() {
        guard !eyeCamera.isCalibrating else { return }
        eyeCamera.toggle()
    }

    @objc func setEyeColor(_ sender: NSMenuItem) {
        guard eyeCamera.colors.indices.contains(sender.tag) else { return }
        eyeCamera.setColor(eyeCamera.colors[sender.tag])
    }

    @objc func setEyeStrength(_ sender: NSMenuItem) {
        guard EyeCamera.strengths.indices.contains(sender.tag) else { return }
        eyeCamera.setStrength(EyeCamera.strengths[sender.tag])
    }

    @objc func setEyeCamera(_ sender: NSMenuItem) {
        eyeCamera.setCamera(sender.tag)
    }

    @objc func refreshEyeCameras() {
        eyeCamera.refreshCameras()
    }

    @objc func calibrateEyeCamera() {
        eyeCamera.calibrate()
    }

    @objc func toggleEyeCameraAtLaunch() {
        Settings.eyeCameraAtLaunch.toggle()
    }

    @objc func showEyeCameraError() {
        guard let message = eyeCamera.errorMessage else { return }
        let alert = NSAlert()
        alert.messageText = "Eye Color Camera"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func quitSeparateCamrelay() {
        EyeCamera.quitSeparateApp()
    }

    @objc func openCamrelayProject() {
        NSWorkspace.shared.open(EyeCamera.projectURL)
    }

    @objc func toggleLayouts() {
        Settings.layoutsEnabled.toggle()
        layouts.isEnabled = Settings.layoutsEnabled
        if needsAccess { AX.requestAccess() }
    }

    @objc func saveLayout() {
        layouts.saveNow()
    }

    @objc func restoreLayout() {
        layouts.restoreNow()
    }

    @objc func checkForUpdates() {
        updater.check(manual: true)
    }

    @objc func installUpdate() {
        if case .available(let release) = updater.state { updater.install(release) }
    }

    @objc func toggleAutoUpdate() {
        Settings.autoUpdate.toggle()
        if Settings.autoUpdate, case .available(let release) = updater.state { updater.install(release) }
    }

    @objc func toggleLogin() {
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
