import Foundation
import IOKit.hidsystem

// macOS's own mouse tracking speed, with a wider range than System Settings (which stops at 3). Each mouse
// has its own, so two connected mice can differ; MouseProfiles remembers them and puts them back.
enum PointerSpeed {
    static let maximum = 16.0
    private static let property = "HIDMouseAcceleration" as CFString
    private static let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)

    // Connected mice by model name, the most recently connected last.
    static func mice() -> [String] {
        order(services().compactMap { service in name(of: service).map { (name: $0, id: registryID(service)) } })
    }

    // Registry IDs only grow, so the highest is the newest connection. Two of the same model count once.
    static func order(_ devices: [(name: String, id: UInt64)]) -> [String] {
        var names: [String] = []
        for device in devices.sorted(by: { $0.id < $1.id }) {
            names.removeAll { $0 == device.name }
            names.append(device.name)
        }
        return names
    }

    static func current(for mouse: String) -> Double? {
        services(named: mouse).lazy.compactMap { IOHIDServiceClientCopyProperty($0, property) as? Int }.first
            .map { Double($0) / 65536 }
    }

    static func set(_ speed: Double, for mouse: String) {
        let fixed = Int((speed * 65536).rounded()) as CFNumber
        services(named: mouse).forEach { IOHIDServiceClientSetProperty($0, property, fixed) }
    }

    // The slider is squared so the everyday 0–3 range gets most of its travel; tenths are plenty.
    static func speed(atSlider position: Double) -> Double { (maximum * position * position * 10).rounded() / 10 }
    static func slider(for speed: Double) -> Double { min(1, (max(0, speed) / maximum).squareRoot()) }

    // Mice carry the property; the built-in trackpad has its own. Keyboards with a pointer part (Logitech's
    // MX Keys) carry it too, but they also have media keys, which mice don't, so they're left out.
    private static func services() -> [IOHIDServiceClient] {
        let all = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
        return all.filter {
            IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0
                && IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_Consumer), UInt32(kHIDUsage_Csmr_ConsumerControl)) == 0
                && IOHIDServiceClientCopyProperty($0, property) != nil
        }
    }

    private static func services(named mouse: String) -> [IOHIDServiceClient] {
        services().filter { name(of: $0) == mouse }
    }

    private static func name(of service: IOHIDServiceClient) -> String? {
        IOHIDServiceClientCopyProperty(service, kIOHIDProductKey as CFString) as? String
    }

    private static func registryID(_ service: IOHIDServiceClient) -> UInt64 {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0
    }

    // Reads each mouse's speed and writes the same value back, so it proves access without changing anything.
    static func selfTestReport() -> String {
        let mice = mice()
        guard !mice.isEmpty else { return "pointer speed: no mouse found" }
        return mice.map { mouse in
            let speed = current(for: mouse)
            let accepted = speed.map { speed in
                services(named: mouse).map { IOHIDServiceClientSetProperty($0, property, Int((speed * 65536).rounded()) as CFNumber) }
            } ?? []
            return "\(mouse): pointer speed \(speed.map { "\($0)" } ?? "nil"), write same value accepted \(accepted), after \(current(for: mouse).map { "\($0)" } ?? "nil")"
        }.joined(separator: "\n")
    }
}
