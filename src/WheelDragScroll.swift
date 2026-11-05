import AppKit

// Windows-style autoscroll: hold the wheel down and move the mouse away from where you pressed; the window
// scrolls that way, faster the further you go, until you let go. It scrolls along one axis at a time,
// whichever the mouse is further along. A quick click without moving still reaches the app as a middle click.
final class WheelDragScroll: TapHandler {
    // Tags the events this posts, so neither this nor WheelSpeed acts on them again.
    static let marker: Int64 = 0x5354_5343

    var isEnabled = false
    var isActive: Bool { isEnabled }

    private var drag = WheelDrag()
    private var anchor = CGPoint.zero
    private var timer: Timer?
    private var remainder = (x: 0.0, y: 0.0)

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard isEnabled, event.getIntegerValueField(.mouseEventButtonNumber) == Int64(CGMouseButton.center.rawValue),
              event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return event }
        switch type {
        case .otherMouseDown:
            let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            guard !AppLists.remote.contains(app ?? "") else { return event }
            drag.press()
            anchor = event.location
            start()
            return nil
        case .otherMouseDragged:
            guard drag.isHolding else { return event }
            drag.move(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
            return event
        case .otherMouseUp:
            guard drag.isHolding else { return event }
            stop()
            if drag.release() { click(at: event.location) }
            return nil
        default:
            return event
        }
    }

    // The button-up may have gone by while the tap was off; stop rather than scroll on forever.
    func tapWasDisabled() {
        guard drag.isHolding else { return }
        stop()
        _ = drag.release()
    }

    private func start() {
        remainder = (0, 0)
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    // Whole pixels only; the fractions carry over so slow scrolling still creeps along.
    private func tick() {
        let step = drag.step()
        remainder.x += step.x
        remainder.y += step.y
        let x = remainder.x.rounded(.towardZero), y = remainder.y.rounded(.towardZero)
        remainder.x -= x
        remainder.y -= y
        guard x != 0 || y != 0, let event = Self.scrollEvent(x: x, y: y) else { return }
        event.location = anchor
        event.post(tap: .cgSessionEventTap)
    }

    // x and y are how far to move through the content (down and right are positive); a wheel delta is the
    // other way round, positive scrolling up and left.
    static func scrollEvent(x: Double, y: Double) -> CGEvent? {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                            wheel1: Int32(-y), wheel2: Int32(-x), wheel3: 0)
        event?.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }

    private func click(at point: CGPoint) {
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .center)
            event?.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event?.post(tap: .cgSessionEventTap)
        }
    }
}

// The gesture itself: how far the mouse is from where the wheel went down, and the scroll that gives.
struct WheelDrag {
    static let deadZone = 8.0
    // Pixels of scroll per frame for each pixel the mouse is past the dead zone.
    static let gain = 0.15

    private(set) var isHolding = false
    private var moved = false
    private var offset = (x: 0.0, y: 0.0)

    mutating func press() {
        isHolding = true
        moved = false
        offset = (0, 0)
    }

    mutating func move(dx: Double, dy: Double) {
        offset.x += dx
        offset.y += dy
        if max(abs(offset.x), abs(offset.y)) > Self.deadZone { moved = true }
    }

    // True when the wheel was let go without the mouse leaving the dead zone: that was a click.
    mutating func release() -> Bool {
        isHolding = false
        return !moved
    }

    func step() -> (x: Double, y: Double) {
        let vertical = abs(offset.y) >= abs(offset.x)
        let along = vertical ? offset.y : offset.x
        guard abs(along) > Self.deadZone else { return (0, 0) }
        let speed = (abs(along) - Self.deadZone) * Self.gain * (along < 0 ? -1 : 1)
        return vertical ? (0, speed) : (speed, 0)
    }
}
