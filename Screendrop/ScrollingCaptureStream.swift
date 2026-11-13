import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os
import ScreenCaptureKit
/// The capture clock: mach absolute time in seconds, as ScreenCaptureKit's displayTime.
nonisolated enum ScrollingCaptureSampleTiming {
    static func now() -> TimeInterval { Double(mach_absolute_time()) * secondsPerTick }
    static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()
}

/// One ScreenCaptureKit stream for a whole Scrolling Capture session. The
/// callback copies each new frame out of its surface, so SCK gets the surface
/// back at once, and leaves it in a single latest-frame slot: a slow stitcher
/// skips stale frames instead of working through a backlog. While the display
/// doesn't change, SCK sends pixel-less idle samples at the frame interval;
/// they go through the slot as idle ticks, but never in place of a frame.
nonisolated final class ScrollingCaptureStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let image: CGImage
        /// When WindowServer showed the frame, on the capture clock
        /// (`ScrollingCaptureSampleTiming.now()`, mach absolute seconds).
        let time: TimeInterval
    }

    enum Event: @unchecked Sendable {
        case frame(Frame)
        /// The display hadn't changed when SCK said so, at this capture-clock time.
        /// An idle sample's own display time stays at the last frame's.
        case idle(TimeInterval)
    }

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.screendrop.scrolling-capture.stream", qos: .userInteractive)
    private let droppedFrames = OSAllocatedUnfairLock<[Frame]>(initialState: [])
    private static let maxDroppedFrames = 3
    override init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
    }

    /// Scrolling further than the region's height between two samples leaves
    /// no overlap to line frames up with, so sample often enough to catch fast flicks.
    static let frameInterval = CMTime(value: 1, timescale: 40)
    /// The region at the display's full pixel scale, without the cursor, in BGRA.
    static func configuration(sourceRect: CGRect, scale: CGFloat) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int((sourceRect.width * scale).rounded()))
        configuration.height = max(1, Int((sourceRect.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = frameInterval
        configuration.queueDepth = 3
        return configuration
    }

    func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    /// No more events; one already waiting in the slot is still delivered.
    func stop() {
        continuation.finish()
        droppedFrames.withLock { $0.removeAll() }
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    /// Returns any frames evicted by the newest-frame slot before `time`, oldest first,
    /// clearing the ring so they are only used once to bridge a fast-scroll jump.
    func drainDroppedFrames(before time: TimeInterval) -> [Frame] {
        droppedFrames.withLock { list in
            let frames = list.filter { $0.time < time }
            list.removeAll()
            return frames
        }
    }

    func enqueue(_ frame: Frame) {
        if case .dropped(.frame(let evicted)) = continuation.yield(.frame(frame)) {
            droppedFrames.withLock { list in
                list.append(evicted)
                if list.count > Self.maxDroppedFrames { list.removeFirst(list.count - Self.maxDroppedFrames) }
            }
        }
    }
    private static func seconds(_ ticks: UInt64) -> TimeInterval { Double(ticks) * ScrollingCaptureSampleTiming.secondsPerTick }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let callbackTime = ScrollingCaptureSampleTiming.now()
        guard type == .screen, sampleBuffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
              let status = (info[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)) else { return }
        if status == .idle {
            // A frame still waiting in the slot matters more: put it back.
            if case .dropped(.frame(let waiting)) = continuation.yield(.idle(callbackTime)) {
                continuation.yield(.frame(waiting))
            } else {
                droppedFrames.withLock { $0.removeAll() }
            }
            return
        }
        guard status == .complete || status == .started,
              let pixels = sampleBuffer.imageBuffer,
              let image = Self.copy(pixels) else { return }
        let time = (info[.displayTime] as? UInt64).map(Self.seconds) ?? callbackTime
        enqueue(Frame(image: image, time: time))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Scrolling Capture stream stopped: %@", error.localizedDescription)
        droppedFrames.withLock { $0.removeAll() }
        continuation.finish()
    }
    /// Byte for byte, tagged with the surface's colour space. Skip-first
    /// alpha, so whatever SCK leaves in the alpha byte never darkens a pixel.
    private static func copy(_ buffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer), row = width * 4
        var data = Data(count: row * height)
        data.withUnsafeMutableBytes { out in
            for y in 0..<height {
                out.baseAddress!.advanced(by: y * row).copyMemory(from: base.advanced(by: y * stride), byteCount: row)
            }
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let space = CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue()
            ?? CVBufferCopyAttachments(buffer, .shouldPropagate).flatMap {
                CVImageBufferCreateColorSpaceFromAttachments($0)?.takeRetainedValue()
            }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
