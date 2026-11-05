import AppKit

// Fades every screen down before the lock warning, and back up instantly on activity.
final class ScreenDimmer {
    private let overlay = ScreenOverlay(level: ScreenOverlay.dimLevel)
    private(set) var isDimmed = false

    // `level` is the fraction of normal brightness left after the fade.
    func dim(to level: Double, over duration: TimeInterval) {
        guard !isDimmed else { return }
        isDimmed = true
        NSScreen.screens.forEach { overlay.set(CGFloat(1 - level), on: $0, duration: duration) }
    }

    func restore() {
        guard isDimmed else { return }
        overlay.clear()
        isDimmed = false
    }
}
