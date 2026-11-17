import AppKit

// In the mouse tap: ⌘ + wheel to the zoom, then each plain wheel notch turned the classic way and made steady.
final class WheelStyleHandler: TapHandler {
    var classic = false
    var steady = false
    var zoomOn = false
    // Read for each event, so turning Natural scrolling on or off in System Settings counts from the next notch: a read
    // takes half a microsecond, and another app's change shows within milliseconds (both measured).
    var natural: () -> Bool = WheelStyle.naturalScrolling
    let zoom: WheelZoom

    init(zoom: WheelZoom) {
        self.zoom = zoom
    }

    var isActive: Bool { classic || steady || zoomOn }

    static let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    // Any scroll with a modifier held, counted before anything can swallow it, so ⌘'s release after it doesn't open
    // Start: the system's own count misses Logi Options+'s wheel (1 of 55 counted, measured).
    static func noteSeen(_ event: CGEvent) {
        if !event.flags.isDisjoint(with: modifiers) { ScrollSeen.note() }
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard type == .scrollWheel else { return event }
        Self.noteSeen(event)
        guard WheelSpeed.isWheel(event) else { return event }
        // ⌘ + wheel belongs to the zoom: it zooms, or goes on as it came, never turned round or made steady.
        if zoomOn, WheelZoom.wants(event.flags) {
            if case .passed = zoom.scroll(event, natural: natural()) { return event }
            return nil
        }
        guard classic || steady, WheelNotch.isNotched(event) else { return event }
        if steady { WheelNotch.steady(event) }
        if classic, WheelNotch.isTurnedRound(event, natural: natural()) { WheelNotch.flip(event) }
        return event
    }
}
