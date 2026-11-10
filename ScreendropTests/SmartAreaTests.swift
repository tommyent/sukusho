import CoreGraphics
import Foundation
import Testing

@Suite
struct SmartAreaTests {
    private static let page: UInt32 = 0xFFF5F5F5
    private static let white: UInt32 = 0xFFFFFFFF

    /// A page of one flat color, drawn on by `paint`.
    private func bitmap(width: Int = 400, height: Int = 300, page: UInt32 = SmartAreaTests.page,
                        paint: (inout Canvas) -> Void) -> SmartAreaBitmap {
        var canvas = Canvas(width: width, height: height, pixels: Array(repeating: page, count: width * height))
        paint(&canvas)
        return SmartAreaBitmap(width: width, height: height, pixels: canvas.pixels)
    }

    private struct Canvas {
        let width: Int
        let height: Int
        var pixels: [UInt32]

        mutating func fill(_ rect: CGRect, _ color: (Int, Int) -> UInt32) {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) { pixels[y * width + x] = color(x, y) }
            }
        }

        mutating func fill(_ rect: CGRect, _ color: UInt32) { fill(rect) { _, _ in color } }

        /// No two neighbours share a color, as in a photo.
        mutating func photo(_ rect: CGRect) {
            fill(rect) { x, y in 0xFF000000 | UInt32((x * 7 + y * 13) % 200 + 20) << 8 | UInt32((x + y) % 2) }
        }
    }

    private func boxes(_ bitmap: SmartAreaBitmap) -> [CGRect] {
        SmartAreaDetector.boxes(in: bitmap, minSide: 20)
    }

    @Test func aFilledCardIsFoundToThePixel() {
        let card = CGRect(x: 50, y: 40, width: 200, height: 120)
        #expect(boxes(bitmap { $0.fill(card, Self.white) }) == [card])
    }

    @Test func aCardWithRoundedCornersKeepsItsFullBounds() {
        let card = CGRect(x: 50, y: 40, width: 200, height: 120)
        let found = boxes(bitmap { canvas in
            canvas.fill(card, Self.white)
            // 12-pixel corners cut back to the page color.
            for corner in [CGPoint(x: 50, y: 40), CGPoint(x: 238, y: 40), CGPoint(x: 50, y: 148), CGPoint(x: 238, y: 148)] {
                let centre = CGPoint(x: corner.x < 100 ? 62 : 238, y: corner.y < 100 ? 52 : 148)
                canvas.fill(CGRect(origin: corner, size: CGSize(width: 12, height: 12))) { x, y in
                    let dx = Double(x) + 0.5 - centre.x, dy = Double(y) + 0.5 - centre.y
                    return dx * dx + dy * dy > 144 ? Self.page : Self.white
                }
            }
        })
        #expect(found == [card])
    }

    @Test func aBorderLineAroundPageColoredContentIsABox() {
        let card = CGRect(x: 60, y: 50, width: 180, height: 100)
        let found = boxes(bitmap { canvas in
            canvas.fill(card, 0xFFCCCCCC)
            canvas.fill(card.insetBy(dx: 1, dy: 1), Self.page)
        })
        #expect(found == [card])
    }

    @Test func aBorderWithRoundedCornersIsPartOfItsCard() {
        let card = CGRect(x: 60, y: 50, width: 180, height: 100)
        let found = boxes(bitmap { canvas in
            canvas.fill(card, 0xFFCCCCCC)
            // The top and bottom lines fall between pixels: a lighter row outside the full one.
            canvas.fill(CGRect(x: 60, y: 50, width: 180, height: 1), 0xFFE2E2E2)
            canvas.fill(CGRect(x: 60, y: 149, width: 180, height: 1), 0xFFE2E2E2)
            canvas.fill(card.insetBy(dx: 2, dy: 2), Self.white)
            // Smoothed corners: in-between colors cut the border into four lines.
            for corner in [card.origin, CGPoint(x: card.maxX - 6, y: card.minY),
                           CGPoint(x: card.minX, y: card.maxY - 6), CGPoint(x: card.maxX - 6, y: card.maxY - 6)] {
                canvas.fill(CGRect(origin: corner, size: CGSize(width: 6, height: 6))) { x, y in
                    0xFFE0E0E0 + UInt32((x + y) % 5)
                }
            }
        })
        #expect(found == [card])
    }

    @Test func aPictureOnThePageIsABox() {
        let picture = CGRect(x: 100, y: 80, width: 160, height: 90)
        #expect(boxes(bitmap { $0.photo(picture) }) == [picture])
    }

    @Test func aCardMadeOfAPictureAndATextPanelIsOneBoxWithItsParts() {
        let picture = CGRect(x: 80, y: 40, width: 200, height: 100)
        let panel = CGRect(x: 80, y: 140, width: 200, height: 80)
        let found = boxes(bitmap { canvas in
            canvas.photo(picture)
            canvas.fill(panel, Self.white)
        })
        // Smallest first: the panel, the picture, then the card they make.
        #expect(found == [panel, picture, picture.union(panel)])
    }

    @Test func cardsWhoseShadowsTouchStayApart() {
        // Two cards, each a picture over a text panel, 16 pixels apart with 12-pixel shadows.
        let cards = [CGRect(x: 40, y: 60, width: 140, height: 160), CGRect(x: 196, y: 60, width: 140, height: 160)]
        let found = boxes(bitmap { canvas in
            // Each pixel takes the darker of the two shadows, so they run into each other between the cards.
            canvas.fill(CGRect(x: 28, y: 48, width: 320, height: 184)) { x, y in
                let depth = cards.map { card in
                    let dx = max(card.minX - Double(x), Double(x) - card.maxX + 1, 0)
                    let dy = max(card.minY - Double(y), Double(y) - card.maxY + 1, 0)
                    return max(0, 12 - Int(max(dx, dy)))
                }.max() ?? 0
                let level = UInt32(245 - 2 * depth)
                return 0xFF000000 | level << 16 | level << 8 | level
            }
            for card in cards {
                canvas.photo(CGRect(x: card.minX, y: card.minY, width: 140, height: 90))
                canvas.fill(CGRect(x: card.minX, y: card.minY + 90, width: 140, height: 70), Self.white)
            }
        })
        // Each card whole, to the pixel, and never the pair as one box.
        for card in cards { #expect(found.contains(card)) }
        #expect(!found.contains { $0.width > 200 })
    }

    @Test func aSoftShadowDoesNotMoveTheCardsOwnBox() {
        let card = CGRect(x: 100, y: 80, width: 200, height: 120)
        let found = boxes(bitmap { canvas in
            // A 12-pixel shadow fading into the page, then the card on top.
            canvas.fill(card.insetBy(dx: -12, dy: -12)) { x, y in
                let dx = max(card.minX - Double(x), Double(x) - card.maxX + 1, 0)
                let dy = max(card.minY - Double(y), Double(y) - card.maxY + 1, 0)
                let level = UInt32(245 - max(0, 12 - Int(max(dx, dy))))
                return 0xFF000000 | level << 16 | level << 8 | level
            }
            canvas.fill(card, Self.white)
        })
        // The shadow adds no box of its own.
        #expect(found == [card])
    }

    @Test func aButtonInsideACardComesBeforeTheCard() {
        let card = CGRect(x: 40, y: 30, width: 300, height: 200)
        let button = CGRect(x: 220, y: 170, width: 90, height: 30)
        let found = boxes(bitmap { canvas in
            canvas.fill(card, Self.white)
            canvas.fill(button, 0xFFEE8800)
        })
        #expect(found == [button, card])
    }

    @Test func aHeadlineLetterIsNotABox() {
        // An L and a T, 40 pixels across with 8-pixel strokes.
        let found = boxes(bitmap { canvas in
            canvas.fill(CGRect(x: 100, y: 100, width: 8, height: 40), 0xFF202020)
            canvas.fill(CGRect(x: 100, y: 132, width: 40, height: 8), 0xFF202020)
            canvas.fill(CGRect(x: 200, y: 100, width: 40, height: 8), 0xFF202020)
            canvas.fill(CGRect(x: 216, y: 100, width: 8, height: 40), 0xFF202020)
        })
        #expect(found.isEmpty)
    }

    @Test func thingsSmallerThanTheMinimumAreLeftOut() {
        #expect(boxes(bitmap { $0.fill(CGRect(x: 50, y: 50, width: 19, height: 60), Self.white) }).isEmpty)
    }

    @Test func aCardCutOffByTheEdgeStillCounts() {
        let card = CGRect(x: 250, y: 100, width: 150, height: 120)
        #expect(boxes(bitmap { $0.photo(card) }) == [card])
    }

    @Test func aDarkPageWorksLikeALightOne() {
        let card = CGRect(x: 50, y: 40, width: 200, height: 120)
        #expect(boxes(bitmap(page: 0xFF0D1117) { $0.fill(card, 0xFF161B22) }) == [card])
    }

    @Test func aBitmapKeepsAnImagesExactColors() throws {
        let image = SyntheticFixtures.faintHeaderEdges()
        let bitmap = try #require(SmartAreaBitmap(image))
        #expect(bitmap.width == 2 && bitmap.height == 1568)
        #expect(Set(bitmap.pixels.map { $0 & 0xFF }) == [21, 27, 34, 42])
    }

    // MARK: - Candidates

    private let candidates = SmartAreaCandidates(
        pixelBoxes: [CGRect(x: 200, y: 200, width: 100, height: 60), CGRect(x: 100, y: 100, width: 600, height: 400)],
        scale: 2,
        windows: [CGRect(x: 20, y: 20, width: 500, height: 400), CGRect(x: 0, y: 0, width: 700, height: 600)],
        displaySize: CGSize(width: 800, height: 600)
    )

    @Test func theStackRunsFromTheSmallestBoxOutToTheDisplay() {
        #expect(candidates.stack(at: CGPoint(x: 120, y: 120)) == [
            CGRect(x: 100, y: 100, width: 50, height: 30),
            CGRect(x: 50, y: 50, width: 300, height: 200),
            CGRect(x: 20, y: 20, width: 500, height: 400),
            CGRect(x: 0, y: 0, width: 800, height: 600),
        ])
    }

    @Test func onlyTheWindowInFrontAtThePointCounts() {
        // Inside both windows: the one behind is hidden there.
        #expect(candidates.stack(at: CGPoint(x: 400, y: 300)) == [
            CGRect(x: 20, y: 20, width: 500, height: 400), CGRect(x: 0, y: 0, width: 800, height: 600),
        ])
        // Past the front window, the one behind shows.
        #expect(candidates.stack(at: CGPoint(x: 600, y: 300)) == [
            CGRect(x: 0, y: 0, width: 700, height: 600), CGRect(x: 0, y: 0, width: 800, height: 600),
        ])
    }

    @Test func aWindowHangingOffTheDisplayIsCutToIt() {
        let candidates = SmartAreaCandidates(pixelBoxes: [], scale: 2,
            windows: [CGRect(x: 600, y: -50, width: 400, height: 300)], displaySize: CGSize(width: 800, height: 600))
        #expect(candidates.stack(at: CGPoint(x: 700, y: 100)).first == CGRect(x: 600, y: 0, width: 200, height: 250))
    }

    // MARK: - Loupe

    @Test func theLoupeShowsThePixelsAroundThePointerAboveAndRightOfIt() {
        let loupe = SmartAreaLoupe(pointer: CGPoint(x: 500, y: 400), viewSize: CGSize(width: 800, height: 600),
                                   scale: 2, imageSize: CGSize(width: 1600, height: 1200))
        #expect(loupe.frame == CGRect(x: 524, y: 424, width: 175, height: 175))
        // 200 points from the top is pixel row 400; twelve pixels each way.
        #expect(loupe.source == CGRect(x: 988, y: 388, width: 25, height: 25))
        #expect(loupe.destination == loupe.frame)
        // The pointer sits on the top-left corner of the middle pixel.
        #expect(loupe.crosshair == CGPoint(x: 524 + 12 * 7, y: 599 - 12 * 7))
    }

    @Test func theLoupeAtADisplayCornerShowsOnlyPixelsThatExist() {
        let loupe = SmartAreaLoupe(pointer: CGPoint(x: 798, y: 598), viewSize: CGSize(width: 800, height: 600),
                                   scale: 2, imageSize: CGSize(width: 1600, height: 1200))
        // No room right or above: it moves left and below the size label.
        #expect(loupe.frame == CGRect(x: 599, y: 375, width: 175, height: 175))
        #expect(loupe.source == CGRect(x: 1584, y: 0, width: 16, height: 17))
        // The missing pixels stay black above and right of the ones drawn.
        #expect(loupe.destination == CGRect(x: 599, y: 375, width: 112, height: 119))
    }

    @Test func aBoxThatRepeatsAWindowFrameIsOfferedOnce() {
        // The window's content area, found in the pixels a point inside its frame.
        let candidates = SmartAreaCandidates(pixelBoxes: [CGRect(x: 42, y: 42, width: 996, height: 796)], scale: 2,
            windows: [CGRect(x: 20, y: 20, width: 500, height: 400)], displaySize: CGSize(width: 800, height: 600))
        #expect(candidates.stack(at: CGPoint(x: 100, y: 100)) == [
            CGRect(x: 20, y: 20, width: 500, height: 400), CGRect(x: 0, y: 0, width: 800, height: 600),
        ])
    }
}
