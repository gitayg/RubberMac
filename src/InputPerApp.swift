import AppKit
import Carbon

// Each app keeps the input language it was last typed in, and search (Spotlight, RubberMAC's Start) opens in English.
final class InputPerApp: Feature {
    static let shared = InputPerApp()

    // In the keyboard tap, right after inputSwitch, so it sees ⌘Space and Alt-Shift before anything swallows them.
    let keys: TapHandler
    var wantsAccess: Bool { searchOn() }

    // Swapped by the live self-test, so it runs on a scratch file with both switches on.
    var storeURL = InputPerAppStore.defaultURL
    var perAppOn: () -> Bool = { Settings.inputPerAppEnabled }
    var searchOn: () -> Bool = { Settings.inputSearchEnglishEnabled }

    private(set) var model: InputPerAppModel?
    private let searchKeys = InputPerAppKeys()
    private var watch: Timer?
    private var spotlight = SpotlightWatch(started: .distantPast)

    private init() {
        keys = searchKeys
        // Already on as the keyboard tap first starts, which is before start().
        searchKeys.set(enabled: searchOn(), shortcut: Spotlight.searchShortcut())
    }

    func start() {
        guard model == nil else { return }
        let url = storeURL
        let memory = InputPerAppStore.load(url)
        model = InputPerAppModel(system: .init(current: InputSources.currentID, select: InputSources.select,
                                               english: InputSources.english, save: { InputPerAppStore.save($0, to: url) }),
                                 memory: memory, ownBundleID: Bundle.main.bundleIdentifier,
                                 front: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        apply()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            self?.activated((note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier)
        }
        // Any switch at all: Alt-Shift, the menu-bar picker, ⌃Space. Delivered at once, whether or not RubberMAC is
        // the active app.
        CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                        { _, observer, _, _, _ in
            guard let observer else { return }
            let me = Unmanaged<InputPerApp>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { me.model?.sourceChanged() }
        }, kTISNotifySelectedKeyboardInputSourceChanged, nil, .deliverImmediately)
        log("input per app: \(memory.count) apps remembered")
    }

    // Its keys ride in the shared keyboard tap, which AppDelegate starts again itself.
    func restartTaps() {}

    // After either switch on the Keyboard page changes.
    func apply() {
        model?.perApp = perAppOn()
        model?.searchEnglish = searchOn()
        searchKeys.set(enabled: searchOn(), shortcut: Spotlight.searchShortcut())
    }

    // Just before a search field opens (Spotlight, RubberMAC's Start). A no-op while the setting is off. Main thread.
    func prepareForSearch() {
        model?.searchStarted()
    }

    // That search closed without switching apps.
    func searchEnded() {
        model?.searchEnded()
    }

    // Spotlight's search bar or Apps view is about to open, unless its shortcut was pressed while it was up, which
    // closes it. Main thread.
    func prepareForSpotlight(closes: Bool) {
        guard let model, model.searchEnglish, !closes else { return }
        model.searchStarted()
        guard model.search != nil, watch == nil else { return }
        spotlight = SpotlightWatch(started: Date())
        // Its window is looked for four times a second, and only until this search is over.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    private func tick() {
        guard let model, model.search != nil else { return stopWatching() }
        guard spotlight.ended(open: Spotlight.isOpen(), now: Date()) else { return }
        stopWatching()
        model.searchEnded()
    }

    private func stopWatching() {
        watch?.invalidate()
        watch = nil
    }

    private func activated(_ bundleID: String?) {
        // The shortcut may have been changed in System Settings, which has just been left or opened.
        searchKeys.set(enabled: searchOn(), shortcut: Spotlight.searchShortcut())
        model?.activated(bundleID)
    }
}
