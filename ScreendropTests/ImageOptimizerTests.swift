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
import zlib

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

private final class OptimizerFixtureBundle: NSObject {}

/// A crop of a real screenshot of the app's Library (Fixtures/capture-library-light.md): mostly neutral,
/// with small colored parts.
private func realCapture() throws -> URL {
    try #require(Bundle(for: OptimizerFixtureBundle.self).url(forResource: "capture-library-light", withExtension: "png"))
}

/// Whether a JPEG's frame header is the progressive one (SOF2).
private func isProgressive(_ url: URL) throws -> Bool {
    let data = try Data(contentsOf: url)
    var offset = 2
    while offset + 4 <= data.count, data[offset] == 0xFF {
        let marker = data[offset + 1]
        if marker == 0xC2 { return true }
        if marker == 0xC0 || marker == 0xC1 || marker == 0xDA { return false }
        offset += marker == 0xFF ? 1 : 2 + (Int(data[offset + 2]) << 8 | Int(data[offset + 3]))
    }
    return false
}

/// Astra's 80-byte file: 64 by 64, 8-bit RGB, a correct PNG container around data that is no image stream.
private func corruptPNG() throws -> Data {
    let hex = "89504e470d0a1a0a0000000d4948445200000040000000400802000000250be689000000174944415"
        + "46e6f742061207a6c696220696d6167652073747265616d7d024fc00000000049454e44ae426082"
    var bytes = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        bytes.append(try #require(UInt8(hex[index..<next], radix: 16)))
        index = next
    }
    try #require(bytes.count == 80)
    return bytes
}

/// A folder of encoders where `tool` is a script that exits cleanly and leaves a copy of `standIn` as its
/// output. The others are the real ones, so a result is read back by the real MozJPEG.
private func standInTools(where tool: String, leaves standIn: URL) throws -> URL {
    let tools = FileManager.default.temporaryDirectory.appending(path: "SukushoStandIn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    for name in try FileManager.default.contentsOfDirectory(atPath: Bench.tools.path) where name != tool {
        try FileManager.default.createSymbolicLink(at: tools.appending(path: name), withDestinationURL: Bench.tools.appending(path: name))
    }
    // The output is what follows --out (oxipng), -outfile (MozJPEG) or the last -o (libwebp).
    let script = """
    #!/bin/sh
    while [ $# -gt 0 ]; do
      case "$1" in --out|-outfile|-o) out="$2";; esac
      shift
    done
    cp "\(standIn.path)" "$out"
    """
    try Data(script.utf8).write(to: tools.appending(path: tool))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tools.appending(path: tool).path)
    return tools
}

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

    /// editor-opus M2: from a million pixels up, ImageIO decodes baseline and progressive JPEGs with different
    /// code, so a baseline capture repacked as progressive never matched and Optimize always failed. The
    /// smaller sample above couldn't show it. Here: a drawn capture and a real one, both over a million pixels.
    @Test func aJPEGOverAMillionPixelsIsRepackedInItsOwnKind() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let real = try image(at: realCapture())
        let enlarged = try #require(CGContext(data: nil, width: 1100, height: 1034, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        enlarged.interpolationQuality = .high
        enlarged.draw(real, in: CGRect(x: 0, y: 0, width: 1100, height: 1034))
        let captures = [("Drawn.jpg", Sample.screenshot(width: 1280, height: 800, seed: 5)), ("Real.jpg", try #require(enlarged.makeImage()))]
        for (name, picture) in captures {
            #expect(picture.width * picture.height > 1_000_000)
            // Baseline, as ImageIO and most cameras and apps write a JPEG.
            let baseline = try bench.file(name, picture, as: .jpeg, quality: 0.8)
            let result = try await bench.optimizer.optimize(baseline)
            #expect(result.outcome == .optimized, "\(name): \(result.outcome)")
            #expect(result.resultByteCount < result.originalByteCount)
            #expect(try pixels(at: result.url) == pixels(at: baseline))
            #expect(try profile(at: result.url) == profile(at: baseline))
            #expect(try !isProgressive(result.url))

            // The same picture as a plain progressive JPEG: it stays progressive, and the same pixels.
            let progressive = bench.folder.appending(path: "progressive/\(name)")
            try FileManager.default.createDirectory(at: progressive.deletingLastPathComponent(), withIntermediateDirectories: true)
            let made = Process()
            made.executableURL = Bench.tools.appending(path: "jpegtran")
            made.arguments = ["-revert", "-progressive", "-copy", "all", "-outfile", progressive.path, baseline.path]
            try made.run()
            made.waitUntilExit()
            try #require(made.terminationStatus == 0)
            #expect(try isProgressive(progressive))
            let again = try await bench.optimizer.optimize(progressive)
            #expect(again.outcome == .optimized, "progressive \(name): \(again.outcome)")
            #expect(try pixels(at: again.url) == pixels(at: progressive))
            #expect(try isProgressive(again.url))
            result.discard()
            again.discard()
        }
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

    /// An image over the pixel budget comes back as it is, for every target, before any encoder runs.
    @Test func anImageOverThePixelBudgetIsLeftAlone() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Page.png", Sample.screenshot(width: 64, height: 40, seed: 31))
        var optimizer = bench.optimizer
        optimizer.pixelBudget = 64 * 40 - 1

        for target in [ImageOptimizationTarget.lossless, .webP(quality: nil), .jpeg(quality: 80)] {
            let result = try await optimizer.optimize(source, to: target)
            guard case .failed(let reason) = result.outcome else {
                Issue.record("\(target): \(result.outcome)")
                continue
            }
            #expect(reason.contains("too large"))
            #expect(result.url == source)
            #expect(bench.leftovers.isEmpty)
        }
        optimizer.pixelBudget = 64 * 40
        #expect(try await optimizer.optimize(source).outcome != .failed("The image is too large to optimize, so the original is used."))

        // The memory its bitmaps would take counts as well: five of them, and twice the bytes for a 16-bit image.
        let tooLarge = ImageOptimizationResult.Outcome.failed("The image is too large to optimize, so the original is used.")
        let deep = try bench.file("Deep.png", Sample.screenshot(width: 64, height: 40, seed: 31, bits: 16))
        optimizer.memoryBudget = 64 * 40 * 4 * 5
        #expect(try await optimizer.optimize(source).outcome != tooLarge)
        #expect(try await optimizer.optimize(deep).outcome == tooLarge)
        optimizer.memoryBudget = 64 * 40 * 8 * 5
        #expect(try await optimizer.optimize(deep).outcome != tooLarge)
        optimizer.memoryBudget = 64 * 40 * 4 * 5 - 1
        #expect(try await optimizer.optimize(source).outcome == tooLarge)
    }

    /// Astra OR3: an encoder that exits cleanly with another picture of the same size, or with a file ImageIO
    /// calls complete that decodes to nothing, must not count as optimized or converted.
    @Test func aResultThatIsNotTheSourcesPictureIsRefused() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Noise.png", Sample.noise(width: 64, height: 64))
        let before = try Data(contentsOf: source)

        let red = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        red.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        red.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let different = try bench.file("standins/different.png", try #require(red.makeImage()))
        #expect(size(different) < before.count)   // smaller, so only the picture check can stop it
        let bad = bench.folder.appending(path: "standins/bad.png")
        try corruptPNG().write(to: bad)

        for (standIn, tool, target) in [
            (different, "oxipng", ImageOptimizationTarget.lossless),
            (bad, "oxipng", .lossless),
            (bad, "cjpeg", .jpeg(quality: 80)),
        ] {
            let tools = try standInTools(where: tool, leaves: standIn)
            defer { try? FileManager.default.removeItem(at: tools) }
            let result = try await ImageOptimizer(toolsDirectory: tools, outputDirectory: bench.output).optimize(source, to: target)
            guard case .failed = result.outcome else {
                Issue.record("\(standIn.lastPathComponent) from \(tool): \(result.outcome)")
                continue
            }
            #expect(result.url == source)
            #expect(try Data(contentsOf: source) == before)
            #expect(bench.leftovers.isEmpty, "\(standIn.lastPathComponent): \(bench.leftovers)")
        }
    }

    /// Astra's second review: ImageIO hands back pixels for a damaged file, zeros where its decoder gave up,
    /// and a transparent source is all zeros too. A result has to be a whole file before its pixels count.
    @Test func aDamagedResultIsRefusedEvenWhenItsPixelsMatch() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let clear = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let transparent = try bench.file("Clear.png", try #require(clear.makeImage()))
        let whole = try Data(contentsOf: transparent)
        #expect(ImageOptimizer.pngIsIntact(whole))

        // Astra's file: a correct container around data that is no image stream.
        let bad = bench.folder.appending(path: "standins/bad.png")
        try FileManager.default.createDirectory(at: bad.deletingLastPathComponent(), withIntermediateDirectories: true)
        try corruptPNG().write(to: bad)
        #expect(!ImageOptimizer.pngIsIntact(try Data(contentsOf: bad)))

        // The source's own PNG with one byte of its image data changed: first with the chunk's checksum left
        // wrong, then with the checksum put right, so only inflating the data can tell.
        let idat = try #require(whole.range(of: Data("IDAT".utf8)))
        let length = Int(whole[idat.lowerBound - 4]) << 24 | Int(whole[idat.lowerBound - 3]) << 16
            | Int(whole[idat.lowerBound - 2]) << 8 | Int(whole[idat.lowerBound - 1])
        var flipped = whole
        flipped[idat.upperBound + length / 2] ^= 0x5A
        let checksumWrong = bench.folder.appending(path: "standins/checksum.png")
        try flipped.write(to: checksumWrong)
        let checksum = flipped[idat.lowerBound..<(idat.upperBound + length)].withUnsafeBytes {
            UInt32(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count)))
        }
        for (index, shift) in [24, 16, 8, 0].enumerated() {
            flipped[idat.upperBound + length + index] = UInt8(truncatingIfNeeded: checksum >> UInt32(shift))
        }
        let streamWrong = bench.folder.appending(path: "standins/stream.png")
        try flipped.write(to: streamWrong)
        #expect(!ImageOptimizer.pngIsIntact(try Data(contentsOf: checksumWrong)))
        #expect(!ImageOptimizer.pngIsIntact(flipped))

        for standIn in [bad, checksumWrong, streamWrong] {
            let tools = try standInTools(where: "oxipng", leaves: standIn)
            defer { try? FileManager.default.removeItem(at: tools) }
            let result = try await ImageOptimizer(toolsDirectory: tools, outputDirectory: bench.output).optimize(transparent)
            guard case .failed(let reason) = result.outcome else {
                Issue.record("\(standIn.lastPathComponent): \(result.outcome)")
                continue
            }
            #expect(reason.contains("didn't come out right"), "\(standIn.lastPathComponent): \(reason)")
            #expect(result.url == transparent)
            #expect(try Data(contentsOf: transparent) == whole)
            #expect(bench.leftovers.isEmpty)
        }

        // A JPEG and a WebP cut short, as a full disk leaves them. The real MozJPEG reads the JPEG back.
        let page = try bench.file("Page.png", Sample.screenshot(width: 320, height: 200, seed: 41))
        for (tool, target) in [("cjpeg", ImageOptimizationTarget.jpeg(quality: 80)), ("cwebp", .webP(quality: 80)), ("cwebp", .webP(quality: nil))] {
            let made = try await bench.optimizer.optimize(page, to: target)
            #expect(made.outcome == .converted)
            let cut = bench.folder.appending(path: "standins/cut.\(made.url.pathExtension)")
            try Data(contentsOf: made.url).prefix(Int(made.resultByteCount) * 2 / 3).write(to: cut)
            made.discard()
            let tools = try standInTools(where: tool, leaves: cut)
            defer { try? FileManager.default.removeItem(at: tools) }
            let result = try await ImageOptimizer(toolsDirectory: tools, outputDirectory: bench.output).optimize(page, to: target)
            guard case .failed = result.outcome else {
                Issue.record("cut \(target): \(result.outcome)")
                continue
            }
            #expect(result.url == page)
            #expect(bench.leftovers.isEmpty)
        }
    }

    /// Astra's second review: a lossy result is judged block by block. A picture with a part gone or blank is
    /// refused, however small the part, and so is lost transparency; a real low-quality result passes.
    @Test func aLossyResultMustKeepEveryPartOfThePicture() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        /// `image` again, on white when `opaque`, with whatever `change` draws over it.
        func drawn(_ image: CGImage, opaque: Bool = false, _ change: (CGContext) -> Void = { _ in }) throws -> CGImage {
            let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
            let space = try #require(image.colorSpace)
            let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: space, bitmapInfo: alpha.rawValue))
            let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            if opaque {
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(frame)
            }
            context.draw(image, in: frame)
            change(context)
            return try #require(context.makeImage())
        }
        /// What the real encoder makes of `image`, kept to stand in for another picture's result.
        func encoded(_ image: CGImage, _ name: String, _ target: ImageOptimizationTarget) async throws -> URL {
            let result = try await bench.optimizer.optimize(try bench.file("made/\(name).png", image), to: target)
            try #require(result.outcome == .converted)
            let kept = bench.folder.appending(path: "standins/\(name).\(result.url.pathExtension)")
            try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: kept)
            try FileManager.default.copyItem(at: result.url, to: kept)
            result.discard()
            return kept
        }
        func refused(_ source: URL, _ target: ImageOptimizationTarget, standIn: URL, _ what: String) async throws {
            var tool = "cwebp"
            if case .jpeg = target { tool = "cjpeg" }
            let tools = try standInTools(where: tool, leaves: standIn)
            defer { try? FileManager.default.removeItem(at: tools) }
            let result = try await ImageOptimizer(toolsDirectory: tools, outputDirectory: bench.output).optimize(source, to: target)
            guard case .failed(let reason) = result.outcome else {
                Issue.record("\(what) as \(target): \(result.outcome)")
                result.discard()
                return
            }
            // Refused for what it shows: each stand-in is a whole file that the real MozJPEG reads back.
            #expect(reason.contains("whole picture"), "\(what) as \(target): \(reason)")
            #expect(result.url == source)
            #expect(bench.leftovers.isEmpty, "\(what): \(bench.leftovers)")
        }

        // Real results pass at 50 and at 10, the lowest quality the app offers: light, dark and with transparency.
        let page = Sample.screenshot(width: 1280, height: 800, seed: 51)
        let clear = Sample.screenshot(width: 640, height: 400, seed: 53, transparent: true)
        let pageFile = try bench.file("Page.png", page), clearFile = try bench.file("Clear.png", clear)
        let darkFile = try bench.file("Dark.png", Sample.screenshot(width: 640, height: 400, seed: 52, dark: true))
        // Noise is what a lossy encoder keeps least of, and quality 30 is where the finer rule starts.
        let noiseFile = try bench.file("Noise.png", Sample.noise(width: 256, height: 256))
        for file in [pageFile, darkFile, clearFile, noiseFile] {
            for target in [ImageOptimizationTarget.jpeg(quality: 10), .jpeg(quality: 30), .jpeg(quality: 50), .webP(quality: 10), .webP(quality: 50)] {
                let result = try await bench.optimizer.optimize(file, to: target)
                #expect(result.outcome == .converted, "\(file.lastPathComponent) as \(target): \(result.outcome)")
                result.discard()
            }
        }

        // Astra's case: a black bar on white, and a result that is only white.
        let bar = try drawn(Sample.noise(width: 64, height: 64), opaque: true) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 16, y: 28, width: 32, height: 8))
        }
        let white = try drawn(bar) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let barFile = try bench.file("Bar.png", bar)
        for target in [ImageOptimizationTarget.jpeg(quality: 80), .webP(quality: 80)] {
            try await refused(barFile, target, standIn: try await encoded(white, "white", target), "a blank result")
        }

        // Sparse content: the same page with one line of its text painted over, then with one word.
        let paper = CGColor(colorSpace: try #require(page.colorSpace), components: [0.97, 0.97, 0.98, 1])!
        for (what, gone) in [("a line gone", CGRect(x: 300, y: 590, width: 980, height: 16)), ("a word gone", CGRect(x: 300, y: 510, width: 64, height: 16))] {
            let erased = try drawn(page) { context in
                context.setFillColor(paper)
                context.fill(gone)
            }
            let erasedFile = try bench.file("made/erased.png", erased)
            #expect(try pixels(at: erasedFile) != pixels(at: pageFile))   // there was text there
            for target in [ImageOptimizationTarget.jpeg(quality: 50), .webP(quality: 50)] {
                try await refused(pageFile, target, standIn: try await encoded(erased, "erased", target), what)
            }
        }

        // Transparency: a WebP of the picture on white is not the picture.
        try await refused(clearFile, .webP(quality: 80), standIn: try await encoded(try drawn(clear, opaque: true), "opaque", .webP(quality: 80)),
                          "transparency gone")
    }

    /// editor-opus M1: a result that has lost its color, on a real capture that is mostly neutral with small
    /// colored parts. Its brightness and patterns are all there, so only a check of color can refuse it.
    @Test func aResultThatLostItsColorIsRefused() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let capture = bench.folder.appending(path: "Library.png")
        try FileManager.default.copyItem(at: try realCapture(), to: capture)

        // Real results of it keep their color well enough at every quality offered.
        for quality in [10, 30, 50, 80] {
            for target in [ImageOptimizationTarget.jpeg(quality: quality), .webP(quality: quality)] {
                let result = try await bench.optimizer.optimize(capture, to: target)
                #expect(result.outcome == .converted, "\(target): \(result.outcome)")
                result.discard()
            }
        }

        // editor-opus's stand-in: the real MozJPEG, told to write a grayscale file.
        let tools = try standInTools(where: "cjpeg", leaves: capture)
        defer { try? FileManager.default.removeItem(at: tools) }
        try FileManager.default.createSymbolicLink(at: tools.appending(path: "real-cjpeg"), withDestinationURL: Bench.tools.appending(path: "cjpeg"))
        try Data("#!/bin/sh\nexec \"$(dirname \"$0\")/real-cjpeg\" -grayscale \"$@\"\n".utf8).write(to: tools.appending(path: "cjpeg"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tools.appending(path: "cjpeg").path)
        for quality in [80, 30] {
            let gray = try await ImageOptimizer(toolsDirectory: tools, outputDirectory: bench.output).optimize(capture, to: .jpeg(quality: quality))
            guard case .failed(let reason) = gray.outcome else {
                Issue.record("a grayscale JPEG at \(quality): \(gray.outcome)")
                gray.discard()
                continue
            }
            #expect(reason.contains("whole picture"), "\(reason)")
            #expect(bench.leftovers.isEmpty)
        }

        // The same for WebP: the real encoder's result for the capture with every pixel turned to its gray.
        let picture = try image(at: capture)
        let context = try #require(CGContext(data: nil, width: picture.width, height: picture.height, bitsPerComponent: 8,
                                             bytesPerRow: picture.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(picture, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for at in stride(from: 0, to: picture.width * picture.height * 4, by: 4) {
            let gray = UInt8((77 * Int(bytes[at]) + 150 * Int(bytes[at + 1]) + 29 * Int(bytes[at + 2])) >> 8)
            bytes[at] = gray
            bytes[at + 1] = gray
            bytes[at + 2] = gray
        }
        let grayFile = try bench.file("made/Gray.png", try #require(context.makeImage()))
        let made = try await bench.optimizer.optimize(grayFile, to: .webP(quality: 80))
        try #require(made.outcome == .converted)
        let standIn = bench.folder.appending(path: "standins/gray.webp")
        try FileManager.default.createDirectory(at: standIn.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: made.url, to: standIn)
        made.discard()
        let webPTools = try standInTools(where: "cwebp", leaves: standIn)
        defer { try? FileManager.default.removeItem(at: webPTools) }
        let grayWebP = try await ImageOptimizer(toolsDirectory: webPTools, outputDirectory: bench.output).optimize(capture, to: .webP(quality: 80))
        guard case .failed(let reason) = grayWebP.outcome else {
            Issue.record("a grayscale WebP: \(grayWebP.outcome)")
            return
        }
        #expect(reason.contains("whole picture"), "\(reason)")
        #expect(bench.leftovers.isEmpty)
    }

    /// Astra's second review: what a result was made from is the file's contents, not its size and date,
    /// and a file rewritten while the encoder runs gives no result at all.
    @Test func aResultNamesTheContentsItWasMadeFrom() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Page.png", Sample.screenshot(width: 320, height: 200, seed: 61))
        let before = try #require(FileIdentity(source))
        let result = try await bench.optimizer.optimize(source)
        #expect(result.outcome == .optimized)
        #expect(result.source == before)
        #expect(result.output == FileIdentity(result.url))   // round 3: what the encoder made, as it made it
        // Nothing smaller, and a failure, name what was read as well: the Library marks a file on the first.
        let again = try await bench.optimizer.optimize(result.url)
        #expect(again.outcome == .alreadyOptimized)
        #expect(again.source == FileIdentity(result.url))
        #expect(again.output == nil)   // nothing was made: the result is the file read
        let noTools = ImageOptimizer(toolsDirectory: bench.folder.appending(path: "none"), outputDirectory: bench.output)
        let failed = try await noTools.optimize(source)
        guard case .failed = failed.outcome else {
            Issue.record("no encoders: \(failed.outcome)")
            return
        }
        #expect(failed.source == before)

        // One byte changed, the length and the date kept: no longer the contents the result names.
        var bytes = try Data(contentsOf: source)
        bytes[bytes.count - 20] ^= 1
        try rewriteKeepingSizeAndDate(source, with: bytes)
        #expect(FileIdentity(source) != result.source)
        result.discard()

        // An encoder run during which the source is rewritten: here with other bytes of the same picture
        // (what the real encoder made of it) and the old date, so the pixels still match the result.
        let other = try bench.file("Other.png", Sample.screenshot(width: 320, height: 200, seed: 62))
        let smaller = try await bench.optimizer.optimize(other)
        try #require(smaller.outcome == .optimized)
        let kept = bench.folder.appending(path: "standins/smaller.png")
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: smaller.url, to: kept)
        smaller.discard()
        let tools = FileManager.default.temporaryDirectory.appending(path: "SukushoRewrites-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tools) }
        let script = """
        #!/bin/sh
        for source; do :; done
        while [ $# -gt 0 ]; do
          if [ "$1" = "--out" ]; then out="$2"; fi
          shift
        done
        touch -r "$source" "$out.date"
        cp "\(kept.path)" "$source"
        touch -r "$out.date" "$source"
        rm "$out.date"
        cp "\(kept.path)" "$out"
        """
        try Data(script.utf8).write(to: tools.appending(path: "oxipng"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tools.appending(path: "oxipng").path)
        let read = try #require(FileIdentity(other))
        let late = try await ImageOptimizer(toolsDirectory: tools, outputDirectory: bench.output).optimize(other)
        guard case .failed(let reason) = late.outcome else {
            Issue.record("a source rewritten under the encoder: \(late.outcome)")
            return
        }
        #expect(reason.contains("changed"))
        #expect(late.url == other)
        #expect(late.source == read)
        #expect(FileIdentity(other) == FileIdentity(kept))   // the rewrite did happen
        #expect(bench.leftovers.isEmpty)
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

        // A file Sukusho isn't allowed to open, as macOS makes one in a folder the person said no for: it says
        // so, for every target, and comes back as it is.
        let refused = try bench.file("Refused.png", Sample.screenshot(width: 64, height: 40, seed: 24))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: refused.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: refused.path) }
        for target in [ImageOptimizationTarget.lossless, .webP(quality: 80), .jpeg(quality: 80)] {
            let result = try await bench.optimizer.optimize(refused, to: target)
            #expect(result.outcome == .failed(ImageOptimizer.unreadableReason), "\(target)")
            #expect(result.url == refused)
        }

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

    /// Astra OR6: an encoder that ignores the request to stop. It is killed after a short grace, so neither a
    /// time limit nor a cancel waits on it, and its working files go.
    @Test func anEncoderThatIgnoresStopIsKilled() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Page.png", Sample.screenshot(width: 64, height: 40, seed: 25))
        let tools = FileManager.default.temporaryDirectory.appending(path: "SukushoStubborn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tools) }
        // Ignores SIGTERM and never finishes by itself. No child process, so nothing can outlive it.
        try Data("#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n".utf8).write(to: tools.appending(path: "oxipng"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tools.appending(path: "oxipng").path)
        let optimizer = ImageOptimizer(toolsDirectory: tools, outputDirectory: bench.output)
        let clock = ContinuousClock()

        var asked = clock.now
        let limited = try await optimizer.optimize(source, timeLimit: .milliseconds(100))
        #expect(limited.outcome == .timedOut)
        #expect(limited.url == source)
        #expect(clock.now - asked < .seconds(2))
        #expect(!isRunning(tools.lastPathComponent))
        #expect(bench.leftovers.isEmpty)

        let task = Task { try await optimizer.optimize(source) }
        var sawEncoder = false
        for _ in 0..<100 where !sawEncoder {
            try await Task.sleep(for: .milliseconds(50))
            sawEncoder = isRunning(tools.lastPathComponent)
        }
        #expect(sawEncoder)
        asked = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.now - asked < .seconds(2))
        #expect(!isRunning(tools.lastPathComponent))
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

    /// A swap of an optimized result, naming what the optimizer read, as the copy route makes it.
    private func swapIn(_ result: ImageOptimizationResult) -> OptimizedImageCopy.Swap? {
        (try? item(result.url)).map { .init(item: $0, source: result.source?.digest, output: result.output?.digest) }
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

    /// Astra's second review: several files copied at once follow the rule one file does.
    @Test func aLateBatchNeverReplacesANewerCopy() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let first = try bench.file("First.png", Sample.screenshot(width: 640, height: 400, seed: 35))
        let second = try bench.file("Second.png", Sample.screenshot(width: 640, height: 400, seed: 36))
        let quick = try bench.file("Quick.png", Sample.screenshot(width: 320, height: 200, seed: 37))
        let optimizer = bench.optimizer
        let copier = OptimizedImageCopy()
        func write(to board: NSPasteboard) -> ([URL]) throws -> Void {
            { urls in
                board.clearContents()
                guard board.writeObjects(urls.map { $0 as NSURL }) else { throw CocoaError(.fileWriteUnknown) }
            }
        }
        func files(on board: NSPasteboard) -> [String] {
            ((board.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []).map(\.lastPathComponent)
        }

        // In time: both files, optimized, in one write.
        do {
            let board = pasteboard()
            defer { board.releaseGlobally() }
            let count = board.changeCount
            let copied = try #require(try await copier.copyAll([first, second], to: board, ready: { try await optimizer.optimize($0) },
                                                               write: write(to: board)))
            #expect(copied.map(\.outcome) == [.optimized, .optimized])
            #expect(files(on: board) == ["First.png", "Second.png"])
            #expect(board.changeCount == count + 1)
            copied.forEach { $0.discard() }
        }

        // Something copied in another app while the second file was still being optimized.
        do {
            let board = pasteboard()
            defer { board.releaseGlobally() }
            let (started, didStart) = AsyncStream<Void>.makeStream()
            let (release, doRelease) = AsyncStream<Void>.makeStream()
            let late = Task {
                try await copier.copyAll([first, second], to: board, ready: { url in
                    if url == second {
                        didStart.yield()
                        for await _ in release { break }
                    }
                    return try await optimizer.optimize(url)
                }, write: write(to: board))
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

        // A single copy from Sukusho that finished first.
        do {
            let board = pasteboard()
            defer { board.releaseGlobally() }
            let (started, didStart) = AsyncStream<Void>.makeStream()
            let (release, doRelease) = AsyncStream<Void>.makeStream()
            let late = Task {
                try await copier.copyAll([first, second], to: board, ready: { url in
                    if url == second {
                        didStart.yield()
                        for await _ in release { break }
                    }
                    return try await optimizer.optimize(url)
                }, write: write(to: board))
            }
            for await _ in started { break }
            let newer = try #require(try await copier.copy(quick, to: board, optimize: { try await optimizer.optimize($0) }, item: item))
            let count = board.changeCount
            doRelease.yield()
            #expect(try await late.value == nil)
            #expect(board.data(forType: .png) == (try Data(contentsOf: newer.url)))
            #expect(board.changeCount == count)
        }
        // Every dropped result was deleted; only the single copy's is kept.
        #expect(bench.leftovers.count == 1)
    }

    /// The copy right after a capture (the owner's choice): the original at once, and the optimized copy in
    /// its place when it is ready.
    @Test func theCopyAfterACaptureIsSwappedForItsOptimizedCopy() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Capture.png", Sample.screenshot(width: 640, height: 400, seed: 38))
        let optimizer = bench.optimizer
        let copier = OptimizedImageCopy()
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let count = board.changeCount
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (release, doRelease) = AsyncStream<Void>.makeStream()
        let original = try item(source)
        let swap = Task {
            try await copier.copyThenSwap(to: board, first: { original }) {
                didStart.yield()
                for await _ in release { break }
                guard let result = try? await optimizer.optimize(source), result.outcome == .optimized else { return nil }
                defer { result.discard() }
                return swapIn(result)
            }
        }
        for await _ in started { break }
        // The original is there before the optimizer has done anything: a paste now gets it, with no wait.
        #expect(board.data(forType: .png) == (try Data(contentsOf: source)))
        #expect(board.changeCount == count + 1)

        doRelease.yield()
        #expect(try await swap.value)
        let swapped = try #require(board.data(forType: .png))
        #expect(swapped.count < size(source))
        let pasted = bench.folder.appending(path: "pasted.png")
        try swapped.write(to: pasted)
        #expect(try pixels(at: pasted) == pixels(at: source))
        #expect(board.changeCount == count + 2)
        #expect(board.pasteboardItems?.count == 1)
        #expect(bench.leftovers.isEmpty)
    }

    /// The swap never replaces anything but the write it follows, and a failed optimizer leaves that write alone.
    @Test func theCopyAfterACaptureStaysWhenItCannotOrMustNotBeSwapped() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Capture.png", Sample.screenshot(width: 640, height: 400, seed: 39))
        let quick = try bench.file("Quick.png", Sample.screenshot(width: 320, height: 200, seed: 40))
        let optimizer = bench.optimizer
        let copier = OptimizedImageCopy()
        /// A swap whose optimized copy is ready only once `meanwhile` has run.
        func swap(on board: NSPasteboard, meanwhile: () async throws -> Void) async throws -> Bool {
            let (started, didStart) = AsyncStream<Void>.makeStream()
            let (release, doRelease) = AsyncStream<Void>.makeStream()
            let original = try item(source)
            let late = Task {
                try await copier.copyThenSwap(to: board, first: { original }) {
                    didStart.yield()
                    for await _ in release { break }
                    guard let result = try? await optimizer.optimize(source), result.outcome == .optimized else { return nil }
                    defer { result.discard() }
                    return swapIn(result)
                }
            }
            for await _ in started { break }
            try await meanwhile()
            doRelease.yield()
            return try await late.value
        }

        // Something copied in another app while the optimizer was working.
        do {
            let board = pasteboard()
            defer { board.releaseGlobally() }
            var count = 0
            let swapped = try await swap(on: board) {
                board.clearContents()
                board.setString("copied elsewhere", forType: .string)
                count = board.changeCount
            }
            #expect(!swapped)
            #expect(board.string(forType: .string) == "copied elsewhere")
            #expect(board.changeCount == count)
        }

        // A copy made in Sukusho meanwhile.
        do {
            let board = pasteboard()
            defer { board.releaseGlobally() }
            var newer: ImageOptimizationResult?
            var count = 0
            let swapped = try await swap(on: board) {
                newer = try await copier.copy(quick, to: board, optimize: { try await optimizer.optimize($0) }, item: item)
                count = board.changeCount
            }
            #expect(!swapped)
            #expect(board.data(forType: .png) == (try Data(contentsOf: try #require(newer).url)))
            #expect(board.changeCount == count)
            newer?.discard()
        }

        // The optimizer fails: the original stays, written once.
        do {
            let board = pasteboard()
            defer { board.releaseGlobally() }
            let count = board.changeCount
            let noTools = ImageOptimizer(toolsDirectory: bench.folder.appending(path: "nothing-here"), outputDirectory: bench.output)
            let original = try item(source)
            let swapped = try await copier.copyThenSwap(to: board, first: { original }) {
                guard let result = try? await noTools.optimize(source), result.outcome == .optimized else { return nil }
                return swapIn(result)
            }
            #expect(!swapped)
            #expect(board.data(forType: .png) == (try Data(contentsOf: source)))
            #expect(board.changeCount == count + 1)
        }
        #expect(bench.leftovers.isEmpty)
    }

    /// Sol OS3-1: reading the original takes time too. A copy made while it is being read is newer than the
    /// capture's, and the capture's first write must not land on it.
    @Test func theCopyAfterACaptureNeverWritesOverACopyMadeWhileItWasBeingRead() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Capture.png", Sample.screenshot(width: 320, height: 200, seed: 42))
        let quick = try bench.file("Quick.png", Sample.screenshot(width: 320, height: 200, seed: 43))
        let optimizer = bench.optimizer
        let copier = OptimizedImageCopy()
        final class Calls { var smaller = 0 }
        let calls = Calls()
        /// A copy after a capture whose original is read only once `meanwhile` has run.
        func copy(on board: NSPasteboard, meanwhile: () async throws -> Void) async throws -> Bool {
            let (started, didStart) = AsyncStream<Void>.makeStream()
            let (release, doRelease) = AsyncStream<Void>.makeStream()
            let original = try item(source)
            let late = Task {
                try await copier.copyThenSwap(to: board, first: {
                    didStart.yield()
                    for await _ in release { break }
                    return original
                }, smaller: {
                    calls.smaller += 1
                    return nil
                })
            }
            for await _ in started { break }
            try await meanwhile()
            doRelease.yield()
            return try await late.value
        }

        // Copied in another app while the capture's original was being read.
        do {
            let board = pasteboard()
            defer { board.releaseGlobally() }
            var count = 0
            let swapped = try await copy(on: board) {
                board.clearContents()
                board.setString("copied elsewhere", forType: .string)
                count = board.changeCount
            }
            #expect(!swapped)
            #expect(board.string(forType: .string) == "copied elsewhere")
            #expect(board.changeCount == count)
        }

        // Copied in Sukusho meanwhile.
        do {
            let board = pasteboard()
            defer { board.releaseGlobally() }
            var newer: ImageOptimizationResult?
            var count = 0
            let swapped = try await copy(on: board) {
                newer = try await copier.copy(quick, to: board, optimize: { try await optimizer.optimize($0) }, item: item)
                count = board.changeCount
            }
            #expect(!swapped)
            #expect(board.data(forType: .png) == (try Data(contentsOf: try #require(newer).url)))
            #expect(board.changeCount == count)
            newer?.discard()
        }
        // Overtaken before its first write, the copy asks for no smaller file either.
        #expect(calls.smaller == 0)

        // Nothing copied meanwhile: the original is written as before.
        do {
            let board = pasteboard()
            defer { board.releaseGlobally() }
            let count = board.changeCount
            let swapped = try await copy(on: board) {}
            #expect(!swapped)
            #expect(board.data(forType: .png) == (try Data(contentsOf: source)))
            #expect(board.changeCount == count + 1)
            #expect(calls.smaller == 1)
        }
        #expect(bench.leftovers.isEmpty)
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

    /// Beta 4, the owner pressing ⌘C again because nothing seemed to happen: the second copy of the same file
    /// writes nothing and doesn't start the optimizer again, while the first one's swap still lands.
    @Test func aSecondCopyOfTheSameFileWritesNothingAndStartsNoSecondOptimization() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Edited.png", Sample.screenshot(width: 640, height: 400, seed: 44))
        let optimizer = bench.optimizer
        let copier = OptimizedImageCopy()
        let board = pasteboard()
        defer { board.releaseGlobally() }
        final class Calls { var smaller = 0 }
        let calls = Calls()
        let (release, doRelease) = AsyncStream<Void>.makeStream()
        var made: ImageOptimizationResult?
        func copy() async throws -> (OptimizedImageCopy.InstantCopy, Task<Bool, Never>?) {
            try await copier.copyNow(to: board, first: { .init(item: try item(source), key: "Edited.png, first save") }) {
                calls.smaller += 1
                for await _ in release { break }
                guard let result = try? await optimizer.optimize(source), result.outcome == .optimized else { return nil }
                made = result
                return swapIn(result)
            }
        }
        let count = board.changeCount
        let (first, swap) = try await copy()
        #expect(first == .written)
        // On the pasteboard when the copy returns, before the optimizer has done anything: a paste gets it now.
        #expect(board.data(forType: .png) == (try Data(contentsOf: source)))
        #expect(board.changeCount == count + 1)

        let (second, noSwap) = try await copy()
        #expect(second == .alreadyThere)
        #expect(noSwap == nil)
        #expect(board.changeCount == count + 1)

        doRelease.yield()
        let swapTask = try #require(swap)
        #expect(await swapTask.value)
        #expect(board.changeCount == count + 2)
        #expect(calls.smaller == 1)
        let optimized = try #require(made)
        #expect(board.data(forType: .png) == (try Data(contentsOf: optimized.url)))

        // Again after the swap: the optimized copy stays as it is.
        #expect(try await copy().0 == .alreadyThere)
        #expect(board.changeCount == count + 2)
        // The file saved again is another copy.
        let (changed, changedSwap) = try await copier.copyNow(to: board,
                                                              first: { .init(item: try item(source), key: "Edited.png, second save") }, smaller: { nil })
        #expect(changed == .written)
        #expect(await changedSwap?.value == false)
        #expect(board.changeCount == count + 3)
        optimized.discard()
        #expect(bench.leftovers.isEmpty)
    }

    /// Sol, round 2: history doesn't wait for the monitor's poll. The copy is filed when it is written (`record`,
    /// as `recordOwnCopy` does it) and its optimized image goes on that card (`stack`), so a swap that comes before
    /// any poll still leaves one card. A poll after it finds nothing to file: the original is Sukusho's own
    /// write, the swap auto-generated.
    @Test func aCopyIsFiledWhenWrittenAndItsSwapGoesOnThatCardWithoutAPoll() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Shot.png", Sample.screenshot(width: 640, height: 400, seed: 45))
        let optimizer = bench.optimizer
        let copier = OptimizedImageCopy()
        let store = try ClipboardHistoryStore(directory: bench.folder.appending(path: "Clipboard"), deviceID: "test-mac")
        let board = pasteboard()
        defer { board.releaseGlobally() }
        func poll() -> ClipboardPasteboardReader.Outcome {
            ClipboardPasteboardReader.read(board, changeCount: board.changeCount, frontmostBundleID: nil, ignoredApps: [],
                                           historyDirectory: bench.folder).outcome
        }
        let originalData = try Data(contentsOf: source)
        let (release, doRelease) = AsyncStream<Void>.makeStream()
        var optimizedData: Data?
        let (outcome, swap) = try await copier.copyNow(to: board, first: {
            let original = try item(source)
            original.setData(Data(), forType: .init(ClipboardCapturePolicy.ownType))
            return .init(item: original, key: UUID())
        }, record: { written in
            guard let capture = ClipboardPasteboardReader.ownCopy([written], ignoredApps: [], historyDirectory: bench.folder),
                  case .inserted(let id)? = try? await store.record(capture, ownCopy: true) else { return nil }
            return id
        }, smaller: {
            for await _ in release { break }
            guard let result = try? await optimizer.optimize(source), result.outcome == .optimized else { return nil }
            defer { result.discard() }
            let smaller = swapIn(result)
            smaller?.item.setData(Data(), forType: .init(ClipboardWriter.autoGeneratedType))
            optimizedData = smaller?.item.data(forType: .png)
            return smaller
        }, stack: { card, swapped in
            guard let data = swapped.data(forType: .png) else {
                Issue.record("the swap has no image")
                return
            }
            var capture = ClipboardCapture(kind: .image, hash: ClipboardPasteboardReader.digest(data))
            capture.image = data
            capture.imageExtension = "png"
            capture.byteSize = data.count
            let stacked = (try? await store.stack(capture, on: card)) ?? false
            #expect(stacked)
        })
        #expect(outcome == .written)
        // A poll now leaves the original to `record`, which already filed it.
        #expect(poll() == .skipped(.ownWrite))
        doRelease.yield()
        #expect(await swap?.value == true)
        #expect(poll() == .skipped(.privateType(ClipboardWriter.autoGeneratedType)))

        let cards = try await store.entries()
        #expect(cards.count == 1)
        let optimized = try #require(optimizedData)
        #expect(cards.first?.hash == ClipboardPasteboardReader.digest(optimized))
        #expect(cards.first?.earlierVersions.map(\.hash) == [ClipboardPasteboardReader.digest(originalData)])
        #expect(bench.leftovers.isEmpty)
    }

    /// Astra, round 3: an image copy is a copy of the bytes its item carries and of the file that item names. Two
    /// files with the same bytes are two copies (a file paste gets the file named), and a file with other bytes is
    /// another copy; the same file with the same bytes is a repeat.
    @Test func anImageCopyIsKeyedOnTheBytesItCarriesAndTheFileItNames() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let a = try Data(contentsOf: try bench.file("A.png", Sample.screenshot(width: 320, height: 200, seed: 50)))
        let b = try Data(contentsOf: try bench.file("B.png", Sample.screenshot(width: 320, height: 200, seed: 51)))
        func item(_ bytes: Data, file: String) -> NSPasteboardItem {
            let item = NSPasteboardItem()
            item.setData(bytes, forType: .png)
            item.setString("file:///Captures/\(file)", forType: .fileURL)
            return item
        }
        let first = await OptimizedImageCopy.key(of: item(a, file: "One.png"))
        #expect(await OptimizedImageCopy.key(of: item(a, file: "One.png")) == first)
        #expect(await OptimizedImageCopy.key(of: item(a, file: "Two.png")) != first)
        #expect(await OptimizedImageCopy.key(of: item(b, file: "One.png")) != first)
    }

    /// Astra, rounds 3 and 4: with A on the pasteboard and its swap still coming, a copy of B starts, one image
    /// (`copyNow`) or a Library selection of several (`copyAll`), and is held while it reads. Copied again before B
    /// writes, A is the newest copy: B gives way, and A's swap still goes in, whether it is ready after B gave way or
    /// while B is still reading. Not copied again, B is the newest: A's swap, ready while B reads, waits for it rather
    /// than land under it, and B's write ends the swap.
    @Test(arguments: [false, true]) func aRepeatOfTheHeldCopyKeepsItsSwapAndANewerCopyStillWrites(batch: Bool) async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let a = try bench.file("A.png", Sample.screenshot(width: 640, height: 400, seed: 48))
        let b = try bench.file("B.png", Sample.screenshot(width: 640, height: 400, seed: 49))
        let c = try bench.file("C.png", Sample.screenshot(width: 320, height: 200, seed: 54))
        let optimizedA = try await bench.optimizer.optimize(a)
        defer { optimizedA.discard() }
        #expect(optimizedA.outcome == .optimized)
        let originalA = try Data(contentsOf: a), smallerA = try Data(contentsOf: optimizedA.url), copiedB = try Data(contentsOf: b)

        enum Order { case bGivesWayFirst, swapReadyFirst, noRepeat }
        for order in [Order.bGivesWayFirst, .swapReadyFirst, .noRepeat] {
            let copier = OptimizedImageCopy()
            let board = pasteboard()
            defer { board.releaseGlobally() }
            /// Whether the pasteboard comes to hold `bytes` within two seconds.
            func lands(_ bytes: Data) async -> Bool {
                for _ in 0..<100 {
                    if board.data(forType: .png) == bytes { return true }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return false
            }
            let (releaseSwap, doReleaseSwap) = AsyncStream<Void>.makeStream()
            let (first, swapA) = try await copier.copyNow(to: board, first: { .init(item: try item(a), key: "A") }) {
                for await _ in releaseSwap { break }
                return swapIn(optimizedA)
            }
            #expect(first == .written)
            let swapTask = try #require(swapA)

            let (bReading, didStartB) = AsyncStream<Void>.makeStream()
            let (releaseB, doReleaseB) = AsyncStream<Void>.makeStream()
            // Whether B wrote.
            let copyB = Task { () throws -> Bool in
                if batch {
                    return try await copier.copyAll([b, c], to: board, ready: { url in
                        if url == b {
                            didStartB.yield()
                            for await _ in releaseB { break }
                        }
                        return .original(url)
                    }, write: { _ in
                        board.clearContents()
                        guard board.writeObjects([try item(b)]) else { throw CocoaError(.fileWriteUnknown) }
                    }) != nil
                }
                return try await copier.copyNow(to: board, first: {
                    didStartB.yield()
                    for await _ in releaseB { break }
                    return .init(item: try item(b), key: "B")
                }, smaller: { nil }).0 == .written
            }
            for await _ in bReading { break }

            switch order {
            case .bGivesWayFirst, .swapReadyFirst:
                let (repeatOfA, noSwap) = try await copier.copyNow(to: board, first: { .init(item: try item(a), key: "A") }, smaller: { nil })
                #expect(repeatOfA == .alreadyThere, "\(order)")
                #expect(noSwap == nil, "\(order)")
                if order == .bGivesWayFirst {
                    doReleaseB.yield()
                    #expect(try await copyB.value == false, "\(order)")
                    #expect(board.data(forType: .png) == originalA, "\(order)")
                    doReleaseSwap.yield()
                } else {
                    // B, older than the repeat, can't write any more: the swap doesn't wait for it.
                    doReleaseSwap.yield()
                    #expect(await lands(smallerA), "\(order)")
                    doReleaseB.yield()
                    #expect(try await copyB.value == false, "\(order)")
                }
                #expect(await swapTask.value, "\(order)")
                #expect(board.data(forType: .png) == smallerA, "\(order)")
            case .noRepeat:
                doReleaseSwap.yield()
                try await Task.sleep(for: .milliseconds(200))
                #expect(board.data(forType: .png) == originalA, "\(order)")
                doReleaseB.yield()
                #expect(try await copyB.value, "\(order)")
                #expect(await swapTask.value == false, "\(order)")
                #expect(board.data(forType: .png) == copiedB, "\(order)")
            }
        }
    }

    /// Astra, round 4, found along the way: an image copied as it is (Copy Original, or with optimizing off) takes
    /// its turn before it reads the file, as the optimized copy does. A copy asked for while it reads, even a repeat of
    /// the clipboard's image that writes nothing, is newer, and the older copy doesn't land after it.
    @Test func anImageCopiedAsItIsTakesItsTurnBeforeItReads() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let a = try bench.file("A.png", Sample.screenshot(width: 640, height: 400, seed: 55))
        let b = try bench.file("B.png", Sample.screenshot(width: 640, height: 400, seed: 56))
        // The copier the app's image copies share, on a private pasteboard.
        let copier = OptimizedImageCopy.shared
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let key = "A, \(UUID())"
        #expect(try await copier.copyNow(to: board, first: { .init(item: try item(a), key: key) }, smaller: { nil }).0 == .written)

        let copyB = Task { try await ScreenshotFileActions.copyImageToClipboard(from: b, dataType: .png, to: board) }
        // B starts, and is reading its file, when A is copied again.
        await Task.yield()
        #expect(try await copier.copyNow(to: board, first: { .init(item: try item(a), key: key) }, smaller: { nil }).0 == .alreadyThere)
        #expect(try await copyB.value == false)
        #expect(board.data(forType: .png) == (try Data(contentsOf: a)))

        // Nothing copied meanwhile: it is written.
        #expect(try await ScreenshotFileActions.copyImageToClipboard(from: b, dataType: .png, to: board))
        #expect(board.data(forType: .png) == (try Data(contentsOf: b)))
    }

    /// Sol, round 2: the swap publishes only the optimized form of the bytes the copy wrote. A file rewritten after
    /// the copy read it (another picture), a result that can't say what it was made from, and the same bytes again
    /// all leave the original on the pasteboard, written once.
    @Test func aSwapMadeFromOtherBytesThanTheCopyWroteIsNeverWritten() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let source = try bench.file("Capture.png", Sample.screenshot(width: 640, height: 400, seed: 46))
        let replacement = try bench.file("Replacement.png", Sample.screenshot(width: 640, height: 400, seed: 47))
        let optimizer = bench.optimizer
        let copier = OptimizedImageCopy()
        let original = try Data(contentsOf: source)
        let result = try await optimizer.optimize(source)
        defer { result.discard() }
        let rewritten = try await optimizer.optimize(replacement)
        defer { rewritten.discard() }
        #expect(result.outcome == .optimized && rewritten.outcome == .optimized)
        let candidates: [(String, OptimizedImageCopy.Swap?)] = [
            ("the rewritten file's optimized picture", swapIn(rewritten)),
            ("a result that can't say what it was made from", OptimizedImageCopy.Swap(item: try item(result.url), source: nil, output: result.output?.digest)),
            ("the copied bytes again", OptimizedImageCopy.Swap(item: try item(source), source: ClipboardPasteboardReader.digest(original),
                                                       output: ClipboardPasteboardReader.digest(original))),
        ]
        for (name, candidate) in candidates {
            let board = pasteboard()
            defer { board.releaseGlobally() }
            let count = board.changeCount
            let swapped = try await copier.copyThenSwap(to: board, first: { try item(source) }) { candidate }
            #expect(!swapped, "\(name)")
            #expect(board.data(forType: .png) == original, "\(name)")
            #expect(board.changeCount == count + 1, "\(name)")
        }
        // And the optimized form of the copied bytes still goes in.
        let board = pasteboard()
        defer { board.releaseGlobally() }
        #expect(try await copier.copyThenSwap(to: board, first: { try item(source) }) { swapIn(result) })
        #expect(board.data(forType: .png) == (try Data(contentsOf: result.url)))
    }

    /// Astra, round 3: a new capture optimized in place is read back from its Library file for the swap. An edit
    /// saved over that file in between is made from no optimizer: its bytes aren't the encoder's output, so the
    /// original stays, written once, whatever the result says it was made from.
    @Test func anEditSavedOverTheOptimizedFileIsNeverSwappedIn() async throws {
        let bench = try Bench()
        defer { bench.remove() }
        let capture = try bench.file("Capture.png", Sample.screenshot(width: 640, height: 400, seed: 52))
        let original = try Data(contentsOf: capture)
        let result = try await bench.optimizer.optimize(capture)
        defer { result.discard() }
        #expect(result.outcome == .optimized)
        #expect(result.output == FileIdentity(result.url))
        // The capture now holds the optimized bytes, then an edit is saved over it before the swap reads it.
        let edit = try bench.file("Edit.png", Sample.screenshot(width: 640, height: 400, seed: 53))
        let copier = OptimizedImageCopy()
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let swapped = try await copier.copyThenSwap(to: board, first: {
            let written = NSPasteboardItem()
            written.setData(original, forType: .png)
            return written
        }) {
            .init(item: try! item(edit), source: result.source?.digest, output: result.output?.digest)
        }
        #expect(!swapped)
        #expect(board.data(forType: .png) == original)
    }
}

// MARK: - One optimization for a new capture

@MainActor
@Suite struct ScheduledOnceTests {
    private final class Counter { var runs = 0 }

    /// A new capture's optimizing is due two seconds after the capture, and wanted at once by the copy that
    /// follows it. Both get the one run: the capture isn't optimized twice.
    @Test func workAskedForSoonerRunsOnceAndAtOnce() async throws {
        let counter = Counter()
        let scheduled = ScheduledOnce<String, Int>()
        let clock = ContinuousClock()
        let start = clock.now
        scheduled.schedule("capture", after: .seconds(30)) {
            counter.runs += 1
            return 7
        }
        // Scheduling it again while it waits adds nothing.
        scheduled.schedule("capture", after: .seconds(30)) {
            counter.runs += 100
            return 8
        }
        #expect(counter.runs == 0)
        let asked = await scheduled.now("capture")
        #expect(asked == 7)
        #expect(clock.now - start < .seconds(5))
        #expect(counter.runs == 1)

        // It has run: there is nothing left to ask for, and nothing runs again.
        let again = await scheduled.now("capture")
        let other = await scheduled.now("another")
        #expect(again == nil && other == nil)
        #expect(counter.runs == 1)

        // Left alone, it runs by itself after its delay.
        scheduled.schedule("later", after: .milliseconds(50)) {
            counter.runs += 1
            return 9
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(counter.runs == 2)
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
