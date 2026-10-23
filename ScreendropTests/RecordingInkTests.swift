import CoreGraphics
import Foundation
import Testing

struct RecordingInkTests {
    private func stroke(start: TimeInterval = 1, hideTime: TimeInterval? = 5, fadesOut: Bool = true) -> RecordingInkStroke {
        RecordingInkStroke(
            width: 0.01,
            points: (0..<5).map { RecordingInkPoint(t: start + Double($0) * 0.25, x: 0.1 + Double($0) * 0.1, y: 0.5) },
            hideTime: hideTime,
            fadesOut: fadesOut
        )
    }

    @Test func legacySidecarsOpenWithoutInkAndNewOnesRoundTrip() throws {
        var capture = PointerCaptureFile()
        capture.travel = [PointerTravelSample(time: 0, x: 0.5, y: 0.5)]
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(capture)) as? [String: Any])
        legacy.removeValue(forKey: "ink")
        let decoded = try JSONDecoder().decode(PointerCaptureFile.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.ink.isEmpty && decoded.travel == capture.travel)

        capture.ink = [stroke()]
        #expect(try JSONDecoder().decode(PointerCaptureFile.self, from: JSONEncoder().encode(capture)) == capture)
    }

    @Test func sanitizerKeepsInkInTimeOrderAndDropsWhatCannotBeDrawn() {
        let late = stroke(start: 3)
        var early = stroke(start: 1)
        early.points.swapAt(0, 4)
        early.points.append(RecordingInkPoint(t: .nan, x: 0, y: 0))
        var empty = stroke(); empty.points = []
        var zeroWidth = stroke(); zeroWidth.width = 0
        var capture = PointerCaptureFile()
        capture.ink = [late, early, empty, zeroWidth]

        let ink = PointerStreamSanitizer.sanitize(
            capture, options: PointerSanitizeOptions(recordingSizeInPoints: CGSize(width: 800, height: 600))
        ).sanitizedCapture.ink

        #expect(ink.map(\.id) == [early.id, late.id])
        #expect(ink[0].points == stroke(start: 1).points)
        #expect(ink[1] == late)
    }

    @Test func strokesDrawAsRecordedThenFadeOrVanish() throws {
        let fading = stroke(hideTime: 5)
        let undone = stroke(start: 2, hideTime: 4, fadesOut: false)
        let timeline = RecordingInkTimeline(strokes: [fading, undone])

        #expect(timeline.frames(at: 0.9).isEmpty)
        let drawing = try #require(timeline.frames(at: 1.3).first)
        #expect(drawing.pointCount == 2 && drawing.opacity == 1)
        #expect(timeline.frames(at: 3).map(\.pointCount) == [5, 5])
        #expect(timeline.frames(at: 4).map(\.stroke.id) == [fading.id])
        #expect(abs(try #require(timeline.frames(at: 5.25).first).opacity - 0.5) < 0.0001)
        #expect(timeline.frames(at: 5.5).isEmpty)

        let hidden = RecordingInkTimeline(strokes: [fading, undone], hiding: [fading.id])
        #expect(hidden.frames(at: 3).map(\.stroke.id) == [undone.id])
    }

    @Test func replayFollowsCutsAndSpeedThroughTheClipTimeline() {
        // Keep 0-1.5 s, cut 1.5-3 s, then play 3-7 s at 2x.
        let clips = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 1.5),
            RecordingClipSegment(sourceStart: 3, sourceEnd: 7, speed: 2)
        ])
        let timeline = RecordingInkTimeline(strokes: [stroke(start: 1, hideTime: 4)])

        #expect(timeline.frames(at: clips.sourceTime(at: 1.25)).first?.pointCount == 2)
        // Past the cut the stroke is complete; 0.5 s of editor time is 1 s of source at 2x.
        #expect(timeline.frames(at: clips.sourceTime(at: 1.6)).first?.pointCount == 5)
        #expect(abs((timeline.frames(at: clips.sourceTime(at: 2.125)).first?.opacity ?? 0) - 0.5) < 0.0001)
        #expect(timeline.frames(at: clips.sourceTime(at: 2.25)).isEmpty)
    }

    @Test func liveStrokesMapOntoTheMovieAndDropWhatItCannotPlace() throws {
        let captures = [
            RecordingInkCapture(samples: [
                .init(uptime: 9, point: CGPoint(x: 100, y: 100)),   // before the first frame
                .init(uptime: 11, point: CGPoint(x: 200, y: 150)),
                .init(uptime: 12, point: CGPoint(x: 400, y: 300))
            ], widthInPoints: 6, hideUptime: 14),
            RecordingInkCapture(samples: [.init(uptime: 9.5, point: .zero)], widthInPoints: 6),
            RecordingInkCapture(samples: [.init(uptime: 13, point: CGPoint(x: 80, y: 60))], widthInPoints: 6, hideUptime: 99),
            // Below the recorded window: nothing of it is on the movie.
            RecordingInkCapture(samples: [.init(uptime: 14, point: CGPoint(x: 100, y: 700)),
                                          .init(uptime: 15, point: CGPoint(x: 300, y: 900))], widthInPoints: 6)
        ]
        let strokes = RecordingInkStroke.mapped(
            captures, widthBase: 600,
            time: { $0 >= 10 && $0 <= 20 ? $0 - 10 : nil },
            point: { point, _ in (x: point.x / 800, y: point.y / 600) }
        )

        #expect(strokes.count == 2)
        let first = try #require(strokes.first)
        #expect(first.id == captures[0].id && first.width == 0.01 && first.hideTime == 4)
        #expect(first.points == [RecordingInkPoint(t: 1, x: 0.25, y: 0.25), RecordingInkPoint(t: 2, x: 0.5, y: 0.5)])
        // Still on screen at Stop: it stays to the end.
        #expect(strokes[1].hideTime == nil && strokes[1].startTime == 3)
    }

    @Test func pathRunsFromFirstToLastSampleAndOnePointIsADot() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 10)]
        let path = RecordingInkPath.path(points)
        #expect(path.currentPoint == points[3])
        #expect(path.boundingBoxOfPath.contains(CGPoint(x: 10, y: 5)))
        let dot = RecordingInkPath.path([CGPoint(x: 4, y: 4)])
        #expect(!dot.isEmpty && dot.currentPoint == CGPoint(x: 4, y: 4))
        #expect(RecordingInkPath.path([]).isEmpty)
    }
}
