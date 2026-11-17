import AppKit
import Carbon.HIToolbox

// The live test's hands: posts real clicks, drags and keys, and runs the app's events in between. Every key is posted
// only while one of the test's own windows has the keyboard, and every click only while Start is on screen above
// everything, so nothing typed or clicked can reach another app.
final class StartMenuLiveDriver {
    private let source = CGEventSource(stateID: .hidSystemState)
    var ownsKeyboard: () -> Bool = { false }
    var note: (String) -> Void = { _ in }
    // Clicks and drags only land on the test's own windows, which are on top while this holds.
    var ownsPointer: () -> Bool = { false }

    init() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
    }

    func pump(_ seconds: TimeInterval) {
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until {
            if let event = NSApp.nextEvent(matching: .any, until: min(until, Date(timeIntervalSinceNow: 0.02)),
                                           inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        }
    }

    // Milliseconds until it held, nil if it didn't in time.
    @discardableResult
    func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Int? {
        let start = Date()
        while -start.timeIntervalSinceNow < seconds {
            if condition() { return Int(-start.timeIntervalSinceNow * 1000) }
            pump(0.02)
        }
        return condition() ? Int(seconds * 1000) : nil
    }

    // AppKit's screen coordinates (origin bottom left of the main screen) to the event system's (top left).
    static func global(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: NSScreen.screens[0].frame.height - point.y)
    }

    // The middle of a rectangle in a view, in the event system's coordinates.
    static func point(_ rect: NSRect, in view: NSView) -> CGPoint? {
        guard let window = view.window else { return nil }
        let onScreen = window.convertToScreen(view.convert(rect, to: nil))
        return global(NSPoint(x: onScreen.midX, y: onScreen.midY))
    }

    private func mouse(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton = .left) {
        Self.mouse(source, type, point, button)
    }

    private static func mouse(_ source: CGEventSource?, _ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton = .left) {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        // As a real press, held and moved, carries them; without them AppKit ends a drag as soon as it starts.
        if type != .mouseMoved {
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            if type != .leftMouseUp && type != .rightMouseUp { event?.setDoubleValueField(.mouseEventPressure, value: 1) }
        }
        event?.post(tap: .cghidEventTap)
    }

    // A press left without its release (a run stopped part way) is let go, so the Mac doesn't think the button is held.
    func releaseIfHeld() {
        guard CGEventSource.buttonState(.hidSystemState, button: .left) else { return }
        note("the left button read as held, so it was let go")
        mouse(.leftMouseUp, CGEvent(source: nil)?.location ?? .zero)
        pump(0.2)
    }

    func click(_ point: CGPoint) {
        guard pointerIsOurs() else { return }
        mouse(.mouseMoved, point)
        pump(0.12)
        mouse(.leftMouseDown, point)
        pump(0.08)
        mouse(.leftMouseUp, point)
        pump(0.25)
    }

    // A press, a move in small steps by way of the points given, a rest, and a release. AppKit runs a drag in a loop of
    // its own until the release, so a helper thread does the moving and letting go while this thread runs the events.
    // held runs on this thread just before the release, to see what the drag looks like then.
    func drag(_ from: CGPoint, _ to: CGPoint, via: [CGPoint] = [], held: @escaping () -> Void = {}) {
        guard pointerIsOurs() else { return }
        let done = StartMenuLiveFlag()
        let source = source
        let stops = [from] + via + [to]
        Thread.detachNewThread {
            Self.mouse(source, .mouseMoved, from)
            Thread.sleep(forTimeInterval: 0.15)
            Self.mouse(source, .leftMouseDown, from)
            Thread.sleep(forTimeInterval: 0.2)
            for (a, b) in zip(stops, stops.dropFirst()) {
                for step in 1...14 {
                    let t = CGFloat(step) / 14
                    Self.mouse(source, .leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                    Thread.sleep(forTimeInterval: 0.03)
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
            DispatchQueue.main.async { held() }
            Thread.sleep(forTimeInterval: 0.2)
            Self.mouse(source, .leftMouseUp, to)
            done.set(true)
        }
        waitFor(15) { done.isSet }
        pump(0.6)
    }

    // The right-click menu runs its own loop until it closes, so a helper thread closes it with Esc once `opened` says
    // it's open, and only then. True when it opened.
    func rightClick(_ point: CGPoint, opened: StartMenuLiveFlag) -> Bool {
        guard pointerIsOurs() else { return false }
        let source = source
        Thread.detachNewThread {
            for _ in 0..<60 {
                if opened.isSet {
                    Thread.sleep(forTimeInterval: 0.6)
                    for down in [true, false] {
                        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: down)?.post(tap: .cghidEventTap)
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        mouse(.mouseMoved, point)
        pump(0.12)
        mouse(.rightMouseDown, point, .right)
        pump(0.08)
        mouse(.rightMouseUp, point, .right)
        pump(1.0)
        return opened.isSet
    }

    private func pointerIsOurs() -> Bool {
        guard ownsPointer() else {
            note("not clicked: Start wasn't on screen")
            return false
        }
        return true
    }

    // false, pressing nothing, if none of the test's windows has the keyboard.
    @discardableResult
    func press(_ key: Int, _ flags: CGEventFlags = []) -> Bool {
        guard ownsKeyboard() else {
            note("not pressed: Start didn't have the keyboard")
            return false
        }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
            pump(0.04)
        }
        pump(0.15)
        return true
    }

    // As characters rather than key positions, so the keyboard's language doesn't matter.
    @discardableResult
    func type(_ text: String) -> Bool {
        for character in text {
            guard ownsKeyboard() else {
                note("not typed: Start didn't have the keyboard")
                return false
            }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                // Plain, or a ⌘ pressed just before is taken to be still held.
                event?.flags = []
                let units = Array(String(character).utf16)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event?.post(tap: .cghidEventTap)
            }
            pump(0.05)
        }
        pump(0.2)
        return true
    }
}

// Whether the menu has opened, read from the helper thread.
final class StartMenuLiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set(_ on: Bool) {
        lock.withLock { value = on }
    }
}

// A small window of the test's own to click on, standing for "somewhere else".
final class StartMenuLiveTarget: NSPanel {
    override var canBecomeKey: Bool { true }
}
