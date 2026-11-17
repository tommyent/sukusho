// The image optimizer, run against the real encoders in Vendor/optimizers (the files the app bundles), on
// pictures drawn here: lossless results keep every pixel and the color profile, the original is never
// touched, nothing is left behind on failure or cancellation, and a copy that finishes late never
// replaces a newer one. Pasteboards are private and named, never the user's.
import AppKit
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

// MARK: - Pictures drawn for the tests

private enum Sample {
    /// A made-up screenshot: panels, a title bar and lines of code-like text, the same for the same seed.
    /// With `transparent`, the corners are clear and a soft shadow sits under the window.
    static func screenshot(width: Int, height: Int, seed: UInt64, space: CFString = CGColorSpace.displayP3,
                           transparent: Bool = false, dark: Bool = false, bits: Int = 8) -> CGImage {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func next(_ limit: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(max(limit, 1)))
        }
        let colorSpace = CGColorSpace(name: space)!
        let info = bits == 16
            ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0,
                                space: colorSpace, bitmapInfo: info)!
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let window = transparent ? bounds.insetBy(dx: CGFloat(width) * 0.06, dy: CGFloat(height) * 0.06) : bounds
        if transparent {
            context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0, 0, 0, 0.45))
        }
        context.setFillColor(dark ? color(0.11, 0.12, 0.14) : color(0.97, 0.97, 0.98))
        context.addPath(CGPath(roundedRect: window, cornerWidth: transparent ? min(12, window.width / 4) : 0,
                               cornerHeight: transparent ? min(12, window.height / 4) : 0, transform: nil))
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.clip(to: window)
        // A title bar and a sidebar in saturated colors, which a wide-gamut profile changes visibly.
        context.setFillColor(color(0.95, 0.2 + CGFloat(next(40)) / 100, 0.15))
        context.fill(CGRect(x: window.minX, y: window.maxY - 28, width: window.width, height: 28))
        context.setFillColor(color(0.1, 0.55 + CGFloat(next(30)) / 100, 0.9, 0.85))
        context.fill(CGRect(x: window.minX, y: window.minY, width: window.width * 0.22, height: window.height - 28))
        let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        let words = ["let", "guard", "return", "optimize", "pixels", "url", "await", "copy", "shelf", "==", "{", "}", "0x1F", "nil"]
        var y = window.maxY - 46
        while y > window.minY + 6 {
            let line = (0..<(3 + next(9))).map { _ in words[next(words.count)] }.joined(separator: " ")
            let text = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    dark ? color(0.6 + CGFloat(next(40)) / 100, 0.9, 0.7) : color(0.1, 0.1, CGFloat(next(60)) / 100),
            ])
            context.textPosition = CGPoint(x: window.minX + window.width * 0.24 + CGFloat(next(4) * 14), y: y)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            y -= 16
        }
        return context.makeImage()!
    }

    /// Noise, which no encoder shrinks quickly: something slow to cancel.
    static func noise(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var state: UInt64 = 88172645463325252
        for index in 0..<(context.bytesPerRow * height) {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            bytes[index] = UInt8(truncatingIfNeeded: state)
        }
        return context.makeImage()!
    }

    static func write(_ image: CGImage, to url: URL, as type: UTType = .png, quality: Double? = nil) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        try #require(CGImageDestinationFinalize(destination))
    }
}

/// A folder for one test, with an optimizer that writes inside it.
private struct Bench {
    static let tools = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Vendor/optimizers")

    let folder = FileManager.default.temporaryDirectory.appending(path: "SukushoOptimizerTests-\(UUID().uuidString)")
    var output: URL { folder.appending(path: "out") }
    var optimizer: ImageOptimizer { ImageOptimizer(toolsDirectory: Self.tools, outputDirectory: output) }

    init() throws { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.removeItem(at: folder) }

    func file(_ name: String, _ image: CGImage, as type: UTType = .png, quality: Double? = nil) throws -> URL {
        let url = folder.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Sample.write(image, to: url, as: type, quality: quality)
        return url
    }

    /// What is left in the output folder: results still there, or scraps that should not be.
    var leftovers: [String] { (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? [] }
}

private func image(at url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

/// Every pixel as it would be shown in Display P3, so a lost or changed color profile shows up as changed pixels.
private func pixels(at url: URL, bits: Int = 8) throws -> [UInt8] {
    let image = try image(at: url)
    let info = bits == 16
        ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        : CGImageAlphaInfo.premultipliedLast.rawValue
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: bits, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: info))
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: context.bytesPerRow * image.height))
}

private func profile(at url: URL) throws -> Data? {
    try image(at: url).colorSpace?.copyICCData() as Data?
}

private func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1 }

/// Whether a process whose command line holds `text` is still running.
private func isRunning(_ text: String) -> Bool {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/pgrep")
    process.arguments = ["-f", text]
    process.standardOutput = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

// MARK: - Results

@Suite struct ImageOptimizerLosslessTests {
    @Test func pngKeepsEveryPixelItsProfileAndTransparency() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Window.png", Sample.screenshot(width: 900, height: 620, seed: 1, transparent: true))
        let before = try Data(contentsOf: source)

        let result = try await bench.optimizer.optimize(source)

        #expect(result.outcome == .optimized)
        #expect(result.url != source)
        #expect(result.url.lastPathComponent == "Window.png")
        #expect(result.originalByteCount == Int64(before.count))
        #expect(result.resultByteCount == Int64(size(result.url)))
        #expect(result.resultByteCount < result.originalByteCount)
        #expect(try pixels(at: result.url) == pixels(at: source))
        #expect(try profile(at: source) != nil)
        #expect(try profile(at: result.url) == profile(at: source))
        // The original is as it was, byte for byte, and the result is the only thing left in the output folder.
        #expect(try Data(contentsOf: source) == before)
        #expect(bench.leftovers.count == 1)
        result.discard()
        #expect(bench.leftovers.isEmpty)
    }

    @Test func sixteenBitPNGKeepsItsDepth() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Deep.png", Sample.screenshot(width: 320, height: 200, seed: 2, bits: 16))
        let result = try await bench.optimizer.optimize(source)
        #expect(try pixels(at: result.url, bits: 16) == pixels(at: source, bits: 16))
        #expect(try profile(at: result.url) == profile(at: source))
    }

    @Test func everyEffortGivesTheSamePixels() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Page.png", Sample.screenshot(width: 640, height: 400, seed: 3))
        for effort in ImageOptimizationEffort.allCases {
            let result = try await bench.optimizer.optimize(source, effort: effort)
            #expect(result.outcome == .optimized, "\(effort)")
            #expect(try pixels(at: result.url) == pixels(at: source), "\(effort)")
        }
    }

    @Test func jpegIsRepackedWithoutChangingAPixel() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Photo.jpg", Sample.screenshot(width: 800, height: 520, seed: 4), as: .jpeg, quality: 0.9)
        let result = try await bench.optimizer.optimize(source)
        #expect(result.outcome == .optimized)
        #expect(result.url.pathExtension == "jpg")
        #expect(result.resultByteCount < result.originalByteCount)
        #expect(try pixels(at: result.url) == pixels(at: source))
        #expect(try profile(at: source) != nil)
        #expect(try profile(at: result.url) == profile(at: source))
    }

    @Test func aResultThatIsNotSmallerKeepsTheOriginal() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Page.png", Sample.screenshot(width: 640, height: 400, seed: 5))
        let first = try await bench.optimizer.optimize(source, effort: .smallest)
        #expect(first.outcome == .optimized)

        // Optimizing the optimized file again, with less effort, finds nothing smaller.
        let again = try await bench.optimizer.optimize(first.url, effort: .fast)
        #expect(again.outcome == .alreadyOptimized)
        #expect(again.url == first.url)
        #expect(again.resultByteCount == again.originalByteCount)
        again.discard()   // not the optimizer's file, so this must leave it alone
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        #expect(bench.leftovers.count == 1)
    }

    @Test func oddSizesComeThroughEveryRoute() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        for (width, height) in [(1, 1), (3, 5), (1, 211), (257, 3)] {
            let name = "odd-\(width)x\(height)"
            let source = try bench.file("\(name).png", Sample.screenshot(width: width, height: height, seed: UInt64(width * height),
                                                                         transparent: true))
            for target in [ImageOptimizationTarget.lossless, .webP(quality: nil), .webP(quality: 80), .jpeg(quality: 80)] {
                let result = try await bench.optimizer.optimize(source, to: target)
                let made = try image(at: result.url)
                #expect(made.width == width && made.height == height, "\(name) \(target): \(result.outcome)")
                switch target {
                case .lossless:
                    #expect([.optimized, .alreadyOptimized].contains(result.outcome), "\(name): \(result.outcome)")
                    #expect(try pixels(at: result.url) == pixels(at: source), "\(name)")
                case .webP(quality: nil):
                    #expect(result.outcome == .converted, "\(name): \(result.outcome)")
                    #expect(try pixels(at: result.url) == pixels(at: source), "\(name)")
                default:
                    #expect(result.outcome == .converted, "\(name) \(target): \(result.outcome)")
                }
            }
        }
    }
}

@Suite struct ImageOptimizerConversionTests {
    @Test func losslessWebPKeepsEveryPixelItsProfileAndTransparency() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Window.png", Sample.screenshot(width: 900, height: 620, seed: 6, transparent: true))
        let result = try await bench.optimizer.optimize(source, to: .webP(quality: nil))
        #expect(result.outcome == .converted)
        #expect(result.url.lastPathComponent == "Window.webp")
        #expect(try pixels(at: result.url) == pixels(at: source))
        #expect(try profile(at: result.url) == profile(at: source))
        #expect(try image(at: result.url).alphaInfo != .none)
        #expect(result.resultByteCount < result.originalByteCount)
    }

    @Test func sRGBWebPCarriesNoProfileAndTheSamePixels() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Page.png", Sample.screenshot(width: 500, height: 300, seed: 7, space: CGColorSpace.sRGB))
        let result = try await bench.optimizer.optimize(source, to: .webP(quality: nil))
        #expect(try pixels(at: result.url) == pixels(at: source))
        // No ICCP chunk: the RIFF file goes straight from its header to the image data.
        #expect(try Data(contentsOf: result.url).range(of: Data("ICCP".utf8)) == nil)
    }

    @Test func lossyWebPAndJPEGKeepTheSizeAndProfile() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Window.png", Sample.screenshot(width: 900, height: 620, seed: 8, transparent: true))
        let webP = try await bench.optimizer.optimize(source, to: .webP(quality: 80))
        #expect(webP.outcome == .converted)
        #expect(try profile(at: webP.url) == profile(at: source))
        // Transparency survives a lossy WebP exactly: the clear corner is still clear.
        #expect(try pixels(at: webP.url)[0..<4] == [0, 0, 0, 0])

        let jpeg = try await bench.optimizer.optimize(source, to: .jpeg(quality: 80))
        #expect(jpeg.outcome == .converted)
        #expect(jpeg.url.lastPathComponent == "Window.jpg")
        #expect(try profile(at: jpeg.url) == profile(at: source))
        let made = try image(at: jpeg.url)
        #expect(made.width == 900 && made.height == 620)
        // JPEG has no transparency: the clear corner is flattened on white.
        #expect(try pixels(at: jpeg.url)[0..<4].allSatisfy { $0 >= 250 })
    }

    /// oxipng turns a picture of few colors into a palette PNG and a gray one into a grayscale PNG. Converting
    /// those must still give the first picture's pixels.
    @Test func paletteAndGrayPNGsConvertExactly() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        for (name, gray) in [("Flat", false), ("Gray", true)] {
            let space = CGColorSpace(name: gray ? CGColorSpace.genericGrayGamma2_2 : CGColorSpace.displayP3)!
            let context = try #require(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                                 bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue))
            for band in 0..<6 {
                let level = CGFloat(band) / 5
                context.setFillColor(CGColor(colorSpace: space, components: gray ? [level, 1] : [1 - level, level, 0.2, 1])!)
                context.fill(CGRect(x: band * 50, y: 0, width: 50, height: 200))
            }
            let source = try bench.file("\(name).png", try #require(context.makeImage()))
            let reduced = try await bench.optimizer.optimize(source)
            #expect(reduced.outcome == .optimized, "\(name)")
            let model = try image(at: reduced.url).colorSpace?.model
            #expect(model == (gray ? .monochrome : .indexed), "\(name): oxipng no longer reduces this picture, so the test checks nothing")

            let webP = try await bench.optimizer.optimize(reduced.url, to: .webP(quality: nil))
            #expect(webP.outcome == .converted, "\(name): \(webP.outcome)")
            #expect(try pixels(at: webP.url) == pixels(at: source), "\(name)")
        }
    }

    @Test func aConversionIsKeptEvenWhenItIsLarger() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        // A 1-pixel PNG is smaller than any JPEG of it.
        let source = try bench.file("Dot.png", Sample.screenshot(width: 1, height: 1, seed: 9))
        let result = try await bench.optimizer.optimize(source, to: .jpeg(quality: 90))
        #expect(result.outcome == .converted)
        #expect(result.resultByteCount > result.originalByteCount)
        #expect(result.url.pathExtension == "jpg")
    }

    @Test func anImageInMemoryIsOptimizedFromAPNGOfIt() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let picture = Sample.screenshot(width: 640, height: 400, seed: 10)
        let reference = try bench.file("reference.png", picture)

        let result = try #require(try await bench.optimizer.optimize(picture, named: "Capture"))
        #expect(result.outcome == .optimized)
        #expect(result.url.lastPathComponent == "Capture.png")
        #expect(try pixels(at: result.url) == pixels(at: reference))
        // The PNG written for it is gone; only the result is left.
        #expect(bench.leftovers.count == 1)
    }

    @Test func aPhotoTurnedOnItsSideComesOutUpright() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = bench.folder.appending(path: "Sideways.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, Sample.screenshot(width: 300, height: 200, seed: 11),
                                   [kCGImagePropertyOrientation: 6] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))

        let result = try await bench.optimizer.optimize(source, to: .webP(quality: 80))
        let made = try image(at: result.url)
        #expect(result.outcome == .converted)
        #expect(made.width == 200 && made.height == 300)
    }
}

// MARK: - Failure, cancellation and limits

@Suite struct ImageOptimizerFailureTests {
    /// A stand-in encoder that behaves like one hitting a full disk: it writes the start of the file and stops.
    private func brokenTools(exit status: Int) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SukushoBrokenTools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        while [ $# -gt 0 ]; do
          if [ "$1" = "--out" ]; then out="$2"; fi
          last="$1"
          shift
        done
        head -c 300 "$last" > "$out"
        echo "error: No space left on device (os error 28)" >&2
        exit \(status)
        """
        let tool = folder.appending(path: "oxipng")
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return folder
    }

    @Test func anEncoderThatStopsHalfwayLeavesTheOriginalAndNoScraps() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Page.png", Sample.screenshot(width: 640, height: 400, seed: 20))
        let before = try Data(contentsOf: source)
        // Status 1 is an encoder that reports the full disk; status 0 is one that doesn't notice.
        for status in [1, 0] {
            let tools = try brokenTools(exit: status)
            defer { try? FileManager.default.removeItem(at: tools) }
            let result = try await ImageOptimizer(toolsDirectory: tools, outputDirectory: bench.output).optimize(source)
            guard case .failed(let reason) = result.outcome else {
                Issue.record("exit \(status): \(result.outcome)")
                continue
            }
            if status == 1 { #expect(reason.contains("No space left on device")) }
            #expect(result.url == source)
            #expect(result.resultByteCount == result.originalByteCount)
            #expect(try Data(contentsOf: source) == before)
            #expect(bench.leftovers.isEmpty, "exit \(status): \(bench.leftovers)")
        }
    }

    @Test func anOutputFolderThatCannotBeWrittenFallsBackToTheOriginal() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Page.png", Sample.screenshot(width: 640, height: 400, seed: 21))
        let before = try Data(contentsOf: source)
        let locked = bench.folder.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let optimizer = ImageOptimizer(toolsDirectory: Bench.tools, outputDirectory: locked.appending(path: "out"))
        for target in [ImageOptimizationTarget.lossless, .webP(quality: nil), .jpeg(quality: 80)] {
            let result = try await optimizer.optimize(source, to: target)
            guard case .failed = result.outcome else {
                Issue.record("\(target): \(result.outcome)")
                continue
            }
            #expect(result.url == source)
        }
        #expect(try Data(contentsOf: source) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: locked.path).isEmpty)
    }

    @Test func missingEncodersAndFilesThatAreNotImagesFallBack() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Page.png", Sample.screenshot(width: 64, height: 40, seed: 22))
        let noTools = ImageOptimizer(toolsDirectory: bench.folder.appending(path: "nothing-here"), outputDirectory: bench.output)
        let missing = try await noTools.optimize(source)
        #expect(missing.outcome == .failed("The oxipng encoder couldn't be started."))
        #expect(missing.url == source)

        let text = bench.folder.appending(path: "notes.png")
        try Data("not a picture".utf8).write(to: text)
        let notAnImage = try await bench.optimizer.optimize(text)
        #expect(notAnImage.outcome == .failed("The file isn't an image Sukusho can read."))
        #expect(notAnImage.url == text)

        let gone = try await bench.optimizer.optimize(bench.folder.appending(path: "gone.png"))
        #expect(gone.outcome == .failed("The file isn't an image Sukusho can read."))

        // Only PNG and JPEG have a lossless route; a TIFF says so and can still be converted.
        let tiff = try bench.file("Scan.tiff", Sample.screenshot(width: 64, height: 40, seed: 23), as: .tiff)
        let lossless = try await bench.optimizer.optimize(tiff)
        #expect(lossless.outcome == .failed("Only PNG and JPEG images can be made smaller without converting them."))
        let converted = try await bench.optimizer.optimize(tiff, to: .webP(quality: nil))
        #expect(converted.outcome == .converted)
        #expect(try pixels(at: converted.url) == pixels(at: tiff))
        converted.discard()
        #expect(bench.leftovers.isEmpty)
    }

    @Test func cancellingStopsTheEncoderAndLeavesNothing() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Noise.png", Sample.noise(width: 3000, height: 2400))
        let before = size(source)
        let optimizer = bench.optimizer
        let clock = ContinuousClock()

        let task = Task { try await optimizer.optimize(source, effort: .smallest) }
        // Wait until the encoder is at work on this test's file, however busy the Mac is.
        var sawEncoder = false
        for _ in 0..<100 where !sawEncoder {
            try await Task.sleep(for: .milliseconds(50))
            sawEncoder = isRunning(bench.folder.lastPathComponent)
        }
        #expect(sawEncoder)
        let cancelled = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(clock.now - cancelled < .seconds(2))
        #expect(!isRunning(bench.folder.lastPathComponent))
        #expect(bench.leftovers.isEmpty)
        #expect(size(source) == before)

        // Cancelled before it starts: nothing runs at all.
        let early = Task { try await optimizer.optimize(source) }
        early.cancel()
        await #expect(throws: CancellationError.self) { try await early.value }
        #expect(bench.leftovers.isEmpty)
    }

    @Test func aTimeLimitGivesTheOriginalBackAndStopsTheEncoder() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Noise.png", Sample.noise(width: 3000, height: 2400))
        let result = try await bench.optimizer.optimize(source, effort: .smallest, timeLimit: .milliseconds(200))
        #expect(result.outcome == .timedOut)
        #expect(result.url == source)
        #expect(!isRunning(bench.folder.lastPathComponent))
        #expect(bench.leftovers.isEmpty)

        // A limit that isn't reached changes nothing.
        let small = try bench.file("Page.png", Sample.screenshot(width: 320, height: 200, seed: 24))
        let inTime = try await bench.optimizer.optimize(small, timeLimit: .seconds(30))
        #expect(inTime.outcome == .optimized)
    }
}

// MARK: - Copying

@MainActor
@Suite struct OptimizedImageCopyTests {
    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("SukushoOptimizeTest-\(UUID().uuidString)"))
    }

    private func item(_ url: URL) throws -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(try Data(contentsOf: url), forType: .png)
        return item
    }

    @Test func twoSameSizeScreenshotsStayTwoDifferentResults() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        // The same name and pixel size, as two captures taken one after the other have.
        let first = try bench.file("a/Screenshot.png", Sample.screenshot(width: 800, height: 500, seed: 30))
        let second = try bench.file("b/Screenshot.png", Sample.screenshot(width: 800, height: 500, seed: 31))
        #expect(try pixels(at: first) != pixels(at: second))
        let optimizer = bench.optimizer

        // Optimized at the same moment, neither gets the other's file.
        async let one = optimizer.optimize(first)
        async let two = optimizer.optimize(second)
        let (resultOne, resultTwo) = try await (one, two)
        #expect(resultOne.url != resultTwo.url)
        #expect(try pixels(at: resultOne.url) == pixels(at: first))
        #expect(try pixels(at: resultTwo.url) == pixels(at: second))

        // Copied one right after the other, each lands on the pasteboard as itself, once.
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let copier = OptimizedImageCopy()
        let count = board.changeCount
        let copiedOne = try #require(try await copier.copy(first, to: board, optimize: { try await optimizer.optimize($0) }, item: item))
        #expect(board.data(forType: .png) == (try Data(contentsOf: copiedOne.url)))
        let afterOne = board.changeCount
        let copiedTwo = try #require(try await copier.copy(second, to: board, optimize: { try await optimizer.optimize($0) }, item: item))
        #expect(board.data(forType: .png) == (try Data(contentsOf: copiedTwo.url)))
        #expect(copiedOne.url != copiedTwo.url)
        #expect(afterOne > count && board.changeCount > afterOne)
        #expect(board.pasteboardItems?.count == 1)

        // Clipboard history folds an optimized copy into its original's card and keeps the two screenshots apart.
        #expect(ClipboardImageMatch.isSamePicture(try Data(contentsOf: copiedOne.url), first))
        #expect(!ClipboardImageMatch.isSamePicture(try Data(contentsOf: copiedOne.url), second))
    }

    @Test func aLateResultNeverReplacesANewerCopy() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let slow = try bench.file("Slow.png", Sample.screenshot(width: 640, height: 400, seed: 32))
        let quick = try bench.file("Quick.png", Sample.screenshot(width: 640, height: 400, seed: 33))
        let optimizer = bench.optimizer
        let copier = OptimizedImageCopy()

        // Something copied in another app while the optimizer was still working.
        do {
            let board = pasteboard()
            defer { board.releaseGlobally() }
            let (started, didStart) = AsyncStream<Void>.makeStream()
            let (release, doRelease) = AsyncStream<Void>.makeStream()
            let late = Task {
                try await copier.copy(slow, to: board, optimize: { url in
                    didStart.yield()
                    for await _ in release { break }
                    return try await optimizer.optimize(url)
                }, item: item)
            }
            for await _ in started { break }
            board.clearContents()
            board.setString("copied elsewhere", forType: .string)
            let count = board.changeCount
            doRelease.yield()
            #expect(try await late.value == nil)
            #expect(board.string(forType: .string) == "copied elsewhere")
            #expect(board.changeCount == count)
        }

        // A second copy from Sukusho that finished first.
        do {
            let board = pasteboard()
            defer { board.releaseGlobally() }
            let (started, didStart) = AsyncStream<Void>.makeStream()
            let (release, doRelease) = AsyncStream<Void>.makeStream()
            let late = Task {
                try await copier.copy(slow, to: board, optimize: { url in
                    didStart.yield()
                    for await _ in release { break }
                    return try await optimizer.optimize(url)
                }, item: item)
            }
            for await _ in started { break }
            let newer = try #require(try await copier.copy(quick, to: board, optimize: { try await optimizer.optimize($0) }, item: item))
            let count = board.changeCount
            doRelease.yield()
            #expect(try await late.value == nil)
            #expect(board.data(forType: .png) == (try Data(contentsOf: newer.url)))
            #expect(board.changeCount == count)
        }
        // The dropped results were deleted; the one that was copied is kept for pasting as a file.
        #expect(bench.leftovers.count == 1)
    }

    @Test func aFailedOptimizationStillCopiesTheOriginalOnce() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Page.png", Sample.screenshot(width: 320, height: 200, seed: 34))
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let noTools = ImageOptimizer(toolsDirectory: bench.folder.appending(path: "nothing-here"), outputDirectory: bench.output)
        let count = board.changeCount
        let result = try #require(try await OptimizedImageCopy().copy(source, to: board, optimize: { try await noTools.optimize($0) }, item: item))
        #expect(result.url == source)
        #expect(board.data(forType: .png) == (try Data(contentsOf: source)))
        #expect(board.changeCount > count)
        #expect(board.pasteboardItems?.count == 1)
    }
}

// MARK: - Sizes

@Suite struct ImageOptimizerSizeTests {
    /// Prints what each route makes of three drawn screenshots, for the round's report; the checks are only
    /// the ones that must always hold.
    @Test func sizesOnSampleScreenshots() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let samples: [(String, CGImage)] = [
            ("light page 1600x1000", Sample.screenshot(width: 1600, height: 1000, seed: 40)),
            ("dark page 1600x1000", Sample.screenshot(width: 1600, height: 1000, seed: 41, dark: true)),
            ("window with shadow 1400x900", Sample.screenshot(width: 1400, height: 900, seed: 42, transparent: true)),
        ]
        for (name, picture) in samples {
            let source = try bench.file("\(name).png", picture)
            let png = try await bench.optimizer.optimize(source)
            let smallest = try await bench.optimizer.optimize(source, effort: .smallest)
            let webP = try await bench.optimizer.optimize(source, to: .webP(quality: nil))
            let lossyWebP = try await bench.optimizer.optimize(source, to: .webP(quality: 80))
            let jpeg = try await bench.optimizer.optimize(source, to: .jpeg(quality: 80))
            let imageIO = try bench.file("\(name)-imageio.jpg", picture, as: .jpeg, quality: 0.8)
            print("SIZES \(name): png \(png.originalByteCount) -> oxipng \(png.resultByteCount) (smallest \(smallest.resultByteCount))"
                + ", webp lossless \(webP.resultByteCount), webp q80 \(lossyWebP.resultByteCount)"
                + ", mozjpeg q80 \(jpeg.resultByteCount) (ImageIO JPEG 0.8: \(size(imageIO)))")
            #expect(png.resultByteCount < png.originalByteCount, "\(name)")
            #expect(smallest.resultByteCount <= png.resultByteCount, "\(name)")
            #expect(webP.resultByteCount < png.originalByteCount, "\(name)")
        }
    }
}
