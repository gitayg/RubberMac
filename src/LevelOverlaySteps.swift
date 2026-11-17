import Foundation

// The levels the keys step through, on macOS's own grid: 16 steps, or 64 with ⌥⇧. A level a slider left between
// two steps goes to the nearest one first, as macOS does.
enum LevelSteps {
    static let segments = 16

    static func volume(_ volume: Float, up: Bool, fine: Bool) -> Float {
        let grid = Float(fine ? segments * 4 : segments)
        let index = (min(max(volume, 0), 1) * grid).rounded() + (up ? 1 : -1)
        return min(max(index, 0), grid) / grid
    }

    static func brightness(_ percent: Int, up: Bool, fine: Bool) -> Int {
        let grid = Double(fine ? segments * 4 : segments)
        let index = (Double(min(max(percent, 0), 100)) * grid / 100).rounded() + (up ? 1 : -1)
        return Int((min(max(index, 0), grid) * 100 / grid).rounded())
    }

    // Either volume key turns mute off, as macOS's do.
    static func apply(_ key: MediaKeys.Key, fine: Bool, volume: Float, muted: Bool) -> (volume: Float, muted: Bool) {
        switch key {
        case .mute: return (volume, !muted)
        case .volumeUp, .volumeDown: return (self.volume(volume, up: key.isUp, fine: fine), false)
        case .brightnessUp, .brightnessDown: return (volume, muted)
        }
    }

    static func volumeSymbol(_ volume: Float, muted: Bool) -> String {
        if muted || volume <= 0 { return "speaker.slash.fill" }
        if volume < 1 / 3 { return "speaker.wave.1.fill" }
        return volume < 2 / 3 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    static let brightnessSymbol = "sun.max.fill"
}
