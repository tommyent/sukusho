//
//  RecordingInk.swift
//  Screendrop
//
//  Pen strokes drawn on screen during a take. The live pen panel is left out
//  of the capture, so the strokes live only here, in input.json, and Studio
//  and export draw them through the same zoom and crop as the cursor.
//

import CoreGraphics
import Foundation

/// One stroke on the screen movie's source clock, with top-left normalized
/// points like the pointer sidecar.
nonisolated struct RecordingInkStroke: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var color = RecordingInkColor.marker
    /// Line width as a fraction of the source's shorter side.
    var width: Double
    var points: [RecordingInkPoint]
    /// When the stroke starts to disappear; nil keeps it to the end.
    var hideTime: TimeInterval?
    /// False once undone: the stroke goes at once instead of fading.
    var fadesOut = true

    var startTime: TimeInterval { points.first?.t ?? 0 }
}

nonisolated struct RecordingInkPoint: Codable, Equatable, Sendable {
    var t: TimeInterval
    var x: Double
    var y: Double
}

nonisolated struct RecordingInkColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    /// The one marker colour: system red.
    static let marker = RecordingInkColor(red: 1, green: 0.231, blue: 0.188)

    func cgColor(opacity: Double) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: opacity)
    }
}

/// A live stroke before Stop: host uptime and Quartz global points, mapped
/// onto the movie with the cursor's own time and geometry mapping.
nonisolated struct RecordingInkCapture: Sendable {
    struct Sample: Sendable {
        var uptime: TimeInterval
        var point: CGPoint
    }

    var id = UUID()
    var samples: [Sample]
    var widthInPoints: Double
    var hideUptime: TimeInterval?
    var fadesOut = true
}

nonisolated extension RecordingInkStroke {
    /// Samples the movie can't place (before its first frame) are dropped,
    /// and so is a stroke drawn wholly outside the recorded window, which
    /// would replay as nothing. A hide after Stop keeps the stroke.
    static func mapped(
        _ captures: [RecordingInkCapture],
        widthBase: Double,
        time: (TimeInterval) -> TimeInterval?,
        point: (CGPoint, TimeInterval) -> (x: Double, y: Double)?
    ) -> [RecordingInkStroke] {
        guard widthBase > 0 else { return [] }
        return captures.compactMap { capture in
            let points = capture.samples.compactMap { sample -> RecordingInkPoint? in
                guard let t = time(sample.uptime), let p = point(sample.point, sample.uptime) else { return nil }
                return RecordingInkPoint(t: t, x: p.x, y: p.y)
            }
            guard points.contains(where: { (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return nil }
            return RecordingInkStroke(
                id: capture.id,
                width: capture.widthInPoints / widthBase,
                points: points,
                hideTime: capture.hideUptime.flatMap(time),
                fadesOut: capture.fadesOut
            )
        }
    }

    /// Drops what can't be drawn and orders points and strokes by time.
    static func sanitized(_ strokes: [RecordingInkStroke]) -> [RecordingInkStroke] {
        strokes.compactMap { stroke in
            var stroke = stroke
            stroke.points = stroke.points
                .filter { $0.t.isFinite && $0.x.isFinite && $0.y.isFinite }
                .sorted { $0.t < $1.t }
            guard !stroke.points.isEmpty, stroke.width.isFinite, stroke.width > 0,
                  stroke.hideTime?.isFinite ?? true else { return nil }
            stroke.points = stroke.points.map { var point = $0; point.t = max(0, point.t); return point }
            return stroke
        }
        .sorted { $0.startTime < $1.startTime }
    }
}

/// What is on screen at a source time: each stroke drawn so far, as far as
/// it had been drawn, and how faded it is.
nonisolated struct RecordingInkTimeline: Sendable {
    /// The live pen's rule too: a group of strokes stays for 2.5 s after
    /// its last pen-up, then fades out over 0.5 s.
    static let holdDuration: TimeInterval = 2.5
    static let fadeDuration: TimeInterval = 0.5

    struct Frame: Sendable {
        let stroke: RecordingInkStroke
        let pointCount: Int
        let opacity: Double

        var points: ArraySlice<RecordingInkPoint> { stroke.points.prefix(pointCount) }
    }

    let strokes: [RecordingInkStroke]

    init(strokes: [RecordingInkStroke], hiding hidden: Set<UUID> = []) {
        self.strokes = strokes.filter { !hidden.contains($0.id) }
    }

    var isEmpty: Bool { strokes.isEmpty }

    func frames(at time: TimeInterval) -> [Frame] {
        strokes.compactMap { stroke in
            guard let first = stroke.points.first, time >= first.t else { return nil }
            let opacity = Self.opacity(hideTime: stroke.hideTime, fadesOut: stroke.fadesOut, at: time)
            guard opacity > 0, let last = stroke.points.lastIndex(atOrBefore: time, by: \.t) else { return nil }
            return Frame(stroke: stroke, pointCount: last + 1, opacity: opacity)
        }
    }

    static func opacity(hideTime: TimeInterval?, fadesOut: Bool, at time: TimeInterval) -> Double {
        guard let hideTime, time >= hideTime else { return 1 }
        guard fadesOut else { return 0 }
        return max(0, 1 - (time - hideTime) / fadeDuration)
    }
}

nonisolated enum RecordingInkPath {
    /// Quadratic curves through the midpoints of successive samples, so the
    /// live pen, Studio and export draw the same line. One point is a dot.
    static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: first)
        for index in points.indices.dropFirst().dropLast() {
            let next = points[index + 1]
            path.addQuadCurve(
                to: CGPoint(x: (points[index].x + next.x) / 2, y: (points[index].y + next.y) / 2),
                control: points[index]
            )
        }
        path.addLine(to: last)
        return path
    }

    static func stroke(_ path: CGPath, color: RecordingInkColor, opacity: Double, width: CGFloat, in context: CGContext) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(width)
        context.setStrokeColor(color.cgColor(opacity: opacity))
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
}
