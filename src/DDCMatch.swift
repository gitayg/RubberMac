import CoreGraphics

// Pairs displays with DCP AV services. Two monitors of the same model differ only in their EDID
// serial and in the framebuffer path CoreDisplay reports, so a pair is accepted only when it is the
// single best candidate for both sides: never guess between twins and dim the wrong one.
enum DDCMatch {
    struct Display {
        let id: CGDirectDisplayID
        let vendor: UInt32
        let model: UInt32
        let serial: UInt32
        let location: String?  // CoreDisplay's IODisplayLocation: the framebuffer's IOService path
    }

    struct Service {
        let key: String  // the framebuffer's parent, e.g. dispext0
        let framebufferPath: String?
        let vendor: Int?
        let product: Int?
        let serial: Int?
    }

    enum Basis: Int, CustomStringConvertible {
        case model = 1, serial, location

        var description: String {
            switch self {
            case .location: "IODisplayLocation (framebuffer path)"
            case .serial: "EDID serial number"
            case .model: "vendor/product only (single candidate)"
            }
        }
    }

    struct Pair {
        let display: CGDirectDisplayID
        let service: String
        let basis: Basis
    }

    static func basis(_ d: Display, _ s: Service) -> Basis? {
        if let v = s.vendor, let p = s.product, UInt32(truncatingIfNeeded: v) != d.vendor || UInt32(truncatingIfNeeded: p) != d.model {
            return nil
        }
        if let location = d.location, location == s.framebufferPath { return .location }
        if let serial = s.serial, serial != 0, d.serial != 0 {
            return UInt32(truncatingIfNeeded: serial) == d.serial ? .serial : nil
        }
        return s.vendor != nil && s.product != nil ? .model : nil
    }

    static func assign(_ displays: [Display], _ services: [Service]) -> [CGDirectDisplayID: Pair] {
        var result: [CGDirectDisplayID: Pair] = [:]
        var taken = Set<String>()
        for rank in [Basis.location, .serial, .model] {
            let pairs = displays.filter { result[$0.id] == nil }.flatMap { d in
                services.filter { !taken.contains($0.key) && basis(d, $0) == rank }
                    .map { Pair(display: d.id, service: $0.key, basis: rank) }
            }
            for p in pairs where pairs.filter({ $0.display == p.display }).count == 1
                && pairs.filter({ $0.service == p.service }).count == 1 {
                result[p.display] = p
                taken.insert(p.service)
            }
        }
        return result
    }
}
