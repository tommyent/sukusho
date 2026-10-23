import AVFoundation
import AppKit
import CoreVideo
import Darwin

// Run with check-video-ink.py and the Dev DerivedData path. No windows or live services.
// Draw while recording (sd-5mg.3): strokes from input.json reach Studio's model and the
// exported pixels through the zoom, held source frames, both screen renderers and Studio
// deletes.
@main
struct VideoInkChecks {
    enum Failure: Error { case check(String) }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.check(message) }
    }

    static let width = 384, height = 216

    /// A flat grey movie with sparse samples, so the screen layer is held and reused.
    /// The one at 0.8 s lands mid-stroke: the held layer is captured again with ink on screen.
    static func movie(at url: URL, duration: Double = 3) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        try check(writer.startWriting(), "Fixture writer start")
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        try check(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
                  "Fixture allocation")
        guard let buffer else { throw Failure.check("Fixture buffer missing") }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 128, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for time in [0.0, 0.8, duration - 0.1] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            try check(adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)), "Fixture append")
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        try check(writer.status == .completed, "Fixture writer finish")
    }

    static func image(_ url: URL, time: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    /// Red minus green at a top-left normalized point: about 0 on grey, large on the marker.
    static func redness(_ image: CGImage, x: Double, y: Double) -> Int {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let index = Int(y * Double(image.height)) * context.bytesPerRow + Int(x * Double(image.width)) * 4
        return Int(bytes[index]) - Int(bytes[index + 1])
    }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let home = ProcessInfo.processInfo.environment["F3_FIXTURE_HOME"] ?? ""
        let isolated = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        let actualHome = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let support = ScreendropStorage.applicationSupportDirectory.resolvingSymlinksInPath().path
        try check(actualHome == isolated && support.hasPrefix(isolated + "/")
                  && home.hasPrefix("/private/tmp/"), "Foundation storage is not isolated: \(actualHome), \(support)")
        NSApplication.shared.setActivationPolicy(.prohibited)

        let root = URL(fileURLWithPath: home).appendingPathComponent("fixture.screendroprec")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = RecordingSession(directoryURL: root)
        try await movie(at: session.screenURL)
        var manifest = CaptureManifest()
        manifest.duration = 3; manifest.pixelWidth = width; manifest.pixelHeight = height
        manifest.pointerSynthesized = true; manifest.pressEffectsBaked = false
        try session.writeCaptureManifest(manifest)

        // One horizontal stroke across the middle, drawn from 0.5 s to 1 s, hidden at 2 s.
        let stroke = RecordingInkStroke(
            width: 0.04,
            points: (0...5).map { RecordingInkPoint(t: 0.5 + Double($0) * 0.1, x: 0.3125 + Double($0) * 0.025, y: 0.5) },
            hideTime: 2
        )
        var capture = PointerCaptureFile()
        capture.ink = [stroke]
        try session.writePointerCapture(capture)

        // A fixed 2x zoom on the centre for the whole take, with no ease.
        let style = RecordingStudioStyle(background: .none, padding: 0, cornerRadius: 0, shadow: 0,
                                         camera: RecordingCameraBubbleSettings(isVisible: false))
        let zoom = ZoomCue(start: 0, end: 3, zoom: 2, anchorMode: .pinnedAnchor, skipsEasing: true)
        var settings = VideoCompressionSettings()
        settings.codec = .h264; settings.removeAudio = true; settings.frameRate = .fps30
        let document = RecordingEditDocument(style: style, zoomEnabled: true, zoomCues: [zoom],
                                             clipTimeline: .full(sourceDuration: 3), exportSettings: settings)
        try session.writeEditDocument(document)

        // Older edit documents and new ones with the pen left on encode alike.
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as! [String: Any]
        try check(encoded["showsInk"] == nil && encoded["hiddenInkStrokeIDs"] == nil, "Default ink settings were written")

        let editor = RecordingStudioModel(url: root)
        await editor.load()
        try check(editor.isLoaded, "Editor load: \(editor.loadError ?? "")")
        try check(editor.hasInk && editor.inkStrokes.map(\.id) == [stroke.id], "Studio lost the stroke")
        try check(editor.inkFrames(at: 0.25).isEmpty, "Stroke before it was drawn")
        try check(editor.inkFrames(at: 0.75).first?.pointCount == 3, "Studio prefix at 0.75 s")
        let opened = editor.currentDocument()
        try check(opened.showsInk == nil && opened.hiddenInkStrokeIDs == nil, "Opening Studio wrote ink settings")
        editor.deleteInkStroke(stroke.id)
        try check(editor.inkFrames(at: 1.5).isEmpty && editor.currentDocument().hiddenInkStrokeIDs == [stroke.id],
                  "Delete did not hide the stroke")
        try check(editor.currentDocument() != opened, "Delete left the render stamp matching")
        editor.undo()
        try check(editor.inkFrames(at: 1.5).count == 1 && editor.currentDocument() == opened, "Undo delete")
        editor.showsInk = false
        try check(editor.inkFrames(at: 1.5).isEmpty && editor.currentDocument().showsInk == false, "Show drawings off")
        try check((try editor.makeExportConfiguration()).ink == nil, "Studio export kept hidden drawings")
        editor.showsInk = true
        try check((try editor.makeExportConfiguration()).ink?.strokes.map(\.id) == [stroke.id], "Studio export lost the stroke")
        editor.teardown()
        try session.writeEditDocument(document)
        session.removeDraftDocument()
        print("PASS Studio model: prefix, delete/undo, Show drawings, document defaults")

        // Canvas = source (no background), so a source x maps to 0.5 + 2 (x - 0.5).
        var configuration = try await RecordingSessionRenderer.makeConfiguration(for: session)
        try check(configuration.ink?.strokes.map(\.id) == [stroke.id], "Library/share configuration lost the stroke")
        for renderer in ["cpu", "metal"] {
            setenv("SCREENDROP_EXPORT_RENDERER", renderer, 1)
            configuration.exportSettings.container = renderer == "cpu" ? .mov : .mp4
            let output = try await RecordingStudioExporter().export(configuration) { _ in }
            let before = try await image(output, time: 0.25)
            try check(abs(redness(before, x: 0.1875, y: 0.5)) < 25, "\(renderer): ink before the stroke")
            let drawing = try await image(output, time: 0.75)
            try check(redness(drawing, x: 0.1875, y: 0.5) > 120, "\(renderer): drawn part missing at 0.75 s")
            try check(abs(redness(drawing, x: 0.34, y: 0.5)) < 25, "\(renderer): undrawn part showing at 0.75 s")
            try check(redness(drawing, x: 0.1875, y: 0.525) > 120, "\(renderer): stroke narrower than 0.04 at 2x")
            try check(abs(redness(drawing, x: 0.1875, y: 0.58)) < 25, "\(renderer): stroke wider than 0.04 at 2x")
            let drawn = try await image(output, time: 1.5)
            try check(redness(drawn, x: 0.34, y: 0.5) > 120, "\(renderer): full stroke missing at 1.5 s")
            let fading = try await image(output, time: 2.25)
            let half = redness(fading, x: 0.25, y: 0.5)
            try check(half > 40 && half < 120, "\(renderer): fade at 2.25 s is \(half)")
            let gone = try await image(output, time: 2.75)
            try check(abs(redness(gone, x: 0.25, y: 0.5)) < 25, "\(renderer): stroke after its fade")
            print("PASS \(renderer) export: absent before, drawn prefix, 2x zoom position and width, fade, gone")
        }
        unsetenv("SCREENDROP_EXPORT_RENDERER")

        var deleted = document
        deleted.hiddenInkStrokeIDs = [stroke.id]
        try session.writeEditDocument(deleted)
        session.removeDraftDocument()
        let hidden = try await RecordingSessionRenderer.makeConfiguration(for: session)
        try check(hidden.ink?.isEmpty ?? true, "Library/share configuration kept a deleted stroke")
        let output = try await RecordingStudioExporter().export(hidden) { _ in }
        let frame = try await image(output, time: 1.5)
        try check(abs(redness(frame, x: 0.34, y: 0.5)) < 25, "Deleted stroke exported")
        print("PASS deleted stroke stays out of Library/share renders")
    }
}
