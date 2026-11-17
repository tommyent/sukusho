//
//  ImageOptimizer.swift
//  Screendrop
//
//  Makes image files smaller with the encoders bundled in Contents/Helpers
//  (built by scripts/build-optimizers.sh): oxipng for PNG, MozJPEG's cjpeg and
//  jpegtran for JPEG, libwebp's cwebp and webpmux for WebP. Each runs as its
//  own process, so a bad file can't take the app down and cancelling is a
//  terminate. The original is never written to: a result is a new file in a
//  folder of its own, or the original itself when nothing better came out.
//

import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import zlib

nonisolated enum ImageOptimizationTarget: Sendable, Equatable {
    /// The same format and the same pixels in fewer bytes. PNG and JPEG only.
    case lossless
    /// A WebP file. A nil quality keeps every pixel; 0–100 trades detail for size.
    case webP(quality: Int?)
    /// A JPEG file from MozJPEG, quality 0–100. Transparent areas become white.
    case jpeg(quality: Int)
}

nonisolated enum ImageOptimizationEffort: String, Sendable, CaseIterable {
    case fast, balanced, smallest
}

nonisolated struct ImageOptimizationResult: Sendable {
    nonisolated enum Outcome: Sendable, Equatable {
        /// `url` is a new, smaller file with the same pixels.
        case optimized
        /// `url` is a new file in the format asked for, whatever its size.
        case converted
        /// Nothing smaller came out; `url` is the original.
        case alreadyOptimized
        /// The time limit passed first; `url` is the original.
        case timedOut
        /// `url` is the original, and this says why in words a person can read.
        case failed(String)
    }

    /// The file to use: the result, or the original when there is none.
    let url: URL
    let outcome: Outcome
    let originalByteCount: Int64
    let resultByteCount: Int64
    /// The folder made for this result, nil when `url` is the caller's own file.
    fileprivate let ownedFolder: URL?

    /// Deletes the result's file once it has been used. The caller's original is never touched.
    func discard() {
        if let ownedFolder { try? FileManager.default.removeItem(at: ownedFolder) }
    }

    /// The file as it is, for a caller that stopped waiting for a result.
    static func original(_ url: URL) -> ImageOptimizationResult {
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return ImageOptimizationResult(url: url, outcome: .timedOut, originalByteCount: bytes, resultByteCount: bytes, ownedFolder: nil)
    }

    /// "↓18%".
    static func saving(from original: Int64, to result: Int64) -> String {
        guard original > 0 else { return "" }
        return "↓\(max(0, Int((100 - 100 * Double(result) / Double(original)).rounded())))%"
    }

    /// "1.3 MB → 1.1 MB · ↓18%".
    var sizeSummary: String {
        let before = ByteCountFormatter.string(fromByteCount: originalByteCount, countStyle: .file)
        let after = ByteCountFormatter.string(fromByteCount: resultByteCount, countStyle: .file)
        return "\(before) → \(after) · \(Self.saving(from: originalByteCount, to: resultByteCount))"
    }
}

nonisolated struct ImageOptimizer: Sendable {
    /// Where the bundled encoders are.
    var toolsDirectory: URL
    /// Every result gets a folder of its own in here, so two images with one name never meet.
    var outputDirectory: URL

    /// The most pixels an image may have: whole bitmaps are held in memory to convert an image and to check a
    /// result, two of them at once. Larger images are left as they are.
    var pixelBudget = 100_000_000

    static let shared = ImageOptimizer(
        toolsDirectory: Bundle.main.bundleURL.appending(path: "Contents/Helpers"),
        outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "\(Bundle.main.bundleIdentifier ?? "Sukusho")/Optimized", directoryHint: .isDirectory)
    )

    /// Optimizes or converts the file at `source`, which stays as it is. Only cancellation throws: any
    /// failure comes back as `.failed` with the original's URL, so the caller always has a file to use.
    /// With a `timeLimit`, work that takes longer is stopped and the original comes back as `.timedOut`.
    func optimize(_ source: URL, to target: ImageOptimizationTarget = .lossless, effort: ImageOptimizationEffort = .balanced,
                  timeLimit: Duration? = nil) async throws -> ImageOptimizationResult {
        try await optimize(source, to: target, effort: effort, timeLimit: timeLimit, sourceFolder: nil)
    }

    /// The same for an image in memory: it is written as a PNG named `name` first, and that file stands in
    /// for the original in the result. Nil when the PNG can't be written.
    func optimize(_ image: CGImage, named name: String, to target: ImageOptimizationTarget = .lossless,
                  effort: ImageOptimizationEffort = .balanced, timeLimit: Duration? = nil) async throws -> ImageOptimizationResult? {
        let folder = outputDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let file = folder.appending(path: name).deletingPathExtension().appendingPathExtension("png")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        do {
            return try await optimize(file, to: target, effort: effort, timeLimit: timeLimit, sourceFolder: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    // MARK: - One run

    private nonisolated struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func optimize(_ source: URL, to target: ImageOptimizationTarget, effort: ImageOptimizationEffort,
                          timeLimit: Duration?, sourceFolder: URL?) async throws -> ImageOptimizationResult {
        try Task.checkCancellation()
        let originalBytes = Self.byteCount(source) ?? 0
        @Sendable func original(_ outcome: ImageOptimizationResult.Outcome) -> ImageOptimizationResult {
            ImageOptimizationResult(url: source, outcome: outcome, originalByteCount: originalBytes,
                                    resultByteCount: originalBytes, ownedFolder: sourceFolder)
        }
        @Sendable func finished() async throws -> ImageOptimizationResult {
            do {
                guard let output = try await produce(from: source, target: target, effort: effort) else {
                    return original(.alreadyOptimized)
                }
                let bytes = Self.byteCount(output) ?? 0
                if target == .lossless, bytes >= originalBytes {
                    try? FileManager.default.removeItem(at: output.deletingLastPathComponent())
                    return original(.alreadyOptimized)
                }
                // The result replaces the PNG written for an image in memory.
                if let sourceFolder { try? FileManager.default.removeItem(at: sourceFolder) }
                return ImageOptimizationResult(url: output, outcome: target == .lossless ? .optimized : .converted,
                                               originalByteCount: originalBytes, resultByteCount: bytes,
                                               ownedFolder: output.deletingLastPathComponent())
            } catch let failure as Failure {
                return original(.failed(failure.message))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return original(.failed(Self.reason(error)))
            }
        }
        guard let timeLimit else { return try await finished() }
        return try await withThrowingTaskGroup(of: ImageOptimizationResult?.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await finished() }
            group.addTask {
                try await Task.sleep(for: timeLimit)
                return nil
            }
            if let first = try await group.next(), let first { return first }
            group.cancelAll()
            // The work can finish in the same instant the limit passes; its file isn't wanted any more.
            if let late = (try? await group.next()) ?? nil, late.url != source { late.discard() }
            return original(.timedOut)
        }
    }

    /// The finished file, alone in a new folder, or nil when the encoder found nothing smaller. Everything
    /// else it took is deleted, also on failure and cancellation.
    private func produce(from source: URL, target: ImageOptimizationTarget, effort: ImageOptimizationEffort) async throws -> URL? {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let size = Self.uprightPixelSize(imageSource) else {
            throw Failure("The file isn't an image Sukusho can read.")
        }
        // Read from the file's header: nothing is decoded and no encoder runs for an image over the budget.
        guard Int(size.width) * Int(size.height) <= pixelBudget else {
            throw Failure("The image is too large to optimize, so the original is used.")
        }
        let type = (CGImageSourceGetType(imageSource) as String?).flatMap { UTType($0) }
        let id = UUID().uuidString
        let scratch = outputDirectory.appending(path: id + ".work", directoryHint: .isDirectory)
        let files = FileManager.default
        do {
            try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            throw Failure("The optimized file couldn't be written. \(Self.reason(error))")
        }
        defer { try? files.removeItem(at: scratch) }
        let log = scratch.appending(path: "errors.txt")
        let made: URL

        switch target {
        case .lossless where type?.conforms(to: .png) == true:
            made = scratch.appending(path: "out.png")
            // No --alpha (it rewrites the color of fully transparent pixels) and no --strip (color profiles stay).
            let level = switch effort {
            case .fast: ["-o", "1"]
            case .balanced: ["-o", "2"]
            case .smallest: ["-o", "4"]
            }
            try await run("oxipng", level + ["--out", made.path, "--", source.path], log: log)
            // oxipng writes nothing when it can't make the file smaller.
            if !files.fileExists(atPath: made.path) { return nil }
        case .lossless where type?.conforms(to: .jpeg) == true:
            made = scratch.appending(path: "out.jpg")
            // Repacks the coefficients; the pixels and every marker (EXIF, color profile) stay.
            try await run("jpegtran", ["-copy", "all", "-optimize", "-progressive", "-outfile", made.path, source.path], log: log)
        case .lossless:
            throw Failure("Only PNG and JPEG images can be made smaller without converting them.")
        case .webP(let quality):
            made = scratch.appending(path: "out.webp")
            let pixels = try Self.writePixels(of: imageSource, to: scratch.appending(path: "in.pam"), keepsAlpha: true,
                                              profile: scratch.appending(path: "profile.icc"))
            let encoded = pixels.hasProfile ? scratch.appending(path: "plain.webp") : made
            var arguments = ["-quiet", "-mt"]
            if let quality {
                let method = switch effort {
                case .fast: "2"
                case .balanced: "4"
                case .smallest: "6"
                }
                // -sharp_yuv keeps the edges of small text; -alpha_q 100 keeps transparency exact.
                arguments += ["-q", String(min(max(quality, 0), 100)), "-m", method, "-sharp_yuv", "-alpha_q", "100"]
            } else {
                let level = switch effort {
                case .fast: "3"
                case .balanced: "6"
                case .smallest: "9"
                }
                arguments += ["-lossless", "-z", level]
            }
            try await run("cwebp", arguments + [pixels.url.path, "-o", encoded.path], log: log)
            if pixels.hasProfile {
                try await run("webpmux", ["-set", "icc", scratch.appending(path: "profile.icc").path, encoded.path, "-o", made.path], log: log)
            }
        case .jpeg(let quality):
            made = scratch.appending(path: "out.jpg")
            let pixels = try Self.writePixels(of: imageSource, to: scratch.appending(path: "in.ppm"), keepsAlpha: false,
                                              profile: scratch.appending(path: "profile.icc"))
            var arguments = ["-quality", String(min(max(quality, 0), 100))]
            if pixels.hasProfile { arguments += ["-icc", scratch.appending(path: "profile.icc").path] }
            try await run("cjpeg", arguments + ["-outfile", made.path, pixels.url.path], log: log)
        }

        // An encoder that exits cleanly can still leave a file nothing reads, such as one cut short by a full disk.
        let wanted: UTType? = switch target {
        case .lossless: type
        case .webP: .webP
        case .jpeg: .jpeg
        }
        guard let check = CGImageSourceCreateWithURL(made as CFURL, nil), CGImageSourceGetCount(check) > 0,
              CGImageSourceGetStatusAtIndex(check, 0) == .statusComplete,
              let madeType = (CGImageSourceGetType(check) as String?).flatMap({ UTType($0) }), let wanted, madeType.conforms(to: wanted),
              let madeSize = Self.uprightPixelSize(check), madeSize == size else {
            throw Self.broken
        }
        // ImageIO forgives a damaged file: it hands back pixels anyway, zeros where the decoder gave up, and
        // those can't be told from a transparent picture. So the file's own structure is checked first.
        try await requireIntact(made, type: madeType, scratch: scratch)
        // The encoder's word isn't taken for it: the result is decoded and held against the source.
        try Self.verify(check, against: imageSource, target: target)
        let folder = outputDirectory.appending(path: id, directoryHint: .isDirectory)
        let name = source.deletingPathExtension().lastPathComponent
        let fileExtension = target == .lossless ? source.pathExtension : made.pathExtension
        let output = folder.appending(path: name).appendingPathExtension(fileExtension.isEmpty ? made.pathExtension : fileExtension)
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try files.moveItem(at: made, to: output)
        } catch {
            try? files.removeItem(at: folder)
            throw Failure("The optimized file couldn't be written. \(Self.reason(error))")
        }
        return output
    }

    // MARK: - Whether a result is a whole file

    private static let broken = Failure("The optimized file didn't come out right, so the original is used.")

    /// Throws unless the file is whole by its format's own rules, whatever a decoder makes of it.
    private func requireIntact(_ url: URL, type: UTType, scratch: URL) async throws {
        if type.conforms(to: .jpeg) {
            // MozJPEG reads every coefficient back; with -strict any warning, such as data cut short, fails it.
            do {
                try await run("jpegtran", ["-strict", "-copy", "none", "-outfile", "/dev/null", url.path],
                              log: scratch.appending(path: "check.txt"))
            } catch is Failure {
                throw Self.broken
            }
            return
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              type.conforms(to: .png) ? Self.pngIsIntact(data) : Self.webPIsWhole(data) else { throw Self.broken }
    }

    /// Whether a PNG's chunks are whole (lengths and checksums, IHDR first, IEND last with nothing after it)
    /// and its image data inflates, to the end of its stream, into exactly the rows the header promises.
    static func pngIsIntact(_ data: Data) -> Bool {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            let count = bytes.count
            guard count >= 8, let base = bytes.baseAddress,
                  bytes.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return false }
            func word(_ offset: Int) -> Int { Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian) }
            var stream = z_stream()
            guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return false }
            defer { inflateEnd(&stream) }
            var output = [UInt8](repeating: 0, count: 1 << 16)
            var expected = -1, inflated = 0, streamEnded = false
            var offset = 8
            while offset + 12 <= count {
                let length = word(offset), type = offset + 4, body = offset + 8
                guard length <= count - offset - 12,
                      UInt(word(body + length)) == UInt(crc32(0, (base + type).assumingMemoryBound(to: Bytef.self), uInt(length + 4))) else {
                    return false
                }
                switch String(decoding: bytes[type..<body], as: UTF8.self) {
                case "IHDR":
                    guard offset == 8, length == 13 else { return false }
                    let width = word(body), height = word(body + 4), depth = Int(bytes[body + 8])
                    guard width > 0, height > 0, [1, 2, 4, 8, 16].contains(depth),
                          let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][bytes[body + 9]] else { return false }
                    // A row is a filter byte and its pixels, packed.
                    func rows(_ width: Int, _ height: Int) -> Int {
                        width > 0 && height > 0 ? height * (1 + (width * channels * depth + 7) / 8) : 0
                    }
                    if bytes[body + 12] == 0 {
                        expected = rows(width, height)
                    } else {
                        // Adam7: seven smaller images, each with rows of its own.
                        let passes = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
                        expected = passes.reduce(0) { $0 + rows((width - $1.0 + $1.2 - 1) / $1.2, (height - $1.1 + $1.3 - 1) / $1.3) }
                    }
                case "IDAT":
                    guard expected >= 0, !streamEnded else { return false }
                    stream.next_in = UnsafeMutablePointer(mutating: (base + body).assumingMemoryBound(to: Bytef.self))
                    stream.avail_in = uInt(length)
                    repeat {
                        let status = output.withUnsafeMutableBufferPointer { buffer -> Int32 in
                            stream.next_out = buffer.baseAddress
                            stream.avail_out = uInt(buffer.count)
                            let status = inflate(&stream, Z_NO_FLUSH)
                            inflated += buffer.count - Int(stream.avail_out)
                            return status
                        }
                        if status == Z_STREAM_END {
                            streamEnded = true
                            break
                        }
                        // Z_BUF_ERROR only says this chunk is used up.
                        guard status == Z_OK || status == Z_BUF_ERROR, inflated <= expected else { return false }
                    } while stream.avail_in > 0 || stream.avail_out == 0
                    guard stream.avail_in == 0 else { return false }
                case "IEND":
                    return length == 0 && offset + 12 == count && streamEnded && inflated == expected
                default:
                    break
                }
                offset += 12 + length
            }
            return false
        }
    }

    /// Whether a WebP's container adds up: its length is the one its header gives, and its chunks end exactly
    /// there. WebP has no checksums; what the picture inside is worth, `verify` decides.
    static func webPIsWhole(_ data: Data) -> Bool {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            let count = bytes.count
            func word(_ offset: Int) -> Int { Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian) }
            guard count >= 20, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WEBP".utf8),
                  word(4) + 8 == count else { return false }
            var offset = 12
            while offset + 8 <= count {
                let length = word(offset + 4)
                offset += 8 + length + (length & 1)
            }
            return offset == count
        }
    }

    // MARK: - Running an encoder

    /// A process that can be cancelled before it starts as well as while it runs.
    private nonisolated final class ToolRun: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var isCancelled = false

        init(_ process: Process) { self.process = process }

        func start() throws {
            try lock.withLock {
                if isCancelled { throw CancellationError() }
                try process.run()
            }
        }

        /// How long an encoder has to stop once it is asked to, before it is killed.
        static let grace: TimeInterval = 0.5

        func cancel() {
            let wasRunning = lock.withLock {
                isCancelled = true
                guard process.isRunning else { return false }
                process.terminate()
                return true
            }
            guard wasRunning else { return }
            // An encoder that ignores the request is killed: a cancel or a time limit is waiting for it to be
            // gone. Only this process, and only while it is still the one that was started.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.grace) { [self] in
                lock.withLock {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    private func run(_ tool: String, _ arguments: [String], log: URL) async throws {
        guard FileManager.default.createFile(atPath: log.path, contents: nil), let errors = try? FileHandle(forWritingTo: log) else {
            throw Failure("The optimized file couldn't be written.")
        }
        defer { try? errors.close() }
        let process = Process()
        process.executableURL = toolsDirectory.appending(path: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        // A file, not a pipe: a pipe nobody reads would stop an encoder that has much to say.
        process.standardError = errors
        // Work nobody is waiting for, such as a new capture optimized in the background, stays out of the way.
        if Task.currentPriority <= .utility { process.qualityOfService = .utility }
        let toolRun = ToolRun(process)
        let status: Int32
        do {
            status = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                    process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                    do {
                        try toolRun.start()
                    } catch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                toolRun.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Not in this build, or not for this Mac's processor.
            throw Failure("The \(tool) encoder couldn't be started.")
        }
        try Task.checkCancellation()
        guard status == 0 else {
            // The last thing it said, after the file names that lead up to it.
            let said = (try? String(contentsOf: log, encoding: .utf8))?.split(whereSeparator: \.isNewline).last?
                .components(separatedBy: ": ").last
            throw Failure(said.map { "\(tool) stopped: \($0)" } ?? "\(tool) stopped with status \(status).")
        }
    }

    // MARK: - Pixels for the encoders

    /// The image's pixels as a PAM (with alpha) or PPM file, 8 bits a channel and never premultiplied, in its
    /// own RGB color space, whose profile goes to `profile` unless it is plain sRGB. Without `keepsAlpha`,
    /// transparency is flattened on white.
    private static func writePixels(of source: CGImageSource, to url: URL, keepsAlpha: Bool, profile: URL) throws -> (url: URL, hasProfile: Bool) {
        guard let image = uprightImage(source) else { throw Failure("The file isn't an image Sukusho can read.") }
        let space = rgbSpace(of: image)
        guard var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space,
                                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)) else {
            throw Failure("The image's colors couldn't be read.")
        }
        var rgba = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&rgba, &format, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            throw Failure("The image is too large to convert.")
        }
        defer { free(rgba.data) }

        let opaque: [CGImageAlphaInfo] = [.none, .noneSkipFirst, .noneSkipLast]
        let hasAlpha = !opaque.contains(image.alphaInfo)
        var pixels = rgba
        var channels = 4
        var rgb = vImage_Buffer()
        defer { free(rgb.data) }
        if !(keepsAlpha && hasAlpha) {
            guard vImageBuffer_Init(&rgb, rgba.height, rgba.width, 24, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                throw Failure("The image is too large to convert.")
            }
            if hasAlpha {
                vImageFlatten_RGBA8888ToRGB888(&rgba, &rgb, [255, 255, 255, 255], false, vImage_Flags(kvImageNoFlags))
            } else {
                vImageConvert_RGBA8888toRGB888(&rgba, &rgb, vImage_Flags(kvImageNoFlags))
            }
            pixels = rgb
            channels = 3
        }
        let width = Int(pixels.width), height = Int(pixels.height)
        let header = channels == 4
            ? "P7\nWIDTH \(width)\nHEIGHT \(height)\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n"
            : "P6\n\(width) \(height)\n255\n"
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + width * height * channels)
        for row in 0..<height {
            data.append(UnsafeBufferPointer(start: (pixels.data! + row * pixels.rowBytes).assumingMemoryBound(to: UInt8.self),
                                            count: width * channels))
        }
        do {
            try data.write(to: url)
            // A file without a profile is read as sRGB, so sRGB's own profile would only add bytes.
            guard space.name as String? != CGColorSpace.sRGB as String, let icc = space.copyICCData() as Data? else { return (url, false) }
            try icc.write(to: profile)
            return (url, true)
        } catch {
            throw Failure("The optimized file couldn't be written. \(Self.reason(error))")
        }
    }

    /// The RGB space an image's pixels are read in: its own when it has one with a profile, else sRGB.
    private static func rgbSpace(of image: CGImage) -> CGColorSpace {
        // A palette image's colors are in the palette's space.
        let own = image.colorSpace.map { $0.model == .indexed ? $0.baseColorSpace ?? $0 : $0 }
        return own.flatMap { $0.model == .rgb && $0.copyICCData() != nil ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// The image as RGBA rows in `space`, 8 or 16 bits a channel, without row padding.
    private static func bitmap(_ image: CGImage, in space: CGColorSpace, bits: Int, premultiplied: Bool) -> Data? {
        let alpha: CGImageAlphaInfo = premultiplied ? .premultipliedLast : .last
        let info = CGBitmapInfo(rawValue: alpha.rawValue | (bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0))
        guard var format = vImage_CGImageFormat(bitsPerComponent: bits, bitsPerPixel: bits * 4, colorSpace: space, bitmapInfo: info) else {
            return nil
        }
        var buffer = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
              let rows = buffer.data else { return nil }
        defer { free(rows) }
        let rowLength = Int(buffer.width) * 4 * bits / 8
        var data = Data(capacity: rowLength * Int(buffer.height))
        for row in 0..<Int(buffer.height) {
            data.append(UnsafeBufferPointer(start: (rows + row * buffer.rowBytes).assumingMemoryBound(to: UInt8.self), count: rowLength))
        }
        return data
    }

    /// Stops a result that isn't the source's picture. An encoder can exit cleanly and leave another image, or
    /// a file ImageIO calls complete that decodes to nothing; either would otherwise replace the original.
    private static func verify(_ result: CGImageSource, against source: CGImageSource, target: ImageOptimizationTarget) throws {
        // A decoder that failed outright has no data to give, though it still gave an image to draw.
        guard let original = uprightImage(source), let candidate = uprightImage(result), candidate.dataProvider?.data != nil else {
            throw broken
        }
        // Both are read into the source's color space, so a lost or changed profile shows as changed pixels.
        let space = rgbSpace(of: original)
        switch target {
        case .lossless:
            // The same pixels at the source's own depth, never premultiplied, and the same orientation.
            let bits = original.bitsPerComponent > 8 ? 16 : 8
            guard orientation(source) == orientation(result),
                  let before = bitmap(original, in: space, bits: bits, premultiplied: false),
                  let after = bitmap(candidate, in: space, bits: bits, premultiplied: false), before == after else {
                throw Failure("The optimized file didn't keep the picture exactly, so the original is used.")
            }
        case .webP(quality: nil):
            // WebP holds 8 bits a channel and may drop the color under fully transparent pixels; premultiplying
            // makes those zero on both sides, so what is compared is what can be seen.
            guard let before = bitmap(original, in: space, bits: 8, premultiplied: true),
                  let after = bitmap(candidate, in: space, bits: 8, premultiplied: true), before == after else {
                throw Failure("The WebP file didn't keep the picture exactly, so it wasn't kept.")
            }
        case .webP, .jpeg:
            // A smaller, lossy file can't be the same pixels, but it has to decode in full and look like the source.
            guard bitmap(candidate, in: space, bits: 8, premultiplied: true) != nil, resembles(original, candidate) else {
                throw Failure("The converted file doesn't show the picture, so it wasn't kept.")
            }
        }
    }

    /// Whether two images show the same picture, roughly: both drawn small on white, their colors may differ by
    /// a sixth of the range on average. Any quality setting passes; another picture, or a blank one, doesn't.
    private static func resembles(_ first: CGImage, _ second: CGImage) -> Bool {
        let side = 64
        func small(_ image: CGImage) -> [UInt8]? {
            guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let data = context.data else { return nil }
            let frame = CGRect(x: 0, y: 0, width: side, height: side)
            context.setFillColor(CGColor.white)
            context.fill(frame)
            context.draw(image, in: frame)
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: side * side * 4))
        }
        guard let one = small(first), let two = small(second) else { return false }
        var difference = 0
        for index in stride(from: 0, to: one.count, by: 4) {
            for channel in 0..<3 { difference += abs(Int(one[index + channel]) - Int(two[index + channel])) }
        }
        return difference / (side * side * 3) < 42
    }

    /// The first image, turned the way its orientation says. An image already upright is decoded as it is,
    /// so its pixels stay exact.
    private static func uprightImage(_ source: CGImageSource) -> CGImage? {
        guard let size = uprightPixelSize(source) else { return nil }
        if orientation(source) == 1 { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
        ] as CFDictionary)
    }

    private static func orientation(_ source: CGImageSource) -> UInt32 {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
    }

    private static func uprightPixelSize(_ source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        // Orientations 5 to 8 lie on their side.
        return orientation(source) >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// Asked of the file system each time: a URL keeps the sizes it has read.
    private static func byteCount(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Why it failed, without the name of a working file nobody has heard of.
    private static func reason(_ error: Error) -> String {
        let error = error as NSError
        return error.localizedFailureReason ?? error.localizedDescription
    }
}
