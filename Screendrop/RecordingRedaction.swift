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
    static let cornerRadiusRange: ClosedRange<Double> = 0...100
    static let fadeRange: ClosedRange<TimeInterval> = 0...2

    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var rect: CGRect
    var mode: Mode = .blur
    var strength: Double = 0.8
    /// Corner radius in pixels of a 1080p picture; 0 keeps hard corners.
    var cornerRadius: Double = 0
    var fadeIn: TimeInterval = 0
    var fadeOut: TimeInterval = 0

    var duration: TimeInterval { end - start }

    init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        rect: CGRect = RecordingRedaction.defaultRect,
        mode: Mode = .blur,
        strength: Double = 0.8,
        cornerRadius: Double = 0,
        fadeIn: TimeInterval = 0,
        fadeOut: TimeInterval = 0
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.rect = rect
        self.mode = mode
        self.strength = strength
        self.cornerRadius = cornerRadius
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, rect, mode, strength, cornerRadius, fadeIn, fadeOut
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
        rect = try container.decodeIfPresent(CGRect.self, forKey: .rect) ?? Self.defaultRect
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode)
            ?? compat.decodeIfPresent(Mode.self, forKey: .style)
            ?? .blur
        strength = try container.decodeIfPresent(Double.self, forKey: .strength)
            ?? compat.decodeIfPresent(Double.self, forKey: .amount)
            ?? 0.8
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        fadeIn = try container.decodeIfPresent(TimeInterval.self, forKey: .fadeIn) ?? 0
        fadeOut = try container.decodeIfPresent(TimeInterval.self, forKey: .fadeOut) ?? 0
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(rect, forKey: .rect)
        try container.encode(mode, forKey: .mode)
        try container.encode(strength, forKey: .strength)
        if cornerRadius != 0 { try container.encode(cornerRadius, forKey: .cornerRadius) }
        if fadeIn != 0 { try container.encode(fadeIn, forKey: .fadeIn) }
        if fadeOut != 0 { try container.encode(fadeOut, forKey: .fadeOut) }
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
              strength.isFinite, (0...1).contains(strength),
              cornerRadius.isFinite, Self.cornerRadiusRange.contains(cornerRadius),
              fadeIn.isFinite, fadeIn >= 0,
              fadeOut.isFinite, fadeOut >= 0 else {
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

    func pixelRect(in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + rect.minX * extent.width,
               y: extent.minY + (1 - rect.maxY) * extent.height,
               width: rect.width * extent.width, height: rect.height * extent.height)
            .integral.intersection(extent)
    }

    /// How strongly the region shows at a source time: 1 across the region,
    /// ramping through `fadeIn` and `fadeOut` when configured.
    func opacity(atSourceTime time: TimeInterval) -> Double {
        guard fadeIn > 0 || fadeOut > 0 else { return 1 }
        guard time >= start, time < end else { return 0 }
        let local = time - start
        var value = 1.0
        if fadeIn > 0, local < fadeIn { value = min(value, local / fadeIn) }
        if fadeOut > 0, local > duration - fadeOut { value = min(value, (duration - local) / fadeOut) }
        return min(max(value, 0), 1)
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
    static func apply(
        _ redactions: [RecordingRedaction],
        to source: CIImage,
        atSourceTime sourceTime: TimeInterval? = nil
    ) throws -> CIImage {
        var result = source
        let extent = source.extent
        let unit = min(extent.width, extent.height) / 1080
        for region in redactions {
            try region.validate()
            let rect = region.pixelRect(in: extent)
            guard !rect.isEmpty else { throw RecordingRedactionError.filterFailed }
            let opacity = sourceTime.map { region.opacity(atSourceTime: $0) } ?? 1
            guard opacity > 0.001 else { continue }
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
            if region.cornerRadius <= 0, opacity >= 0.999 {
                result = filtered.cropped(to: rect).composited(over: result).cropped(to: extent)
            } else {
                let mask = CIFilter.roundedRectangleGenerator()
                mask.extent = rect
                mask.radius = Float(min(CGFloat(region.cornerRadius) * unit, rect.width / 2, rect.height / 2))
                let level = CGFloat(opacity)
                mask.color = CIColor(red: level, green: level, blue: level, alpha: 1)
                guard let maskImage = mask.outputImage else { throw RecordingRedactionError.filterFailed }
                let blend = CIFilter.blendWithMask()
                blend.inputImage = filtered.cropped(to: rect)
                blend.backgroundImage = result
                blend.maskImage = maskImage
                guard let blended = blend.outputImage else { throw RecordingRedactionError.filterFailed }
                result = blended.cropped(to: extent)
            }
        }
        return result
    }

    /// Materialize once before either screen renderer; the master is never mutated.
    static func buffer(
        from source: CVPixelBuffer,
        redactions: [RecordingRedaction],
        sourceTime: TimeInterval? = nil,
        context: CIContext
    ) throws -> CVPixelBuffer {
        guard !redactions.isEmpty else { return source }
        let image = try apply(redactions, to: CIImage(cvPixelBuffer: source), atSourceTime: sourceTime)
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
            let editorTime = parameters.compositionTime.seconds
            let active = redactions.filter {
                $0.covers(editorTime: editorTime, frameDuration: interval, timeline: map)
            }
            let sourceTime = map.sourceTime(at: editorTime)
            return AVCIImageFilteringResult(
                resultImage: try apply(active, to: parameters.sourceImage, atSourceTime: sourceTime),
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
            let editorTime = parameters.compositionTime.seconds
            let active = regions.filter {
                $0.covers(editorTime: editorTime, frameDuration: interval, timeline: map)
            }
            guard !active.isEmpty else {
                return AVCIImageFilteringResult(resultImage: parameters.sourceImage, ciContext: context)
            }
            let sourceTime = map.sourceTime(at: editorTime)
            return AVCIImageFilteringResult(
                resultImage: try RecordingRedactionFilter.apply(active, to: parameters.sourceImage, atSourceTime: sourceTime),
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
