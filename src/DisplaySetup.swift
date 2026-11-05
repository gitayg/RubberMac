import AppKit

// Which monitors are connected, and where, as far as telling saved layouts apart is concerned.
enum DisplaySetup {
    struct Display: Equatable {
        let vendor: UInt32
        let model: UInt32
        let serial: UInt32
        let bounds: CGRect
    }

    // Displays ordered by position, each as vendor:model:serial@x,y,wxh. Identical monitors are told
    // apart by serial; a serial of 0 leaves only the position in the arrangement to tell them apart.
    static func key(for displays: [Display]) -> String {
        displays
            .sorted { ($0.bounds.minX, $0.bounds.minY) < ($1.bounds.minX, $1.bounds.minY) }
            .map { d in
                let b = d.bounds.integral
                return "\(d.vendor):\(d.model):\(d.serial)@\(Int(b.minX)),\(Int(b.minY)),\(Int(b.width))x\(Int(b.height))"
            }
            .joined(separator: "|")
    }

    // A burst of display changes only needs a restore if the setup was different at some point;
    // a Dock or wake notification that leaves the same monitors in place does not.
    static func changed(seen: Set<String>, now: String) -> Bool {
        seen.union([now]).count > 1
    }

    static func currentDisplays() -> [Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map {
            Display(vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0),
                    serial: CGDisplaySerialNumber($0), bounds: CGDisplayBounds($0))
        }
    }

    static func currentKey() -> String { key(for: currentDisplays()) }

    static func currentName() -> String {
        NSScreen.screens.map(\.localizedName).joined(separator: " + ")
    }
}
