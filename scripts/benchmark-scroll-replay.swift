// Build with build-scroll-replay.py. Arguments: mode (timing|identity), optional frame-dump folders.
import CoreText
import CryptoKit
import Foundation
import ImageIO

@main struct ScrollReplay {
    typealias Stitcher = ScrollingCaptureFrameStitcher
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    struct Record: Decodable {
        let index: Int
        let action: String
    }

    static func inputs(files: [URL], manifest: String?) throws -> [(index: Int, file: URL?, reset: Bool)] {
        var byIndex: [Int: URL] = [:]
        for file in files where file.pathExtension == "png" {
            guard let index = Int(file.deletingPathExtension().lastPathComponent) else { continue }
            guard byIndex.updateValue(file, forKey: index) == nil else { throw CocoaError(.fileReadCorruptFile) }
        }
        guard let manifest else { return byIndex.keys.sorted().map { ($0, byIndex[$0], false) } }
        let decoder = JSONDecoder()
        let records = try manifest.split(separator: "\n").map { try decoder.decode(Record.self, from: Data($0.utf8)) }
        return try records.sorted { $0.index < $1.index }.map { record in
            let file = byIndex[record.index]
            guard file != nil || record.action == "skipped" else { throw CocoaError(.fileReadNoSuchFile) }
            return (record.index, file, record.action == "first")
        }
    }

    static func checkInputs() throws {
        let files = ["10.png", "0.png", "2.png"].map { URL(fileURLWithPath: $0) }
        let numeric = try inputs(files: files, manifest: nil)
        precondition(numeric.map(\.index) == [0, 2, 10] && numeric.map(\.file) == [files[1], files[2], files[0]])
        let gap = try inputs(files: files, manifest: """
            {"index":10,"action":"first"}
            {"index":0,"action":"first"}
            {"index":3,"action":"skipped"}
            {"index":2,"action":"skipped"}
            """)
        precondition(gap.map(\.index) == [0, 2, 3, 10] && gap[1].file == files[2] && gap[2].file == nil && gap[3].reset)
    }

    static func load(_ url: URL, space: CGColorSpace? = nil) -> (pixels: [UInt8], w: Int, h: Int, space: CGColorSpace) {
        autoreleasepool {
            let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
            let space = space ?? ScrollingCapturePixels.colorSpace(of: image)
            return (ScrollingCapturePixels.bytes(of: image, in: space)!, image.width, image.height, space)
        }
    }

    static func add(_ name: String, index: Int, reference: Int, next: [UInt8], stitcher: Stitcher,
                    identity: Bool) async -> Stitcher.Placement {
        let start = DispatchTime.now().uptimeNanoseconds
        let (p, c) = await stitcher.add(next)
        let total = DispatchTime.now().uptimeNanoseconds - start
        if identity {
            let sha = SHA256.hash(data: await stitcher.makeImageData()).map { String(format: "%02x", $0) }.joined()
            print("ID \(name) \(index) ref=\(reference) bands=\(c?.bands ?? []) candidate=\(String(describing: c?.offset)) consensus=\(c?.bandsAgree ?? false) alternatives=\(c?.alternatives ?? []) placement=\(p) height=\(await stitcher.stitchedHeight) bytes=\(sha)")
        } else {
            #if SCROLL_STAGE_CLOCK
            let vision = next.isEmpty ? 0 : await stitcher.visionNS
            print("TIME \(name) \(index) \(vision) \(total - vision) \(total)")
            #else
            print("TOTAL \(name) \(index) \(total)")
            #endif
        }
        return p
    }

    // Sticky sidebars: the same native-resolution rows on either side of a scrolling article.
    static func page(w: Int, h: Int) -> [UInt8] {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: space, bitmapInfo: ScrollingCapturePixels.bitmapInfo)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let attrs = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 25, nil)]
        for y in stride(from: 0, to: h, by: 38) {
            for x in stride(from: 20, to: w, by: w / 3) {
                ctx.textPosition = CGPoint(x: x, y: y)
                let text = "\(y * 37 + x): Screenshot notes for the next review."
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs)), ctx)
            }
        }
        return Array(UnsafeRawBufferPointer(start: ctx.data!, count: w * h * 4))
    }

    static func main() async throws {
        guard let mode = CommandLine.arguments.dropFirst().first, ["identity", "timing"].contains(mode) else {
            print("Usage: replay identity|timing [numbered-frame folder ...]")
            exit(2)
        }
        let identity = mode == "identity"
        try checkInputs()
        func pair(_ name: String, _ a: [UInt8], _ b: [UInt8], _ w: Int, _ h: Int, _ offset: Int) async {
            for i in 0..<(identity ? 1 : 12) {
                let s = Stitcher(firstFrame: a, width: w, height: h, ignoredTrailingColumns: 0)!
                let placement = await add(name, index: i, reference: 0, next: b, stitcher: s, identity: identity)
                precondition(placement == .appended(offset))
            }
        }
        let fixtures = URL(fileURLWithPath: "ScreendropTests/Fixtures")
        func wiki(_ i: Int) -> [UInt8] { load(fixtures.appendingPathComponent("wikipedia-scroll-\(i).png")).pixels }
        await pair("wiki", wiki(3), wiki(4), 600, 400, 180)
        let w = 2400, h = 1400, k = 211
        let large = page(w: w, h: h + k)
        let first = Array(large.prefix(w*h*4))
        var next = Array(large.suffix(w*h*4))
        await pair("article", first, next, w, h, k)
        for y in 0..<h {
            for x in [0..<420, (w-520)..<w] {
                let r = (y*w+x.lowerBound)*4..<(y*w+x.upperBound)*4
                next.replaceSubrange(r, with: first[r])
            }
        }
        await pair("sticky", first, next, w, h, k)
        for (n, path) in CommandLine.arguments.dropFirst(2).enumerated() {
            let dir = URL(fileURLWithPath: path)
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            let dump = dir.appendingPathComponent("frames.jsonl")
            let manifest = FileManager.default.fileExists(atPath: dump.path) ? try String(contentsOf: dump, encoding: .utf8) : nil
            let frames = try inputs(files: files, manifest: manifest)
            guard let first = frames.first, let initial = first.file else { throw CocoaError(.fileReadCorruptFile) }
            let config = [dir.appendingPathComponent("page.json"), dir.appendingPathComponent("truth.json")]
                .first { FileManager.default.fileExists(atPath: $0.path) }!
            let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
            let trailing = metadata["ignoredTrailingColumns"] as! Int
            let base = load(initial)
            var s = Stitcher(firstFrame: base.pixels, width: base.w, height: base.h, ignoredTrailingColumns: trailing)!
            var reference = first.index
            for (index, file, reset) in frames.dropFirst() {
                let pixels: [UInt8] = file.map { url in
                    let next = load(url, space: base.space)
                    precondition(next.w == base.w && next.h == base.h)
                    return next.pixels
                } ?? [] // A missing crop still breaks a run of upward frames.
                let p = await add("replay\(n)", index: index, reference: reference, next: pixels, stitcher: s, identity: identity)
                if reset {
                    s = Stitcher(firstFrame: pixels, width: base.w, height: base.h, ignoredTrailingColumns: trailing)!
                    reference = index
                } else if p.isReference { reference = index }
            }
        }
    }
}
