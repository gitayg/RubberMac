import CoreVideo
import Foundation

// What happens to each camera frame: find the eyes, recolour them, send the frame to OBS Virtual Camera. Runs on the
// capture queue; the colour and strength can change from the main thread at any time.
final class EyePipeline {
    let sink: VirtualCameraSink
    // Called once, on the capture queue, when the first frame has gone out.
    var onFirstFrame: (() -> Void)?
    private let tracker = EyeTracker(video: true)
    private let lock = NSLock()
    private var rgb: (r: Double, g: Double, b: Double)
    private var strength: Double
    private var sent: [TimeInterval] = []
    private var eyesFound = 0
    private var total = 0

    init(sink: VirtualCameraSink, rgb: (r: Double, g: Double, b: Double), strength: Double) {
        self.sink = sink
        self.rgb = rgb
        self.strength = strength
    }

    func setLook(rgb: (r: Double, g: Double, b: Double), strength: Double) {
        lock.withLock {
            self.rgb = rgb
            self.strength = strength
        }
    }

    func process(_ frame: CVPixelBuffer, at time: TimeInterval) {
        let (rgb, strength) = lock.withLock { (self.rgb, self.strength) }
        let eyes = tracker.eyes(in: frame, at: time)
        IrisRecolor.apply(eyes, color: rgb, strength: strength, to: frame)
        sink.send(frame)
        let first = lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            sent.append(now)
            sent.removeAll { now - $0 > 1 }
            eyesFound = eyes.count
            total += 1
            return total == 1
        }
        if first { onFirstFrame?() }
    }

    // Frames sent in the last second, how many eyes the last one had, and frames sent in all.
    var reading: (fps: Int, eyes: Int, frames: Int) {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            return (sent.filter { now - $0 <= 1 }.count, eyesFound, total)
        }
    }
}
