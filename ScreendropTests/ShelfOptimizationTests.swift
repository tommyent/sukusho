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

    /// A noisy JPEG whose lossless WebP conversion comes out larger than the original.
    private func noisyJPEG(_ url: URL) throws {
        let width = 160, height = 160
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            pixels[i] = UInt8((state >> 24) & 0xFF)
            pixels[i + 1] = UInt8((state >> 32) & 0xFF)
            pixels[i + 2] = UInt8((state >> 40) & 0xFF)
        }
        let image = try pixels.withUnsafeMutableBytes { raw -> CGImage in
            let context = try #require(CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            return try #require(context.makeImage())
        }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
    }

    @Test func aLargerConversionKeepsTheOriginalAndNeverGrowsTheTotal() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SukushoShelfLarger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let jpeg = folder.appending(path: "noisy.jpeg")
        try noisyJPEG(jpeg)

        let list = model([jpeg], .webP, in: folder)
        try await settled(list)
        for _ in 0..<200 where list.rows[0].bytes == 0 { try await Task.sleep(for: .milliseconds(10)) }

        // A larger result is never offered: original is kept, total does not grow, Save/Replace stay off,
        // temp output is cleaned up, and Copy/Share/Upload act on the original.
        #expect(list.rows[0].result == nil)
        #expect(list.rows[0].largerFormat == .webP)
        #expect(list.rows[0].isSettled)
        #expect(!list.rows[0].hasNewFile)
        #expect(list.resultBytes == list.originalBytes)
        #expect(!list.canSave)
        #expect(list.canHandOver)
        #expect(await ShelfOptimization.currentFiles(of: list.rows) == [jpeg])
        let leaked = (try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "out").path)) ?? []
        #expect(leaked.isEmpty)

        // Switching formats clears largerFormat and runs fresh.
        list.rerun(as: .same)
        try await settled(list)
        #expect(list.rows[0].largerFormat == nil)
        list.discard()

        // A mixed list keeps the smaller WebP for the PNG and the original for the JPEG, so total shrinks.
        let png = folder.appending(path: "flat.png")
        try picture(png, shade: 0.7)
        let mixed = model([png, jpeg], .webP, in: folder)
        try await settled(mixed)
        for _ in 0..<200 where mixed.rows.contains(where: { $0.bytes == 0 }) { try await Task.sleep(for: .milliseconds(10)) }
        let converted = try #require(mixed.rows[0].result)
        #expect(converted.outcome == .converted)
        #expect(mixed.rows[1].result == nil && mixed.rows[1].largerFormat == .webP)
        #expect(mixed.resultBytes == converted.resultByteCount + mixed.rows[1].bytes)
        #expect(mixed.resultBytes < mixed.originalBytes)
        #expect(mixed.canSave && mixed.canHandOver)
        #expect(await ShelfOptimization.currentFiles(of: mixed.rows) == [converted.url, jpeg])
        mixed.discard()
    }

    /// Sol 6.2 #8: originalByteCount is derived from the fingerprinted bytes, and settling a row updates
    /// row.bytes to match the version the optimizer actually read rather than an earlier size scan.
    @Test func settledRowUsesFingerprintedOriginalByteCount() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SukushoShelfBytes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "pic.png")
        try picture(file, shade: 0.5)
        let firstID = try #require(FileIdentity(file))
        let firstSize = try #require((FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value)
        #expect(firstID.byteCount == firstSize)

        let list = model([file], .webP, in: folder)
        try await settled(list)
        let converted = try #require(list.rows[0].result)
        #expect(converted.originalByteCount == firstID.byteCount)
        #expect(list.rows[0].bytes == converted.originalByteCount)

        // Replace the file on disk with a different-sized image and rerun: header originalBytes must reflect
        // the new fingerprinted bytes, not the old row.bytes.
        let bigger = folder.appending(path: "noisy.jpeg")
        try noisyJPEG(bigger)
        let newData = try Data(contentsOf: bigger)
        try newData.write(to: file)
        let secondID = try #require(FileIdentity(file))
        #expect(secondID.byteCount == Int64(newData.count))
        #expect(secondID.byteCount != firstID.byteCount)

        list.rerun(as: .webP)
        try await settled(list)
        #expect(list.rows[0].largerFormat == .webP)
        #expect(list.rows[0].bytes == secondID.byteCount)
        #expect(list.originalBytes == secondID.byteCount)
        #expect(list.resultBytes == secondID.byteCount)
        list.discard()
    }

    /// Sol 6.2 #4: a same-size conversion can be saved as a separate file, but Replace requires a strictly
    /// smaller result.
    @Test func replaceRequiresStrictlySmallerResultWhileSaveAllowsSameSizeConversion() async throws {
        #expect(ShelfOptimization.Row.canSave(outcome: .converted))
        #expect(!ShelfOptimization.Row.canReplace(outcome: .converted, originalBytes: 12_000, resultBytes: 12_000))
        #expect(!ShelfOptimization.Row.canReplace(outcome: .converted, originalBytes: 12_000, resultBytes: 12_001))
        #expect(ShelfOptimization.Row.canReplace(outcome: .converted, originalBytes: 12_000, resultBytes: 11_999))
        #expect(ShelfOptimization.Row.canReplace(outcome: .optimized, originalBytes: 12_000, resultBytes: 10_000))
        #expect(!ShelfOptimization.Row.canReplace(outcome: .alreadyOptimized, originalBytes: 12_000, resultBytes: 10_000))

        let folder = FileManager.default.temporaryDirectory.appending(path: "SukushoShelfReplace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appending(path: "flat.png")
        let jpeg = folder.appending(path: "noisy.jpeg")
        try picture(png, shade: 0.6)
        try noisyJPEG(jpeg)

        let list = model([png, jpeg], .webP, in: folder)
        try await settled(list)
        #expect(list.canSave)
        #expect(list.canReplace)
        #expect(ShelfOptimization.rowsToSave(from: list.rows, replacing: true).map(\.file) == [png])
        #expect(ShelfOptimization.rowsToSave(from: list.rows, replacing: false).map(\.file) == [png])
        list.discard()
    }

    private func model(_ files: [URL], _ format: ShelfOptimization.Format, in folder: URL) -> ShelfOptimization {
        let tools = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Vendor/optimizers")
        return ShelfOptimization(files: files, format: format, optimizer: ImageOptimizer(toolsDirectory: tools, outputDirectory: folder.appending(path: "out")),
                                 effort: .fast) { $0 == .same ? .lossless : $0 == .webP ? .webP(quality: nil) : .jpeg(quality: 80) }
    }

    /// From the test Mac, macOS 26.5.1: a file on the Desktop made macOS ask, the thumbnail's read waited on
    /// the main thread, and the app waited with it. The shelf reads nothing on the main actor now, and a file
    /// it isn't allowed to open gets a row that says so. Here a file without read permission stands in for
    /// one macOS refuses.
    @Test func theShelfReadsOffTheMainActorAndSaysWhenItMayNotReadAFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SukushoShelfReads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let readable = folder.appending(path: "readable.png"), refused = folder.appending(path: "refused.png")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: refused.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try picture(readable, shade: 0.8)
        try picture(refused, shade: 0.4)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: refused.path)

        // Making the list reads nothing: the sizes come a moment later, from another queue.
        let list = model([readable, refused], .webP, in: folder)
        #expect(list.rows.map(\.bytes) == [0, 0])
        try await settled(list)
        for _ in 0..<200 where list.rows[0].bytes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(list.rows[0].bytes > 0)

        // The readable file is converted; the other one's row says it couldn't be read, and nothing else fails.
        #expect(list.rows[0].result?.outcome == .converted)
        #expect(list.rows[1].result?.outcome == .failed(ImageOptimizer.unreadableReason))
        #expect(list.rows[1].result?.url == refused)
        // The list's total counts the unread file at its own size, not as shrunk to nothing.
        for _ in 0..<200 where list.rows[1].bytes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let converted = try #require(list.rows[0].result?.resultByteCount)
        #expect(list.rows[1].bytes > 0)
        #expect(list.resultBytes == converted + list.rows[1].bytes)
        #expect(list.originalBytes == list.rows[0].bytes + list.rows[1].bytes)

        // From the test Mac: with a row that couldn't be read, Copy and Save must have something to work with.
        // Here one file did come out, so both are on, and only that file is handed over.
        #expect(list.canSave && list.canHandOver)
        let handed = await ShelfOptimization.currentFiles(of: list.rows)
        #expect(handed == [try #require(list.rows[0].result?.url)])
        // A list of nothing but the unreadable file: nothing to save, nothing to hand over.
        let unreadableOnly = model([refused], .same, in: folder)
        try await settled(unreadableOnly)
        #expect(unreadableOnly.rows[0].isUnreadable)
        #expect(!unreadableOnly.canSave && !unreadableOnly.canHandOver)
        let nothing = await ShelfOptimization.currentFiles(of: unreadableOnly.rows)
        #expect(nothing.isEmpty)

        // Thumbnails are read off the main actor too (this test runs on it), and a refused file has none.
        let thumbnail = await ShelfOptimization.thumbnail(of: readable)
        let none = await ShelfOptimization.thumbnail(of: refused)
        #expect(thumbnail != nil)
        #expect(none == nil)

        // Folders are told from files without the main actor reading anything either.
        let kinds = await ShelfOptimization.regularFiles([readable, folder])
        #expect(kinds == [readable])
        list.discard()
    }

    /// Sol, second round: Save for list A is done only after A was put away and the shelf opened again with
    /// list B. A finishes with its own results and is told it is no longer on show; B is not touched.
    @Test func aChoiceDoneAfterTheShelfMovedOnLeavesTheNewListAlone() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SukushoShelfStage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let filesA = [folder.appending(path: "a1.png"), folder.appending(path: "a2.png")]
        let filesB = [folder.appending(path: "b1.png")]
        try picture(filesA[0], shade: 0.9)
        try picture(filesA[1], shade: 0.3)
        try picture(filesB[0], shade: 0.6)
        let stage = ShelfStage()
        let a = model(filesA, .webP, in: folder)
        stage.show(a)
        try await settled(a)
        let resultsA = try a.rows.map { try #require($0.result?.url) }

        // A's Save, held open as a slow save is.
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (release, doRelease) = AsyncStream<Void>.makeStream()
        let save = Task {
            await stage.finish(a) { rows -> [Bool] in
                didStart.yield()
                for await _ in release { break }
                return rows.map { $0.result.map { FileManager.default.fileExists(atPath: $0.url.path) } ?? false }
            }
        }
        for await _ in started { break }

        // The shelf is put away from outside (the setting switched off, say), then opens with other files.
        stage.putAway()
        #expect(stage.holding == nil)
        #expect(resultsA.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })   // A's results are kept for its Save
        let b = model(filesB, .webP, in: folder)
        stage.show(b)
        try await settled(b)
        let resultB = try #require(b.rows.first?.result?.url)

        doRelease.yield()
        let done = try #require(await save.value)
        // A's Save had its files to the end, and is told the shelf is no longer its own.
        #expect(done.value == [true, true])
        #expect(!done.isShowing)
        // So the presenter doesn't dismiss: B is still on show, with its result.
        #expect(stage.holding === b)
        #expect(b.rows.first?.result?.url == resultB)
        // A cleans up its own results and nothing of B's.
        a.discard()
        #expect(resultsA.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: resultB.path))

        // A choice on the list that is on show is told so.
        let onShow = try #require(await stage.finish(b) { $0.count })
        #expect(onShow.value == 1 && onShow.isShowing)
        b.discard()
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
