import AppKit

// Brightness per screen: real backlight over DDC where the monitor answers, otherwise a software
// dark layer (the only option for DisplayLink-driven monitors). Software levels are remembered
// per monitor. DDC writes go to a background queue, newest value only, so slider drags don't pile up.
final class Brightness {
    struct Display {
        let id: CGDirectDisplayID
        let name: String
        let hardware: Bool
    }

    static let step = 10
    static let softwareMinimum = 10

    private let queue = DispatchQueue(label: "screentools.ddc")
    private let overlay = ScreenOverlay(level: ScreenOverlay.brightnessLevel)
    private(set) var displays: [Display] = []
    private(set) var levels: [CGDirectDisplayID: Int] = [:]
    private var pending: [CGDirectDisplayID: Int] = [:]
    private var draining = false

    var allSoftware: Bool { !displays.isEmpty && displays.allSatisfy { !$0.hardware } }

    func refresh(then done: @escaping () -> Void) {
        queue.async {
            var hardware: [CGDirectDisplayID: Int] = [:]
            for display in DDC.externalDisplays() {
                if let level = DDC.brightness(of: display.id) { hardware[display.id] = level }
            }
            DispatchQueue.main.async {
                self.displays = NSScreen.screens.compactMap { screen in
                    guard let id = screen.displayID else { return nil }
                    return Display(id: id, name: screen.localizedName, hardware: hardware[id] != nil)
                }
                for display in self.displays {
                    self.levels[display.id] = hardware[display.id] ?? Self.savedLevel(display.id)
                }
                self.applySoftware()
                done()
            }
        }
    }

    func set(_ percent: Int, for id: CGDirectDisplayID) {
        guard let display = displays.first(where: { $0.id == id }) else { return }
        let value = min(max(percent, display.hardware ? 0 : Self.softwareMinimum), 100)
        levels[id] = value
        if display.hardware {
            pending[id] = value
            guard !draining else { return }
            draining = true
            queue.async { self.drain() }
        } else {
            Self.saveLevel(value, id)
            applySoftware()
        }
    }

    // Keys change every screen together.
    func stepAll(_ direction: Int) {
        refresh { [self] in
            for display in displays {
                set((levels[display.id] ?? 100) + direction * Self.step, for: display.id)
            }
        }
    }

    private func applySoftware() {
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let display = displays.first(where: { $0.id == id }), !display.hardware
            else { continue }
            overlay.set(Self.darkness(forPercent: levels[id] ?? 100), on: screen)
        }
    }

    static func darkness(forPercent percent: Int) -> CGFloat {
        CGFloat(100 - min(max(percent, 0), 100)) / 100 * 0.9
    }

    private func drain() {
        while true {
            let next: (CGDirectDisplayID, Int)? = DispatchQueue.main.sync {
                guard let item = pending.first else { draining = false; return nil }
                pending[item.key] = nil
                return (item.key, item.value)
            }
            guard let (id, value) = next else { return }
            DDC.setBrightness(value, of: id)
        }
    }

    // Display IDs can change when a monitor reconnects; vendor/model/serial don't.
    private static func key(_ id: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    private static func savedLevel(_ id: CGDirectDisplayID) -> Int {
        let saved = UserDefaults.standard.dictionary(forKey: "softwareBrightness") as? [String: Int]
        return saved?[key(id)] ?? 100
    }

    private static func saveLevel(_ value: Int, _ id: CGDirectDisplayID) {
        var saved = UserDefaults.standard.dictionary(forKey: "softwareBrightness") as? [String: Int] ?? [:]
        saved[key(id)] = value
        UserDefaults.standard.set(saved, forKey: "softwareBrightness")
    }
}
