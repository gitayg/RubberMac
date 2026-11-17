import CoreGraphics
import Foundation

// Screens whose brightness macOS sets itself keep their brightness keys, so their real backlight is never swapped for
// software dimming: the built-in one, Apple's own displays (Studio Display, Pro Display XDR: Apple's vendor number)
// and any other macOS drives itself, like LG's UltraFine, which has LG's number. DisplayServices answers the last; it's
// private, so it's looked up at run time, and without it the vendor number still keeps Apple's displays with macOS.
extension MediaKeys {
    static let appleVendor: UInt32 = 0x610

    static func macOSSetsBrightness(builtIn: Bool, vendor: UInt32, displayServices: Bool) -> Bool {
        builtIn || vendor == appleVendor || displayServices
    }

    static func macOSSetsBrightness(_ display: CGDirectDisplayID) -> Bool {
        macOSSetsBrightness(builtIn: CGDisplayIsBuiltin(display) != 0, vendor: CGDisplayVendorNumber(display),
                            displayServices: displayServicesCanChange?(display) ?? false)
    }

    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

    // nil if this macOS doesn't have it.
    static let displayServicesCanChange: ((CGDirectDisplayID) -> Bool)? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(framework, "DisplayServicesCanChangeBrightness") else { return nil }
        let call = unsafeBitCast(symbol, to: CanChangeBrightness.self)
        return { call($0) }
    }()
}
