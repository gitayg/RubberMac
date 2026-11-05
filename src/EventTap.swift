import AppKit

protocol TapHandler: AnyObject {
    var isActive: Bool { get }
    // Returns the event to pass on (possibly rewritten), or nil to swallow it.
    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent?
    // The system switched the tap off for a moment (a slow callback); events in that gap went past unseen.
    func tapWasDisabled()
}

extension TapHandler {
    func tapWasDisabled() {}
}

// One event tap shared by a set of handlers, run in order. It runs only while one of them is on.
// Needs Accessibility: a tap that changes events is refused without it.
// With ownThread, the handlers run on a thread of the tap's own instead of the main one, so a busy main thread
// (saving layouts, an app slow to answer Accessibility) doesn't hold up typing. They then must not touch AppKit
// there: Frontmost stands in for NSWorkspace, and real work goes to the main queue.
final class EventTap {
    private let name: String
    private let types: [CGEventType]
    private let location: CGEventTapLocation
    private let handlers: [TapHandler]
    private let ownThread: Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var lastLagLog = Date.distantPast

    var isRunning: Bool { tap != nil }

    init(name: String, types: [CGEventType], location: CGEventTapLocation, ownThread: Bool = false, handlers: [TapHandler]) {
        self.name = name
        self.types = types
        self.location = location
        self.ownThread = ownThread
        self.handlers = handlers
    }

    // Call after changing any handler's settings, or once Accessibility is granted.
    func update() {
        if handlers.contains(where: \.isActive) { start() } else { stop() }
    }

    private func start() {
        guard tap == nil else { return }
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, info in
            Unmanaged<EventTap>.fromOpaque(info!).takeUnretainedValue().handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log("\(name) tap: not created (Accessibility not granted?)")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        Frontmost.start()
        if ownThread {
            let started = DispatchSemaphore(value: 0)
            var loop: CFRunLoop?
            let thread = Thread {
                loop = CFRunLoopGetCurrent()
                CFRunLoopAddSource(loop, source, .commonModes)
                started.signal()
                // Returns once stop() takes the source away.
                CFRunLoopRun()
            }
            thread.name = "\(name) tap"
            thread.qualityOfService = .userInteractive
            thread.start()
            started.wait()
            runLoop = loop
        } else {
            runLoop = CFRunLoopGetMain()
            CFRunLoopAddSource(runLoop, source, .commonModes)
        }
        log("\(name) tap: on (\(handlers.filter(\.isActive).map { "\(type(of: $0))" }.joined(separator: ", ")))")
    }

    private func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        if ownThread, let runLoop { CFRunLoopStop(runLoop) }
        runLoop = nil
        self.tap = nil
        source = nil
        log("\(name) tap: off")
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            handlers.forEach { $0.tapWasDisabled() }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown { noteLag(event) }
        var current = event
        for handler in handlers where handler.isActive {
            guard let next = handler.handle(type, current) else { return nil }
            current = next
        }
        return Unmanaged.passUnretained(current)
    }

    // A key waits while the tap's thread is busy. Logs how long (never which key), at most once a second, when it's
    // long enough to feel.
    private func noteLag(_ event: CGEvent) {
        guard let waited = Self.waited(event), waited > 0.05, -lastLagLog.timeIntervalSinceNow > 1 else { return }
        lastLagLog = Date()
        DispatchQueue.main.async { [name] in log("\(name) tap: a key waited \(Int(waited * 1000)) ms") }
    }

    // Seconds since the keyboard sent the event. Its timestamp is in nanoseconds or in mach ticks depending on the
    // Mac, so whichever reads as recent is taken; nil for events with none, like posted ones.
    private static func waited(_ event: CGEvent) -> TimeInterval? {
        let stamp = event.timestamp
        guard stamp != 0 else { return nil }
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        let ticks = mach_absolute_time()
        let nanos = ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
        let candidates = [nanos >= stamp ? Double(nanos - stamp) : nil,
                          ticks >= stamp ? Double(ticks - stamp) * Double(timebase.numer) / Double(timebase.denom) : nil]
        return candidates.compactMap { $0 }.map { $0 / 1e9 }.filter { $0 < 60 }.min()
    }
}
