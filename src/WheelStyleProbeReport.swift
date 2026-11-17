import AppKit

// What the probe recorded, phase by phase, and what WheelStyle's own code makes of a copy of each event with each
// switch on, checked against what the hand did.
struct WheelStyleProbeReport {
    // The SDK's raw and accelerated wheel deltas for axis 1 (178 and 176), which it gives no Swift names; recorded to see
    // whether a fast spin's events say how many notches they carry.
    static let raw = CGEventField(rawValue: 178)!
    static let accelerated = CGEventField(rawValue: 176)!

    let samples: [WheelStyleProbe.Sample]
    let holds: [WheelStyleProbe.Hold]
    let watchedModifiers: Bool
    let modifierChanges: Int
    let naturalBefore: Bool
    let naturalAfter: Bool

    func text() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        let natural = naturalBefore
        let phases = WheelStyleProbe.phases
        let classic = WheelStyleChecks.handler(classic: true, natural: natural)
        let steady = WheelStyleChecks.handler(steady: true, natural: natural)
        let all = WheelStyleChecks.handler(classic: true, steady: true, zoom: true, natural: natural)
        // The zoom on a made-up front app with a Zoom In and Zoom Out, at the events' own times; nothing is pressed.
        var now = 0.0
        let zoom = WheelZoom(lookup: { _ in .found(ZoomMenu(zoomIn: ZoomItem(title: "Zoom In", key: "+"), zoomOut: ZoomItem(title: "Zoom Out", key: "-"))) },
                             press: { _, _ in })
        zoom.front = { ("probe.front.app", 1) }
        zoom.now = { now }

        func out(_ handler: WheelStyleHandler, _ sample: WheelStyleProbe.Sample) -> CGEvent? {
            handler.handle(.scrollWheel, sample.event.copy()!)
        }
        func isCommand(_ s: WheelStyleProbe.Sample) -> Bool { WheelZoom.wants(s.event.flags) }
        func notched(_ s: WheelStyleProbe.Sample) -> Bool { WheelNotch.isNotched(s.event) && !isCommand(s) }
        func range(_ values: [Double]) -> String {
            guard let low = values.min(), let high = values.max() else { return "none" }
            return String(format: "%.2f–%.2f", low, high)
        }
        func fixed(_ s: WheelStyleProbe.Sample) -> Double { abs(s.event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)) }
        func pad(_ value: Any, _ width: Int) -> String {
            let text = "\(value)"
            return String(repeating: " ", count: max(0, width - text.count)) + text
        }

        lines.append("Natural scrolling: \(naturalBefore ? "on" : "off") at the start, \(naturalAfter ? "on" : "off") at the end")
        // Each zoom step, and the way the wheel turned for the event that made it.
        var zoomSteps: [(zoomIn: Bool, turn: Int64)] = []
        for (index, phase) in phases.enumerated() {
            let mine = samples.filter { $0.phase == index }
            let seconds = (mine.last?.time ?? 0) - (mine.first?.time ?? 0)
            let notches = mine.filter { WheelNotch.isNotched($0.event) }
            let lineCounts = notches.map { abs($0.event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) }
            lines.append("")
            lines.append("== \(index + 1). \(phase.name): \(mine.count) events in \(String(format: "%.1f", seconds)) s; "
                         + "\(notches.count) notched (|lines| \(lineCounts.min() ?? 0)–\(lineCounts.max() ?? 0), |fixed| \(range(notches.map(fixed)))), "
                         + "\(mine.filter(isCommand).count) with ⌘, "
                         + "\(mine.filter { WheelSpeed.isWheel($0.event) && !WheelNotch.isNotched($0.event) }.count) smoothing steps (not whole lines), "
                         + "\(mine.filter { !WheelSpeed.isWheel($0.event) }.count) with a phase or momentum")
            lines.append("    #  gap ms | lines fixed points, axis 1 | axis 2 | phase momentum continuous inverted ⌘ counter raw accelerated | classic → | steady → | zoom")
            var previous: TimeInterval?
            for (n, s) in mine.enumerated() {
                let gap = previous.map { Int(((s.time - $0) * 1000).rounded()) }.map(String.init) ?? "-"
                previous = s.time
                let e = s.event
                let counter = s.polled.map { "+\(Int64(s.counter) - Int64($0))" } ?? "·"
                var zoomed = "-"
                if isCommand(s), WheelSpeed.isWheel(e) {
                    now = s.time
                    switch zoom.scroll(e.copy()!, natural: natural) {
                    case .zoomed(let zoomIn): zoomed = zoomIn ? "step in" : "step out"
                    case .held: zoomed = "held"
                    case .passed(let reason): zoomed = "passed: \(reason)"
                    }
                    if zoomed.hasPrefix("step") {
                        zoomSteps.append((zoomed == "step in", WheelNotch.deviceDirection(e, axis: 0, natural: natural)))
                    }
                }
                lines.append("  \(pad(n + 1, 3)) \(pad(gap, 7)) | " + WheelStyleChecks.describe(e).replacingOccurrences(of: " (turned round)", with: "")
                             + " | \(e.getIntegerValueField(.scrollWheelEventScrollPhase)) \(e.getIntegerValueField(.scrollWheelEventMomentumPhase))"
                             + " \(e.getIntegerValueField(.scrollWheelEventIsContinuous)) \(s.inverted ? 1 : 0) \(isCommand(s) ? "⌘" : "-") \(counter)"
                             + " \(String(format: "%.2f", e.getDoubleValueField(Self.raw))) \(String(format: "%.2f", e.getDoubleValueField(Self.accelerated)))"
                             + (e.getIntegerValueField(.eventSourceUserData) != 0 ? " user \(e.getIntegerValueField(.eventSourceUserData))" : "")
                             + " | \(WheelStyleChecks.describe(out(classic, s))) | \(WheelStyleChecks.describe(out(steady, s))) | \(zoomed)")
            }
        }
        lines.append("")

        check(naturalBefore == naturalAfter, "Natural scrolling stayed the same throughout")
        let turned = samples.filter { phases[$0.phase].turn != 0 && notched($0) }
        for index in phases.indices where phases[index].turn != 0 {
            let count = turned.filter { $0.phase == index }.count
            let smooth = samples.filter { $0.phase == index && WheelSpeed.isWheel($0.event) && !WheelNotch.isNotched($0.event) }.count
            check(count >= 3, "\(phases[index].name): \(count) notched wheel events recorded"
                  + (count < 3 && smooth > 0 ? "; \(smooth) smoothing steps (not whole lines) instead: a driver smooths this wheel, and Classic and Steady leave those alone" : ""))
        }

        // The wheel's own direction, read from what macOS sent.
        let misread = turned.filter { WheelNotch.deviceDirection($0.event, axis: 0, natural: natural) != phases[$0.phase].turn }
        check(!turned.isEmpty && misread.isEmpty, "the wheel's own direction is read right on \(turned.count - misread.count) of \(turned.count) notches: towards you as down, "
              + "away as up (macOS marked \(turned.filter(\.inverted).count) as turned round; Natural scrolling \(natural ? "on" : "off"))")

        // Classic.
        let wrongWay = turned.filter { classic.handle(.scrollWheel, $0.event.copy()!).map { WheelNotch.direction($0, axis: 0) } != phases[$0.phase].turn }
        check(!turned.isEmpty && wrongWay.isEmpty, "classic: towards you scrolls down and away up, as on Windows, on \(turned.count - wrongWay.count) of \(turned.count) notches")
        if natural {
            let kept = turned.filter { WheelNotch.direction(out(classic, $0)!, axis: 0) == WheelNotch.direction($0.event, axis: 0) }
            check(!turned.isEmpty && kept.isEmpty, "classic, Natural scrolling on: every notch is turned round (\(turned.count - kept.count) of \(turned.count))")
        } else {
            let changed = turned.filter { WheelStyleChecks.describe(out(classic, $0)) != WheelStyleChecks.describe($0.event) }
            check(!turned.isEmpty && changed.isEmpty, "classic, Natural scrolling off: every notch goes by untouched (\(turned.count - changed.count) of \(turned.count))")
            lines.append("untested here: Classic turning real notches round, which it does only with Natural scrolling on; "
                         + "turn it on in System Settings › Mouse and run again to see it")
        }

        // Steady.
        func oneNotch(_ s: WheelStyleProbe.Sample) -> String {
            WheelNotch.axes.indices.map { axis in
                let sign = WheelNotch.direction(s.event, axis: axis)
                return "\(sign * WheelNotch.lines) \(String(format: "%.2f", Double(sign * WheelNotch.lines))) \(sign * WheelNotch.lines * WheelNotch.pointsPerLine)"
            }.joined(separator: " | ")
        }
        let uneven = turned.filter { WheelStyleChecks.describe(out(steady, $0)) != oneNotch($0) }
        let slow = turned.filter { $0.phase != 1 }, fast = turned.filter { $0.phase == 1 }
        check(!slow.isEmpty && !fast.isEmpty && uneven.isEmpty, "steady: \(slow.count) slow notches (|fixed| \(range(slow.map(fixed)))) and \(fast.count) fast ones (|fixed| \(range(fast.map(fixed)))) "
              + "each scroll \(WheelNotch.lines) lines, \(WheelNotch.lines).00 and \(WheelNotch.lines * WheelNotch.pointsPerLine) points, their own way"
              + (uneven.isEmpty ? "" : "; \(uneven.count) didn't"))

        // Trackpad and Magic Mouse.
        let swipes = samples.filter { !WheelSpeed.isWheel($0.event) }
        if swipes.isEmpty {
            lines.append("no trackpad or Magic Mouse events were recorded (none here, or the phase was skipped)")
        } else {
            let touched = swipes.filter { WheelStyleChecks.describe(out(all, $0)) != WheelStyleChecks.describe($0.event) }
            check(touched.isEmpty, "every switch on, \(swipes.count - touched.count) of \(swipes.count) trackpad or Magic Mouse events go by untouched")
        }

        // ⌘ + wheel.
        let command = samples.filter { $0.phase == WheelStyleProbe.zoomPhase && isCommand($0) && WheelSpeed.isWheel($0.event) }
        let wrongZoom = zoomSteps.filter { $0.zoomIn != ($0.turn > 0) }
        check(!command.isEmpty && !zoomSteps.isEmpty && wrongZoom.isEmpty,
              "⌘ + wheel: \(zoomSteps.count) steps (\(zoomSteps.map { $0.zoomIn ? "in" : "out" }.joined(separator: " "))) from \(samples.filter { isCommand($0) && WheelSpeed.isWheel($0.event) }.count) "
              + "⌘ scrolls, each the way its notch turned: in away from you, out towards you"
              + (wrongZoom.isEmpty ? "" : "; \(wrongZoom.count) the wrong way"))

        // The ⌘ tap that opens Start: the system's counter misses some mice, so the mouse tap counts scrolls itself.
        let read = samples.filter { $0.polled != nil }
        lines.append("the system's scroll counter moved for \(read.filter { $0.counter > $0.polled! }.count) of the \(read.count) scrolls it was read around")
        if !watchedModifiers {
            check(false, "a listen-only tap could be made to watch ⌘ go down and up (flagsChanged)")
        } else {
            let scrolled = holds.filter { $0.scrolls > 0 }, bare = holds.filter { $0.scrolls == 0 }
            check(modifierChanges > 0, "the probe saw ⌘ go down and up: \(modifierChanges) modifier changes"
                  + (modifierChanges == 0 ? " (none: a listen-only tap may need Input Monitoring for them)" : ""))
            check(!scrolled.isEmpty && scrolled.allSatisfy { !$0.opened },
                  "⌘ held while the wheel turned, then let go: Start would open after \(scrolled.filter(\.opened).count) of \(scrolled.count) "
                  + "(\(scrolled.map { "\($0.scrolls) scrolls" }.joined(separator: ", ")))")
            lines.append("⌘ pressed and let go with no scroll: \(bare.count), of which \(bare.filter(\.opened).count) would open Start, as a ⌘ tap should")
        }
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }
}
