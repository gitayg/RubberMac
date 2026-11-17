import AppKit

// Volume and brightness shown on the screen being changed, rather than where macOS puts its own. The volume keys set
// the volume of the device sound goes to, shown on the screen under the pointer; the brightness keys step an external
// screen under the pointer through Brightness (DDC or software dimming), shown there, unless macOS sets that screen's
// brightness itself. ⌃⌥⌘↑/↓ show it on each screen they change. Off, every key goes to macOS as before.
final class LevelOverlay: Feature {
    static let shared = LevelOverlay()

    let keys = MediaKeys()
    let windows = LevelOverlayWindows()
    // AppDelegate's, so its levels and dimming windows are the ones changed.
    weak var brightness: Brightness?
    // At session level, where the volume and brightness keys arrive before macOS acts on them.
    private lazy var tap = EventTap(name: "media keys", types: [MediaKeys.systemDefined], location: .cgSessionEventTap,
                                    ownThread: true, handlers: [keys])

    var wantsAccess: Bool { Settings.levelOverlayEnabled }

    func start() {
        brightness = brightness ?? (NSApp.delegate as? AppDelegate)?.brightness
        brightness?.onStep = { [weak self] id, level in self?.showBrightness(level, on: id) }
        keys.onPress = { [weak self] in self?.perform($0) }
        update()
    }

    func restartTaps() {
        tap.update()
    }

    // After the setting changes.
    func update() {
        keys.isEnabled = Settings.levelOverlayEnabled
        tap.update()
        if !keys.isEnabled { windows.hideAll() }
    }

    func perform(_ press: MediaKeys.Press) {
        if press.key.isVolume { stepVolume(press) } else { stepBrightness(press) }
    }

    private func stepVolume(_ press: MediaKeys.Press) {
        guard let output = OutputVolume.current, let volume = output.volume else { return }
        let muted = output.isMuted ?? false
        let next = LevelSteps.apply(press.key, fine: press.fine, volume: volume, muted: muted)
        if next.volume != volume { output.setVolume(next.volume) }
        if next.muted != muted { output.setMuted(next.muted) }
        guard let screen = Self.screenUnderPointer() else { return }
        windows.show(symbol: LevelSteps.volumeSymbol(next.volume, muted: next.muted), level: next.muted ? 0 : Double(next.volume), on: screen)
    }

    private func stepBrightness(_ press: MediaKeys.Press) {
        guard let id = press.display, let brightness else { return }
        let step = { [self] in
            guard brightness.displays.contains(where: { $0.id == id }) else { return }
            brightness.set(LevelSteps.brightness(brightness.levels[id] ?? 100, up: press.key.isUp, fine: press.fine), for: id)
            showBrightness(brightness.levels[id] ?? 100, on: id)
        }
        // A screen connected since the last refresh isn't known yet.
        if brightness.displays.contains(where: { $0.id == id }) { step() } else { brightness.refresh(then: step) }
    }

    func showBrightness(_ percent: Int, on id: CGDirectDisplayID) {
        guard Settings.levelOverlayEnabled, let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return }
        windows.show(symbol: LevelSteps.brightnessSymbol, level: Double(percent) / 100, on: screen)
    }

    static func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }
}
