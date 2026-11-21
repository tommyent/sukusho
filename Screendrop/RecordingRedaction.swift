import AVFoundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

/// Fixed, top-left normalized bounds in the original screen movie, on its source clock.
nonisolated struct RecordingRedaction: Codable, Equatable, Hashable, Identifiable, Sendable {
    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case blur, pixelate

        var id: String { rawValue }
        var title: String { self == .blur ? "Blur" : "Pixelate" }
        var systemImage: String { self == .blur ? "drop.halffull" : "squareshape.split.3x3" }
    }

    static let minimumDuration: TimeInterval = 0.1
    static let defaultDuration: TimeInterval = 3
    /// Smallest region side, as a fraction of the picture.
    static let minimumSide: CGFloat = 0.02
    static let defaultRect = CGRect(x: 0.35, y: 0.4, width: 0.3, height: 0.2)

    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var rect: CGRect
    var mode: Mode = .blur
    var strength: Double = 0.8

    var duration: TimeInterval { end - start }

    init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        rect: CGRect = RecordingRedaction.defaultRect,
        mode: Mode = .blur,
        strength: Double = 0.8
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.rect = rect
        self.mode = mode
        self.strength = strength
    }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, rect, mode, strength
    }

    /// Upstream compatibility keys when reading documents with `style`/`amount`.
    private enum CompatCodingKeys: String, CodingKey {
        case style, amount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let compat = try decoder.container(keyedBy: CompatCodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        rect = try container.decode(CGRect.self, forKey: .rect)
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode)
            ?? compat.decodeIfPresent(Mode.self, forKey: .style)
            ?? .blur
        strength = try container.decodeIfPresent(Double.self, forKey: .strength)
            ?? compat.decodeIfPresent(Double.self, forKey: .amount)
            ?? 0.8
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(rect, forKey: .rect)
        try container.encode(mode, forKey: .mode)
        try container.encode(strength, forKey: .strength)
    }

    /// Legacy links have no snapshot and must be treated as unredacted.
    static func needsSharedReplacement(_ current: [Self], shared: [Self]?) -> Bool {
        !current.isEmpty && current != (shared ?? [])
    }

    func validate(sourceDuration: TimeInterval? = nil) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start,
              sourceDuration.map({ end <= $0 + 0.000_001 }) ?? true,
              [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.minX >= 0, rect.minY >= 0, rect.width > 0, rect.height > 0,
              rect.maxX <= 1, rect.maxY <= 1,
              strength.isFinite, (0...1).contains(strength) else {
            throw RecordingRedactionError.invalidRegion
        }
    }

    /// Keeps the region inside the picture and no smaller than the minimum.
    static func clamped(_ rect: CGRect) -> CGRect {
        let width = min(max(rect.width, minimumSide), 1)
        let height = min(max(rect.height, minimumSide), 1)
        return CGRect(
            x: min(max(rect.minX, 0), 1 - width),
            y: min(max(rect.minY, 0), 1 - height),
            width: width,
            height: height
        )
    }

    func nudged(dx: CGFloat, dy: CGFloat) -> Self {
        var copy = self
        copy.rect = Self.clamped(rect.offsetBy(dx: dx, dy: dy))
        return copy
    }

    func resized(dWidth: CGFloat, dHeight: CGFloat) -> Self {
        var copy = self
        let nextWidth = min(max(rect.width + dWidth, Self.minimumSide), 1)
        let nextHeight = min(max(rect.height + dHeight, Self.minimumSide), 1)
        let centered = CGRect(
            x: rect.midX - nextWidth / 2,
            y: rect.midY - nextHeight / 2,
            width: nextWidth,
            height: nextHeight
        )
        copy.rect = Self.clamped(centered)
        return copy
    }

    func pixelRect(in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + rect.minX * extent.width,
               y: extent.minY + (1 - rect.maxY) * extent.height,
               width: rect.width * extent.width, height: rect.height * extent.height)
            .integral.intersection(extent)
    }

    /// Intersect the output frame with mapped mask ranges, rounding coverage outward.
    func covers(editorTime: TimeInterval, frameDuration: TimeInterval, timeline: RecordingClipTimeline) -> Bool {
        timeline.slices(overlapping: start, sourceEnd: end).contains {
            editorTime < $0.editorEnd && editorTime + frameDuration > $0.editorStart
        }
    }
}

nonisolated enum RecordingRedactionError: LocalizedError {
    case invalidRegion, filterFailed

    var errorDescription: String? {
        switch self {
        case .invalidRegion: "A video redaction has invalid bounds or timing. Fix it in Studio before exporting."
        case .filterFailed: "The video redaction could not be rendered. No unredacted output was used."
        }
    }
}

nonisolated enum RecordingRedactionFilter {
    static func apply(_ redactions: [RecordingRedaction], to source: CIImage) throws -> CIImage {
        var result = source
        let extent = source.extent
        for region in redactions {
            try region.validate()
            let rect = region.pixelRect(in: extent)
            guard !rect.isEmpty else { throw RecordingRedactionError.filterFailed }
            let filtered: CIImage?
            switch region.mode {
            case .blur:
                let radius = RedactionImageProcessor.blurRadius(for: max(region.strength, 0.35))
                let filter = CIFilter.gaussianBlur()
                filter.inputImage = result.cropped(to: rect.insetBy(dx: -radius * 3, dy: -radius * 3)
                    .intersection(extent)).clampedToExtent()
                filter.radius = Float(radius)
                filtered = filter.outputImage
            case .pixelate:
                let filter = CIFilter.pixellate()
                filter.inputImage = result.clampedToExtent()
                filter.scale = Float(RedactionImageProcessor.pixelBlockSize(for: max(region.strength, 0.35)))
                filter.center = CGPoint(x: rect.midX, y: rect.midY)
                filtered = filter.outputImage
            }
            guard let filtered else { throw RecordingRedactionError.filterFailed }
            // Privacy redactions always mask the entire selected rectangle at full strength.
            result = filtered.cropped(to: rect).composited(over: result).cropped(to: extent)
        }
        return result
    }

    /// Materialize once before either screen renderer; the master is never mutated.
    static func buffer(from source: CVPixelBuffer, redactions: [RecordingRedaction], context: CIContext) throws -> CVPixelBuffer {
        guard !redactions.isEmpty else { return source }
        let image = try apply(redactions, to: CIImage(cvPixelBuffer: source))
        guard let cgImage = context.createCGImage(image, from: image.extent, format: .BGRA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, deferred: false) else {
            throw RecordingRedactionError.filterFailed
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, cgImage.width, cgImage.height, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferMetalCompatibilityKey: true,
                                   kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw RecordingRedactionError.filterFailed }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let bitmap = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: cgImage.width, height: cgImage.height,
                                     bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw RecordingRedactionError.filterFailed }
        bitmap.draw(cgImage, in: image.extent)
        bitmap.flush()
        return buffer
    }

    static func composition(asset: AVAsset, redactions: [RecordingRedaction], timeline: RecordingClipTimeline? = nil) async throws -> AVVideoComposition {
        for region in redactions { try region.validate() }
        let duration = try await asset.load(.duration).seconds
        let map = timeline ?? .full(sourceDuration: duration)
        let interval = 1.0 / 60
        let context = CIContext(options: [.cacheIntermediates: false])
        let composition = try await AVVideoComposition(applyingFiltersTo: asset) { parameters in
            let active = redactions.filter {
                $0.covers(editorTime: parameters.compositionTime.seconds, frameDuration: interval, timeline: map)
            }
            return AVCIImageFilteringResult(
                resultImage: try apply(active, to: parameters.sourceImage),
                ciContext: context
            )
        }
        // A static capture may hold one source frame across a mask boundary.
        // Force filtering on the playback clock rather than only at source samples.
        return AVVideoComposition(configuration: .init(
            customVideoCompositorClass: composition.customVideoCompositorClass,
            frameDuration: CMTime(value: 1, timescale: 60),
            instructions: composition.instructions,
            renderSize: composition.renderSize,
            sourceTrackIDForFrameTiming: kCMPersistentTrackID_Invalid
        ))
    }
}

/// Live-updating redaction source for Studio's paused/playing screen preview.
/// Keeps Sukusho's fail-closed `RecordingRedactionFilter.apply` validation and
/// throws through the composition handler on any invalid region or filter error.
nonisolated final class RecordingRedactionPreviewSource: @unchecked Sendable {
    private let lock = NSLock()
    private var redactions: [RecordingRedaction] = []
    private var clipTimeline = RecordingClipTimeline(segments: [])

    func update(redactions: [RecordingRedaction], clipTimeline: RecordingClipTimeline) {
        lock.withLock {
            self.redactions = redactions
            self.clipTimeline = clipTimeline
        }
    }

    func composition(asset: AVAsset) async throws -> AVVideoComposition {
        let snapshot = lock.withLock { (redactions, clipTimeline) }
        for region in snapshot.0 { try region.validate() }
        let interval = 1.0 / 60
        let context = CIContext(options: [.cacheIntermediates: false])
        let composition = try await AVVideoComposition(applyingFiltersTo: asset) { [self] parameters in
            let (regions, map) = lock.withLock { (redactions, clipTimeline) }
            let active = regions.filter {
                $0.covers(editorTime: parameters.compositionTime.seconds, frameDuration: interval, timeline: map)
            }
            guard !active.isEmpty else {
                return AVCIImageFilteringResult(resultImage: parameters.sourceImage, ciContext: context)
            }
            return AVCIImageFilteringResult(
                resultImage: try RecordingRedactionFilter.apply(active, to: parameters.sourceImage),
                ciContext: context
            )
        }
        return AVVideoComposition(configuration: .init(
            customVideoCompositorClass: composition.customVideoCompositorClass,
            frameDuration: CMTime(value: 1, timescale: 60),
            instructions: composition.instructions,
            renderSize: composition.renderSize,
            sourceTrackIDForFrameTiming: kCMPersistentTrackID_Invalid
        ))
    }
}
