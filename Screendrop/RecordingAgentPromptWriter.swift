import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum RecordingAgentPromptWriter {
    enum ExportError: LocalizedError {
        case invalidMovie
        case unavailableFrame(Double)
        case jpegFailed

        var errorDescription: String? {
            switch self {
            case .invalidMovie: "The rendered recording could not be read."
            case .unavailableFrame(let time): "No matching frame could be extracted at \(RecordingAgentPromptPlan.timestamp(time))."
            case .jpegFailed: "A recording still could not be saved."
            }
        }
    }

    /// `master` is the unedited screen recording; with it, each moment also
    /// gets a strip of frames around it. Stills come from the edited `movie`,
    /// or, with none, from the master, marked like the strips. The folder is
    /// named after `name` (the plan's title by default), and a later export of
    /// the same name replaces it.
    @concurrent
    static func write(movie: URL?, plan: RecordingAgentPromptPlan, to directory: URL, name: String? = nil, master: URL? = nil,
                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try Task.checkCancellation()
        var edited: (generator: AVAssetImageGenerator, duration: Double, frameDuration: Double)?
        if let movie {
            let asset = AVURLAsset(url: movie)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0,
                  let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.invalidMovie }
            let rate = try await track.load(.nominalFrameRate)
            let frameDuration = rate.isFinite && rate > 0 ? 1 / Double(rate) : 1 / 30
            guard abs(duration - plan.duration) <= max(frameDuration * 2, 0.1) else { throw ExportError.invalidMovie }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1920, height: 1920)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: frameDuration, preferredTimescale: 60_000)
            edited = (generator, duration, frameDuration)
        }
        defer { edited?.generator.cancelAllCGImageGeneration() }

        let staging = directory.appendingPathComponent(".agent-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let stills = staging.appendingPathComponent("stills", isDirectory: true)
        try FileManager.default.createDirectory(at: stills, withIntermediateDirectories: false)
        let strips = staging.appendingPathComponent("strips", isDirectory: true)
        // With an edited movie, a master that can't be read only costs the strips.
        var masterFrames: MasterFrames?
        if let master { masterFrames = await MasterFrames(url: master) }
        defer {
            masterFrames?.generator.cancelAllCGImageGeneration()
            masterFrames?.stillGenerator.cancelAllCGImageGeneration()
        }
        guard edited != nil || masterFrames != nil else { throw ExportError.invalidMovie }
        var frameTimes: [Double] = []
        var stripSpans: [ClosedRange<Double>?] = []
        for (index, moment) in plan.moments.enumerated() {
            try Task.checkCancellation()
            let image: CGImage
            if let edited {
                let requested = min(moment.time, max(0, edited.duration - edited.frameDuration))
                let frame = try await edited.generator.image(at: CMTime(seconds: requested, preferredTimescale: 60_000))
                let actual = frame.actualTime.seconds
                guard actual.isFinite, actual >= 0, actual < edited.duration,
                      abs(actual - requested) <= edited.frameDuration + 0.001 else { throw ExportError.unavailableFrame(moment.time) }
                image = frame.image
                frameTimes.append(actual)
            } else {
                guard let still = await masterFrames?.still(for: moment, plan: plan) else { throw ExportError.unavailableFrame(moment.time) }
                image = still
                frameTimes.append(moment.time)
            }
            try Task.checkCancellation()
            // With a strip beside it, the still needn't be near-lossless; this kept an 89 s, 26-moment export at 12 MB.
            try writeJPEG(image, to: stills.appendingPathComponent(RecordingAgentPromptPlan.stillName(index)), quality: 0.7)
            if let masterFrames, let strip = await masterFrames.strip(for: moment, plan: plan) {
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: strips, withIntermediateDirectories: true)
                // About 0.3 MB a strip with UI text still readable.
                try writeJPEG(strip.image, to: strips.appendingPathComponent(RecordingAgentPromptPlan.stillName(index)), quality: 0.5)
                stripSpans.append(strip.span)
            } else {
                stripSpans.append(nil)
            }
            progress(Double(index + 1) / Double(plan.moments.count))
        }
        try plan.markdown(frameTimes: frameTimes, strips: stripSpans, sourceStills: edited == nil)
            .write(to: staging.appendingPathComponent("prompt.md"), atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        let destination = directory.appendingPathComponent(folderName(name ?? plan.title), isDirectory: true)
        do {
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch CocoaError.fileWriteFileExists {
            // One folder per recording: the new export takes the old one's place in one step.
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        }
        return destination
    }

    static let folderSuffix = "_agent-prompt"

    static func folderName(_ name: String) -> String {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return String((safe.isEmpty || safe == "." || safe == ".." ? "Recording" : safe).prefix(100)) + folderSuffix
    }

    /// The recording ID a folder is named with: what follows its last "_". Folders
    /// named after the whole package ("Screendrop_…_20F562") end in the same ID.
    static func recordingID(ofFolder name: String) -> String? {
        guard name.hasSuffix(folderSuffix) else { return nil }
        let stem = name.dropLast(folderSuffix.count)
        return stem.lastIndex(of: "_").map { String(stem[stem.index(after: $0)...]) }
    }

    /// `~/Agent Prompts`, without creating it.
    static func directoryURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Agent Prompts", isDirectory: true)
    }

    /// `~/Agent Prompts`, where every export goes; owner-only, since prompts hold screen content.
    static func centralDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let directory = directoryURL(home: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // An existing folder may have been made with other permissions.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    /// The newest export, which Rex's Insert Sukusho Prompt action types into the focused pane.
    struct Latest: Codable, Equatable {
        var path: String
        var title: String
        var recording: String
        var time: Date
    }

    /// Writes `latest.json` beside `folder`, replacing it in one step so a reader never sees half a file.
    static func recordLatest(_ folder: URL, title: String, recording: String, time: Date = Date()) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(Latest(path: folder.path, title: title, recording: recording, time: time))
            .write(to: folder.deletingLastPathComponent().appendingPathComponent("latest.json"), options: .atomic)
    }

    private static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) throws {
        guard let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ExportError.jpegFailed
        }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw ExportError.jpegFailed }
    }

    /// Frames of the unedited screen recording: no zoom, crop or style, and no
    /// pointer, which the input log has instead.
    struct MasterFrames {
        let generator: AVAssetImageGenerator
        /// For whole-frame stills: decodes at most 1920 px, not a full 6K frame.
        let stillGenerator: AVAssetImageGenerator
        let size: CGSize

        init?(url: URL) async {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let natural = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform) else { return nil }
            let size = natural.applying(transform)
            guard size.width != 0, size.height != 0 else { return nil }
            self.size = CGSize(width: abs(size.width), height: abs(size.height))
            func exact(_ maximum: CGSize) -> AVAssetImageGenerator {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = maximum
                // Exactly the frame on screen at each time; any tolerance lets a keyframe from earlier stand in.
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                return generator
            }
            generator = exact(.zero)
            stillGenerator = exact(CGSize(width: 1920, height: 1920))
        }

        /// A 4-column grid of the moment's strip times, each cropped to 720 × 450 pt
        /// of a 2x screen around the moment's focus and drawn at half size, with the
        /// pointer ringed, the pen's strokes drawn in and the edited time in a corner.
        /// Nil if no frame came back.
        func strip(for moment: RecordingAgentPromptPlan.Moment, plan: RecordingAgentPromptPlan) async
            -> (image: CGImage, span: ClosedRange<Double>)? {
            let times = plan.stripTimes(for: moment)
            guard let first = times.first, let last = times.last else { return nil }
            let cropSize = CGSize(width: min(size.width, 1440), height: min(size.height, 900))
            let focus = moment.focus ?? CGPoint(x: 0.5, y: 0.5)
            let crop = CGRect(x: min(max(focus.x * size.width - cropSize.width / 2, 0), size.width - cropSize.width),
                              y: min(max(focus.y * size.height - cropSize.height / 2, 0), size.height - cropSize.height),
                              width: cropSize.width, height: cropSize.height).integral
            let scale = min(1, 720 / crop.width)
            let cell = CGSize(width: (crop.width * scale).rounded(), height: (crop.height * scale).rounded())
            let columns = min(4, times.count), rows = (times.count + columns - 1) / columns
            guard let context = CGContext(data: nil, width: Int(cell.width) * columns, height: Int(cell.height) * rows,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            let ink = RecordingInkTimeline(strokes: plan.ink)
            var drewFrame = false
            for (index, time) in times.enumerated() {
                // Rows run top to bottom; Core Graphics counts from the bottom.
                let cellRect = CGRect(x: CGFloat(index % columns) * cell.width,
                                      y: CGFloat(rows - 1 - index / columns) * cell.height,
                                      width: cell.width, height: cell.height)
                let source = plan.timeline.sourceTime(at: time)
                if let frame = try? await generator.image(at: CMTime(seconds: source, preferredTimescale: 60_000)).image,
                   let cropped = frame.cropping(to: crop) {
                    context.draw(cropped, in: cellRect)
                    drewFrame = true
                }
                drawMarks(at: source, crop: crop, scale: scale, in: cellRect, ink: ink, plan: plan, context: context)
                Self.label(RecordingAgentPromptPlan.timestamp(time), in: cellRect, context: context)
                context.setStrokeColor(CGColor(gray: 1, alpha: 1))
                context.setLineWidth(2)
                context.stroke(cellRect)
            }
            guard drewFrame, let image = context.makeImage() else { return nil }
            return (image, first...last)
        }

        /// The whole frame at a moment, at most 1920 px on its long side, marked like a strip.
        func still(for moment: RecordingAgentPromptPlan.Moment, plan: RecordingAgentPromptPlan) async -> CGImage? {
            let source = plan.timeline.sourceTime(at: moment.time)
            guard let frame = try? await stillGenerator.image(at: CMTime(seconds: source, preferredTimescale: 60_000)).image else { return nil }
            let scale = min(1, 1920 / max(size.width, size.height))
            let rect = CGRect(x: 0, y: 0, width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            guard let context = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(frame, in: rect)
            drawMarks(at: source, crop: CGRect(origin: .zero, size: size), scale: scale, in: rect,
                      ink: RecordingInkTimeline(strokes: plan.ink), plan: plan, context: context)
            return context.makeImage()
        }

        /// The pen's strokes as far as drawn and as faded, as Studio shows them, then the pointer's ring,
        /// for the part of the frame in `crop` drawn into `cell` at `scale`.
        private func drawMarks(at source: Double, crop: CGRect, scale: CGFloat, in cell: CGRect, ink: RecordingInkTimeline,
                               plan: RecordingAgentPromptPlan, context: CGContext) {
            for frame in ink.frames(at: source) {
                let points = frame.points.map { CGPoint(x: cell.minX + ($0.x * size.width - crop.minX) * scale,
                                                        y: cell.maxY - ($0.y * size.height - crop.minY) * scale) }
                context.saveGState()
                context.clip(to: cell)
                RecordingInkPath.stroke(RecordingInkPath.path(points), color: frame.stroke.color, opacity: frame.opacity,
                                        width: frame.stroke.width * min(size.width, size.height) * scale, in: context)
                context.restoreGState()
            }
            guard let pointer = RecordingAgentPromptPlan.pointerPosition(in: plan.pointer, at: source) else { return }
            let x = pointer.x * size.width - crop.minX, y = pointer.y * size.height - crop.minY
            guard (0..<crop.width).contains(x), (0..<crop.height).contains(y) else { return }
            let ring = CGRect(x: cell.minX + x * scale - 9, y: cell.maxY - y * scale - 9, width: 18, height: 18)
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.setLineWidth(5)
            context.strokeEllipse(in: ring)
            context.setStrokeColor(CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1))
            context.setLineWidth(2.5)
            context.strokeEllipse(in: ring)
        }

        private static func label(_ text: String, in cell: CGRect, context: CGContext) {
            let size = max(9, (cell.height * 0.045).rounded())
            let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ]))
            let bounds = CTLineGetTypographicBounds(line, nil, nil, nil)
            let box = CGRect(x: cell.minX + 4, y: cell.maxY - 4 - size * 1.4, width: bounds + size * 0.8, height: size * 1.4)
            context.setFillColor(CGColor(gray: 0, alpha: 0.65))
            context.fill(box)
            context.textPosition = CGPoint(x: box.minX + size * 0.4, y: box.minY + size * 0.35)
            CTLineDraw(line, context)
        }
    }
}
