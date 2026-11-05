import CoreGraphics
import Foundation

struct ExternalDisplay {
    let id: CGDirectDisplayID
    let name: String
}

// DDC/CI brightness control for external monitors, over Apple Silicon's IOAVService I2C.
// Every call blocks for tens of milliseconds: call from a background queue, never the main thread.
// Displays driven by DisplayLink, AirPlay or Sidecar are virtual: they have no DDC path and read as nil.
enum DDC {
    nonisolated(unsafe) private static var maxima: [CGDirectDisplayID: UInt16] = [:]

    static func externalDisplays() -> [ExternalDisplay] {
        let ids = externalIDs()
        let names = ids.map { DDCRegistry.info($0).name }
        return zip(ids, names).map { id, name in
            // Identical models get their position so a menu can tell them apart.
            ExternalDisplay(id: id, name: names.filter { $0 == name }.count > 1 ? "\(name) (\(position(of: id)))" : name)
        }
    }

    // Percent 0...100, or nil when the monitor doesn't answer.
    static func brightness(of display: CGDirectDisplayID) -> Int? {
        guard let handle = handle(for: display), let value = DDCTransport.read(handle, DDCProtocol.brightness) else { return nil }
        maxima[display] = value.max
        return DDCProtocol.percent(current: value.current, max: value.max)
    }

    @discardableResult
    static func setBrightness(_ percent: Int, of display: CGDirectDisplayID) -> Bool {
        guard let handle = handle(for: display) else { return false }
        if maxima[display] == nil, let value = DDCTransport.read(handle, DDCProtocol.brightness) {
            maxima[display] = value.max
        }
        guard let max = maxima[display] else { return false }
        return DDCTransport.write(handle, DDCProtocol.brightness, DDCProtocol.raw(percent: percent, max: max))
    }

    static func selfTestReport() -> String {
        let services = DDCRegistry.services()
        let infos = externalIDs().map(DDCRegistry.info)
        let pairs = DDCMatch.assign(infos.map(\.facts), services.map(\.facts))
        var lines = ["DDC self-test (read-only)", "External DCP AV services: \(services.count)"]
        for s in services {
            let f = s.facts
            lines.append("  \(f.key): framebuffer \(f.framebufferPath ?? "not found"), vendor \(text(f.vendor)) product \(text(f.product)) serial \(text(f.serial)), I2C handle \(s.handle == nil ? "no" : "yes")")
        }
        lines.append("External displays: \(infos.count)")
        for info in infos {
            let f = info.facts
            lines.append("  \(f.id) \(info.name) (\(position(of: f.id))): vendor \(f.vendor) model \(f.model) serial \(f.serial)\(info.isVirtual ? ", VIRTUAL (DisplayLink/AirPlay/Sidecar: no DDC path)" : "")")
            lines.append("    IODisplayLocation: \(f.location ?? "none")")
            guard let pair = pairs[f.id], let handle = services.first(where: { $0.facts.key == pair.service })?.handle else {
                let candidates = services.compactMap { s in DDCMatch.basis(f, s.facts).map { "\(s.facts.key) by \($0)" } }
                lines.append("    match: none" + (candidates.isEmpty ? " (no candidate service)" : " (ambiguous: \(candidates.joined(separator: ", ")))"))
                lines.append("    brightness: n/a")
                continue
            }
            lines.append("    match: \(pair.service) by \(pair.basis)")
            if let value = DDCTransport.read(handle, DDCProtocol.brightness) {
                lines.append("    brightness: \(DDCProtocol.percent(current: value.current, max: value.max))% (raw \(value.current)/\(value.max))")
            } else {
                lines.append("    brightness: no reply (\(DDCTransport.lastStatus))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func handle(for display: CGDirectDisplayID) -> CFTypeRef? {
        let services = DDCRegistry.services()
        let pairs = DDCMatch.assign(externalIDs().map { DDCRegistry.info($0).facts }, services.map(\.facts))
        guard let pair = pairs[display] else { return nil }
        return services.first { $0.facts.key == pair.service }?.handle
    }

    private static func externalIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
    }

    private static func position(of id: CGDirectDisplayID) -> String {
        let main = CGDisplayBounds(CGMainDisplayID())
        let b = CGDisplayBounds(id)
        if id == CGMainDisplayID() { return "main" }
        if b.maxX <= main.minX { return "left" }
        if b.minX >= main.maxX { return "right" }
        return b.maxY <= main.minY ? "above" : "below"
    }

    private static func text(_ value: Int?) -> String { value.map(String.init) ?? "?" }
}
