import CoreGraphics
import Foundation
import ImageIO
import Testing

private final class OffsetFixtureBundle: NSObject {}

/// 600x400 crops of Wikipedia's "Scroll" article (CC BY-SA 4.0), corpus page
/// fresh-wikipedia: frame 4 is frame 3 scrolled 180 px, frame 25 is 3,000 px on.
@Suite struct ScrollingOffsetTests {
    private func frame(_ index: Int) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let url = try #require(Bundle(for: OffsetFixtureBundle.self).url(forResource: "wikipedia-scroll-\(index)", withExtension: "png"))
        let image = try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let pixels = try #require(ScrollingCapturePixels.bytes(of: image, in: CGColorSpace(name: CGColorSpace.sRGB)!))
        return (pixels, image.width, image.height)
    }

    @Test("The verifier accepts the true offset and rejects it one or two pixels off")
    func verifierIsExact() throws {
        let last = try frame(3), new = try frame(4)
        func verified(_ candidate: Int) -> Int? {
            ScrollingCaptureOffsetVerifier.verifiedOffset(candidate: candidate, from: last.pixels, to: new.pixels,
                width: last.width, height: last.height, ignoredTrailingColumns: 0)?.offset
        }
        #expect(verified(180) == 180)
        // Each tries its candidate ±2: 181...185 and 175...179.
        #expect(verified(183) == nil)
        #expect(verified(177) == nil)
    }

    @Test("The stitcher trims on the second upward frame, not the first")
    func stitcherTrimsOnSecondUpwardFrame() async throws {
        let top = try frame(3), lower = try frame(4)
        let stitcher = try #require(ScrollingCaptureFrameStitcher(firstFrame: top.pixels,
            width: top.width, height: top.height, ignoredTrailingColumns: 0))
        #expect(await stitcher.add(lower.pixels).placement == .appended(180))
        #expect(await stitcher.add(top.pixels).placement == .upward(-180))
        #expect(await stitcher.stitchedHeight == top.height + 180)
        #expect(await stitcher.add(top.pixels).placement == .trimmed(-180))
        #expect(await stitcher.stitchedHeight == top.height)
        #expect(await stitcher.makeImage() == top.pixels)
    }

    /// `height` rows from `top` of a page whose rows repeat every 20 rows, apart from the first 8
    /// columns, which number each repeat: log lines alike but for a counter.
    private func logFrame(top: Int, height: Int = 400) -> [UInt8] {
        let width = 64
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let row = top + y
            for x in 0..<width {
                let value = UInt8(truncatingIfNeeded: x < 8 ? (row / 20) * 37 + x * 11 : (row % 20) * 13 + x * 7)
                pixels.replaceSubrange(((y * width + x) * 4)..<((y * width + x) * 4 + 3), with: [value, value, value])
            }
        }
        return pixels
    }

    @Test("On repeating rows, a candidate a whole repeat off falls back to the last step")
    func lastStepRescuesRepeatAlias() async throws {
        let stitcher = try #require(ScrollingCaptureFrameStitcher(firstFrame: logFrame(top: 0), width: 64, height: 400,
                                                                  ignoredTrailingColumns: 0))
        #expect(await stitcher.place(logFrame(top: 40), candidate: 40) == .appended(40))
        // Three repeats off: most strips agree there, but no row matches whole, so the verifier refuses it.
        #expect(await stitcher.place(logFrame(top: 80), candidate: -20) == .appended(40))
        #expect(await stitcher.makeImage() == logFrame(top: 0, height: 480))
        // Before any step there's nothing to fall back on: the same candidate is refused.
        let fresh = try #require(ScrollingCaptureFrameStitcher(firstFrame: logFrame(top: 0), width: 64, height: 400,
                                                               ignoredTrailingColumns: 0))
        #expect(await fresh.place(logFrame(top: 40), candidate: -20) == .skipped)
    }

    @Test("The bands of two frames with no overlap reach no consensus")
    func estimatorBandsDisagree() throws {
        let last = try frame(3), far = try frame(25)
        let shifts = ScrollingCaptureOffsetEstimator.bandShifts(from: last.pixels, to: far.pixels,
            width: last.width, height: last.height, ignoredTrailingColumns: 0)
        #expect(shifts.count == ScrollingCaptureOffsetEstimator.bands)
        #expect(ScrollingCaptureOffsetEstimator.consensus(shifts) == nil)
    }
}
