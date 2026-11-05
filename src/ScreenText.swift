import AppKit
import ScreenCaptureKit
import Vision

// Reads the text shown in a window: captures it with ScreenCaptureKit and recognizes the text with Vision.
// Needs the Screen Recording permission.
enum ScreenText {
    // Vision has no Hebrew recognizer on macOS 27, so Hebrew lines are dropped; this picks one up if it ships.
    private static let wanted: [Locale.LanguageCode?] = [.english, .hebrew]

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func requestPermission() { CGRequestScreenCaptureAccess() }

    // The window's text, top to bottom, one line per recognized line; "" when it can't be read.
    // Checks the permission first: asking ScreenCaptureKit without it raises the system prompt.
    static func read(window: CGWindowID) async -> String {
        guard hasPermission, let image = await image(of: window) else { return "" }
        return await text(in: image)
    }

    // The first recognition after an install compiles Vision's model, which takes 30–45 s. Doing it at launch
    // keeps that wait off the first time the pad opens.
    static func warmUp() {
        let image = NSImage(size: NSSize(width: 160, height: 40), flipped: false) { _ in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 160, height: 40).fill()
            ("Warming up" as NSString).draw(at: NSPoint(x: 8, y: 10), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
            return true
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let start = Date()
        Task.detached(priority: .utility) {
            _ = await text(in: cgImage)
            log(String(format: "writing pad: screen reading ready in %.1fs", -start.timeIntervalSinceNow))
        }
    }

    static func image(of id: CGWindowID) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
              let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func text(in image: CGImage) async -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = request.supportedRecognitionLanguages.filter { wanted.contains($0.languageCode) }
        guard let lines = try? await request.perform(on: image) else { return "" }
        return ordered(lines).joined(separator: "\n")
    }

    // A line joins the row above when its middle is inside that row's first line; rows read left to right.
    // Vision's boxes are normalized with the origin at the bottom left.
    private static func ordered(_ lines: [RecognizedTextObservation]) -> [String] {
        var rows: [[RecognizedTextObservation]] = []
        for line in lines.sorted(by: { $0.boundingBox.cgRect.maxY > $1.boundingBox.cgRect.maxY }) {
            if let first = rows.last?.first, line.boundingBox.cgRect.midY > first.boundingBox.cgRect.minY {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { $0.boundingBox.cgRect.minX < $1.boundingBox.cgRect.minX } }
            .compactMap { $0.topCandidates(1).first?.string }
    }
}
