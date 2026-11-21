import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Darwin
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

struct StudioTracksTests {
    // MARK: - Redaction Codable round-trip (legacy + new)

    @Test func redactionDecodesLegacySukushoDocumentAndPreservesSharedSafety() throws {
        let id = UUID()
        let legacyJSON = """
        {
            "id": "\(id.uuidString)",
            "start": 1.5,
            "end": 4.25,
            "rect": [[0.1, 0.2], [0.3, 0.4]],
            "mode": "blur",
            "strength": 0.75
        }
        """
        let decoded = try JSONDecoder().decode(RecordingRedaction.self, from: Data(legacyJSON.utf8))
        #expect(decoded.id == id)
        #expect(decoded.start == 1.5)
        #expect(decoded.end == 4.25)
        #expect(decoded.rect == CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        #expect(decoded.mode == .blur)
        #expect(decoded.strength == 0.75)
        try decoded.validate(sourceDuration: 10)

        let reencoded = try JSONEncoder().encode(decoded)
        let restored = try JSONDecoder().decode(RecordingRedaction.self, from: reencoded)
        #expect(restored == decoded)
        #expect(!RecordingRedaction.needsSharedReplacement([decoded], shared: [restored]))

        // Changing redaction mode flags shared links as needing replacement.
        var edited = decoded
        edited.mode = .pixelate
        try edited.validate(sourceDuration: 10)
        let roundTripped = try JSONDecoder().decode(RecordingRedaction.self, from: JSONEncoder().encode(edited))
        #expect(roundTripped == edited)
        #expect(RecordingRedaction.needsSharedReplacement([edited], shared: [decoded]))
    }

    @Test func redactionDecodesUpstreamStyleAndAmountAndIgnoresFadeCornerKeys() throws {
        let upstreamJSON = """
        {
            "start": 0.5,
            "end": 3.5,
            "rect": [[0.2, 0.2], [0.4, 0.3]],
            "style": "pixelate",
            "amount": 0.6,
            "cornerRadius": 80,
            "fadeIn": 1.5,
            "fadeOut": 1.5
        }
        """
        let decoded = try JSONDecoder().decode(RecordingRedaction.self, from: Data(upstreamJSON.utf8))
        #expect(decoded.mode == .pixelate)
        #expect(decoded.strength == 0.6)
        try decoded.validate(sourceDuration: 5)
    }

    @Test func redactionDecodingRequiresBoundsAndRejectsMissingOrNullRect() throws {
        let missingRect = """
        { "start": 0.5, "end": 2.0, "mode": "pixelate", "strength": 0.8 }
        """
        let nullRect = """
        { "start": 0.5, "end": 2.0, "rect": null, "mode": "blur", "strength": 0.8 }
        """
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(RecordingRedaction.self, from: Data(missingRect.utf8))
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(RecordingRedaction.self, from: Data(nullRect.utf8))
        }

        // Optional styling keys still default cleanly when bounds are present.
        let minimalValid = """
        { "start": 0.5, "end": 2.0, "rect": [[0.1, 0.1], [0.2, 0.2]] }
        """
        let decoded = try JSONDecoder().decode(RecordingRedaction.self, from: Data(minimalValid.utf8))
        #expect(decoded.rect == CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        #expect(decoded.mode == .blur)
        #expect(decoded.strength == 0.8)
    }

    @Test(arguments: RecordingRedaction.Mode.allCases)
    func exportedRedactionMasksFullRectangleAndCornersOnFirstAndLastIntersectingFrames(_ mode: RecordingRedaction.Mode) async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioRedactionExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let width = 128, height = 128, fps = 30
        let frameInterval = 1.0 / Double(fps)
        let sourceURL = tempDir.appendingPathComponent("source.mov")
        let exportedURL = tempDir.appendingPathComponent("exported.mov")

        // Write a 2-second 30fps movie with a stark black/white 2x2 checkerboard inside [32..96, 32..96]
        // and flat mid-gray outside. Every corner of [32..96, 32..96] has high-contrast alternating tiles.
        try await writeCheckerboardMovie(to: sourceURL, width: width, height: height, fps: fps, frameCount: fps * 2)

        // Redaction spans 0.51...1.49 so frame 15 (0.500..0.533) straddles start
        // and frame 44 (1.467..1.500) straddles end. Even if loaded from a draft
        // carrying fade/corner keys, every intersecting frame and corner must be masked.
        let json = """
        {
            "start": 0.51,
            "end": 1.49,
            "rect": [[0.25, 0.25], [0.5, 0.5]],
            "mode": "\(mode.rawValue)",
            "strength": 0.9,
            "cornerRadius": 100,
            "fadeIn": 1.0,
            "fadeOut": 1.0
        }
        """
        let region = try JSONDecoder().decode(RecordingRedaction.self, from: Data(json.utf8))
        let timeline = RecordingClipTimeline.full(sourceDuration: 2.0)

        // Export through the exact buffer filter + outward covers() check used by RecordingStudioExporter.
        try await exportRedactedMovie(
            from: sourceURL,
            to: exportedURL,
            redactions: [region],
            timeline: timeline,
            width: width,
            height: height,
            fps: fps
        )

        let exportedAsset = AVURLAsset(url: exportedURL)
        let generator = AVAssetImageGenerator(asset: exportedAsset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // Frame 15 (0.500s) is the first intersecting frame; frame 44 (1.467s) is the last.
        // Frame 10 (0.333s) is outside and must remain unredacted (high corner contrast).
        let unredactedFrame = try await generator.image(at: CMTime(value: 10, timescale: CMTimeScale(fps))).image
        let firstIntersecting = try await generator.image(at: CMTime(value: 15, timescale: CMTimeScale(fps))).image
        let lastIntersecting = try await generator.image(at: CMTime(value: 44, timescale: CMTimeScale(fps))).image

        #expect(region.covers(editorTime: 15 * frameInterval, frameDuration: frameInterval, timeline: timeline))
        #expect(region.covers(editorTime: 44 * frameInterval, frameDuration: frameInterval, timeline: timeline))
        #expect(!region.covers(editorTime: 10 * frameInterval, frameDuration: frameInterval, timeline: timeline))

        // Check all 4 corners of the redacted box [32..96, 32..96]:
        // unredacted corner 8x8 patch has max-min luminance > 180; masked patch collapses contrast.
        let corners = [(32, 32), (88, 32), (32, 88), (88, 88)]
        for (cx, cy) in corners {
            let baselineContrast = try patchLuminanceRange(in: unredactedFrame, x: cx, y: cy, size: 8)
            #expect(baselineContrast > 150, "Baseline checkerboard corner (\(cx),\(cy)) must have high contrast")

            let firstContrast = try patchLuminanceRange(in: firstIntersecting, x: cx, y: cy, size: 8)
            let lastContrast = try patchLuminanceRange(in: lastIntersecting, x: cx, y: cy, size: 8)
            #expect(firstContrast < 40, "First intersecting frame leaked corner (\(cx),\(cy)) with contrast \(firstContrast)")
            #expect(lastContrast < 40, "Last intersecting frame leaked corner (\(cx),\(cy)) with contrast \(lastContrast)")
        }
    }

    // MARK: - Finder drop loader

    @Test func finderDropStartsEveryProviderSynchronouslyAndPreservesOrder() async throws {
        let expected = [
            URL(fileURLWithPath: "/tmp/first.png"),
            URL(fileURLWithPath: "/tmp/second.gif"),
            URL(fileURLWithPath: "/tmp/third.webp")
        ]
        let lock = NSLock()
        var started: [Int] = []
        let providers: [NSItemProvider] = expected.enumerated().map { index, url in
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { handler in
                lock.withLock { started.append(index) }
                // Complete in reverse order so ordering depends on slot index, not arrival.
                let delayMs = (expected.count - index) * 15
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
                    handler(url.dataRepresentation, nil)
                }
                return nil
            }
            return provider
        }

        let delivered: [URL] = await withCheckedContinuation { continuation in
            let accepted = StudioMediaDropLoader.loadFileURLs(from: providers) { urls in
                continuation.resume(returning: urls)
            }
            #expect(accepted)
            let startedBeforeReturn = lock.withLock { started }
            #expect(startedBeforeReturn.count == expected.count)
        }
        #expect(delivered == expected)
    }

    // MARK: - Media resolver, symlink rejection, validation, and regular-file cleanup

    @Test func mediaResolverEnforcesSimpleRegularFilesRejectsSymlinksAndCleansSafely() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioMediaResolver-\(UUID().uuidString)", isDirectory: true)
        let mediaDir = tempDir.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a real PNG outside media/ and a symlink to it.
        let externalPNG = tempDir.appendingPathComponent("outside.png")
        try writeSolidPNG(to: externalPNG, width: 32, height: 32, r: 20, g: 120, b: 220)
        let externalSymlink = tempDir.appendingPathComponent("link-outside.png")
        try FileManager.default.createSymbolicLink(at: externalSymlink, withDestinationURL: externalPNG)

        // Importer rejects symlink sources and copies regular files.
        #expect(RecordingOverlayMedia.copyRegularFile(from: externalSymlink, into: mediaDir) == nil)
        let copiedName = try #require(RecordingOverlayMedia.copyRegularFile(from: externalPNG, into: mediaDir))
        #expect(RecordingOverlayMedia.resolveRegularFile(named: copiedName, in: mediaDir) != nil)

        // Resolver rejects path traversal, nested paths, empty names, symlinks, and directories.
        let mediaSymlink = mediaDir.appendingPathComponent("sym.png")
        try FileManager.default.createSymbolicLink(at: mediaSymlink, withDestinationURL: externalPNG)
        let nestedDir = mediaDir.appendingPathComponent("folder.png", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let nestedChild = nestedDir.appendingPathComponent("child.txt")
        try Data("keep".utf8).write(to: nestedChild)

        for bad in ["", ".", "..", "../outside.png", "folder.png/child.txt", "/etc/hosts", "sym.png", "folder.png"] {
            #expect(RecordingOverlayMedia.resolveRegularFile(named: bad, in: mediaDir) == nil, "Expected \(bad) to be rejected")
        }

        // Export validation succeeds for the regular file and fails naming the missing/symlinked asset.
        let timeline = RecordingClipTimeline.full(sourceDuration: 5)
        let store = RecordingOverlayImageStore()
        let validOverlay = RecordingImageOverlay(fileName: copiedName, displayName: "Logo", start: 0, end: 2)
        try RecordingOverlayMedia.validateOverlays([validOverlay], in: mediaDir, clipTimeline: timeline, store: store)

        let symlinkOverlay = RecordingImageOverlay(fileName: "sym.png", displayName: "Linked Badge", start: 0, end: 2)
        do {
            try RecordingOverlayMedia.validateOverlays([symlinkOverlay], in: mediaDir, clipTimeline: timeline, store: store)
            Issue.record("Expected symlinked overlay to fail validation")
        } catch let error as RecordingOverlayMedia.ResolutionError {
            #expect(error == .missingOrInvalid("Linked Badge"))
            #expect(error.errorDescription?.contains("Linked Badge") == true)
        }

        let missingOverlay = RecordingImageOverlay(fileName: "gone.png", displayName: "Hero Art", start: 0, end: 2)
        do {
            try RecordingOverlayMedia.validateOverlays([missingOverlay], in: mediaDir, clipTimeline: timeline, store: store)
            Issue.record("Expected missing overlay to fail validation")
        } catch let error as RecordingOverlayMedia.ResolutionError {
            #expect(error == .missingOrInvalid("Hero Art"))
        }

        // Cleanup removes only unreferenced UUID-named regular image imports; keeps referenced files,
        // non-owned regular images, non-image files, symlinks, and directories named like images.
        let orphanName = try #require(RecordingOverlayMedia.copyRegularFile(from: externalPNG, into: mediaDir))
        let handPlaced = mediaDir.appendingPathComponent("custom-logo.png")
        try writeSolidPNG(to: handPlaced, width: 16, height: 16, r: 90, g: 90, b: 90)
        let audioFile = mediaDir.appendingPathComponent("voice.m4a")
        try Data("audio".utf8).write(to: audioFile)

        RecordingOverlayMedia.cleanupUnreferencedImages(in: mediaDir, referenced: [copiedName])
        #expect(FileManager.default.fileExists(atPath: mediaDir.appendingPathComponent(copiedName).path))
        #expect(!FileManager.default.fileExists(atPath: mediaDir.appendingPathComponent(orphanName).path))
        #expect(FileManager.default.fileExists(atPath: handPlaced.path))
        #expect(FileManager.default.fileExists(atPath: audioFile.path))
        #expect(FileManager.default.fileExists(atPath: nestedChild.path))
        var linkStat = stat()
        #expect(lstat(mediaSymlink.path, &linkStat) == 0)
    }

    @Test func mediaResolverAndCleanupRejectSymlinkedMediaRootDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioLinkedMediaRoot-\(UUID().uuidString)", isDirectory: true)
        let packageDir = tempDir.appendingPathComponent("demo.sukushorec", isDirectory: true)
        let externalPictures = tempDir.appendingPathComponent("Pictures", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalPictures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let externalPhoto = externalPictures.appendingPathComponent("vacation.png")
        let externalUUIDPhoto = externalPictures.appendingPathComponent("\(UUID().uuidString).png")
        try writeSolidPNG(to: externalPhoto, width: 32, height: 32, r: 10, g: 180, b: 80)
        try writeSolidPNG(to: externalUUIDPhoto, width: 32, height: 32, r: 180, g: 80, b: 10)

        let linkedMediaRoot = packageDir.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedMediaRoot, withDestinationURL: externalPictures)

        // Resolver rejects files through a linked media root.
        #expect(RecordingOverlayMedia.resolveRealMediaDirectory(linkedMediaRoot) == nil)
        #expect(RecordingOverlayMedia.resolveRegularFile(named: externalPhoto.lastPathComponent, in: linkedMediaRoot) == nil)
        #expect(RecordingOverlayMedia.resolveRegularFile(named: externalUUIDPhoto.lastPathComponent, in: linkedMediaRoot) == nil)

        // Copy rejects importing into a linked media root.
        let sourcePNG = tempDir.appendingPathComponent("fresh.png")
        try writeSolidPNG(to: sourcePNG, width: 16, height: 16, r: 50, g: 50, b: 200)
        #expect(RecordingOverlayMedia.copyRegularFile(from: sourcePNG, into: linkedMediaRoot) == nil)
        #expect((try FileManager.default.contentsOfDirectory(atPath: externalPictures.path)).count == 2)

        // Export validation fails naming the overlay rather than reading through the linked root.
        let timeline = RecordingClipTimeline.full(sourceDuration: 4)
        let overlay = RecordingImageOverlay(fileName: externalUUIDPhoto.lastPathComponent, displayName: "Linked Root Asset", start: 0, end: 2)
        do {
            try RecordingOverlayMedia.validateOverlays([overlay], in: linkedMediaRoot, clipTimeline: timeline, store: RecordingOverlayImageStore())
            Issue.record("Expected linked media root to fail export validation")
        } catch let error as RecordingOverlayMedia.ResolutionError {
            #expect(error == .missingOrInvalid("Linked Root Asset"))
        }

        // Cleanup NEVER enumerates or deletes anything inside the symlinked target directory.
        RecordingOverlayMedia.cleanupUnreferencedImages(in: linkedMediaRoot, referenced: [])
        #expect(FileManager.default.fileExists(atPath: externalPhoto.path))
        #expect(FileManager.default.fileExists(atPath: externalUUIDPhoto.path))
    }

    // MARK: - Pending overlay edit flushing before Undo, Redo, or a new edit

    @MainActor
    @Test func pendingOverlayEditsFlushBeforeUndoRedoAndSeparateEdits() async throws {
        // Mirror RecordingStudioModel's UndoManager + StudioPendingEdit protocol.
        final class Harness {
            let undoManager = UndoManager()
            let pendingImage = StudioPendingEdit<[RecordingImageOverlay]>()
            let pendingRedaction = StudioPendingEdit<[RecordingRedaction]>()
            var images: [RecordingImageOverlay] = []
            var redactions: [RecordingRedaction] = []
            var draftWrites = 0

            init() { undoManager.groupsByEvent = false }

            var canUndo: Bool {
                undoManager.canUndo
                    || pendingImage.isDirty(current: images)
                    || pendingRedaction.isDirty(current: redactions)
            }

            func flushPending() {
                if let commit = pendingImage.takeCommit(current: images, fallbackActionName: "Edit Image") {
                    registerUndo(commit.actionName) { $0.applyImages(commit.previous, actionName: commit.actionName) }
                }
                if let commit = pendingRedaction.takeCommit(current: redactions, fallbackActionName: "Edit Redaction") {
                    draftWrites += 1
                    registerUndo(commit.actionName) { $0.applyRedactions(commit.previous, actionName: commit.actionName) }
                }
            }

            func registerUndo(_ name: String, _ op: @escaping (Harness) -> Void) {
                if !undoManager.isUndoing && !undoManager.isRedoing { flushPending() }
                undoManager.beginUndoGrouping()
                undoManager.registerUndo(withTarget: self) { op($0) }
                undoManager.setActionName(name)
                undoManager.endUndoGrouping()
            }

            func applyImages(_ next: [RecordingImageOverlay], actionName: String) {
                if !undoManager.isUndoing && !undoManager.isRedoing { flushPending() }
                let prev = images
                registerUndo(actionName) { $0.applyImages(prev, actionName: actionName) }
                images = next
            }

            func editImage(_ updated: RecordingImageOverlay, actionName: String) {
                pendingImage.begin(from: images, actionName: actionName)
                images = images.map { $0.id == updated.id ? updated : $0 }
                pendingImage.scheduleCommit(actionName: actionName, delay: .milliseconds(80)) { [weak self] in
                    self?.flushPending()
                }
            }

            func applyRedactions(_ next: [RecordingRedaction], actionName: String) {
                if !undoManager.isUndoing && !undoManager.isRedoing { flushPending() }
                let prev = redactions
                draftWrites += 1
                registerUndo(actionName) { $0.applyRedactions(prev, actionName: actionName) }
                redactions = next
            }

            func editRedaction(_ updated: RecordingRedaction, actionName: String) {
                pendingRedaction.begin(from: redactions, actionName: actionName)
                redactions = redactions.map { $0.id == updated.id ? updated : $0 }
                pendingRedaction.scheduleCommit(actionName: actionName, delay: .milliseconds(80)) { [weak self] in
                    self?.flushPending()
                }
            }

            func undo() {
                flushPending()
                guard undoManager.canUndo else { return }
                undoManager.undo()
            }
        }

        // 1. Only a pending edit exists -> canUndo is true and Undo immediately reverts it.
        let solo = Harness()
        let initialImg = RecordingImageOverlay(fileName: "a.png", displayName: "a", start: 0, end: 2)
        solo.images = [initialImg]
        #expect(!solo.canUndo)
        var faded = initialImg; faded.opacity = 0.4
        solo.editImage(faded, actionName: "Change Image Opacity")
        #expect(solo.canUndo)
        solo.undo()
        #expect(solo.images.first?.opacity == 1.0)

        // 2. Import image, change opacity, immediately Undo -> undoes opacity first, keeps image,
        //    and waiting past the debounce window does NOT register a stale edit.
        let flow = Harness()
        flow.applyImages([initialImg], actionName: "Add Image")
        flow.editImage(faded, actionName: "Change Image Opacity")
        flow.undo()
        #expect(flow.images.count == 1)
        #expect(flow.images[0].opacity == 1.0)
        try await Task.sleep(for: .milliseconds(120))
        #expect(flow.images.count == 1)
        #expect(flow.images[0].opacity == 1.0)
        flow.undo()
        #expect(flow.images.isEmpty)

        // 3. Redaction strength edit followed immediately by mode change commits strength
        //    (with draft write) BEFORE registering the mode change.
        let redaction = RecordingRedaction(start: 0, end: 3, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), mode: .blur, strength: 0.8)
        flow.redactions = [redaction]
        var stronger = redaction; stronger.strength = 0.95
        flow.editRedaction(stronger, actionName: "Change Redaction Strength")
        var pixelated = stronger; pixelated.mode = .pixelate
        flow.applyRedactions([pixelated], actionName: "Change Redaction Mode")
        #expect(flow.draftWrites == 2)
        flow.undo()
        #expect(flow.redactions.first?.mode == .blur)
        #expect(flow.redactions.first?.strength == 0.95)
        flow.undo()
        #expect(flow.redactions.first?.strength == 0.8)
    }

    @MainActor
    @Test func sharedEffectsLaneTransactionsIsolateEditedItemAndFlushInspectorEdits() throws {
        enum EffectsItem: Identifiable {
            case image(RecordingImageOverlay)
            case redaction(RecordingRedaction)

            var id: UUID {
                switch self {
                case .image(let img): img.id
                case .redaction(let red): red.id
                }
            }
        }

        final class LaneHost: StudioBlockLaneHost {
            var isDraggingTimelineBlock = false
            let undoManager: UndoManager = {
                let m = UndoManager()
                m.groupsByEvent = false
                return m
            }()
            let pendingImage = StudioPendingEdit<[RecordingImageOverlay]>()
            let pendingRedaction = StudioPendingEdit<[RecordingRedaction]>()
            var images: [RecordingImageOverlay] = []
            var redactions: [RecordingRedaction] = []
            var selectedID: UUID?
            var beganImage = 0
            var beganRedaction = 0

            func pause() {}
            func seek(to time: TimeInterval) {}
            func clearTimelineSelection() { selectedID = nil }

            func commitPending(excluding kind: String? = nil) {
                if kind != "image", pendingImage.isActive { endImageEdit() }
                if kind != "redaction", pendingRedaction.isActive { endRedactionEdit() }
            }

            func beginImageEdit() {
                commitPending(excluding: "image")
                if pendingImage.isCoalescing { endImageEdit() }
                pendingImage.begin(from: images)
                beganImage += 1
            }

            func endImageEdit(actionName: String = "Edit Image") {
                guard let commit = pendingImage.takeCommit(current: images, fallbackActionName: actionName) else { return }
                registerUndo(commit.actionName) { $0.applyImages(commit.previous, actionName: commit.actionName) }
            }

            func editImageInspector(_ updated: RecordingImageOverlay, actionName: String) {
                commitPending(excluding: "image")
                if pendingImage.isActive, !pendingImage.actionName.isEmpty, pendingImage.actionName != actionName {
                    endImageEdit()
                }
                pendingImage.begin(from: images, actionName: actionName)
                images = images.map { $0.id == updated.id ? updated : $0 }
                pendingImage.scheduleCommit(actionName: actionName, delay: .seconds(5)) { [weak self] in
                    self?.endImageEdit(actionName: actionName)
                }
            }

            func beginRedactionEdit() {
                commitPending(excluding: "redaction")
                if pendingRedaction.isCoalescing { endRedactionEdit() }
                pendingRedaction.begin(from: redactions)
                beganRedaction += 1
            }

            func endRedactionEdit(actionName: String = "Edit Redaction") {
                guard let commit = pendingRedaction.takeCommit(current: redactions, fallbackActionName: actionName) else { return }
                registerUndo(commit.actionName) { $0.applyRedactions(commit.previous, actionName: commit.actionName) }
            }

            func registerUndo(_ name: String, _ op: @escaping (LaneHost) -> Void) {
                let openGroup = !undoManager.isUndoing && !undoManager.isRedoing
                if openGroup {
                    commitPending()
                    undoManager.beginUndoGrouping()
                }
                undoManager.registerUndo(withTarget: self) { op($0) }
                undoManager.setActionName(name)
                if openGroup { undoManager.endUndoGrouping() }
            }

            func applyImages(_ next: [RecordingImageOverlay], actionName: String) {
                let prev = images
                registerUndo(actionName) { $0.applyImages(prev, actionName: actionName) }
                images = next
            }

            func applyRedactions(_ next: [RecordingRedaction], actionName: String) {
                let prev = redactions
                registerUndo(actionName) { $0.applyRedactions(prev, actionName: actionName) }
                redactions = next
            }
        }

        let host = LaneHost()
        let img = RecordingImageOverlay(fileName: "logo.png", displayName: "logo", start: 1.0, end: 3.0)
        let red = RecordingRedaction(start: 4.0, end: 6.0, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        host.images = [img]
        host.redactions = [red]

        let imageBlock = StudioLaneBlock(item: EffectsItem.image(img), editorStart: 1.0, editorEnd: 3.0)
        let redactionBlock = StudioLaneBlock(item: EffectsItem.redaction(red), editorStart: 4.0, editorEnd: 6.0)
        let lane = StudioBlockLane(
            model: host,
            blocks: [imageBlock, redactionBlock],
            selectedID: host.selectedID,
            scale: StudioTimelineScale(viewportWidth: 800, duration: 10, zoom: 1),
            height: 28,
            empty: .scrub,
            actions: StudioBlockLaneActions(
                select: { host.selectedID = $0.id },
                begin: { item, _ in
                    switch item {
                    case .image: host.beginImageEdit()
                    case .redaction: host.beginRedactionEdit()
                    }
                },
                edit: { edit in
                    switch edit.base.item {
                    case .image(var overlay):
                        overlay.start += edit.delta
                        overlay.end += edit.delta
                        host.images = host.images.map { $0.id == overlay.id ? overlay : $0 }
                    case .redaction(var region):
                        if edit.kind == .trimTrailing { region.end += edit.delta }
                        host.redactions = host.redactions.map { $0.id == region.id ? region : $0 }
                    }
                },
                end: { item, kind in
                    let verb = kind == .move ? "Move" : "Resize"
                    switch item {
                    case .image: host.endImageEdit(actionName: "\(verb) Image")
                    case .redaction: host.endRedactionEdit(actionName: "\(verb) Redaction")
                    }
                }
            ),
            content: { _, _ in Color.clear },
            menu: { _ in EmptyView() },
            help: { _ in "" },
            accessibility: { _ in StudioBlockAccessibility(label: "", value: "") }
        )

        // 1. Moving an image block through the shared lane begins ONLY the image transaction
        //    (never flushed by beginRedactionEdit) and registers an undoable Move Image step.
        lane.performAccessibleEdit(imageBlock, kind: .move, delta: 0.5)
        #expect(host.beganImage == 1)
        #expect(host.beganRedaction == 0)
        #expect(abs(host.images[0].start - 1.5) < 0.0001)
        #expect(host.undoManager.canUndo)
        #expect(host.undoManager.undoActionName == "Move Image")
        host.undoManager.undo()
        #expect(abs(host.images[0].start - 1.0) < 0.0001)

        // 2. Trimming a redaction block through the shared lane begins ONLY the redaction transaction.
        lane.performAccessibleEdit(redactionBlock, kind: .trimTrailing, delta: 0.5)
        #expect(host.beganImage == 1)
        #expect(host.beganRedaction == 1)
        #expect(abs(host.redactions[0].end - 6.5) < 0.0001)
        #expect(host.undoManager.undoActionName == "Resize Redaction")
        host.undoManager.undo()
        #expect(abs(host.redactions[0].end - 6.0) < 0.0001)

        // 3. A pending inspector opacity edit is finalized as its own undo step when a
        //    same-kind lane gesture begins immediately after.
        var faded = host.images[0]; faded.opacity = 0.5
        host.editImageInspector(faded, actionName: "Change Image Opacity")
        let fadedBlock = StudioLaneBlock(item: EffectsItem.image(faded), editorStart: 1.0, editorEnd: 3.0)
        lane.performAccessibleEdit(fadedBlock, kind: .move, delta: 0.5)
        #expect(abs(host.images[0].start - 1.5) < 0.0001)
        #expect(host.images[0].opacity == 0.5)
        #expect(host.undoManager.undoActionName == "Move Image")
        host.undoManager.undo()
        #expect(abs(host.images[0].start - 1.0) < 0.0001)
        #expect(host.images[0].opacity == 0.5)
        #expect(host.undoManager.undoActionName == "Change Image Opacity")
        host.undoManager.undo()
        #expect(host.images[0].opacity == 1.0)
    }

    // MARK: - Byte-bounded animated frame cache

    @Test func animatedFrameCacheEnforcesByteBudgetAcrossAssetsAndRejectsOversizedFrames() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioFrameCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let gifA = tempDir.appendingPathComponent("a.gif")
        let gifB = tempDir.appendingPathComponent("b.gif")
        try writeAnimatedGIF(to: gifA, frameCount: 8, width: 64, height: 64, delay: 0.1)
        try writeAnimatedGIF(to: gifB, frameCount: 4, width: 64, height: 64, delay: 0.1)

        // Probe one 64x64 decoded frame cost, then budget for only 3 frames across BOTH assets.
        let probeCache = RecordingOverlayFrameCache(byteLimit: 1024 * 1024)
        let probe = try #require(RecordingOverlayImage(url: gifA, cache: probeCache))
        let oneFrameBytes = probeCache.currentBytes
        #expect(oneFrameBytes > 0)
        #expect(probe.frameCount == 8)

        let budget = oneFrameBytes * 3
        let sharedCache = RecordingOverlayFrameCache(byteLimit: budget)
        let storeA = RecordingOverlayImageStore(frameCache: sharedCache)
        let storeB = RecordingOverlayImageStore(frameCache: sharedCache)

        // Opening both assets only decodes frame 0 of each (2 frames <= 3-frame budget).
        let imageA = try #require(storeA.image(at: gifA))
        let imageB = try #require(storeB.image(at: gifB))
        #expect(sharedCache.currentBytes <= budget)
        #expect(sharedCache.currentBytes == oneFrameBytes * 2)

        // Scrubbing through every frame of both assets never exceeds the shared byte budget.
        for index in 0..<8 {
            let fA = try #require(imageA.frame(at: Double(index) * 0.1 + 0.02))
            #expect(fA.width == 64 && fA.height == 64)
            #expect(sharedCache.currentBytes <= budget)
        }
        for index in 0..<4 {
            let fB = try #require(imageB.frame(at: Double(index) * 0.1 + 0.02))
            #expect(fB.width == 64 && fB.height == 64)
            #expect(sharedCache.currentBytes <= budget)
        }

        // An image whose single frame exceeds the cache budget fails init without retaining memory.
        let tinyCache = RecordingOverlayFrameCache(byteLimit: max(1, oneFrameBytes / 2))
        #expect(RecordingOverlayImage(url: gifA, cache: tinyCache) == nil)
        #expect(tinyCache.currentBytes == 0)
    }

    @Test func lateFrameDecodeFailureRaisesNamedExportErrorAndPreviewPrefetchesOffDrawPath() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioLateDecode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let gifURL = tempDir.appendingPathComponent("anim.gif")
        try writeAnimatedGIF(to: gifURL, frameCount: 4, width: 64, height: 64, delay: 0.1)

        // 1. Frame 0 decodes cleanly, frame 1 fails: export draw must throw the named asset error.
        let failingCache = RecordingOverlayFrameCache(byteLimit: 4 * 1024 * 1024)
        let failingImage = try #require(RecordingOverlayImage(url: gifURL, cache: failingCache) { source, index in
            index == 0 ? RecordingOverlayImage.decodeFrame(from: source, at: 0) : nil
        })
        let overlay = RecordingImageOverlay(fileName: "anim.gif", displayName: "Corrupt Badge", start: 0, end: 5)
        let size = CGSize(width: 128, height: 128)
        let ctx = try #require(CGContext(
            data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 128 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        try RecordingImageOverlayRenderer.drawForExport(overlay, image: failingImage, atSourceTime: 0.02, canvasSize: size, in: ctx)
        do {
            try RecordingImageOverlayRenderer.drawForExport(overlay, image: failingImage, atSourceTime: 0.15, canvasSize: size, in: ctx)
            Issue.record("Expected late frame decode failure to throw missingOrInvalid")
        } catch let error as RecordingOverlayMedia.ResolutionError {
            #expect(error == .missingOrInvalid("Corrupt Badge"))
        }

        // 2. Preview draw on a cache miss returns the last completed frame immediately WITHOUT
        //    decoding synchronously on the calling thread, and prefetches off the draw path.
        let probeCache = RecordingOverlayFrameCache(byteLimit: 1024 * 1024)
        let _ = try #require(RecordingOverlayImage(url: gifURL, cache: probeCache))
        let oneFrameBytes = probeCache.currentBytes

        nonisolated final class DecodeLog: @unchecked Sendable {
            private let lock = NSLock()
            private var indices: [Int] = []
            func record(_ index: Int) { lock.withLock { indices.append(index) } }
            func contains(_ index: Int) -> Bool { lock.withLock { indices.contains(index) } }
        }
        let decodeLog = DecodeLog()
        let singleSlotCache = RecordingOverlayFrameCache(byteLimit: oneFrameBytes)
        let previewImage = try #require(RecordingOverlayImage(url: gifURL, cache: singleSlotCache) { source, index in
            decodeLog.record(index)
            if index > 0 { Thread.sleep(forTimeInterval: 0.02) }
            return RecordingOverlayImage.decodeFrame(from: source, at: index)
        })
        let frame0 = previewImage.previewFrame(at: 0.02)
        // Request frame 2 (uncached): must return frame0 immediately without blocking for decode.
        let decodedSignal = AsyncStream<Void>.makeStream()
        let immediate = previewImage.previewFrame(at: 0.25) {
            decodedSignal.continuation.yield()
        }
        #expect(immediate === frame0)

        // Wait for background prefetch to complete and verify frame 2 is now cached and distinct.
        for await _ in decodedSignal.stream {
            break
        }
        let afterPrefetch = previewImage.previewFrame(at: 0.25)
        #expect(afterPrefetch !== frame0)
        #expect(decodeLog.contains(2))
    }

    // MARK: - Animated frame delay rules (GIF vs APNG, WebP, HEIC)

    @Test func gifDelayFallbackAppliesOnlyToGIFAndPreservesShortDelaysInOtherFormats() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioFrameDelays-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Real APNG with 10 ms and 40 ms frames must stay 50 ms total (not stretched to 140 ms).
        let apngURL = tempDir.appendingPathComponent("fast.png")
        let apngDest = try #require(CGImageDestinationCreateWithURL(apngURL as CFURL, UTType.png.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(apngDest, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
        let red = try solidImage(width: 32, height: 32, r: 240, g: 20, b: 20)
        let blue = try solidImage(width: 32, height: 32, r: 20, g: 40, b: 240)
        CGImageDestinationAddImage(apngDest, red, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGUnclampedDelayTime: 0.01]] as CFDictionary)
        CGImageDestinationAddImage(apngDest, blue, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGUnclampedDelayTime: 0.04]] as CFDictionary)
        #expect(CGImageDestinationFinalize(apngDest))

        let cache = RecordingOverlayFrameCache(byteLimit: 4 * 1024 * 1024)
        let apng = try #require(RecordingOverlayImage(url: apngURL, cache: cache))
        #expect(apng.frameCount == 2)
        #expect(abs(apng.loopDuration - 0.05) < 0.005)
        let apngFrame0 = try #require(apng.frame(at: 0.005))
        let apngFrame1 = try #require(apng.frame(at: 0.025))
        #expect(apngFrame0 !== apngFrame1)

        // Real GIF with 0 ms (sub-11 ms) and 50 ms frames applies the GIF fallback -> 150 ms total.
        let gifURL = tempDir.appendingPathComponent("short.gif")
        let gifDest = try #require(CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(gifDest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        CGImageDestinationAddImage(gifDest, red, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 0.005]] as CFDictionary)
        CGImageDestinationAddImage(gifDest, blue, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 0.05]] as CFDictionary)
        #expect(CGImageDestinationFinalize(gifDest))

        let gif = try #require(RecordingOverlayImage(url: gifURL, cache: cache))
        #expect(abs(gif.loopDuration - 0.15) < 0.01)

        // Direct delay parsing across GIF, APNG, WebP, and HEIC metadata dictionaries.
        #expect(RecordingOverlayImage.delay(from: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 0.01]]) == 0.1)
        #expect(RecordingOverlayImage.delay(from: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 0.02]]) == 0.02)
        #expect(RecordingOverlayImage.delay(from: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGUnclampedDelayTime: 0.01]]) == 0.01)
        #expect(RecordingOverlayImage.delay(from: [kCGImagePropertyWebPDictionary: [kCGImagePropertyWebPUnclampedDelayTime: 0.01]]) == 0.01)
        #expect(RecordingOverlayImage.delay(from: [kCGImagePropertyWebPDictionary: [kCGImagePropertyWebPDelayTime: 0.025]]) == 0.025)
        #expect(RecordingOverlayImage.delay(from: [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSUnclampedDelayTime: 0.01]]) == 0.01)
        #expect(RecordingOverlayImage.delay(from: [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSDelayTime: 0.033]]) == 0.033)
        // Missing or invalid delays fall back to 0.1s.
        #expect(RecordingOverlayImage.delay(from: [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSUnclampedDelayTime: 0.0]]) == 0.1)
        #expect(RecordingOverlayImage.delay(from: [kCGImagePropertyWebPDictionary: [kCGImagePropertyWebPUnclampedDelayTime: Double.nan]]) == 0.1)
        #expect(RecordingOverlayImage.delay(from: [:]) == 0.1)
    }

    // MARK: - Accessible canvas position and bounds actions

    @Test func accessibleOverlayGeometryStepsClampCleanlyAndStayValid() throws {
        var text = RecordingTextOverlay(start: 0, end: 2)
        text.center = CGPoint(x: 0.98, y: 0.02)
        let movedText = text.nudged(dx: 0.05, dy: -0.05)
        #expect(movedText.center == CGPoint(x: 1, y: 0))

        var image = RecordingImageOverlay(fileName: "a.png", displayName: "a", start: 0, end: 2)
        image.center = CGPoint(x: 0.5, y: 0.5)
        image.width = 0.04
        #expect(image.nudged(dx: -0.05, dy: 0.05).center == CGPoint(x: 0.45, y: 0.55))
        #expect(image.scaled(by: -0.05).width == RecordingImageOverlay.widthRange.lowerBound)
        #expect(image.scaled(by: 2.0).width == RecordingImageOverlay.widthRange.upperBound)

        let redaction = RecordingRedaction(start: 0, end: 2, rect: CGRect(x: 0.8, y: 0.8, width: 0.15, height: 0.15))
        let movedRedaction = redaction.nudged(dx: 0.2, dy: 0.2)
        #expect(abs(movedRedaction.rect.maxX - 1.0) < 0.0001)
        #expect(abs(movedRedaction.rect.maxY - 1.0) < 0.0001)
        try movedRedaction.validate(sourceDuration: 5)

        let widened = movedRedaction.resized(dWidth: 0.1, dHeight: 0.05)
        #expect(abs(widened.rect.width - 0.25) < 0.0001)
        #expect(abs(widened.rect.height - 0.20) < 0.0001)
        #expect(widened.rect.maxX <= 1.0 + 0.0001 && widened.rect.maxY <= 1.0 + 0.0001)
        try widened.validate(sourceDuration: 5)

        let narrowed = redaction.resized(dWidth: -0.5, dHeight: -0.5)
        #expect(abs(narrowed.rect.width - RecordingRedaction.minimumSide) < 0.0001)
        #expect(abs(narrowed.rect.height - RecordingRedaction.minimumSide) < 0.0001)
        try narrowed.validate(sourceDuration: 5)
    }

    @Test func accessiblePercentNeverTrapsOnHugeOrNonFiniteDecodedValues() throws {
        #expect(studioAccessiblePercent(0.345) == "35%")
        #expect(studioAccessiblePercent(0) == "0%")
        #expect(studioAccessiblePercent(1.0) == "100%")
        #expect(studioAccessiblePercent(1e20) == "10000%")
        #expect(studioAccessiblePercent(-1e20) == "-10000%")
        #expect(studioAccessiblePercent(.infinity) == "0%")
        #expect(studioAccessiblePercent(-.infinity) == "0%")
        #expect(studioAccessiblePercent(.nan) == "0%")

        let damagedJSON = """
        {
            "fileName": "logo.png",
            "displayName": "Logo",
            "start": 0,
            "end": 2,
            "center": [1e30, -1e30],
            "width": 1e20,
            "aspect": 1.0
        }
        """
        let decoded = try JSONDecoder().decode(RecordingImageOverlay.self, from: Data(damagedJSON.utf8))
        #expect(RecordingImageOverlay.widthRange.contains(decoded.width))
        #expect(studioAccessiblePercent(decoded.width) == "150%")
        #expect(studioAccessiblePercent(decoded.center.x) == "100%")
        #expect(studioAccessiblePercent(decoded.center.y) == "0%")
    }

    // MARK: - Source-time placement across cuts and speed ramps

    @Test func textAndImageBlocksMapAcrossCutsAndSpeedRamps() {
        // Source 0..10s with 4..6s deleted, and 0..4s playing at 2x (editor 0..2s)
        // followed by 6..10s playing at 1x (editor 2..6s).
        let timeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 4, speed: 2),
            RecordingClipSegment(sourceStart: 6, sourceEnd: 10, speed: 1)
        ])

        // Text spanning the deleted cut (source 2..8s):
        // slice 1 = source 2..4 -> editor 1..2
        // slice 2 = source 6..8 -> editor 2..4
        // Touching slices merge into one editor block 1..4s.
        let spanningText = RecordingTextOverlay(start: 2, end: 8)
        let hiddenText = RecordingTextOverlay(start: 4.2, end: 5.8)
        let textBlocks = RecordingOverlayTimelineBlock.blocks(
            for: [spanningText, hiddenText],
            clipTimeline: timeline
        ) { ($0.start, $0.end) }
        #expect(textBlocks.count == 1)
        #expect(textBlocks[0].id == spanningText.id)
        #expect(abs(textBlocks[0].editorStart - 1.0) < 0.0001)
        #expect(abs(textBlocks[0].editorEnd - 4.0) < 0.0001)

        // Image entirely inside the 2x clip (source 1..3s -> editor 0.5..1.5s).
        let fastImage = RecordingImageOverlay(fileName: "a.png", displayName: "a", start: 1, end: 3)
        let cutImage = RecordingImageOverlay(fileName: "b.png", displayName: "b", start: 4.5, end: 5.5)
        let imageBlocks = RecordingOverlayTimelineBlock.blocks(
            for: [fastImage, cutImage],
            clipTimeline: timeline
        ) { ($0.start, $0.end) }
        #expect(imageBlocks.count == 1)
        #expect(imageBlocks[0].id == fastImage.id)
        #expect(abs(imageBlocks[0].editorStart - 0.5) < 0.0001)
        #expect(abs(imageBlocks[0].editorEnd - 1.5) < 0.0001)

        // Moving a 1s editor-length block from the 2x clip onto the 1x clip keeps
        // its 1s editor length (covers 1s of source on the 1x clip).
        let moved = studioMovedSourceRange(clipTimeline: timeline, editorStart: 3.0, editorLength: 1.0)
        #expect(abs(moved.start - 7.0) < 0.0001)
        #expect(abs(moved.end - 8.0) < 0.0001)
    }

    @Test func insertingAtTailTrimmedEndClampsIntoKeptFootage() throws {
        // 10s recording trimmed to source 0...5s, playhead at edited end (5.0s).
        let trimmed = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 5, speed: 1)
        ])
        let textRange = try #require(trimmed.insertionSourceRange(
            atEditorTime: trimmed.duration,
            length: RecordingTextOverlay.defaultDuration,
            minimum: RecordingTextOverlay.minimumDuration
        ))
        #expect(textRange.lowerBound >= 0)
        #expect(textRange.upperBound <= 5)
        #expect(abs((textRange.upperBound - textRange.lowerBound) - RecordingTextOverlay.minimumDuration) < 0.0001)

        let text = RecordingTextOverlay(start: textRange.lowerBound, end: textRange.upperBound)
        let blocks = RecordingOverlayTimelineBlock.blocks(for: [text], clipTimeline: trimmed) { ($0.start, $0.end) }
        #expect(blocks.count == 1)
        #expect(blocks[0].editorEnd > blocks[0].editorStart)

        // Multi-segment timeline with a cut and trimmed tail (0...3, 6...8), playhead at edited end (5.0s).
        let multi = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 3, speed: 1),
            RecordingClipSegment(sourceStart: 6, sourceEnd: 8, speed: 1)
        ])
        let imageRange = try #require(multi.insertionSourceRange(
            atEditorTime: multi.duration,
            length: RecordingImageOverlay.defaultDuration,
            minimum: RecordingImageOverlay.minimumDuration
        ))
        #expect(imageRange.lowerBound >= 6)
        #expect(imageRange.upperBound <= 8)
        #expect(multi.editorSpan(overlapping: imageRange.lowerBound, sourceEnd: imageRange.upperBound) != nil)
    }

    @Test func addRedactionKeepsOriginalSourceEndBeforeAndAfterRestoringCut() throws {
        let sourceDuration: TimeInterval = 10
        let trimmed = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 5, speed: 1)
        ])
        let restored = RecordingClipTimeline.full(sourceDuration: sourceDuration)
        let frame = 1.0 / 30.0

        // Add Redaction at source 2 while trimmed to 0...5 keeps source end 10.
        let midRange = try #require(trimmed.redactionCoverageSourceRange(
            atEditorTime: 2.0,
            sourceDuration: sourceDuration,
            minimum: RecordingRedaction.minimumDuration
        ))
        #expect(abs(midRange.lowerBound - 2.0) < 0.0001)
        #expect(abs(midRange.upperBound - 10.0) < 0.0001)

        let midRedaction = RecordingRedaction(start: midRange.lowerBound, end: midRange.upperBound)
        try midRedaction.validate(sourceDuration: sourceDuration)
        // Before restoring the cut: covers trimmed playback [2..5).
        #expect(midRedaction.covers(editorTime: 2.5, frameDuration: frame, timeline: trimmed))
        let trimmedBlocks = RecordingOverlayTimelineBlock.blocks(for: [midRedaction], clipTimeline: trimmed) { ($0.start, $0.end) }
        #expect(trimmedBlocks.count == 1)
        #expect(abs(trimmedBlocks[0].editorStart - 2.0) < 0.0001)
        #expect(abs(trimmedBlocks[0].editorEnd - 5.0) < 0.0001)

        // After restoring the cut: tail frames [5..10) remain redacted.
        #expect(midRedaction.covers(editorTime: 5.5, frameDuration: frame, timeline: restored))
        #expect(midRedaction.covers(editorTime: 9.9, frameDuration: frame, timeline: restored))
        let restoredBlocks = RecordingOverlayTimelineBlock.blocks(for: [midRedaction], clipTimeline: restored) { ($0.start, $0.end) }
        #expect(restoredBlocks.count == 1)
        #expect(abs(restoredBlocks[0].editorStart - 2.0) < 0.0001)
        #expect(abs(restoredBlocks[0].editorEnd - 10.0) < 0.0001)

        // Add Redaction at the tail-trimmed end (5.0) still starts inside kept footage (4.9)
        // AND keeps original source end (10.0) after restoring the cut.
        let endRange = try #require(trimmed.redactionCoverageSourceRange(
            atEditorTime: trimmed.duration,
            sourceDuration: sourceDuration,
            minimum: RecordingRedaction.minimumDuration
        ))
        #expect(abs(endRange.lowerBound - 4.9) < 0.0001)
        #expect(abs(endRange.upperBound - 10.0) < 0.0001)
        let endRedaction = RecordingRedaction(start: endRange.lowerBound, end: endRange.upperBound)
        #expect(endRedaction.covers(editorTime: 4.95, frameDuration: frame, timeline: trimmed))
        #expect(endRedaction.covers(editorTime: 8.0, frameDuration: frame, timeline: restored))
    }

    // MARK: - Preview vs Export pixel comparison (including animated GIF + Text)

    @Test func previewAndExportRenderMatchingFramesForTextAndAnimatedGIF() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioTracksTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Build a 2-frame animated GIF: frame 0 solid red (0.1s), frame 1 solid blue (0.1s).
        let gifURL = tempDir.appendingPathComponent("anim.gif")
        try writeTwoFrameAnimatedGIF(to: gifURL)
        let decodedGIF = try #require(RecordingOverlayImage(url: gifURL))
        #expect(decodedGIF.isAnimated)
        #expect(decodedGIF.frameCount == 2)
        #expect(abs(decodedGIF.loopDuration - 0.2) < 0.02)

        var imageOverlay = RecordingImageOverlay(fileName: "anim.gif", displayName: "anim", start: 0, end: 5)
        imageOverlay.center = CGPoint(x: 0.5, y: 0.5)
        imageOverlay.width = 0.5
        imageOverlay.aspect = 1
        imageOverlay.cornerRadius = 16
        imageOverlay.rotation = 10
        imageOverlay.fadeIn = 0.2

        var textOverlay = RecordingTextOverlay(start: 0, end: 5)
        textOverlay.text = "Hello\nStudio"
        textOverlay.font = .sans
        textOverlay.fontSize = 0.12
        textOverlay.hasBackground = true
        textOverlay.backgroundColor = RecordingOverlayColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.8)
        textOverlay.animationIn = RecordingTextAnimation(effect: .fade, duration: 0.4, unit: .words, order: .forward, delay: 0.05, ease: .out)

        let size = CGSize(width: 320, height: 180)

        // Warm both frames into cache so preview and export compare the exact same frames.
        _ = decodedGIF.frame(at: 0.05)
        _ = decodedGIF.frame(at: 0.15)

        for sampleTime in [0.05, 0.15, 1.0] {
            // Preview path: top-down canvas coordinates (matching SwiftUI Canvas).
            let previewBytes = try renderPixels(size: size, flipForExport: false) { ctx in
                RecordingImageOverlayRenderer.drawForPreview(imageOverlay, image: decodedGIF, atSourceTime: sampleTime, canvasSize: size, in: ctx)
                RecordingTextOverlayRenderer.draw(textOverlay, atSourceTime: sampleTime, canvasSize: size, in: ctx)
            }
            // Exporter path: bottom-up CGContext flipped top-down identically to
            // StudioFrameCompositor.drawImageOverlays / drawTextOverlays.
            let exportBytes = try renderPixels(size: size, flipForExport: true) { ctx in
                ctx.saveGState()
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
                try RecordingImageOverlayRenderer.drawForExport(imageOverlay, image: decodedGIF, atSourceTime: sampleTime, canvasSize: size, in: ctx)
                ctx.restoreGState()

                ctx.saveGState()
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
                RecordingTextOverlayRenderer.draw(textOverlay, atSourceTime: sampleTime, canvasSize: size, in: ctx)
                ctx.restoreGState()
            }

            #expect(previewBytes == exportBytes, "Preview and exporter frames diverged at t=\(sampleTime)")
            // Verify non-empty drawing occurred.
            #expect(previewBytes.contains { $0 != 0 })
        }

        // Verify the animated GIF actually advances from frame 0 (red) to frame 1 (blue).
        let frame0 = try renderPixels(size: size, flipForExport: false) { ctx in
            try RecordingImageOverlayRenderer.drawForExport(imageOverlay, image: decodedGIF, atSourceTime: 0.25, canvasSize: size, in: ctx)
        }
        let frame1 = try renderPixels(size: size, flipForExport: false) { ctx in
            try RecordingImageOverlayRenderer.drawForExport(imageOverlay, image: decodedGIF, atSourceTime: 0.35, canvasSize: size, in: ctx)
        }
        #expect(frame0 != frame1)
    }

    // MARK: - Helpers

    private func renderPixels(
        size: CGSize,
        flipForExport: Bool,
        draw: (CGContext) throws -> Void
    ) throws -> Data {
        let width = Int(size.width)
        let height = Int(size.height)
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        if !flipForExport {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        try draw(context)
        let ptr = try #require(context.data)
        return Data(bytes: ptr, count: bytesPerRow * height)
    }

    private func writeTwoFrameAnimatedGIF(to url: URL) throws {
        try writeAnimatedGIF(to: url, frameCount: 2, width: 64, height: 64, delay: 0.1)
    }

    private func writeAnimatedGIF(to url: URL, frameCount: Int, width: Int, height: Int, delay: Double) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil))
        let gifProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(dest, gifProps as CFDictionary)
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay]
        ]
        for index in 0..<frameCount {
            let r = UInt8((index * 53 + 30) % 256)
            let g = UInt8((index * 97 + 60) % 256)
            let b = UInt8((index * 131 + 90) % 256)
            let img = try solidImage(width: width, height: height, r: r, g: g, b: b)
            CGImageDestinationAddImage(dest, img, frameProps as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(dest))
    }

    private func writeSolidPNG(to url: URL, width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws {
        let img = try solidImage(width: width, height: height, r: r, g: g, b: b)
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    private func solidImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = 255
        }
        let ctx = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(ctx.makeImage())
    }

    private func writeCheckerboardMovie(
        to url: URL,
        width: Int,
        height: Int,
        fps: Int,
        frameCount: Int
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let pool = try #require(adaptor.pixelBufferPool)
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            var rawBuffer: CVPixelBuffer?
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &rawBuffer) == kCVReturnSuccess)
            let buffer = try #require(rawBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bpr = CVPixelBufferGetBytesPerRow(buffer)
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let inside = x >= width / 4 && x < width * 3 / 4 && y >= height / 4 && y < height * 3 / 4
                        let v: UInt8 = inside ? ((((x / 2) + (y / 2)) % 2 == 0) ? 255 : 0) : 128
                        let offset = y * bpr + x * 4
                        ptr[offset] = v; ptr[offset + 1] = v; ptr[offset + 2] = v; ptr[offset + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    private func exportRedactedMovie(
        from sourceURL: URL,
        to destinationURL: URL,
        redactions: [RecordingRedaction],
        timeline: RecordingClipTimeline,
        width: Int,
        height: Int,
        fps: Int
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        #expect(reader.startReading())

        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: [.useSoftwareRenderer: true])
        let frameInterval = 1.0 / Double(fps)
        while let sample = output.copyNextSampleBuffer() {
            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let active = redactions.filter {
                $0.covers(editorTime: pts.seconds, frameDuration: frameInterval, timeline: timeline)
            }
            let filtered = try RecordingRedactionFilter.buffer(from: sourceBuffer, redactions: active, context: ciContext)
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(adaptor.append(filtered, withPresentationTime: pts))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    private func patchLuminanceRange(in image: CGImage, x: Int, y: Int, size: Int) throws -> Int {
        let width = image.width, height = image.height
        let bpr = width * 4
        var bytes = [UInt8](repeating: 0, count: bpr * height)
        let ctx = try #require(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minV = 255, maxV = 0
        for py in y..<min(y + size, height) {
            for px in x..<min(x + size, width) {
                let v = Int(bytes[py * bpr + px * 4])
                if v < minV { minV = v }
                if v > maxV { maxV = v }
            }
        }
        return maxV - minV
    }
}
