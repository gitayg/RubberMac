import CoreGraphics
import Synchronization

// At the HID tap, the earliest place an app can change the pointer's moves and ahead of FullScreenDock's
// session-level tap, keeps other screens' Dock edges from being pushed: a move onto one goes on one point short of
// it, with nothing pushing past. Moves everywhere else, and along the edge, go on as they were. Runs on the tap's
// own thread.
final class DockScreenGuard: TapHandler {
    private let state = Mutex<DockScreenLayout?>(nil)
    private let edge: () -> FullScreenDock.Edge
    // Moves seen and moves held since the layout was set, for the self-tests.
    private let counts = Mutex<(seen: Int, held: Int)>((0, 0))

    init(edge: @escaping () -> FullScreenDock.Edge) {
        self.edge = edge
    }

    var layout: DockScreenLayout? {
        get { state.withLock { $0 } }
        set {
            state.withLock { $0 = newValue }
            counts.withLock { $0 = (0, 0) }
        }
    }

    var isActive: Bool { layout != nil }
    var seen: Int { counts.withLock { $0.seen } }
    var heldCount: Int { counts.withLock { $0.held } }

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard let layout else { return event }
        counts.withLock { $0.seen += 1 }
        let point = event.location
        guard let index = DockScreenGeometry.screen(at: point, in: layout.screens), !layout.isFree(index),
              DockScreenGeometry.nearSomeEdge(point, of: layout.screens[index], depth: layout.depth) else { return event }
        let delta = CGVector(dx: CGFloat(event.getIntegerValueField(.mouseEventDeltaX)), dy: CGFloat(event.getIntegerValueField(.mouseEventDeltaY)))
        guard let held = DockScreenGeometry.held(point, delta: delta, edge: edge(), layout: layout) else { return event }
        event.location = held.point
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(held.delta.dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(held.delta.dy))
        counts.withLock { $0.held += 1 }
        return event
    }
}
