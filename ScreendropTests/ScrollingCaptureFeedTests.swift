import CoreGraphics
import Foundation
import ImageIO
import Testing

private final class FeedFixtureBundle: NSObject {}

/// The feed on the Wikipedia crops `ScrollingOffsetTests` uses (600x400, CC BY-SA 4.0): frame 4 is
/// frame 3 scrolled 180 px. The selection is the top 360 rows, so 40 rows of each frame lie below it.
@Suite struct ScrollingCaptureFeedTests {
    private let selection = ScrollingCaptureOutputRect(columns: 0..<600, rows: 0..<360)

    private func frame(_ index: Int) throws -> CGImage {
        let url = try #require(Bundle(for: FeedFixtureBundle.self).url(forResource: "wikipedia-scroll-\(index)", withExtension: "png"))
        return try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    }

    private func pixels(_ image: CGImage, rows: Range<Int>) throws -> [UInt8] {
        let crop = try #require(image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count)))
        return try #require(ScrollingCapturePixels.bytes(of: crop, in: ScrollingCapturePixels.colorSpace(of: image)))
    }

    @Test("The live preview is the capture so far, every few pixels of every few rows")
    func previewIsTheCaptureShrunk() async throws {
        let top = try frame(3), lower = try frame(4)
        let feed = try #require(ScrollingCaptureFeed(firstFrame: top, at: 0, selection: selection, ignoredTrailingColumns: 0))
        #expect(await feed.add(lower, at: 1)?.placement == .appended(180))
        let full = try #require(await feed.makeImage())
        let preview = try #require(await feed.makePreview(maxWidth: 150))
        // 600 px across fits 150 at every fourth pixel; 540 rows give 135.
        #expect(preview.width == 150 && preview.height == 135)
        let all = try pixels(full, rows: 0..<full.height), small = try pixels(preview, rows: 0..<preview.height)
        for (x, y) in [(0, 0), (149, 0), (37, 60), (80, 100), (149, 134)] {
            let from = (y * 4 * 600 + x * 4) * 4, to = (y * 150 + x) * 4
            #expect(Array(all[from..<from + 4]) == Array(small[to..<to + 4]), "pixel \(x),\(y)")
        }
        #expect(try #require(await feed.makePreview(maxWidth: 4000)).width == 600, "never enlarged")
    }

    @Test("The preview strip sits right of the region, else left, and keeps clear of the bar")
    func previewPlacement() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        func frame(_ rect: CGRect, bar: CGRect? = nil) -> CGRect? {
            ScrollingCapturePreviewPlacement.frame(beside: rect, visible: visible, avoiding: bar, width: 156)
        }
        #expect(frame(CGRect(x: 200, y: 100, width: 800, height: 600)) == CGRect(x: 1004, y: 100, width: 156, height: 600))
        #expect(frame(CGRect(x: 500, y: 100, width: 900, height: 600)) == CGRect(x: 340, y: 100, width: 156, height: 600))
        #expect(frame(CGRect(x: 100, y: 100, width: 1300, height: 600)) == nil)
        // A short region gets a taller strip, upward, unless the bar is in the way there.
        let short = CGRect(x: 200, y: 300, width: 300, height: 200)
        #expect(frame(short)?.height == 420 && frame(short)?.minY == 300)
        #expect(frame(short, bar: CGRect(x: 100, y: 500, width: 524, height: 76))?.height == 200)
    }

    @Test("At the end of the page the reference frame's rows below the selection go on under the capture")
    func rowsBelowComeFromTheReference() async throws {
        let top = try frame(3), lower = try frame(4)
        let feed = try #require(ScrollingCaptureFeed(firstFrame: top, at: 0, selection: selection, ignoredTrailingColumns: 0))
        #expect(await feed.add(lower, at: 1)?.placement == .appended(180))
        let plain = try #require(await feed.makeImage())
        #expect(plain.height == 360 + 180)
        let image = try #require(await feed.makeImage(rowsBelow: 360..<400))
        #expect(image.height == 360 + 180 + 40)
        #expect(try pixels(image, rows: 0..<540) == pixels(plain, rows: 0..<540))
        #expect(try pixels(image, rows: 540..<580) == pixels(lower, rows: 360..<400))
    }

    /// The frame under a grey veil: the selection's dimming caught mid-fade.
    private func veiled(_ image: CGImage) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: ScrollingCapturePixels.colorSpace(of: image),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        let all = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: all)
        context.setFillColor(gray: 0, alpha: 0.1)
        context.fill(all)
        return try #require(context.makeImage())
    }

    @Test("Before any input, a newer frame takes a stale first frame's place")
    func staleFirstFrameIsReplaced() async throws {
        let top = try frame(3), lower = try frame(4)
        // Matched against the stale frame, the scrolled one is refused.
        let stale = try #require(ScrollingCaptureFeed(firstFrame: veiled(top), at: 0, selection: selection,
                                                      ignoredTrailingColumns: 0))
        #expect(await stale.add(lower, at: 2)?.placement == .skipped)
        let feed = try #require(ScrollingCaptureFeed(firstFrame: veiled(top), at: 0, selection: selection,
                                                     ignoredTrailingColumns: 0))
        #expect(await feed.add(top, at: 1, mayReplaceFirst: true) == nil)
        #expect(await feed.add(lower, at: 2)?.placement == .appended(180))
        let image = try #require(await feed.makeImage())
        #expect(image.height == 360 + 180)
        #expect(try pixels(image, rows: 0..<360) == pixels(top, rows: 0..<360))
    }

    @Test("Before any input, a frame that moved is placed as always, and once rows are appended one that doesn't fit is refused")
    func onlyAnUnfittingFirstIsReplaced() async throws {
        let top = try frame(3), lower = try frame(4)
        // A page that scrolls itself, or a scroll the input check missed, still stitches.
        let feed = try #require(ScrollingCaptureFeed(firstFrame: top, at: 0, selection: selection, ignoredTrailingColumns: 0))
        #expect(await feed.add(lower, at: 1, mayReplaceFirst: true)?.placement == .appended(180))
        // A frame that doesn't fit then waits for one that does, as without the flag.
        let unfitting = try veiled(lower)
        #expect(await feed.add(unfitting, at: 2, mayReplaceFirst: true)?.placement == .skipped)
        #expect(try #require(await feed.makeImage()).height == 360 + 180)
    }

    @Test("A repeat of an upward frame trims, as one notch back up needs; later repeats are dropped")
    func upwardRepeatTrims() async throws {
        let top = try frame(3), lower = try frame(4)
        let feed = try #require(ScrollingCaptureFeed(firstFrame: top, at: 0, selection: selection, ignoredTrailingColumns: 0))
        #expect(await feed.add(lower, at: 1)?.placement == .appended(180))
        #expect(await feed.add(top, at: 2)?.placement == .upward(-180))
        #expect(await feed.add(top, at: 3)?.placement == .trimmed(-180))
        #expect(await feed.add(top, at: 4) == nil)
        #expect(try #require(await feed.makeImage()).height == 360)
    }
}
