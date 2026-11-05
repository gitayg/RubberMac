import CoreGraphics
import Foundation
import IOKit

// Collects matching facts from CoreDisplay and the IORegistry (Apple Silicon).
// Layout as used by MonitorControl's Arm64DDC and Lunar: the DCPAVServiceProxy under dcpextN
// drives the framebuffer under dispextN, and that framebuffer carries the EDID ProductAttributes.
enum DDCRegistry {
    struct DisplayInfo {
        let facts: DDCMatch.Display
        let name: String
        let isVirtual: Bool
    }

    struct Service {
        let facts: DDCMatch.Service
        let handle: CFTypeRef?
    }

    static func info(_ id: CGDirectDisplayID) -> DisplayInfo {
        let dict = createInfo?(id)?.takeRetainedValue() as? [String: Any] ?? [:]
        let names = dict["DisplayProductName"] as? [String: String] ?? [:]
        let facts = DDCMatch.Display(id: id, vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                                     serial: CGDisplaySerialNumber(id), location: dict["IODisplayLocation"] as? String)
        return DisplayInfo(facts: facts, name: names["en_US"] ?? names.values.first ?? "Display \(id)",
                           isVirtual: (dict["kCGDisplayIsVirtualDevice"] as? NSNumber)?.boolValue ?? false)
    }

    // External DCP AV services only; each one paired with its framebuffer's facts.
    static func services() -> [Service] {
        var result: [Service] = []
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        while case let proxy = IOIteratorNext(iterator), proxy != 0 {
            defer { IOObjectRelease(proxy) }
            guard property(proxy, "Location") as? String == "External", let disp = framebufferParent(of: proxy) else { continue }
            result.append(Service(facts: framebufferFacts(disp), handle: DDCTransport.open(proxy)))
        }
        return result
    }

    private typealias CreateInfo = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    // CoreDisplay isn't linked by build.sh, so look the symbol up at run time.
    private static let createInfo: CreateInfo? = {
        guard let lib = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
              let sym = dlsym(lib, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
        return unsafeBitCast(sym, to: CreateInfo.self)
    }()

    // dcpextN serves dispextN; the main dcp serves disp0 (HDMI on some Macs).
    private static func framebufferParent(of proxy: io_registry_entry_t) -> String? {
        var entry = proxy
        IOObjectRetain(entry)
        while true {
            if let n = name(of: entry) {
                if n.hasPrefix("dcpext"), Int(n.dropFirst(6)) != nil { IOObjectRelease(entry); return "disp" + n.dropFirst(3) }
                if n == "dcp" { IOObjectRelease(entry); return "disp0" }
            }
            var parent = io_registry_entry_t()
            let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard kr == KERN_SUCCESS else { return nil }
            entry = parent
        }
    }

    private static func framebufferFacts(_ disp: String) -> DDCMatch.Service {
        let none = DDCMatch.Service(key: disp, framebufferPath: nil, vendor: nil, product: nil, serial: nil)
        let parent = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching(disp))
        guard parent != 0 else { return none }
        defer { IOObjectRelease(parent) }
        guard let fb = child(of: parent, named: ["AppleCLCD2", "IOMobileFramebufferShim"]) else { return none }
        defer { IOObjectRelease(fb) }
        let product = (property(fb, "DisplayAttributes") as? [String: Any])?["ProductAttributes"] as? [String: Any]
        return DDCMatch.Service(key: disp, framebufferPath: path(of: fb), vendor: product?["LegacyManufacturerID"] as? Int,
                                product: product?["ProductID"] as? Int, serial: product?["SerialNumber"] as? Int)
    }

    private static func child(of entry: io_registry_entry_t, named names: [String]) -> io_registry_entry_t? {
        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(entry, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let next = IOIteratorNext(iterator), next != 0 {
            if let n = name(of: next), names.contains(n) { return next }
            IOObjectRelease(next)
        }
        return nil
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func name(of entry: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)  // io_name_t
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func path(of entry: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 512)  // io_string_t
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &buffer) == KERN_SUCCESS else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
