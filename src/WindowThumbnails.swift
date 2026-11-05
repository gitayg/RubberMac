import AppKit
import ScreenCaptureKit

// Small pictures of windows for the switcher, taken with ScreenCaptureKit each time it opens and kept until the next
// time, so the list shows the last ones right away. Needs Screen Recording; without it the switcher shows app icons.
// The pictures are only held in memory. Called on the main thread.
final class WindowThumbnails {
    // The box a picture fits in, in points.
    static let size = NSSize(width: SwitcherPanel.largestPreview, height: SwitcherPanel.largestPreview * SwitcherTileView.previewShape)

    // Set directly only by the self-test.
    var pictures: [CGWindowID: NSImage] = [:]
    private var capturing: Task<Void, Never>?

    func picture(of id: CGWindowID?) -> NSImage? { id.flatMap { pictures[$0] } }

    // Takes a fresh picture of each window, in list order, handing each over on the main thread as it comes in.
    func refresh(_ ids: [CGWindowID], each: @escaping (CGWindowID, NSImage) -> Void) {
        capturing?.cancel()
        let listed = Set(ids)
        pictures = pictures.filter { listed.contains($0.key) }
        guard ScreenText.hasPermission else { return }
        let start = Date()
        capturing = Task { @MainActor [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            else { return }
            let windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
            var taken = 0, fromServer = 0
            await withTaskGroup(of: (CGWindowID, CGImage?, Bool).self) { group in
                // A window ScreenCaptureKit leaves off its list gets no picture at all, and one on screen that it
                // can't take isn't the case the window server is asked for.
                for id in ids {
                    guard let window = windows[id] else { continue }
                    group.addTask {
                        if let image = await Self.capture(window) { return (id, image, false) }
                        return (id, window.isOnScreen ? nil : Self.serverPicture(of: id), true)
                    }
                }
                for await (id, image, fromWindowServer) in group {
                    guard let self, !Task.isCancelled, let image else { continue }
                    let picture = NSImage(cgImage: image, size: Self.fitted(NSSize(width: image.width, height: image.height)))
                    self.pictures[id] = picture
                    taken += 1
                    if fromWindowServer { fromServer += 1 }
                    each(id, picture)
                }
            }
            if !Task.isCancelled {
                log(String(format: "switcher: %d of %d previews (%d from the window server) in %.0f ms", taken, ids.count,
                           fromServer, -start.timeIntervalSinceNow * 1000))
            }
        }
    }

    private static func capture(_ window: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let fitted = fitted(filter.contentRect.size)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(fitted.width * scale))
        config.height = max(1, Int(fitted.height * scale))
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // For a window ScreenCaptureKit lists but takes no picture of, off screen: a full-screen one whose Space isn't
    // showing. The window server's picture is the window's full size, so it's shrunk to what ScreenCaptureKit would
    // have given.
    private static func serverPicture(of id: CGWindowID) -> CGImage? {
        guard let image = SpaceWindows.picture(of: id) else { return nil }
        let size = fitted(NSSize(width: image.width, height: image.height))
        let width = Int(size.width * 2), height = Int(size.height * 2)
        guard width < image.width, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                                           bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                           bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // A window's size scaled to fit the box, keeping its shape.
    static func fitted(_ window: NSSize) -> NSSize {
        guard window.width > 0, window.height > 0 else { return size }
        let scale = min(size.width / window.width, size.height / window.height)
        return NSSize(width: (window.width * scale).rounded(), height: (window.height * scale).rounded())
    }
}
