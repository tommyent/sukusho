//
//  RecordingImageOverlay.swift
//  Screendrop
//
//  Images and GIFs placed over a Studio recording: a logo, a screenshot, a
//  sticker or a reaction. Like text, each lives on the recording's clock
//  so it stays with the footage through cuts, and is placed in canvas
//  fractions so one Core Graphics routine draws it identically in the
//  preview and the export. Animated images (GIF, APNG, animated WebP and
//  HEIC sequences) loop on their own frame timing wherever they're shown.
//
//  Imported files are copied into the project's media folder, so a project
//  keeps working after the original is moved or deleted.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct RecordingImageOverlay: Identifiable, Codable, Equatable, Hashable, Sendable {
    static let minimumDuration: TimeInterval = 0.1
    static let defaultDuration: TimeInterval = 4
    static let widthRange: ClosedRange<Double> = 0.02...1.5
    static let cornerRadiusRange: ClosedRange<Double> = 0...200
    static let fadeRange: ClosedRange<TimeInterval> = 0...2

    var id = UUID()
    /// The copy inside the project's media folder.
    var fileName: String
    /// The file's name as it was picked, for the timeline and inspector.
    var displayName: String
    /// Recording (source) time.
    var start: TimeInterval
    var end: TimeInterval
    /// The image's centre, as a fraction of the canvas.
    var center = CGPoint(x: 0.5, y: 0.5)
    /// Width as a fraction of the canvas width; height follows the image.
    var width: Double = 0.3
    /// The image's width over its height.
    var aspect: Double = 1
    /// Degrees, clockwise.
    var rotation: Double = 0
    var opacity: Double = 1
    /// Corner radius in pixels of a 1080p canvas.
    var cornerRadius: Double = 0
    /// Drop shadow strength, 0...1.
    var shadow: Double = 0
    var fadeIn: TimeInterval = 0
    var fadeOut: TimeInterval = 0
    var isAnimated = false

    var duration: TimeInterval { end - start }

    init(fileName: String, displayName: String, start: TimeInterval, end: TimeInterval) {
        self.fileName = fileName
        self.displayName = displayName
        self.start = start
        self.end = end
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fileName = try container.decode(String.self, forKey: .fileName)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? fileName
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        center = try container.decodeIfPresent(CGPoint.self, forKey: .center) ?? CGPoint(x: 0.5, y: 0.5)
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 0.3
        aspect = try container.decodeIfPresent(Double.self, forKey: .aspect) ?? 1
        rotation = try container.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        shadow = try container.decodeIfPresent(Double.self, forKey: .shadow) ?? 0
        fadeIn = try container.decodeIfPresent(TimeInterval.self, forKey: .fadeIn) ?? 0
        fadeOut = try container.decodeIfPresent(TimeInterval.self, forKey: .fadeOut) ?? 0
        isAnimated = try container.decodeIfPresent(Bool.self, forKey: .isAnimated) ?? false
    }

    func isActive(atSourceTime time: TimeInterval) -> Bool {
        time >= start && time < end
    }

    /// 0 outside the image's stretch, ramping through its fades.
    func fade(atSourceTime time: TimeInterval) -> Double {
        guard isActive(atSourceTime: time) else { return 0 }
        let local = time - start
        var value = 1.0
        if fadeIn > 0, local < fadeIn { value = min(value, local / fadeIn) }
        if fadeOut > 0, local > duration - fadeOut { value = min(value, (duration - local) / fadeOut) }
        return min(max(value, 0), 1)
    }

    /// Where the image sits on the canvas before rotation.
    func rect(canvasSize: CGSize) -> CGRect {
        let drawWidth = CGFloat(width) * canvasSize.width
        let drawHeight = drawWidth / CGFloat(max(aspect, 0.01))
        return CGRect(
            x: center.x * canvasSize.width - drawWidth / 2,
            y: center.y * canvasSize.height - drawHeight / 2,
            width: drawWidth,
            height: drawHeight
        )
    }
}

// MARK: - Decoded images

/// A decoded image: one frame, or an animated image's frames and timing.
nonisolated final class RecordingOverlayImage: @unchecked Sendable {
    let frames: [CGImage]
    /// When each frame ends, from the first frame's start.
    private let frameEnds: [TimeInterval]
    let loopDuration: TimeInterval
    let aspect: Double

    var isAnimated: Bool { frames.count > 1 }

    /// Longest side frames are decoded at. Overlays rarely cover more than
    /// a fraction of the canvas, and a long GIF's frames add up.
    private static let maximumPixelSize = 1600

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        var frames: [CGImage] = []
        var ends: [TimeInterval] = []
        var elapsed: TimeInterval = 0
        for index in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { continue }
            frames.append(frame)
            elapsed += count > 1 ? Self.delay(of: source, at: index) : 0
            ends.append(elapsed)
        }
        guard let first = frames.first, first.height > 0 else { return nil }
        self.frames = frames
        frameEnds = ends
        loopDuration = elapsed
        aspect = Double(first.width) / Double(first.height)
    }

    /// The frame showing `local` seconds after the image first appears.
    func frame(at local: TimeInterval) -> CGImage {
        guard frames.count > 1, loopDuration > 0 else { return frames[0] }
        let safeLocal = local.isFinite ? max(0, local) : 0
        let time = safeLocal.truncatingRemainder(dividingBy: loopDuration)
        var low = 0
        var high = frameEnds.count - 1
        while low < high {
            let mid = (low + high) / 2
            if frameEnds[mid] > time { high = mid } else { low = mid + 1 }
        }
        return frames[low]
    }

    /// A frame's delay. Like browsers, delays under 11 ms - which many GIFs
    /// carry by mistake - play at a tenth of a second.
    private static func delay(of source: CGImageSource, at index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.1
        }
        let dictionaries: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime)
        ]
        for (dictionaryKey, unclampedKey, clampedKey) in dictionaries {
            guard let dictionary = properties[dictionaryKey] as? [CFString: Any] else { continue }
            let value = (dictionary[unclampedKey] as? Double) ?? (dictionary[clampedKey] as? Double) ?? 0.1
            return value < 0.011 ? 0.1 : value
        }
        return 0.1
    }

    /// Whether a file is an image the overlay track can show.
    static func canImport(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}

/// Starts every Finder drop provider request synchronously inside `performDrop`
/// so the drop session's file-access window is still open, then delivers the
/// loaded URLs in their original drop order on the main actor.
nonisolated enum StudioMediaDropLoader {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL?]
        private var remaining: Int

        init(count: Int) {
            urls = Array(repeating: nil, count: count)
            remaining = count
        }

        func record(_ url: URL?, at index: Int) -> [URL]? {
            lock.withLock {
                urls[index] = url
                remaining -= 1
                guard remaining == 0 else { return nil }
                return urls.compactMap { $0 }
            }
        }
    }

    @discardableResult
    static func loadFileURLs(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor @Sendable ([URL]) -> Void
    ) -> Bool {
        guard !providers.isEmpty else { return false }
        let collector = Collector(count: providers.count)
        for (index, provider) in providers.enumerated() {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let finished = collector.record(url, at: index) else { return }
                Task { @MainActor in
                    completion(finished)
                }
            }
        }
        return true
    }
}

/// Decoded overlay images by file, shared by the preview and the exporter.
/// The preview asks without loading, so a draw never decodes on the main
/// thread; the exporter loads on demand from its own thread.
nonisolated final class RecordingOverlayImageStore: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [URL: RecordingOverlayImage] = [:]

    func cachedImage(at url: URL) -> RecordingOverlayImage? {
        lock.withLock { images[url] }
    }

    func image(at url: URL) -> RecordingOverlayImage? {
        if let cached = cachedImage(at: url) { return cached }
        guard let image = RecordingOverlayImage(url: url) else { return nil }
        lock.withLock { images[url] = image }
        return image
    }

    func removeAll() {
        lock.withLock { images.removeAll() }
    }
}

// MARK: - Rendering

nonisolated enum RecordingImageOverlayRenderer {
    /// Draws `overlay` at `sourceTime` into `context`, whose user space is
    /// the canvas with a top-left origin.
    static func draw(
        _ overlay: RecordingImageOverlay,
        image: RecordingOverlayImage,
        atSourceTime sourceTime: TimeInterval,
        canvasSize: CGSize,
        in context: CGContext
    ) {
        let fade = overlay.fade(atSourceTime: sourceTime)
        guard fade > 0.001, overlay.opacity > 0.001 else { return }
        let frame = image.frame(at: sourceTime - overlay.start)
        let rect = overlay.rect(canvasSize: canvasSize)
        guard rect.width >= 1, rect.height >= 1 else { return }
        // Measurements follow the canvas's shorter side, so portrait and
        // landscape canvases look alike.
        let unit = min(canvasSize.width, canvasSize.height) / 1080
        let radius = min(CGFloat(overlay.cornerRadius) * unit, rect.width / 2, rect.height / 2)
        let strength = CGFloat(min(max(overlay.shadow, 0), 1))

        // Shadows are measured in device units. Converting before the
        // rotation keeps the look the same at the preview's size and the
        // export's, and keeps the shadow falling straight down whichever
        // way the image is turned or the context is flipped.
        let shadowOffset = context.convertToDeviceSpace(CGSize(width: 0, height: 12 * unit * strength))
        let shadowBlurVector = context.convertToDeviceSpace(CGSize(width: 40 * unit * strength, height: 0))
        let shadowBlur = hypot(shadowBlurVector.width, shadowBlurVector.height)

        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(CGFloat(overlay.opacity * fade))
        context.interpolationQuality = .high
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: CGFloat(overlay.rotation) * .pi / 180)
        context.translateBy(x: -rect.midX, y: -rect.midY)

        func castShadow() {
            context.setShadow(offset: shadowOffset, blur: shadowBlur, color: CGColor(gray: 0, alpha: 0.5 * strength))
        }

        if radius > 0 {
            // Rounded corners clip the image, so a matching card underneath
            // casts the shadow.
            if strength > 0 {
                context.saveGState()
                castShadow()
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fillPath()
                context.restoreGState()
            }
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
        } else if strength > 0 {
            // Square corners shadow the image itself, which follows a
            // transparent sticker's outline.
            castShadow()
        }

        // Core Graphics draws images bottom-up; flip them into the
        // top-down canvas.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(frame, in: CGRect(origin: .zero, size: rect.size))
    }
}
