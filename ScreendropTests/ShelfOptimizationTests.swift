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
