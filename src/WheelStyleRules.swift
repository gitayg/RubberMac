import AppKit

// What the switches do to one wheel event: turned back the way the wheel turns, and the same distance for every notch.
enum WheelNotch {
    // Windows scrolls 3 lines a notch out of the box. AppKit moves 10 points a line (NSScrollView, measured), and
    // macOS's own line events carry 10 points a line too, so a notch is 3 lines, 3.0 and 30 points.
    static let lines: Int64 = 3
    static let pointsPerLine: Int64 = 10

    // Has no name in the SDK: it's what NSEvent's isDirectionInvertedFromDevice reads (measured, 0 or 1).
    static let invertedField = CGEventField(rawValue: 137)!

    static let axes: [(lines: CGEventField, fixed: CGEventField, points: CGEventField)] = [
        (.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1),
        (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2),
    ]

    // A wheel notch: no phase or momentum, and in lines, or in whole lines if marked continuous. Logi Options+ posts its
    // wheel that way (an MX Master 3, measured: 1 line, 1.00 and 12 or 13 points a slow notch, 10 lines an event in free-spin).
    // A smoothing driver's steps of less than a line are left alone: a notch is many of them.
    static func isNotched(_ event: CGEvent) -> Bool {
        guard WheelSpeed.isWheel(event) else { return false }
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 else { return true }
        return axes.contains { axis in
            let fixed = event.getDoubleValueField(axis.fixed)
            return event.getIntegerValueField(axis.lines) != 0 && fixed != 0 && fixed == fixed.rounded()
        }
    }

    // macOS turned this event round for Natural scrolling: it says so on the event, or the setting is on.
    static func isTurnedRound(_ event: CGEvent, natural: Bool) -> Bool {
        natural || event.getIntegerValueField(invertedField) != 0
    }

    // The way the wheel itself turned on one axis: 1 away from you (or left), -1 towards you (or right), 0 not at all.
    static func deviceDirection(_ event: CGEvent, axis: Int, natural: Bool) -> Int64 {
        let sign = direction(event, axis: axis)
        return isTurnedRound(event, natural: natural) ? -sign : sign
    }

    // 1 scrolling up or left, -1 down or right. The fixed-point delta is the one apps read; a slow notch can have
    // a fraction of a line there and still a whole line in the line count.
    static func direction(_ event: CGEvent, axis: Int) -> Int64 {
        let (lines, fixed, points) = axes[axis]
        let f = event.getDoubleValueField(fixed)
        if f != 0 { return f > 0 ? 1 : -1 }
        let l = event.getIntegerValueField(lines)
        if l != 0 { return l.signum() }
        return event.getIntegerValueField(points).signum()
    }

    // Back the way the wheel turns, and no longer marked as turned round, as macOS sends it with Natural scrolling off.
    static func flip(_ event: CGEvent) {
        WheelSpeed.scale(event, by: -1)
        event.setIntegerValueField(invertedField, value: 0)
    }

    // One notch on each axis that moved, however fast the wheel turned. Setting the line count recomputes the other two
    // deltas (to 8 points a line), so it goes first.
    static func steady(_ event: CGEvent) {
        for (axis, (lines, fixed, points)) in axes.enumerated() {
            let sign = direction(event, axis: axis)
            guard sign != 0 else { continue }
            event.setIntegerValueField(lines, value: sign * Self.lines)
            event.setDoubleValueField(fixed, value: Double(sign * Self.lines))
            event.setIntegerValueField(points, value: sign * Self.lines * pointsPerLine)
        }
    }
}
