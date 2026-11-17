import AppKit

// RubberMAC's own Start: the grid of apps the ⌘ tap opens instead of Spotlight's Apps view.
final class StartMenu: Feature {
    static let shared = StartMenu()

    // When on, the ⌘ tap calls toggle() rather than opening Spotlight's Apps view.
    var isEnabled: Bool { Settings.startMenuEnabled }
    // Start has no tap of its own: the ⌘ tap is SpotlightKeys', which already counts towards needing Accessibility.
    var wantsAccess: Bool { false }

    private(set) lazy var controller = StartMenuController()

    // The first ⌘ tap shouldn't wait for the window to be built and every app's name read.
    func start() {
        guard isEnabled else { return }
        DispatchQueue.main.async { [self] in controller.refresh() }
    }

    func restartTaps() {}

    // Opens the grid on the screen in use, or closes it if it's open. Called on the main thread.
    func toggle() {
        controller.toggle()
    }

    func close() {
        controller.close()
    }
}
