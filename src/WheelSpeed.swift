import AppKit

// Scales how far each turn of a mouse wheel scrolls. Trackpad and Magic Mouse swipes are left alone.
final class WheelSpeed: TapHandler {
    static let range = 0.5...8.0

    var multiplier = 1.0
    var isActive: Bool { multiplier != 1 }

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard type == .scrollWheel, Self.isWheel(event) else { return event }
        Self.scale(event, by: multiplier)
        return event
    }

    // Trackpads and the Magic Mouse scroll in phases (began, changed, ended, then momentum); a wheel has none.
    // Smooth-scrolling mouse drivers send pixel deltas without phases, so they count as a wheel too.
    static func isWheel(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0
            && event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0
            && event.getIntegerValueField(.eventSourceUserData) != WheelDragScroll.marker
    }

    // Setting the line count recomputes the other two deltas, so it goes first. A notch never drops to zero
    // lines, or apps that count lines would stop scrolling at low speeds.
    static func scale(_ event: CGEvent, by factor: Double) {
        let axes: [(CGEventField, CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1),
            (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2),
        ]
        for (lines, fixed, points) in axes {
            let l = event.getIntegerValueField(lines)
            let f = event.getDoubleValueField(fixed)
            let p = event.getIntegerValueField(points)
            guard l != 0 || f != 0 || p != 0 else { continue }
            let scaled = Int64((Double(l) * factor).rounded())
            event.setIntegerValueField(lines, value: scaled == 0 && l != 0 ? l.signum() : scaled)
            event.setDoubleValueField(fixed, value: f * factor)
            event.setIntegerValueField(points, value: Int64((Double(p) * factor).rounded()))
        }
    }

    // The slider is logarithmic: 1× sits a quarter of the way along, 2× in the middle. Tenths, so 1× is easy to hit.
    static func multiplier(atSlider position: Double) -> Double {
        (range.lowerBound * pow(range.upperBound / range.lowerBound, position) * 10).rounded() / 10
    }

    static func slider(for multiplier: Double) -> Double {
        let clamped = min(max(multiplier, range.lowerBound), range.upperBound)
        return log2(clamped / range.lowerBound) / log2(range.upperBound / range.lowerBound)
    }
}
