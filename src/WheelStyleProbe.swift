import AppKit

// --selftest wheelstyle probe: a real wheel, turned by hand while a small window says what to do. A listen-only tap
// records every scroll for about a minute; then a copy of each is put through WheelStyle's own code with each switch on,
// and what it would hand on is checked. A second listen-only tap sees ⌘ go down and up (modifiers only) and feeds a real
// CommandTap, to show a ⌘ + wheel keeps ⌘'s release from opening Start. The taps change no event, nothing is posted and
// no setting changes. It needs someone at the mouse, so it waits for no idle desktop; only for Accessibility and an
// unlocked screen.
enum WheelStyleProbe {
    struct Phase {
        let name: String
        let prompt: String
        let seconds: Double
        // -1 towards you, 1 away, 0 not one way.
        let turn: Int64
    }

    static let phases = [
        Phase(name: "slow down", prompt: "Turn the wheel slowly towards you (down), one notch at a time", seconds: 10, turn: -1),
        Phase(name: "fast down", prompt: "Now spin it fast towards you (down)", seconds: 8, turn: -1),
        Phase(name: "slow up", prompt: "Now turn it slowly away from you (up), one notch at a time", seconds: 8, turn: 1),
        Phase(name: "⌘ zoom", prompt: "Hold ⌘ and turn the wheel away from you a few notches, then towards you", seconds: 10, turn: 0),
        Phase(name: "trackpad", prompt: "Let go of ⌘. Now scroll on the trackpad, if there is one; otherwise just wait", seconds: 8, turn: 0),
        Phase(name: "⌘ tap", prompt: "Hold ⌘, turn the wheel a few notches, let go of ⌘. Two or three times. "
              + "(The RubberMAC you have installed may still open Start: that's what this checks is fixed.)", seconds: 12, turn: 0),
    ]
    static let lead: Double = 4
    static let zoomPhase = 3, tapPhase = 5

    // ⌘ pressed on its own and let go, while a phase was on.
    struct Hold {
        let phase: Int
        let scrolls: Int
        // What CommandTap made of the release: true would open Start.
        let opened: Bool
    }

    struct Sample {
        let phase: Int
        let time: TimeInterval
        // A copy, fed to the real code afterwards.
        let event: CGEvent
        let inverted: Bool
        // The system's scroll counter as the tap saw this event, and as last read while nothing was scrolling, if it
        // was read since the event before.
        let counter: UInt32
        let polled: UInt32?
    }

    final class Recorder {
        var phase = -1
        var samples: [Sample] = []
        var polled: UInt32?
        var holds: [Hold] = []
        var modifierChanges = 0
        private var tap = CommandTap()
        private var holding: Int?

        func record(_ event: CGEvent) {
            // As the mouse tap does, so the CommandTap below sees what RubberMAC's own would.
            WheelStyleHandler.noteSeen(event)
            if WheelZoom.wants(event.flags) { holding = holding.map { $0 + 1 } }
            guard phase >= 0, let copy = event.copy() else { return }
            samples.append(Sample(phase: phase, time: ProcessInfo.processInfo.systemUptime, event: copy,
                                  inverted: NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false,
                                  counter: Self.counter(), polled: polled))
            polled = nil
        }

        func poll() {
            polled = Self.counter()
        }

        // Every modifier change goes to a real CommandTap, read with the counters it reads in the keyboard tap.
        func modifiers(_ event: CGEvent) {
            let flags = event.flags.rawValue
            let opened = tap.feed(.flagsChanged, flags: flags, counters: CommandTap.Counters.now)
            if phase >= 0 { modifierChanges += 1 }
            switch flags & (Modifiers.control | Modifiers.command | Modifiers.option | Modifiers.shift) {
            case Modifiers.command:
                if holding == nil { holding = 0 }
            case 0:
                if let scrolls = holding, phase >= 0 { holds.append(Hold(phase: phase, scrolls: scrolls, opened: opened)) }
                holding = nil
            default:
                holding = nil
            }
        }

        static func counter() -> UInt32 { CGEventSource.counterForEventType(.combinedSessionState, eventType: .scrollWheel) }
    }

    static func report() -> String {
        guard AX.isTrusted else { return "skipped: accessibility not trusted" }
        guard !ScreenLock.isLocked else { return "skipped: the screen is locked" }
        let naturalBefore = WheelStyle.naturalScrolling()
        print("wheel probe: follow the small RubberMAC window for about \(Int(lead + phases.map(\.seconds).reduce(0, +))) s, keeping the pointer over it. "
              + "Natural scrolling is \(naturalBefore ? "on" : "off").")
        fflush(stdout)

        let recorder = Recorder()
        // Ahead of every tap already there (RubberMAC's own included), so it sees each scroll as macOS made it.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                                          callback: { _, type, event, info in
            if type == .scrollWheel, let info { Unmanaged<Recorder>.fromOpaque(info).takeUnretainedValue().record(event) }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(recorder).toOpaque()) else {
            return "FAIL a listen-only tap for scrolling could be made\nFAIL: 1 failed"
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        // ⌘ going down and up, for the CommandTap: modifiers only, never a key.
        let keys = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                     eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
                                     callback: { _, type, event, info in
            if type == .flagsChanged, let info { Unmanaged<Recorder>.fromOpaque(info).takeUnretainedValue().modifiers(event) }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(recorder).toOpaque())
        let keySource = keys.map { CFMachPortCreateRunLoopSource(kCFAllocatorDefault, $0, 0) }
        if let keySource { CFRunLoopAddSource(CFRunLoopGetMain(), keySource, .commonModes) }
        let window = ProbeWindow()
        window.show()
        var clock = ProcessInfo.processInfo.systemUptime
        window.say(step: "Get ready", prompt: "Put your hand on the mouse, with the pointer over this window", seconds: lead, clock,
                   count: { 0 }) { recorder.poll() }
        for (index, phase) in phases.enumerated() {
            clock += index == 0 ? lead : phases[index - 1].seconds
            recorder.phase = index
            let start = recorder.samples.count
            window.say(step: "\(index + 1) of \(phases.count)", prompt: phase.prompt, seconds: phase.seconds, clock,
                       count: { recorder.samples.count - start }) { recorder.poll() }
        }
        recorder.phase = -1
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        if let keys, let keySource {
            CGEvent.tapEnable(tap: keys, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), keySource, .commonModes)
        }
        window.close()
        return WheelStyleProbeReport(samples: recorder.samples, holds: recorder.holds, watchedModifiers: keys != nil,
                                     modifierChanges: recorder.modifierChanges, naturalBefore: naturalBefore,
                                     naturalAfter: WheelStyle.naturalScrolling()).text()
    }
}

// The probe's own small window, over every app and Space, full-screen ones too, so it can be seen wherever the user is.
final class ProbeWindow {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 200), styleMask: [.titled],
                                  backing: .buffered, defer: false)
    private let step = NSTextField(labelWithString: "")
    private let prompt = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")

    func show() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        window.title = "RubberMAC Wheel Probe"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        step.font = .systemFont(ofSize: 13, weight: .semibold)
        step.textColor = .secondaryLabelColor
        prompt.font = .systemFont(ofSize: 22, weight: .bold)
        status.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        status.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [step, prompt, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        prompt.preferredMaxLayoutWidth = 520
        window.contentView = stack
        window.center()
        window.orderFrontRegardless()
    }

    // Shows one step and runs the app until its time is up, the countdown and events seen kept current.
    func say(step: String, prompt: String, seconds: Double, _ start: TimeInterval, count: () -> Int, _ tick: () -> Void) {
        self.step.stringValue = step.uppercased()
        self.prompt.stringValue = prompt
        let end = start + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.02), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            tick()
            let left = Int((end - ProcessInfo.processInfo.systemUptime).rounded(.up))
            status.stringValue = "\(max(left, 0)) s left  ·  \(count()) scroll events"
        }
    }

    func close() {
        window.orderOut(nil)
    }
}
