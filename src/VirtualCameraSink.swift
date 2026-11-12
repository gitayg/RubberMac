import Accelerate
import CoreMedia
import CoreMediaIO
import CoreVideo

// Sends frames to OBS Virtual Camera, which is what Zoom, Meet or Teams then show. OBS's camera extension has a
// second stream that takes frames in (its sink); this queues frames there, as pyvirtualcam does, with no OBS app
// running. The sink says it takes BGRA at 1920 × 1080, so frames go in as they come from the camera, scaled to fit.
final class VirtualCameraSink {
    // OBS's camera extension's fixed device ID (obs-studio plugins/mac-virtualcam).
    static let obsDeviceUID = "7626645E-4425-469E-9D8B-97E0FA59AC75"

    enum Failure: Error, CustomStringConvertible {
        case notInstalled, noSink, cantQueue(OSStatus), cantStart(OSStatus)

        var description: String {
            switch self {
            case .notInstalled: return "OBS Virtual Camera isn't installed: install OBS, then click Start Virtual Camera in it once"
            case .noSink: return "OBS Virtual Camera has no stream to send to; update OBS"
            case .cantQueue(let status): return "couldn't reach OBS Virtual Camera (\(status))"
            case .cantStart(let status): return "OBS Virtual Camera wouldn't start (\(status))"
            }
        }
    }

    let width: Int
    let height: Int
    private let device: CMIOObjectID
    private let stream: CMIOStreamID
    private let queue: CMSimpleQueue
    private let format: CMVideoFormatDescription
    private let pool: CVPixelBufferPool
    private var running = true
    private(set) var sent = 0

    init() throws {
        guard let device = Self.obsDevice() else { throw Failure.notInstalled }
        // Direction 0 is a stream that takes frames from the computer; the one apps read is 1.
        guard let stream = Self.property(device, kCMIODevicePropertyStreams, CMIOStreamID.self).first(where: {
            Self.property($0, kCMIOStreamPropertyDirection, UInt32.self).first == 0
        }) else { throw Failure.noSink }
        let declared = Self.property(stream, kCMIOStreamPropertyFormatDescription, Unmanaged<CMFormatDescription>.self)
            .first.map { CMVideoFormatDescriptionGetDimensions($0.takeRetainedValue()) }
        width = Int(declared?.width ?? 1920)
        height = Int(declared?.height ?? 1080)

        var queue: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &queue)
        guard status == noErr, let queue else { throw Failure.cantQueue(status) }
        self.queue = queue.takeRetainedValue()

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCVPixelFormatType_32BGRA, width: Int32(width),
                                       height: Int32(height), extensions: nil, formatDescriptionOut: &format)
        var pool: CVPixelBufferPool?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height, kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard let format, let pool else { throw Failure.cantQueue(-1) }
        self.format = format
        self.pool = pool
        self.device = device
        self.stream = stream

        let started = CMIODeviceStartStream(device, stream)
        guard started == noErr else { throw Failure.cantStart(started) }
    }

    deinit { stop() }

    static var isInstalled: Bool { obsDevice() != nil }

    // Copies the frame (any size, 32BGRA) into a buffer of the sink's size and queues it. A full queue drops the frame:
    // the extension takes them as fast as it shows them.
    func send(_ frame: CVPixelBuffer) {
        guard running else { return }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        var source = vImage_Buffer(data: CVPixelBufferGetBaseAddress(frame), height: vImagePixelCount(CVPixelBufferGetHeight(frame)),
                                   width: vImagePixelCount(CVPixelBufferGetWidth(frame)), rowBytes: CVPixelBufferGetBytesPerRow(frame))
        var target = vImage_Buffer(data: CVPixelBufferGetBaseAddress(out), height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRow(out))
        if source.width == target.width && source.height == target.height {
            vImageCopyBuffer(&source, &target, 4, vImage_Flags(kvImageNoFlags))
        } else {
            vImageScale_ARGB8888(&source, &target, nil, vImage_Flags(kvImageHighQualityResampling))
        }
        CVPixelBufferUnlockBaseAddress(out, [])
        CVPixelBufferUnlockBaseAddress(frame, .readOnly)

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)), timescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: nil, imageBuffer: out, dataReady: true, makeDataReadyCallback: nil,
                                           refcon: nil, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample, CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return }
        if CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sample).toOpaque()) == noErr { sent += 1 }
    }

    func stop() {
        guard running else { return }
        running = false
        CMIODeviceStopStream(device, stream)
    }

    private static func obsDevice() -> CMIOObjectID? {
        property(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices, CMIOObjectID.self).first {
            property($0, kCMIODevicePropertyDeviceUID, Unmanaged<CFString>.self).first?.takeRetainedValue() as String? == obsDeviceUID
        }
    }

    private static func property<T>(_ object: CMIOObjectID, _ selector: Int, _ type: T.Type) -> [T] {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, raw) == noErr else { return [] }
        return (0..<Int(size) / MemoryLayout<T>.stride).map { raw.load(fromByteOffset: $0 * MemoryLayout<T>.stride, as: T.self) }
    }
}
