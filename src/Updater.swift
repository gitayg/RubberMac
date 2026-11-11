import AppKit

// Looks for a newer release at launch and every six hours. With automatic install on (the default) it
// installs it and relaunches straight away; otherwise the settings panel offers it.
final class Updater {
    enum State {
        case idle, checking, upToDate, available(UpdateFeed.Release), installing(String), failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .installing: return true
            default: return false
            }
        }
    }

    static let interval: TimeInterval = 6 * 60 * 60

    let current = UpdateInstaller.version(of: Bundle.main.bundleURL) ?? "0"
    private(set) var state = State.idle {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?
    private var timer: Timer?

    var isBusy: Bool { state.isBusy }

    func start() {
        check()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // A check from the panel says so when there's nothing new; a scheduled one stays quiet.
    func check(manual: Bool = false) {
        guard !isBusy else { return }
        state = .checking
        Task { @MainActor in
            do {
                guard let release = try await UpdateInstaller.latest(),
                      UpdateFeed.isNewer(release.version, than: current) else {
                    state = .upToDate
                    if manual { tell("RubberMAC \(current) is the latest version.") }
                    return
                }
                log("update: \(release.version) available")
                state = .available(release)
                if Settings.autoUpdate { install(release) }
            } catch {
                fail(error, manual: manual)
            }
        }
    }

    func install(_ release: UpdateFeed.Release) {
        state = .installing(release.version)
        Task { @MainActor in
            do {
                try await UpdateInstaller.install(release, over: Bundle.main.bundleURL, current: current)
                log("update: installed \(release.version), relaunching")
                UpdateInstaller.relaunch(Bundle.main.bundleURL)
            } catch {
                fail(error, manual: true)
            }
        }
    }

    private func fail(_ error: Error, manual: Bool) {
        state = .failed(error.localizedDescription)
        log("update failed: \(error.localizedDescription)")
        if manual { tell("Couldn't update RubberMAC: \(error.localizedDescription)") }
    }

    private func tell(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}
