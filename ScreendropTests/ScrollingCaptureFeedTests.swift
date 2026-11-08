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
