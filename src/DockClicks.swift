import AppKit

// A plain click on a running app's Dock icon is held back from the Dock, and the picker decides once it's let go:
// open the app's window menu, or hand the click on to the Dock as it was. Dragging the icon hands the press on as soon
// as the pointer moves, so icons can still be moved, and so does holding it still, which asks for the Dock's own menu.
// Runs on the pointer tap's thread; the picker's part runs on main.
final class DockClicks: TapHandler {
    var isEnabled = false
    var isActive: Bool { isEnabled }

    // Main queue. A press on an icon, then its release (where it was pressed) or its being handed on to the Dock.
    var onPress: (DockItems.Item) -> Void = { _ in }
    var onRelease: (DockItems.Item, CGPoint) -> Void = { _, _ in }
    var onHandedOn: () -> Void = {}
    // Any other click, in screen coordinates (origin at the top left of the primary screen).
    var onOtherClick: (CGPoint) -> Void = { _ in }

    // Replaced by the self-test.
    var itemAt: (CGPoint) -> DockItems.Item? = DockItems.runningApp(at:)
    var post: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }

    // Marks the clicks this hands on, so they go through.
    private static let marker: Int64 = 0x5354_4443_4C4B  // "STDCLK"
    private static let dragDistance: CGFloat = 4
    // The Dock opens its menu for a press held a moment; past this, the press is handed on so it still can.
    private static let holdTime: TimeInterval = 0.6

    private var held: (item: DockItems.Item, at: CGPoint, press: Int)?
    private var presses = 0

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard isEnabled, event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return event }
        switch type {
        case .leftMouseDown:
            held = nil
            let point = event.location
            let modifiers = Modifiers.control | Modifiers.command | Modifiers.option | Modifiers.shift
            guard event.flags.rawValue & modifiers == 0, let item = itemAt(point) else {
                DispatchQueue.main.async { [onOtherClick] in onOtherClick(point) }
                return event
            }
            presses += 1
            let press = presses
            held = (item, point, press)
            DispatchQueue.main.async { [onPress] in onPress(item) }
            // On the thread handling events, so the press can't be let go of and handed on at once.
            RunLoop.current.add(Timer(timeInterval: Self.holdTime, repeats: false) { [weak self] _ in
                guard let self, self.held?.press == press else { return }
                self.handOnPress()
            }, forMode: .common)
            return nil
        case .leftMouseDragged:
            guard let held else { return event }
            guard hypot(event.location.x - held.at.x, event.location.y - held.at.y) > Self.dragDistance else { return nil }
            // The Dock gets the press it missed, then this move, in that order.
            handOnPress()
            if let move = event.copy() {
                move.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                post(move)
            }
            return nil
        case .leftMouseUp:
            guard let held else { return event }
            self.held = nil
            DispatchQueue.main.async { [onRelease] in onRelease(held.item, held.at) }
            return nil
        default:
            return event
        }
    }

    // A press the Dock never saw has no release coming either; nothing to hand on.
    func tapWasDisabled() {
        guard held != nil else { return }
        held = nil
        DispatchQueue.main.async { [onHandedOn] in onHandedOn() }
    }

    private func handOnPress() {
        guard let held else { return }
        self.held = nil
        post(Self.marked(.leftMouseDown, at: held.at))
        DispatchQueue.main.async { [onHandedOn] in onHandedOn() }
    }

    // Main thread: the click held back, handed on to the Dock where it was made.
    func handOn(at point: CGPoint) {
        post(Self.marked(.leftMouseDown, at: point))
        post(Self.marked(.leftMouseUp, at: point))
    }

    private static func marked(_ type: CGEventType, at point: CGPoint) -> CGEvent {
        let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)!
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }
}
