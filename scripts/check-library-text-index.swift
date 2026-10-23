import AppKit
import AVFoundation
import CoreText
import Foundation

// Run with check-editor-idle-save.py against the actual app sources and an isolated home.
// It reads real text with Vision, so run it on a Mac where Vision works (not the VMPal VM).
@main
struct LibraryTextIndexChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }

    static func require<T>(_ value: T?, _ message: String = "Missing value") throws -> T {
        guard let value else { throw Failure(description: message) }
        return value
    }

    static func waitUntil(_ what: String, timeout: Duration = .seconds(120), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure(description: "Timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    static func draw(_ lines: [String], in context: CGContext, width: Int, height: Int) {
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (row, text) in lines.enumerated() {
            let string = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 40, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 80, y: CGFloat(height) - 120 - CGFloat(row) * 52)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
    }

    static func writePNG(_ lines: [String], to url: URL) throws {
        let context = CGContext(data: nil, width: 1600, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(lines, in: context, width: 1600, height: 900)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try check(CGImageDestinationFinalize(destination), "PNG fixture failed")
    }

    /// Eight seconds of 1280×720: one line of text, then another from 3 s.
    static func movie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280, AVVideoHeightKey: 720,
        ])
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: .init(rawValue: kCVPixelFormatType_32ARGB),
                                                         size: .init(width: 1280, height: 720))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<80 {
            var pixels = try CVMutablePixelBuffer(attributes)
            try pixels.accessUnsafeMutableRawPlaneBytes { planes in
                guard let plane = planes.first,
                      let context = CGContext(data: plane.bytes.baseAddress, width: 1280, height: 720,
                        bitsPerComponent: 8, bytesPerRow: plane.properties.bytesPerRow,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
                else { throw Failure(description: "Cannot create fixture pixels") }
                draw([frame < 30 ? "Okavango delta itinerary" : "Masai Mara checklist"], in: context, width: 1280, height: 720)
            }
            try await receiver.append(CVReadOnlyPixelBuffer(pixels), with: CMTime(value: Int64(frame), timescale: 10))
        }
        receiver.finish()
        writer.endSession(atSourceTime: CMTime(value: 8, timescale: 1))
        await writer.finishWriting()
        try check(writer.status == .completed, "Movie fixture failed: \(String(describing: writer.error))")
    }

    static func search(_ text: String, expect ids: [String]) async throws {
        let model = CaptureLibraryModel.shared
        model.searchText = text
        try await waitUntil("search \(text) shows \(ids)", timeout: .seconds(5)) { Set(model.visibleItems.map(\.id)) == Set(ids) }
        print("CHECK: search \"\(text)\" finds \(ids.count)")
        model.searchText = ""
    }

    static func main() async {
        do {
            try await run()
            print("PASS: Library text index")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        let support = ScreendropStorage.applicationSupportDirectory
        try check(support.path.contains("/tmp/screendrop-idle-save-"), "Storage is outside the temporary home: \(support.path)")
        let history = ScreenshotHistoryStore.shared
        let index = CaptureLibraryIndex.shared
        let store = CaptureTextIndexStore(directory: support.appendingPathComponent("Library Index", isDirectory: true))
        let scratch = support.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        index.start()

        // A screenshot is read (Vision is cold here), stored and found by its words.
        let started = ContinuousClock.now
        try writePNG(["Quarterly Zanzibar report", "The launch moved to November because the",
                      "supplier needs the new café menu."], to: scratch.appendingPathComponent("first.png"))
        let firstURL = history.importScreenshot(from: scratch.appendingPathComponent("first.png"))
        let firstID = try require(history.items.first).id.uuidString
        try await waitUntil("first screenshot read") { index.entries[firstID] != nil }
        let first = try require(index.entries[firstID])
        print("CHECK: read in \(ContinuousClock.now - started): \(first.paragraphs)")
        try check(first.paragraphs.contains { $0.contains("Zanzibar") }, "Screenshot text missing")
        try check(first.paragraphs.contains { $0.contains("November because the supplier") }, "Wrapped lines not joined")
        try check(store.loadAll()[firstID] == first, "Entry not saved to the Library Index folder")
        try await search("zanzibar", expect: [firstID])
        try await search("CAFE MENU", expect: [firstID])
        try await search("nowhere in it", expect: [])

        // Never recorded: no Recordings folder, yet a deleted capture still loses its text.
        try check(!FileManager.default.fileExists(atPath: RecordingSessionStore.recordingsDirectory.path), "Recordings folder exists already")
        try writePNG(["Temporary Lofoten note"], to: scratch.appendingPathComponent("temporary.png"))
        history.importScreenshot(from: scratch.appendingPathComponent("temporary.png"))
        let temporary = try require(history.items.first)
        let temporaryID = temporary.id.uuidString
        try await waitUntil("temporary screenshot read") { index.entries[temporaryID] != nil }
        try FileManager.default.removeItem(at: temporary.url)
        history.removeTrashedItems(ids: [temporary.id])
        try await waitUntil("deleted capture's text removed before any recording") {
            index.entries[temporaryID] == nil && !FileManager.default.fileExists(atPath: store.url(for: temporaryID).path)
        }
        print("CHECK: a Library that never recorded clears a deleted capture's text")

        // An edited screenshot is read again.
        try writePNG(["Kilimanjaro shipping update"], to: firstURL)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: firstURL.path)
        CaptureLibraryModel.shared.refresh()
        try await waitUntil("edited screenshot read again") {
            index.entries[firstID]?.paragraphs.contains { $0.contains("Kilimanjaro") } == true
        }
        try check(!(index.entries[firstID]?.paragraphs.joined().contains("Zanzibar") ?? true), "Old text kept after an edit")
        try await search("zanzibar", expect: [])
        print("CHECK: edit re-read")

        // A recording: its frames and its saved captions.
        let session = try RecordingSessionStore.createSession()
        try await movie(at: session.screenURL)
        var manifest = CaptureManifest()
        manifest.duration = 8; manifest.pixelWidth = 1280; manifest.pixelHeight = 720
        try session.writeCaptureManifest(manifest)
        var document = RecordingEditDocument(style: RecordingStudioStyle(), zoomEnabled: false, zoomCues: [])
        document.subtitleCues = [RecordingSubtitleCue(start: 0, end: 2, text: "Welcome to the"),
                                 RecordingSubtitleCue(start: 2, end: 4, text: "Serengeti walkthrough")]
        try session.writeEditDocument(document)
        await history.importRecordingSession(session)
        let recordingID = "recording:\(session.directoryURL.standardizedFileURL.path)"
        try await waitUntil("recording read") { index.entries[recordingID] != nil }
        let recording = try require(index.entries[recordingID])
        print("CHECK: recording \(recording.paragraphs) transcript \(recording.transcript ?? "nil")")
        try check(recording.transcript == "Welcome to the Serengeti walkthrough", "Transcript missing")
        try check(recording.paragraphs.contains { $0.contains("Okavango") }, "First frame not read")
        try check(recording.paragraphs.contains { $0.contains("Masai") }, "Later frames not read")
        try check(recording.paragraphs.count == 2, "Repeated frame text not merged")
        try await search("serengeti walk", expect: [recordingID])
        try await search("masai mara", expect: [recordingID])
        // A tag, a rename or opening Studio rewrites project.json; the text stands.
        try session.updateProjectMetadata { $0.tags = ["demo"] }
        CaptureLibraryModel.shared.refresh()
        try await waitUntil("tag seen", timeout: .seconds(5)) {
            CaptureLibraryModel.shared.items.first { $0.id == recordingID }?.tags == ["demo"]
        }
        try check(!index.pendingIDs.contains(recordingID) && index.entries[recordingID] == recording,
                  "Touching project.json queued the recording to be read again")
        print("CHECK: project.json changes keep a recording's text")

        // Off stops reading and keeps the index; on again reads what was missed.
        UserDefaults.standard.set(false, forKey: ScreendropPreferences.libraryReadsTextKey)
        index.settingsDidChange()
        try writePNG(["Patagonia expenses"], to: scratch.appendingPathComponent("second.png"))
        history.importScreenshot(from: scratch.appendingPathComponent("second.png"))
        let secondID = try require(history.items.first).id.uuidString
        try await waitUntil("Library sees the second screenshot", timeout: .seconds(5)) {
            CaptureLibraryModel.shared.items.contains { $0.id == secondID }
        }
        try await Task.sleep(for: .seconds(3))
        try check(index.entries[secondID] == nil && index.pendingIDs.isEmpty, "Read while off")
        try await search("kilimanjaro", expect: [firstID])
        UserDefaults.standard.set(true, forKey: ScreendropPreferences.libraryReadsTextKey)
        index.settingsDidChange()
        try await waitUntil("second screenshot read once on") { index.entries[secondID] != nil }
        print("CHECK: switch off and on")

        // Deleting a capture removes its entry; an empty scan removes nothing.
        let second = try require(history.items.first { $0.id.uuidString == secondID })
        try FileManager.default.removeItem(at: second.url)
        history.removeTrashedItems(ids: [second.id])
        try await waitUntil("deleted capture's entry removed") {
            index.entries[secondID] == nil && !FileManager.default.fileExists(atPath: store.url(for: secondID).path)
        }
        index.sync([], isComplete: true)
        try await Task.sleep(for: .milliseconds(500))
        try check(index.entries[firstID] != nil && index.entries[recordingID] != nil, "An empty scan wiped the index")
        try check(store.loadAll().keys.sorted() == [firstID, recordingID].sorted(), "An empty scan removed index files")
        // History or the Recordings folder read in part: nothing missing is removed.
        index.sync(CaptureLibraryModel.shared.items.filter { $0.id != firstID }, isComplete: false)
        try await Task.sleep(for: .milliseconds(500))
        try check(index.entries[firstID] != nil && FileManager.default.fileExists(atPath: store.url(for: firstID).path),
                  "A partial scan removed an entry")
        CaptureLibraryModel.shared.refresh()
        print("CHECK: delete, empty scan and partial scan")
    }
}
