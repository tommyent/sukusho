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

    @Test("A frame that differs only in the ignored trailing columns repeats the view")
    func sameViewIgnoresTrailingColumns() throws {
        let view = try frame(3)
        var scrollBar = view.pixels
        for y in 0..<view.height { scrollBar[(y * view.width + view.width - 2) * 4] ^= 0xFF }
        func same(_ other: [UInt8], ignoring trailing: Int) -> Bool {
            ScrollingCaptureOffsetVerifier.sameView(view.pixels, other, width: view.width, height: view.height,
                                                    ignoredTrailingColumns: trailing)
        }
        #expect(same(scrollBar, ignoring: 8))
        #expect(!same(scrollBar, ignoring: 0))
        #expect(!same(try frame(4).pixels, ignoring: 8))
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

    /// 80 x 400: columns 0-23 and 56-79 pinned (a sidebar each side, the same in every frame),
    /// 24-55 the page from row `top`. Each has blank rows, as text lines do.
    private func pinnedFrame(top: Int, change: Bool = false) -> [UInt8] {
        let width = 80, height = 400
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let row = top + y
            for x in 0..<width {
                let pinned = x < 24 || x >= 56
                guard pinned ? y % 10 < 5 : row % 8 < 6 else { continue }
                var value = UInt8(truncatingIfNeeded: pinned ? y * 7 + x * 13 : row * 29 + x * 3)
                if change, !pinned, y < 40 { value ^= 0x55 }
                pixels.replaceSubrange(((y * width + x) * 4)..<((y * width + x) * 4 + 3), with: [value, value, value])
            }
        }
        return pixels
    }

    @Test("Pinned side columns can't pass a moved page as unmoved when another offset fits more rows")
    func pinnedColumnsDontHideMotion() async throws {
        let stitcher = try #require(ScrollingCaptureFrameStitcher(firstFrame: pinnedFrame(top: 0), width: 80, height: 400,
                                                                  ignoredTrailingColumns: 0))
        // Vision's whole-frame fallback says 0 (the pinned columns); the bands that saw the page say 40.
        #expect(ScrollingCaptureOffsetVerifier.verifiedOffset(candidate: 0, from: pinnedFrame(top: 0),
            to: pinnedFrame(top: 40), width: 80, height: 400, ignoredTrailingColumns: 0)?.offset == 0)
        #expect(await stitcher.place(pinnedFrame(top: 40), candidate: 0, alternatives: [40]) == .appended(40))
        // At rest, a change in part of the frame still places at 0: the last step (40) never
        // overrides it, and a shift two bands agree on only does when it's confirmed exactly.
        #expect(await stitcher.place(pinnedFrame(top: 40, change: true), candidate: 0) == .redrawn)
        #expect(await stitcher.place(pinnedFrame(top: 40, change: true), candidate: 0, alternatives: [24]) == .redrawn)
        #expect(ScrollingCaptureOffsetEstimator.pairs([-0.2, 40, 39.5, 120, 40.8]) == [40])
    }

    /// 96 x 400, MDN's layout in small: a dense sidebar each side (columns 0-23 and 72-95, the same in
    /// every frame, something in every row), a gap of 4 blank columns inside each, and between them
    /// the page from row `top`, whose rows repeat nothing. `left` and `right` replace a sidebar's
    /// pixels at screen row y, column x (0-23 within it).
    private func sidebarFrame(top: Int, page: ((Int, Int) -> UInt8)? = nil,
                              left: ((Int, Int) -> UInt8)? = nil, right: ((Int, Int) -> UInt8)? = nil) -> [UInt8] {
        let width = 96, height = 400
        let page: (Int, Int) -> UInt8 = page ?? { (row: Int, x: Int) -> UInt8 in
            guard row % 8 < 6 else { return 255 }
            return UInt8(truncatingIfNeeded: row * 29 + x * 3 + (row / 256) * 101)
        }
        let left: (Int, Int) -> UInt8 = left ?? { (y: Int, x: Int) -> UInt8 in UInt8(truncatingIfNeeded: y * 7 + x * 13) }
        let right: (Int, Int) -> UInt8 = right ?? { (y: Int, x: Int) -> UInt8 in UInt8(truncatingIfNeeded: y * 11 + x * 5 + 3) }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = switch x {
                case 0..<24: left(y, x)
                case 72..<96: right(y, x - 72)
                case 28..<68: page(top + y, x)
                default: 255
                }
                pixels.replaceSubrange(((y * width + x) * 4)..<((y * width + x) * 4 + 3), with: [value, value, value])
            }
        }
        return pixels
    }

    @Test("With a dense sidebar pinned each side, the content between verifies at its offset")
    func pinnedSidebarsLeftOut() {
        // No row matches whole at 40 across the sidebars; with them left out the page does.
        let found = ScrollingCaptureOffsetVerifier.verifiedOffset(candidate: 40, from: sidebarFrame(top: 0),
            to: sidebarFrame(top: 40), width: 96, height: 400, ignoredTrailingColumns: 0)
        #expect(found == .init(offset: 40, pinnedLeft: 28, pinnedRight: 28))
        // At rest, nothing is pinned.
        #expect(ScrollingCaptureOffsetVerifier.verifiedOffset(candidate: 0, from: sidebarFrame(top: 40),
            to: sidebarFrame(top: 40), width: 96, height: 400, ignoredTrailingColumns: 0) == .init(offset: 0))
    }

    @Test("Pinned sidebars show once, from the first frame, then one plain colour; the page between is whole")
    func pinnedSidebarsShowOnce() async throws {
        let first = sidebarFrame(top: 0)
        let stitcher = try #require(ScrollingCaptureFrameStitcher(firstFrame: first, width: 96, height: 400,
                                                                  ignoredTrailingColumns: 0))
        #expect(await stitcher.place(sidebarFrame(top: 40), candidate: 40) == .appended(40))
        #expect(await stitcher.place(sidebarFrame(top: 80), candidate: 40) == .appended(40))
        let image = await stitcher.makeImage()
        #expect(image.count == 96 * 480 * 4)
        func pixel(_ pixels: [UInt8], _ y: Int, _ x: Int) -> UInt8 { pixels[(y * 96 + x) * 4] }
        let page = sidebarFrame(top: 0) + sidebarFrame(top: 400)
        var wrong = 0
        for y in 0..<480 {
            for x in 28..<68 where pixel(image, y, x) != pixel(page, y, x) { wrong += 1 }
            // The gap columns make the side's most common colour blank.
            for x in Array(0..<28) + Array(68..<96) where pixel(image, y, x) != (y < 400 ? pixel(first, y, x) : 255) { wrong += 1 }
        }
        #expect(wrong == 0)
    }

    @Test("When only the pinned sidebars confirm 0, the last step is tried between them; at rest it isn't")
    func sidesOnlyZeroYieldsToTheLastStep() async throws {
        let stitcher = try #require(ScrollingCaptureFrameStitcher(firstFrame: sidebarFrame(top: 0), width: 96, height: 400,
                                                                  ignoredTrailingColumns: 0))
        #expect(await stitcher.place(sidebarFrame(top: 40), candidate: 40) == .appended(40))
        // Vision says 0 with no band pair (MDN, VM 2026-11-08 frames 4-6); the sidebars confirm it.
        #expect(ScrollingCaptureOffsetVerifier.verifiedOffset(candidate: 0, from: sidebarFrame(top: 40),
            to: sidebarFrame(top: 80), width: 96, height: 400, ignoredTrailingColumns: 0)
            == .init(offset: 0, sidesOnly: true))
        #expect(await stitcher.place(sidebarFrame(top: 80), candidate: 0) == .appended(40))
        // At rest, something small changes between the sidebars: the content there still confirms 0.
        let hover: (Int, Int) -> UInt8 = { (row: Int, x: Int) -> UInt8 in
            let base: UInt8 = row % 8 < 6 ? UInt8(truncatingIfNeeded: row * 29 + x * 3 + (row / 256) * 101) : 255
            return (200..<216).contains(row) && (40..<52).contains(x) ? base ^ 0x5A : base
        }
        #expect(await stitcher.place(sidebarFrame(top: 80, page: hover), candidate: 0) == .redrawn)
    }

    @Test("A pinned sidebar redrawn in place stays filled; one that moves with the page shows again")
    func pinnedRunsFollowTheSidebar() async throws {
        // A contents column on the left (lines every 20 rows, each its own) and no right sidebar.
        func toc(_ shift: Int) -> (Int, Int) -> UInt8 {
            { (y: Int, x: Int) -> UInt8 in
                let r = y - 20 - shift
                guard r >= 0, r % 20 < 6, y < 380 else { return 255 }
                return UInt8(truncatingIfNeeded: (r / 20) * 41 + x * 9 + 7)
            }
        }
        let none: (Int, Int) -> UInt8 = { (_: Int, _: Int) -> UInt8 in 255 }
        func frame(_ top: Int, left: @escaping (Int, Int) -> UInt8) -> [UInt8] { sidebarFrame(top: top, left: left, right: none) }
        func sidebarPixels(_ image: [UInt8], rows: Range<Int>) -> Int {
            rows.reduce(0) { count, y in count + (0..<24).filter { image[(y * 96 + $0) * 4] != 255 }.count }
        }
        // Redrawn in place: the current section turns bold and the lines below move down 10 rows.
        let redrawn = try #require(ScrollingCaptureFrameStitcher(firstFrame: frame(0, left: toc(0)), width: 96, height: 400,
                                                                 ignoredTrailingColumns: 0))
        #expect(await redrawn.place(frame(40, left: toc(0)), candidate: 40) == .appended(40))
        #expect(await redrawn.place(frame(80, left: toc(10)), candidate: 40) == .appended(40))
        #expect(await redrawn.place(frame(120, left: toc(10)), candidate: 40) == .appended(40))
        #expect(sidebarPixels(await redrawn.makeImage(), rows: 400..<520) == 0)
        // Moved with the page (a footer pushing it up): the column's own pixels are kept from there.
        let moved = try #require(ScrollingCaptureFrameStitcher(firstFrame: frame(0, left: toc(0)), width: 96, height: 400,
                                                               ignoredTrailingColumns: 0))
        #expect(await moved.place(frame(40, left: toc(0)), candidate: 40) == .appended(40))
        #expect(await moved.place(frame(80, left: toc(-40)), candidate: 40) == .appended(40))
        #expect(sidebarPixels(await moved.makeImage(), rows: 400..<480) > 0)
    }

    @Test("An inner scroller moving above the cut while the page stands still is refused")
    func innerScrollerStaysRefused() async throws {
        // A static page with a box (columns 28-67, rows 100-199) scrolling its own list by 20.
        func frame(_ list: Int) -> [UInt8] {
            sidebarFrame(top: 0, page: { (row: Int, x: Int) -> UInt8 in
                guard (100..<200).contains(row) else { return UInt8(truncatingIfNeeded: row * 3 + x * 17) }
                return UInt8(truncatingIfNeeded: (row + list) * 29 + x * 3)
            })
        }
        #expect(ScrollingCaptureOffsetVerifier.verifiedOffset(candidates: [20], from: frame(0), to: frame(20),
            width: 96, height: 400, ignoredTrailingColumns: 0) == nil)
        let stitcher = try #require(ScrollingCaptureFrameStitcher(firstFrame: frame(0), width: 96, height: 400,
                                                                  ignoredTrailingColumns: 0))
        #expect(await stitcher.place(frame(20), candidate: 0, alternatives: [20]) == .redrawn)
    }

    @Test("A sparse page that jumps past the overlap beside a pinned sidebar is refused")
    func sparseJumpStaysRefused() {
        // Six-row lines every 50 rows, each its own; the view jumps 1,000 rows.
        let sparse: (Int, Int) -> UInt8 = { (row: Int, x: Int) -> UInt8 in
            guard row % 50 < 6 else { return 255 }
            return UInt8(truncatingIfNeeded: (row / 50) * 37 + row * 5 + x * 3)
        }
        let last = sidebarFrame(top: 0, page: sparse), new = sidebarFrame(top: 1000, page: sparse)
        #expect(ScrollingCaptureOffsetVerifier.verifiedOffset(candidates: [40, 50, -3], from: last, to: new,
            width: 96, height: 400, ignoredTrailingColumns: 0) == nil)
    }

    @Test("Side columns that repeat at the offset, such as a list's icons, aren't pinned")
    func repeatingColumnsArentPinned() {
        let icons: (Int, Int) -> UInt8 = { y, x in UInt8(truncatingIfNeeded: (y % 40) * 7 + x * 13) }
        let found = ScrollingCaptureOffsetVerifier.verifiedOffset(candidate: 40, from: sidebarFrame(top: 0, left: icons),
            to: sidebarFrame(top: 40, left: icons), width: 96, height: 400, ignoredTrailingColumns: 0)
        #expect(found == .init(offset: 40, pinnedLeft: 0, pinnedRight: 28))
    }

    /// 100 x 400, Apple's docs at the end of the page in small: a dense navigator (columns 0-36, text in
    /// 8 rows of 10) from row `side`, and the article (columns 37-99, text in 4 rows of 8) from row `page`:
    /// a footer pushes the navigator up at another rate than the article.
    private func pushedSidebarFrame(side: Int, page: Int) -> [UInt8] {
        let width = 100, height = 400
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let row = x < 37 ? side + y : page + y
                guard x < 37 ? row % 10 < 8 : row % 8 < 4 else { continue }
                let value = UInt8(truncatingIfNeeded: row * 29 + x * 3 + (row / 256) * 101 + (x < 37 ? 0 : 50))
                pixels.replaceSubrange(((y * width + x) * 4)..<((y * width + x) * 4 + 3), with: [value, value, value])
            }
        }
        return pixels
    }

    @Test("Of two shifts that both verify, the one most of Vision's bands saw wins over the one with more rows")
    func bandsPickBetweenShifts() async throws {
        let last = pushedSidebarFrame(side: 0, page: 0), new = pushedSidebarFrame(side: 24, page: 40)
        func place(bands: [Int]) async throws -> ScrollingCaptureFrameStitcher.Placement {
            let stitcher = try #require(ScrollingCaptureFrameStitcher(firstFrame: last, width: 100, height: 400,
                                                                      ignoredTrailingColumns: 0))
            // Vision's whole-frame shift doesn't verify, so the shifts two or more bands agree on are tried.
            return await stitcher.place(new, candidate: -900, alternatives: [24, 40], bands: bands)
        }
        // Both verify alone; the dense navigator matches more rows at 24, so the rows pick it.
        func verified(_ k: Int) -> Int? {
            ScrollingCaptureOffsetVerifier.verifiedOffset(candidates: [k], from: last, to: new, width: 100, height: 400,
                                                          ignoredTrailingColumns: 0)?.offset
        }
        #expect(verified(24) == 24 && verified(40) == 40)
        #expect(try await place(bands: []) == .appended(24))
        // Three of five bands saw the article move 40: it wins.
        #expect(try await place(bands: [24, 24, 40, 40, 40]) == .appended(40))
        // Without a majority of the bands, the rows decide as before.
        #expect(try await place(bands: [24, 24, 24, 40, 40]) == .appended(24))
        #expect(try await place(bands: [24, 40, 40, 7, 99]) == .appended(24))
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
