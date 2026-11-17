// The shake shelf's list of files: a choice on it (save, copy, share) works with result files that a change of
// format would delete, so while one is being carried out nothing else may touch them.
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@MainActor
@Suite struct ShelfOptimizationTests {
    private func picture(_ url: URL, shade: CGFloat) throws {
        let context = try #require(CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: shade, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 12, y: 12, width: 40, height: 24))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }

    private func settled(_ model: ShelfOptimization) async throws {
        for _ in 0..<600 where model.isWorking { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!model.isWorking)
    }

    /// Sol OS3-2: Save is still reading the results when another format is chosen.
    @Test func aChoiceBeingCarriedOutKeepsItsResults() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SukushoShelfModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = [folder.appending(path: "one.png"), folder.appending(path: "two.png")]
        try picture(files[0], shade: 0.9)
        try picture(files[1], shade: 0.3)
        let tools = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Vendor/optimizers")
        let model = ShelfOptimization(files: files, format: .webP, optimizer: ImageOptimizer(toolsDirectory: tools, outputDirectory: folder.appending(path: "out")),
                                      effort: .fast) { $0 == .same ? .lossless : $0 == .webP ? .webP(quality: nil) : .jpeg(quality: 80) }
        try await settled(model)
        let results = try model.rows.map { try #require($0.result?.url) }
        #expect(results.allSatisfy { $0.pathExtension == "webp" && FileManager.default.fileExists(atPath: $0.path) })

        // A choice that takes a while, as hashing and saving large files does.
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (release, doRelease) = AsyncStream<Void>.makeStream()
        let save = Task {
            await model.finishing { rows -> [Bool] in
                didStart.yield()
                for await _ in release { break }
                // What Save does next: read each result's file.
                return rows.map { $0.result.map { FileManager.default.fileExists(atPath: $0.url.path) } ?? false }
            }
        }
        for await _ in started { break }
        #expect(model.isFinishing)

        // Another format chosen meanwhile, and a second choice: neither happens.
        model.rerun(as: .jpeg)
        #expect(model.format == .webP)
        #expect(!model.isWorking)
        #expect(model.rows.map { $0.result?.url } == results)
        let second = await model.finishing { _ in true }
        #expect(second == nil)

        doRelease.yield()
        #expect(await save.value == [true, true])
        #expect(!model.isFinishing)
        #expect(results.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        // Once it is done, the format can change again, and the old results go.
        model.rerun(as: .same)
        #expect(model.format == .same)
        try await settled(model)
        #expect(results.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(model.rows.allSatisfy { $0.result != nil })
        model.discard()
    }
}
