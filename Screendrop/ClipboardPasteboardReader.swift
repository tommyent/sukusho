import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// One copy, read off the pasteboard and ready to store.
nonisolated struct ClipboardCapture: Sendable, Equatable {
    var kind: ClipboardEntryKind
    /// SHA-256 of the main content, for de-duplication.
    var hash: String
    /// The text as copied (links and colours included), or a files copy's paths, one per line.
    var text: String?
    /// Bytes to keep; nil for a Sukusho capture, which stays in the Library.
    var image: Data?
    var imageExtension: String?
    var libraryPath: String?
    var pixelWidth = 0
    var pixelHeight = 0
    /// The copy's size as shown to the user.
    var byteSize = 0
    /// RTF and HTML, kept so a paste from history keeps its formatting.
    var richText: [String: Data] = [:]
    var sourceBundleID: String?
    var isRemote = false

    /// What this entry adds to the history folder and database.
    var storedBytes: Int {
        (image?.count ?? 0) + (text?.utf8.count ?? 0) + richText.values.reduce(0) { $0 + $1.count }
    }
}

/// Reads the pasteboard's first item into a `ClipboardCapture`. Runs off the
/// main thread: an app that promised data and then hangs only stalls this read.
nonisolated enum ClipboardPasteboardReader {
    enum Outcome: Equatable, Sendable {
        case captured(ClipboardCapture)
        case skipped(ClipboardCapturePolicy.Skip)
        /// The pasteboard changed while it was read; the next poll gets the new copy.
        case changed
    }

    /// - Parameters:
    ///   - changeCount: the count that was seen when the copy was noticed.
    ///   - frontmostBundleID: the app in front then, for copies without a source marker.
    static func read(
        _ pasteboard: NSPasteboard,
        changeCount: Int,
        frontmostBundleID: String?,
        ignoredApps: Set<String>,
        historyDirectory: URL
    ) -> (outcome: Outcome, types: [String]) {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        if let marker = ClipboardCapturePolicy.privateMarker(in: types) {
            return (.skipped(.privateType(marker)), types)
        }
        let marker = types.contains(ClipboardCapturePolicy.sourceType)
            ? pasteboard.string(forType: .init(ClipboardCapturePolicy.sourceType)) : nil
        let source = marker.flatMap { $0.isEmpty ? nil : $0 } ?? frontmostBundleID
        let outcome: Outcome
        switch ClipboardCapturePolicy.decide(types: types, sourceBundleID: source, ignoredApps: ignoredApps) {
        case .skip(let reason):
            outcome = .skipped(reason)
        case .read(let content):
            if var capture = capture(content, from: pasteboard, types: types, historyDirectory: historyDirectory) {
                capture.sourceBundleID = source
                capture.isRemote = types.contains(ClipboardCapturePolicy.remoteType)
                outcome = .captured(capture)
            } else {
                outcome = .skipped(.tooLarge)
            }
        }
        // A copy that replaced this one mid-read could have mixed two copies.
        return (pasteboard.changeCount == changeCount ? outcome : .changed, types)
    }

    private static func capture(
        _ content: ClipboardCapturePolicy.Content,
        from pasteboard: NSPasteboard,
        types: [String],
        historyDirectory: URL
    ) -> ClipboardCapture? {
        guard let item = pasteboard.pasteboardItems?.first else { return nil }
        switch content {
        case .files:
            let paths = (pasteboard.pasteboardItems ?? []).prefix(ClipboardCapturePolicy.maxFiles).compactMap { item -> String? in
                guard let raw = item.string(forType: .fileURL), let url = URL(string: raw) else { return nil }
                // Finder hands out file reference URLs (file:///.file/id=…); resolve them to paths.
                return ((url as NSURL).filePathURL ?? url).path
            }
            guard !paths.isEmpty else { return nil }
            let text = paths.joined(separator: "\n")
            return ClipboardCapture(kind: .files, hash: digest(Data(text.utf8)), text: text, byteSize: text.utf8.count)

        case .image:
            guard let type = ClipboardCapturePolicy.imageTypes.first(where: types.contains),
                  let data = item.data(forType: .init(type)),
                  data.count <= ClipboardCapturePolicy.maxImageBytes,
                  let size = pixelSize(of: data),
                  size.width * size.height <= ClipboardCapturePolicy.maxImagePixels else { return nil }
            var capture = ClipboardCapture(kind: .image, hash: digest(data), pixelWidth: size.width,
                                           pixelHeight: size.height, byteSize: data.count)
            let fileURL = item.string(forType: .fileURL).flatMap(URL.init(string:))
            if let libraryPath = ClipboardCapturePolicy.libraryPath(of: fileURL, historyDirectory: historyDirectory) {
                capture.libraryPath = libraryPath
            } else if type == "public.tiff" {
                guard let png = png(from: data) else { return nil }
                capture.image = png
                capture.imageExtension = "png"
            } else {
                capture.image = data
                capture.imageExtension = UTType(type)?.preferredFilenameExtension ?? "img"
            }
            return capture

        case .text:
            let string = item.string(forType: .string) ?? item.string(forType: .URL)
                ?? (types.contains(ClipboardCapturePolicy.colorType) ? NSColor(from: pasteboard).flatMap(hex) : nil)
            guard let string, !string.isEmpty, string.utf8.count <= ClipboardCapturePolicy.maxTextBytes else { return nil }
            var richText: [String: Data] = [:]
            for type in ClipboardCapturePolicy.richTextTypes where types.contains(type) {
                if let data = item.data(forType: .init(type)), data.count <= ClipboardCapturePolicy.maxRichTextBytes {
                    richText[type] = data
                }
            }
            return ClipboardCapture(kind: .text, hash: digest(Data(string.utf8)), text: string,
                                    byteSize: string.utf8.count, richText: richText)
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Width and height from the file's header, without decoding the image.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// TIFF copies are kept as PNG: lossless and far smaller.
    static func png(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
    }
}
