import AppKit

// An overlay window, which can blur what's behind it.
final class BackgroundDimWindow: NSWindow {
    // Private, as iTerm2 uses it for its blurred backgrounds; looked up at run time.
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetBlurRadius = @convention(c) (Int32, UInt32, Int32) -> Int32
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let connection = dlsym(skyLight, "SLSMainConnectionID").map { unsafeBitCast($0, to: MainConnection.self)() }
    private static let setBlurRadius = dlsym(skyLight, "SLSSetWindowBackgroundBlurRadius").map { unsafeBitCast($0, to: SetBlurRadius.self) }

    static var canBlur: Bool { connection != nil && setBlurRadius != nil }

    // The window server is told only on a change.
    var blurRadius: Int32 = 0 {
        didSet {
            guard blurRadius != oldValue, let connection = Self.connection, let setBlurRadius = Self.setBlurRadius else { return }
            _ = setBlurRadius(connection, UInt32(windowNumber), blurRadius)
        }
    }
}
