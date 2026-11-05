import CoreGraphics

// Where a camera stands in front of a screen, as fractions of that screen measured from its top-left, so it
// stays put when the resolution or the arrangement changes. The screen is known by vendor, model and serial.
struct CameraArea: Codable, Equatable {
    let display: String
    let name: String
    let x, y, width, height: Double

    // `box` and `screen` in AppKit coordinates (bottom-left origin).
    init(display: String, name: String, box: CGRect, on screen: CGRect) {
        self.display = display
        self.name = name
        x = (box.minX - screen.minX) / screen.width
        y = (screen.maxY - box.maxY) / screen.height
        width = box.width / screen.width
        height = box.height / screen.height
    }

    // Back in AppKit coordinates on the screen's current frame, edges on whole points.
    func box(on screen: CGRect) -> CGRect {
        let left = (screen.minX + x * screen.width).rounded(), right = (screen.minX + (x + width) * screen.width).rounded()
        let bottom = (screen.maxY - (y + height) * screen.height).rounded(), top = (screen.maxY - y * screen.height).rounded()
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    static func key(of display: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(display)):\(CGDisplayModelNumber(display)):\(CGDisplaySerialNumber(display))"
    }
}
