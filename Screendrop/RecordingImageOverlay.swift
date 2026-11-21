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
import Darwin
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

    func nudged(dx: CGFloat, dy: CGFloat) -> Self {
        var copy = self
        copy.center = CGPoint(
            x: min(max(center.x + dx, 0), 1),
            y: min(max(center.y + dy, 0), 1)
        )
        return copy
    }

    func scaled(by delta: Double) -> Self {
        var copy = self
        copy.width = min(max(width + delta, Self.widthRange.lowerBound), Self.widthRange.upperBound)
        return copy
    }
}

// MARK: - Decoded images

/// Byte-bounded LRU cache of decoded overlay frames shared across preview,
/// exporter, and multiple animated assets so long animations stay within a
/// fixed memory budget.
nonisolated final class RecordingOverlayFrameCache: @unchecked Sendable {
    /// 96 MiB shared budget across all open Studio previews and exports.
    static let defaultByteLimit = 96 * 1024 * 1024
    static let shared = RecordingOverlayFrameCache()

    private struct Key: Hashable {
        let url: URL
        let frameIndex: Int
    }

    private struct Entry {
        let image: CGImage
        let bytes: Int
        var lastUsed: UInt64
    }

    let byteLimit: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var totalBytes = 0
    private var clock: UInt64 = 0

    init(byteLimit: Int = RecordingOverlayFrameCache.defaultByteLimit) {
        self.byteLimit = max(0, byteLimit)
    }

    var currentBytes: Int {
        lock.withLock { totalBytes }
    }

    static func byteCost(of image: CGImage) -> Int {
        max(image.bytesPerRow * image.height, image.width * image.height * 4)
    }

    func image(for url: URL, frameIndex: Int) -> CGImage? {
        let key = Key(url: url, frameIndex: frameIndex)
        return lock.withLock {
            guard var entry = entries[key] else { return nil }
            clock &+= 1
            entry.lastUsed = clock
            entries[key] = entry
            return entry.image
        }
    }

    @discardableResult
    func insert(_ image: CGImage, for url: URL, frameIndex: Int) -> Bool {
        let cost = Self.byteCost(of: image)
        guard cost > 0, cost <= byteLimit else { return false }
        let key = Key(url: url, frameIndex: frameIndex)
        lock.withLock {
            if let existing = entries.removeValue(forKey: key) {
                totalBytes -= existing.bytes
            }
            // ponytail: O(n) eviction scan over cached frames (~dozens of entries at 96 MiB); upgrade to intrusive LRU list if tiny icons ever grow n past ~1k.
            while totalBytes + cost > byteLimit,
                  let oldestKey = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key,
                  let removed = entries.removeValue(forKey: oldestKey) {
                totalBytes -= removed.bytes
            }
            clock &+= 1
            entries[key] = Entry(image: image, bytes: cost, lastUsed: clock)
            totalBytes += cost
        }
        return true
    }

    func removeFrames(for url: URL) {
        lock.withLock {
            for key in entries.keys where key.url == url {
                if let removed = entries.removeValue(forKey: key) {
                    totalBytes -= removed.bytes
                }
            }
        }
    }

    func removeAll() {
        lock.withLock {
            entries.removeAll()
            totalBytes = 0
        }
    }
}

/// An overlay image's timing table and on-demand frame decoder backed by a
/// byte-bounded frame cache rather than retaining every decoded animation frame.
nonisolated final class RecordingOverlayImage: @unchecked Sendable {
    let url: URL
    let frameCount: Int
    /// When each frame ends, from the first frame's start.
    private let frameEnds: [TimeInterval]
    let loopDuration: TimeInterval
    let aspect: Double
    private let source: CGImageSource
    private let sourceLock = NSLock()
    private let frameCache: RecordingOverlayFrameCache

    var isAnimated: Bool { frameCount > 1 }

    /// Longest side frames are decoded at. Overlays rarely cover more than
    /// a fraction of the canvas, and a long GIF's frames add up.
    private static let maximumPixelSize = 1600

    init?(url: URL, cache: RecordingOverlayFrameCache = .shared) {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        // Decode only the first frame eagerly to validate readability, aspect,
        // and that a single decoded frame fits within the cache budget.
        guard let first = Self.decodeFrame(from: source, at: 0),
              first.height > 0,
              cache.insert(first, for: url, frameIndex: 0) else {
            return nil
        }

        var ends: [TimeInterval] = []
        ends.reserveCapacity(count)
        var elapsed: TimeInterval = 0
        for index in 0..<count {
            elapsed += count > 1 ? Self.delay(of: source, at: index) : 0
            ends.append(elapsed)
        }

        self.url = url
        self.frameCount = count
        self.frameEnds = ends
        self.loopDuration = elapsed
        self.aspect = Double(first.width) / Double(first.height)
        self.source = source
        self.frameCache = cache
    }

    /// The frame showing `local` seconds after the image first appears.
    func frame(at local: TimeInterval) -> CGImage? {
        let index = frameIndex(at: local)
        if let cached = frameCache.image(for: url, frameIndex: index) {
            return cached
        }
        guard let decoded = sourceLock.withLock({ Self.decodeFrame(from: source, at: index) }) else {
            return nil
        }
        _ = frameCache.insert(decoded, for: url, frameIndex: index)
        return decoded
    }

    private func frameIndex(at local: TimeInterval) -> Int {
        guard frameCount > 1, loopDuration > 0 else { return 0 }
        let safeLocal = local.isFinite ? max(0, local) : 0
        let time = safeLocal.truncatingRemainder(dividingBy: loopDuration)
        var low = 0
        var high = frameEnds.count - 1
        while low < high {
            let mid = (low + high) / 2
            if frameEnds[mid] > time { high = mid } else { low = mid + 1 }
        }
        return low
    }

    private static func decodeFrame(from source: CGImageSource, at index: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// A frame's delay. Only GIF carries the legacy browser rule where delays
    /// under 11 ms play at 100 ms; APNG, WebP, and HEIC honor any finite
    /// positive delay and fall back to 100 ms only when timing is missing or invalid.
    static func delay(from properties: [CFString: Any]) -> TimeInterval {
        if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            let value = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
            guard let value, value.isFinite, value >= 0.011 else { return 0.1 }
            return value
        }
        let nonGIFDictionaries: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime)
        ]
        for (dictionaryKey, unclampedKey, clampedKey) in nonGIFDictionaries {
            guard let dictionary = properties[dictionaryKey] as? [CFString: Any] else { continue }
            let value = (dictionary[unclampedKey] as? Double) ?? (dictionary[clampedKey] as? Double)
            guard let value, value.isFinite, value > 0 else { return 0.1 }
            return value
        }
        return 0.1
    }

    private static func delay(of source: CGImageSource, at index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.1
        }
        return delay(from: properties)
    }

    /// Whether a file is an image the overlay track can show.
    static func canImport(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}

/// Single path resolver, importer, and cleanup guard for files inside a
/// project's `media` directory. Enforces simple filenames and regular files
/// without following symbolic links, so neither preview nor export can escape
/// the package or silently drop missing assets.
nonisolated enum RecordingOverlayMedia {
    enum ResolutionError: LocalizedError, Equatable {
        case missingOrInvalid(String)

        var errorDescription: String? {
            switch self {
            case .missingOrInvalid(let name):
                "The overlay image \"\(name)\" is missing or unreadable."
            }
        }
    }

    static func isSimpleFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains("\0")
            && (name as NSString).lastPathComponent == name
    }

    static func isRegularFileNoFollow(at url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    static func resolveRegularFile(named fileName: String, in mediaDirectory: URL) -> URL? {
        guard isSimpleFileName(fileName) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mediaDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        let realDirectory = mediaDirectory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = realDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard isRegularFileNoFollow(at: candidate) else { return nil }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.deletingLastPathComponent().path == realDirectory.path else { return nil }
        return resolved
    }

    static func copyRegularFile(from sourceURL: URL, into mediaDirectory: URL) -> String? {
        let ext = sourceURL.pathExtension.lowercased()
        let fileName = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        do {
            let accessing = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
            guard isRegularFileNoFollow(at: sourceURL) else { return nil }
            try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            let destination = mediaDirectory.appendingPathComponent(fileName, isDirectory: false)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            guard resolveRegularFile(named: fileName, in: mediaDirectory) != nil else {
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
            return fileName
        } catch {
            return nil
        }
    }

    static func validateOverlays(
        _ overlays: [RecordingImageOverlay],
        in mediaDirectory: URL?,
        clipTimeline: RecordingClipTimeline,
        store: RecordingOverlayImageStore
    ) throws {
        for overlay in overlays {
            guard !clipTimeline.slices(overlapping: overlay.start, sourceEnd: overlay.end).isEmpty else { continue }
            let label = overlay.displayName.isEmpty ? overlay.fileName : overlay.displayName
            guard let mediaDirectory,
                  let resolved = resolveRegularFile(named: overlay.fileName, in: mediaDirectory),
                  store.image(at: resolved) != nil else {
                throw ResolutionError.missingOrInvalid(label)
            }
        }
    }

    static func cleanupUnreferencedImages(in mediaDirectory: URL, referenced: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: mediaDirectory.path)) ?? []
        for name in names where isSimpleFileName(name) && !referenced.contains(name) {
            guard let fileURL = resolveRegularFile(named: name, in: mediaDirectory),
                  RecordingOverlayImage.canImport(fileURL) else { continue }
            try? FileManager.default.removeItem(at: fileURL)
        }
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

/// Decoded overlay image metadata by file, backed by a shared byte-bounded
/// frame cache across preview and export.
nonisolated final class RecordingOverlayImageStore: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [URL: RecordingOverlayImage] = [:]
    private let frameCache: RecordingOverlayFrameCache

    init(frameCache: RecordingOverlayFrameCache = .shared) {
        self.frameCache = frameCache
    }

    func cachedImage(at url: URL) -> RecordingOverlayImage? {
        lock.withLock { images[url] }
    }

    func image(at url: URL) -> RecordingOverlayImage? {
        if let cached = cachedImage(at: url) { return cached }
        guard let image = RecordingOverlayImage(url: url, cache: frameCache) else { return nil }
        lock.withLock { images[url] = image }
        return image
    }

    func removeAll() {
        let urls = lock.withLock { () -> [URL] in
            let keys = Array(images.keys)
            images.removeAll()
            return keys
        }
        for url in urls {
            frameCache.removeFrames(for: url)
        }
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
        guard fade > 0.001, overlay.opacity > 0.001,
              let frame = image.frame(at: sourceTime - overlay.start) else { return }
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
