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

    /// Initial width fraction for an imported image: at most 40% of the canvas
    /// wide and half of it tall, even when a tall image falls below the
    /// inspector slider's minimum.
    static func initialWidth(aspect: Double, canvasSize: CGSize) -> Double {
        guard aspect.isFinite, aspect > 0 else { return 0.4 }
        let heightLimited = canvasSize.width > 0 ? 0.5 * canvasSize.height * aspect / canvasSize.width : 0.4
        return min(0.4, max(heightLimited, .leastNormalMagnitude))
    }

    /// Preserves any finite positive width up to `widthRange.upperBound` so
    /// tall imported images narrower than the inspector slider's minimum
    /// round-trip without growing on reopen or non-size edits.
    static func sanitizedWidth(_ rawWidth: Double, fallback: Double = 0.3) -> Double {
        guard rawWidth.isFinite, rawWidth > 0 else { return fallback }
        return min(rawWidth, widthRange.upperBound)
    }

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
        let rawCenter = try container.decodeIfPresent(CGPoint.self, forKey: .center) ?? CGPoint(x: 0.5, y: 0.5)
        center = CGPoint(
            x: rawCenter.x.isFinite ? min(max(rawCenter.x, 0), 1) : 0.5,
            y: rawCenter.y.isFinite ? min(max(rawCenter.y, 0), 1) : 0.5
        )
        let rawWidth = try container.decodeIfPresent(Double.self, forKey: .width) ?? 0.3
        width = Self.sanitizedWidth(rawWidth)
        let rawAspect = try container.decodeIfPresent(Double.self, forKey: .aspect) ?? 1
        aspect = (rawAspect.isFinite && rawAspect > 0) ? max(rawAspect, 0.01) : 1
        let rawRotation = try container.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        rotation = rawRotation.isFinite ? rawRotation : 0
        let rawOpacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        opacity = rawOpacity.isFinite ? min(max(rawOpacity, 0), 1) : 1
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

/// Formats a normalized fraction as a percentage for VoiceOver without
/// trapping on non-finite or huge decoded values.
nonisolated func studioAccessiblePercent(_ fraction: Double) -> String {
    guard fraction.isFinite else { return "0%" }
    let percent = (fraction * 100).rounded()
    guard percent.isFinite else { return "0%" }
    if percent >= 10_000 { return "10000%" }
    if percent <= -10_000 { return "-10000%" }
    return "\(Int(percent))%"
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
    typealias FrameDecoder = @Sendable (CGImageSource, Int) -> CGImage?

    let url: URL
    let frameCount: Int
    /// When each frame ends, from the first frame's start.
    private let frameEnds: [TimeInterval]
    let loopDuration: TimeInterval
    let aspect: Double
    private let source: CGImageSource
    private let sourceLock = NSLock()
    private let stateLock = NSLock()
    private var lastCompletedFrame: CGImage
    private var pendingDecodeCallbacks: [Int: [@Sendable () -> Void]] = [:]
    private let frameCache: RecordingOverlayFrameCache
    private let frameDecoder: FrameDecoder

    var isAnimated: Bool { frameCount > 1 }

    /// Longest side frames are decoded at. Overlays rarely cover more than
    /// a fraction of the canvas, and a long GIF's frames add up.
    private static let maximumPixelSize = 1600

    init?(
        url: URL,
        cache: RecordingOverlayFrameCache = .shared,
        frameDecoder: @escaping FrameDecoder = RecordingOverlayImage.decodeFrame(from:at:)
    ) {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        // Decode only the first frame eagerly to validate readability, aspect,
        // and that a single decoded frame fits within the cache budget.
        guard let first = frameDecoder(source, 0),
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
        self.lastCompletedFrame = first
        self.frameCache = cache
        self.frameDecoder = frameDecoder
    }

    /// Strict synchronous frame lookup for export. Returns `nil` when Image I/O
    /// cannot decode the requested frame so export can fail naming the asset.
    func frame(at local: TimeInterval) -> CGImage? {
        let index = frameIndex(at: local)
        if let cached = frameCache.image(for: url, frameIndex: index) {
            stateLock.withLock { lastCompletedFrame = cached }
            return cached
        }
        guard let decoded = sourceLock.withLock({ frameDecoder(source, index) }) else {
            return nil
        }
        _ = frameCache.insert(decoded, for: url, frameIndex: index)
        stateLock.withLock { lastCompletedFrame = decoded }
        return decoded
    }

    /// Non-blocking preview frame lookup. Never decodes synchronously on the
    /// draw path: returns a cached frame immediately (and prefetches the next
    /// animated frame), or keeps the last completed frame visible while
    /// decoding the requested frame in the background.
    func previewFrame(at local: TimeInterval, onDecoded: (@Sendable () -> Void)? = nil) -> CGImage {
        previewFrame(at: local, beforePrefetch: nil, onDecoded: onDecoded)
    }

    func previewFrame(
        at local: TimeInterval,
        beforePrefetch: (() -> Void)?,
        onDecoded: (@Sendable () -> Void)? = nil
    ) -> CGImage {
        let index = frameIndex(at: local)
        if let cached = frameCache.image(for: url, frameIndex: index) {
            stateLock.withLock { lastCompletedFrame = cached }
            if isAnimated {
                prefetchIfNeeded(index: (index + 1) % frameCount, onDecoded: nil)
            }
            return cached
        }
        beforePrefetch?()
        if let cached = prefetchIfNeeded(index: index, onDecoded: onDecoded) {
            stateLock.withLock { lastCompletedFrame = cached }
            if isAnimated {
                prefetchIfNeeded(index: (index + 1) % frameCount, onDecoded: nil)
            }
            return cached
        }
        if isAnimated {
            prefetchIfNeeded(index: (index + 1) % frameCount, onDecoded: nil)
        }
        return stateLock.withLock { lastCompletedFrame }
    }

    @discardableResult
    private func prefetchIfNeeded(index: Int, onDecoded: (@Sendable () -> Void)?) -> CGImage? {
        if let cached = frameCache.image(for: url, frameIndex: index) {
            return cached
        }
        var hitAfterLock: CGImage?
        let shouldStart = stateLock.withLock { () -> Bool in
            if let cached = frameCache.image(for: url, frameIndex: index) {
                hitAfterLock = cached
                return false
            }
            if pendingDecodeCallbacks[index] != nil {
                if let onDecoded {
                    pendingDecodeCallbacks[index]?.append(onDecoded)
                }
                return false
            }
            pendingDecodeCallbacks[index] = onDecoded.map { [$0] } ?? []
            return true
        }
        if let hitAfterLock {
            return hitAfterLock
        }
        guard shouldStart else { return nil }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let decoded = self.sourceLock.withLock { self.frameDecoder(self.source, index) }
            let callbacks: [@Sendable () -> Void]
            if let decoded {
                _ = self.frameCache.insert(decoded, for: self.url, frameIndex: index)
                callbacks = self.stateLock.withLock {
                    self.lastCompletedFrame = decoded
                    return self.pendingDecodeCallbacks.removeValue(forKey: index) ?? []
                }
                for callback in callbacks {
                    callback()
                }
            } else {
                _ = self.stateLock.withLock {
                    self.pendingDecodeCallbacks.removeValue(forKey: index)
                }
            }
        }
        return nil
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

    static func decodeFrame(from source: CGImageSource, at index: Int) -> CGImage? {
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

    static func isRealDirectoryNoFollow(at url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Resolves `mediaDirectory` only when it is a real directory (never a
    /// symlink) sitting directly inside its real parent package directory.
    static func resolveRealMediaDirectory(_ mediaDirectory: URL) -> URL? {
        guard isRealDirectoryNoFollow(at: mediaDirectory) else { return nil }
        let parent = mediaDirectory.deletingLastPathComponent()
        guard isRealDirectoryNoFollow(at: parent) else { return nil }
        let realParent = parent.resolvingSymlinksInPath().standardizedFileURL
        let realMedia = mediaDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard realMedia.deletingLastPathComponent().path == realParent.path,
              realMedia.lastPathComponent == mediaDirectory.lastPathComponent else {
            return nil
        }
        return realMedia
    }

    static func isOwnedImportFileName(_ name: String) -> Bool {
        guard isSimpleFileName(name) else { return false }
        let stem = (name as NSString).deletingPathExtension
        return UUID(uuidString: stem) != nil
    }

    static func resolveRegularFile(named fileName: String, in mediaDirectory: URL) -> URL? {
        guard isSimpleFileName(fileName),
              let realDirectory = resolveRealMediaDirectory(mediaDirectory) else { return nil }
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
            // Never create through or copy into a symlinked media root.
            var existing = stat()
            if lstat(mediaDirectory.path, &existing) == 0 {
                guard (existing.st_mode & S_IFMT) == S_IFDIR else { return nil }
            } else {
                let parent = mediaDirectory.deletingLastPathComponent()
                guard isRealDirectoryNoFollow(at: parent) else { return nil }
                try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: false)
            }
            guard let realDirectory = resolveRealMediaDirectory(mediaDirectory) else { return nil }
            let destination = realDirectory.appendingPathComponent(fileName, isDirectory: false)
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
        // Verify the media root is a real package directory BEFORE enumerating it.
        guard let realDirectory = resolveRealMediaDirectory(mediaDirectory) else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: realDirectory.path)) ?? []
        for name in names where isOwnedImportFileName(name) && !referenced.contains(name) {
            guard let fileURL = resolveRegularFile(named: name, in: realDirectory),
                  RecordingOverlayImage.canImport(fileURL) else { continue }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

/// Package-contained, regular-file resolver for every input a `.sukushorec`
/// Finished render can read: `screen.mov`, `camera.mov`, edit/draft/capture/
/// pointer/project/render-stamp sidecars, cached finished deliverables
/// (`<packageName>.mov`/`.mp4`), replacement audio, isolated microphone audio,
/// background music, and `media/` assets. Rejects symlinks and `..` traversal
/// before anything reads or renders from the package.
nonisolated enum RecordingPackageMedia {
    enum ValidationError: LocalizedError, Equatable {
        case invalidPackage(String)
        case unsafeFile(String)

        var errorDescription: String? {
            switch self {
            case .invalidPackage(let name):
                "The recording package \"\(name)\" is invalid or unreadable."
            case .unsafeFile(let name):
                "The recording file \"\(name)\" cannot be opened because it is missing or links outside the package."
            }
        }
    }

    struct ResolvedRenderInputs: Equatable, Sendable {
        let packageDirectory: URL
        let screenURL: URL
        let cameraURL: URL?
        let activeEditURL: URL?
        let replacementAudioURL: URL?
        let isolatedMicrophoneURL: URL?
        let backgroundMusicURL: URL?
        let mediaDirectory: URL?
    }

    private static let screenFileName = "screen.mov"
    private static let cameraFileName = "camera.mov"
    private static let editFileName = "edit.json"
    private static let draftFileName = "edit.draft.json"
    private static let renderStampFileName = "render.json"
    private static let isolatedAudioFileName = "mic-isolated-v2.m4a"
    private static let optionalSidecars = [
        "capture.json",
        "input.json",
        "project.json",
        renderStampFileName
    ]
    private static let deliverableExtensions = ["mov", "mp4"]

    /// Resolves `packageDirectory` only when it is a real directory (not a symlink).
    static func resolveRealPackageDirectory(_ packageDirectory: URL) -> URL? {
        guard RecordingOverlayMedia.isRealDirectoryNoFollow(at: packageDirectory) else { return nil }
        return packageDirectory.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Resolves a single top-level file `fileName` inside `packageDirectory`,
    /// rejecting empty names, path separators, `..`, symlinks, and non-regular files.
    static func resolvePackageFile(named fileName: String, in packageDirectory: URL) -> URL? {
        guard RecordingOverlayMedia.isSimpleFileName(fileName),
              let realPackage = resolveRealPackageDirectory(packageDirectory) else { return nil }
        let candidate = realPackage.appendingPathComponent(fileName, isDirectory: false)
        guard RecordingOverlayMedia.isRegularFileNoFollow(at: candidate) else { return nil }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.deletingLastPathComponent().path == realPackage.path else { return nil }
        return resolved
    }

    /// Checks an optional top-level package file: returns `nil` when absent,
    /// returns the resolved URL when it is a regular non-symlink file inside the
    /// package, or throws `ValidationError.unsafeFile` when it exists as a
    /// symlink, directory, or escaping path.
    static func resolveOptionalPackageFile(named fileName: String, in packageDirectory: URL) throws -> URL? {
        guard RecordingOverlayMedia.isSimpleFileName(fileName) else {
            throw ValidationError.unsafeFile(fileName)
        }
        guard let realPackage = resolveRealPackageDirectory(packageDirectory) else {
            throw ValidationError.invalidPackage(packageDirectory.lastPathComponent)
        }
        let candidate = realPackage.appendingPathComponent(fileName, isDirectory: false)
        var info = stat()
        guard lstat(candidate.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw ValidationError.unsafeFile(fileName)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ValidationError.unsafeFile(fileName)
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.deletingLastPathComponent().path == realPackage.path else {
            throw ValidationError.unsafeFile(fileName)
        }
        return resolved
    }

    /// Validates that `packageDirectory` is a real directory containing a regular
    /// non-symlink `screen.mov`, without requiring Finished-only sidecars or
    /// optional assets. Used to gate the Raw recording import choice.
    @discardableResult
    static func validateRawScreenInput(in packageDirectory: URL) throws -> URL {
        guard let realPackage = resolveRealPackageDirectory(packageDirectory) else {
            throw ValidationError.invalidPackage(packageDirectory.lastPathComponent)
        }
        guard let screenURL = resolvePackageFile(named: screenFileName, in: realPackage) else {
            throw ValidationError.unsafeFile(screenFileName)
        }
        return screenURL
    }

    /// Checks an optional file inside `mediaDirectory`: returns `nil` when absent
    /// (`ENOENT`), returns the resolved URL when it is a regular non-symlink file
    /// inside `mediaDirectory`, or throws `ValidationError.unsafeFile` for `..`
    /// traversal, symlinks (including dangling symlinks), or non-regular entries.
    static func resolveOptionalMediaFile(named fileName: String, in mediaDirectory: URL?) throws -> URL? {
        guard RecordingOverlayMedia.isSimpleFileName(fileName) else {
            throw ValidationError.unsafeFile(fileName)
        }
        guard let mediaDirectory else { return nil }
        let candidate = mediaDirectory.appendingPathComponent(fileName, isDirectory: false)
        var info = stat()
        guard lstat(candidate.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw ValidationError.unsafeFile(fileName)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ValidationError.unsafeFile(fileName)
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.deletingLastPathComponent().path == mediaDirectory.path else {
            throw ValidationError.unsafeFile(fileName)
        }
        return resolved
    }

    /// Validates a `.sukushorec` package and every input a Finished render can
    /// read (masters, sidecars, render cache, replacement/isolated/music audio,
    /// detached replacement audio, and `media/` assets). Rejects unsafe entries
    /// (including `..` traversal and dangling symlinks) while leaving truly
    /// absent optional references to the renderer's audibility/visibility rules.
    /// Call before offering Finished movie and again before starting the render.
    @discardableResult
    static func validateRenderInputs(in packageDirectory: URL) throws -> ResolvedRenderInputs {
        guard let realPackage = resolveRealPackageDirectory(packageDirectory) else {
            throw ValidationError.invalidPackage(packageDirectory.lastPathComponent)
        }
        guard let screenURL = resolvePackageFile(named: screenFileName, in: realPackage) else {
            throw ValidationError.unsafeFile(screenFileName)
        }
        let cameraURL = try resolveOptionalPackageFile(named: cameraFileName, in: realPackage)
        let draftURL = try resolveOptionalPackageFile(named: draftFileName, in: realPackage)
        let editURL = try resolveOptionalPackageFile(named: editFileName, in: realPackage)
        for sidecar in optionalSidecars {
            _ = try resolveOptionalPackageFile(named: sidecar, in: realPackage)
        }

        // Cached finished deliverables (`<packageName>.mov` / `.mp4`) read by the render cache.
        let packageStem = realPackage.deletingPathExtension().lastPathComponent
        if RecordingOverlayMedia.isSimpleFileName(packageStem) {
            for ext in deliverableExtensions {
                _ = try resolveOptionalPackageFile(named: "\(packageStem).\(ext)", in: realPackage)
            }
        }

        let isolatedMicrophoneURL = try resolveOptionalPackageFile(named: isolatedAudioFileName, in: realPackage)

        // Optional `media/` directory must be a real directory inside the package.
        let mediaCandidate = realPackage.appendingPathComponent("media", isDirectory: true)
        var mediaInfo = stat()
        let mediaDirectory: URL?
        if lstat(mediaCandidate.path, &mediaInfo) == 0 {
            guard let realMedia = RecordingOverlayMedia.resolveRealMediaDirectory(mediaCandidate) else {
                throw ValidationError.unsafeFile("media")
            }
            mediaDirectory = realMedia
        } else if errno == ENOENT {
            mediaDirectory = nil
        } else {
            throw ValidationError.unsafeFile("media")
        }

        // Inspect active edit document (`edit.draft.json` wins over `edit.json`,
        // matching `RecordingSession.editDocumentForRendering`).
        let activeEditURL = draftURL ?? editURL
        var replacementAudioURL: URL?
        var backgroundMusicURL: URL?

        if let activeEditURL {
            guard let data = try? Data(contentsOf: activeEditURL) else {
                throw ValidationError.invalidPackage(realPackage.lastPathComponent)
            }
            struct PackageEditRefs: Decodable {
                struct ClipRef: Decodable {
                    var sourceFileName: String?
                }
                struct AudioClipRef: Decodable {
                    var source: String?
                    var fileName: String?
                }
                struct FileRef: Decodable {
                    var fileName: String?
                }
                struct BackgroundMusicRef: Decodable {
                    var fileName: String?
                }
                var replacementAudioFileName: String?
                var backgroundMusic: BackgroundMusicRef?
                var clips: [ClipRef]?
                var audioClips: [AudioClipRef]?
                var imageOverlays: [FileRef]?
                var videoOverlays: [FileRef]?
            }

            guard let refs = try? JSONDecoder().decode(PackageEditRefs.self, from: data) else {
                throw ValidationError.invalidPackage(realPackage.lastPathComponent)
            }

            if let replacement = refs.replacementAudioFileName, !replacement.isEmpty {
                replacementAudioURL = try resolveOptionalPackageFile(named: replacement, in: realPackage)
            }

            if let musicFile = refs.backgroundMusic?.fileName, !musicFile.isEmpty {
                backgroundMusicURL = try resolveOptionalPackageFile(named: musicFile, in: realPackage)
            }

            var detachedReplacements: [String] = []
            var mediaFiles: [String] = []
            for clip in refs.clips ?? [] {
                if let name = clip.sourceFileName, !name.isEmpty { mediaFiles.append(name) }
            }
            for clip in refs.audioClips ?? [] {
                guard let name = clip.fileName, !name.isEmpty else { continue }
                if clip.source == "replacement" {
                    detachedReplacements.append(name)
                } else if clip.source == "file" || clip.source == nil {
                    mediaFiles.append(name)
                }
            }
            for image in refs.imageOverlays ?? [] {
                if let name = image.fileName, !name.isEmpty { mediaFiles.append(name) }
            }
            for video in refs.videoOverlays ?? [] {
                if let name = video.fileName, !name.isEmpty { mediaFiles.append(name) }
            }

            for name in Set(detachedReplacements) {
                _ = try resolveOptionalPackageFile(named: name, in: realPackage)
            }
            for name in Set(mediaFiles) {
                _ = try resolveOptionalMediaFile(named: name, in: mediaDirectory)
            }
        }

        return ResolvedRenderInputs(
            packageDirectory: realPackage,
            screenURL: screenURL,
            cameraURL: cameraURL,
            activeEditURL: activeEditURL,
            replacementAudioURL: replacementAudioURL,
            isolatedMicrophoneURL: isolatedMicrophoneURL,
            backgroundMusicURL: backgroundMusicURL,
            mediaDirectory: mediaDirectory
        )
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
    /// Preview draw: never decodes synchronously on the draw path; keeps the
    /// last completed frame visible while prefetching any uncached frame.
    static func drawForPreview(
        _ overlay: RecordingImageOverlay,
        image: RecordingOverlayImage,
        atSourceTime sourceTime: TimeInterval,
        canvasSize: CGSize,
        in context: CGContext,
        onFrameDecoded: (@Sendable () -> Void)? = nil
    ) {
        let fade = overlay.fade(atSourceTime: sourceTime)
        guard fade > 0.001, overlay.opacity > 0.001 else { return }
        let frame = image.previewFrame(at: sourceTime - overlay.start, onDecoded: onFrameDecoded)
        draw(overlay, frame: frame, fade: fade, canvasSize: canvasSize, in: context)
    }

    /// Export draw: synchronously decodes the requested frame and throws a named
    /// asset error if Image I/O fails on any frame.
    static func drawForExport(
        _ overlay: RecordingImageOverlay,
        image: RecordingOverlayImage,
        atSourceTime sourceTime: TimeInterval,
        canvasSize: CGSize,
        in context: CGContext
    ) throws {
        let fade = overlay.fade(atSourceTime: sourceTime)
        guard fade > 0.001, overlay.opacity > 0.001 else { return }
        guard let frame = image.frame(at: sourceTime - overlay.start) else {
            let label = overlay.displayName.isEmpty ? overlay.fileName : overlay.displayName
            throw RecordingOverlayMedia.ResolutionError.missingOrInvalid(label)
        }
        draw(overlay, frame: frame, fade: fade, canvasSize: canvasSize, in: context)
    }

    /// Shared Core Graphics draw routine for `frame` at `sourceTime` into
    /// `context`, whose user space is the canvas with a top-left origin.
    private static func draw(
        _ overlay: RecordingImageOverlay,
        frame: CGImage,
        fade: Double,
        canvasSize: CGSize,
        in context: CGContext
    ) {
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
