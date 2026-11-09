import CoreGraphics
import Foundation
import Testing

@Suite
struct ShakeDetectorTests {
    /// Feeds a side-to-side wave sampled at `rate` per second; the times it fired.
    private func fires(hz: Double, amplitude: CGFloat, seconds: Double, rate: Double = 120,
                       detector: inout ShakeDetector) -> [TimeInterval] {
        var times: [TimeInterval] = []
        for step in 0...Int(seconds * rate) {
            let time = Double(step) / rate
            let x = 500 + amplitude * CGFloat(sin(2 * .pi * hz * time))
            if detector.add(x: x, time: time) { times.append(time) }
        }
        return times
    }

    private func fires(hz: Double, amplitude: CGFloat, seconds: Double, rate: Double = 120) -> [TimeInterval] {
        var detector = ShakeDetector()
        return fires(hz: hz, amplitude: amplitude, seconds: seconds, rate: rate, detector: &detector)
    }

    @Test func aBriskShakeFiresOnItsThirdTurn() throws {
        // Out and back 4 times a second, 80 points wide: it turns at 0.19, 0.31 and 0.44 s,
        // and the last turn counts once the pointer is half a stroke back.
        let first = try #require(fires(hz: 4, amplitude: 40, seconds: 1).first)
        #expect(first > 0.44 && first < 0.55)
    }

    @Test func aSmallSlowShakeStillCounts() {
        // 60-point strokes at 2.5 Hz: three turns 0.2 s apart.
        #expect(!fires(hz: 2.5, amplitude: 30, seconds: 1).isEmpty)
    }

    @Test func coarseSamplesStillCount() {
        // A busy Mac or VM may deliver drag events at 30 a second.
        #expect(!fires(hz: 4, amplitude: 50, seconds: 1, rate: 30).isEmpty)
    }

    @Test func slowSwayingIsAimingNotShaking() {
        #expect(fires(hz: 1.5, amplitude: 80, seconds: 3).isEmpty)
    }

    @Test func jitterAndSmallCorrectionsNeverCount() {
        // 30-point strokes, however fast, stay under the 40-point stroke.
        #expect(fires(hz: 8, amplitude: 15, seconds: 3).isEmpty)
        #expect(fires(hz: 5, amplitude: 19, seconds: 3).isEmpty)
    }

    @Test func aStraightDragNeverCounts() {
        var detector = ShakeDetector()
        let fired = (0...120).contains { step in
            detector.add(x: CGFloat(step) * 8, time: Double(step) / 120)
        }
        #expect(!fired)
    }

    @Test func aPauseStartsTheCountOver() {
        var detector = ShakeDetector()
        // Out, back, out: two turns.
        let strokes: [(CGFloat, TimeInterval)] = [(0, 0), (60, 0.08), (0, 0.16), (60, 0.24)]
        #expect(!strokes.contains { detector.add(x: $0.0, time: $0.1) })
        // Held still past the window, then two more turns: never three in a row.
        let later: [(CGFloat, TimeInterval)] = [(60, 0.9), (0, 0.98), (60, 1.06), (0, 1.14)]
        #expect(!later.contains { detector.add(x: $0.0, time: $0.1) })
    }

    @Test func turnsSpreadOverMoreThanTheWindowDontCount() {
        var detector = ShakeDetector()
        // Each stroke takes 0.3 s: the three turns span 0.6 s.
        let points: [(CGFloat, TimeInterval)] = (0...8).flatMap { stroke -> [(CGFloat, TimeInterval)] in
            let from: CGFloat = stroke.isMultiple(of: 2) ? 0 : 100
            let to: CGFloat = 100 - from
            return (0..<10).map { step in
                (from + (to - from) * CGFloat(step) / 10, Double(stroke) * 0.3 + Double(step) * 0.03)
            }
        }
        #expect(!points.contains { detector.add(x: $0.0, time: $0.1) })
    }

    @Test func firingStartsTheCountOver() {
        var detector = ShakeDetector()
        // A 4 Hz shake turns every 0.125 s, so a second shake needs three more turns.
        let times = fires(hz: 4, amplitude: 40, seconds: 1.2, detector: &detector)
        #expect(times.count == 2)
        if times.count == 2 { #expect(times[1] - times[0] >= 0.375 - 0.01) }
    }

    @Test func galleriesNeedTwoOrMoreReadableImagesAndAWorkerThatHasThem() {
        let images = ["a.png", "b.JPG", "c.heic"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        #expect(ShakeShelfFiles.canShareGallery(images, workerSupportsGalleries: true))
        #expect(!ShakeShelfFiles.canShareGallery(images, workerSupportsGalleries: false))
        #expect(!ShakeShelfFiles.canShareGallery(Array(images.prefix(1)), workerSupportsGalleries: true))
        let mixed = images + [URL(fileURLWithPath: "/tmp/notes.pdf")]
        #expect(!ShakeShelfFiles.canShareGallery(mixed, workerSupportsGalleries: true))
        let withMovie = images + [URL(fileURLWithPath: "/tmp/clip.mov")]
        #expect(!ShakeShelfFiles.canShareGallery(withMovie, workerSupportsGalleries: true))
        let noExtension = images + [URL(fileURLWithPath: "/tmp/README")]
        #expect(!ShakeShelfFiles.canShareGallery(noExtension, workerSupportsGalleries: true))
        let tooMany = (0...CloudGalleryAPI.maxImages).map { URL(fileURLWithPath: "/tmp/\($0).png") }
        #expect(!ShakeShelfFiles.canShareGallery(tooMany, workerSupportsGalleries: true))
    }
}
