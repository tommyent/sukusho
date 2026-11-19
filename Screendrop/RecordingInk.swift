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
import CoreText

/// One stroke on the screen movie's source clock, with top-left normalized
/// points like the pointer sidecar.
nonisolated struct RecordingMarkerTarget: Codable, Equatable, Sendable {
    var role: String?
    var label: String?
    var window: String?
}

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

    var fittedOval: Bool?
    var visibilityChanges: [TimeInterval]?
    var markerNumber: Int?
    var target: RecordingMarkerTarget?

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
    var fittedOval: Bool?
    var visibilityChanges: [TimeInterval]?
    var markerNumber: Int?
    var target: RecordingMarkerTarget?
    var hideUptime: TimeInterval?
    var fadesOut = true
}

nonisolated extension RecordingInkStroke {
    /// Samples the movie can't place (before its first frame) are dropped,
    /// and so is a stroke drawn wholly outside the recorded window, which
    /// would replay as nothing. A hide after Stop keeps the stroke.
    /// `widthScale` turns screen points at an uptime into a fraction of the
    /// movie's shorter side; it is taken at the stroke's first sample.
    static func mapped(
        _ captures: [RecordingInkCapture],
        widthScale: (TimeInterval) -> Double?,
        time: (TimeInterval) -> TimeInterval?,
        point: (CGPoint, TimeInterval) -> (x: Double, y: Double)?
    ) -> [RecordingInkStroke] {
        captures.compactMap { capture in
            guard let firstUptime = capture.samples.first?.uptime,
                  let scale = widthScale(firstUptime), scale > 0 else { return nil }
            let points = capture.samples.compactMap { sample -> RecordingInkPoint? in
                guard let t = time(sample.uptime), let p = point(sample.point, sample.uptime) else { return nil }
                return RecordingInkPoint(t: t, x: p.x, y: p.y)
            }
            guard points.contains(where: { (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return nil }
            return RecordingInkStroke(
                id: capture.id,
                width: capture.widthInPoints * scale,
                points: points,
                hideTime: capture.hideUptime.flatMap(time),
                fadesOut: capture.fadesOut,
                fittedOval: capture.fittedOval,
                visibilityChanges: capture.visibilityChanges?.compactMap(time),
                markerNumber: capture.markerNumber, target: capture.target
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

nonisolated struct RecordingInkHistory {
    enum Edit { case added(Int), cleared([Int]) }
    private var edits: [Edit] = []
    private var nextNumber = 1

    mutating func added(at index: Int, marker: Bool) -> Int? {
        edits.append(.added(index))
        guard marker else { return nil }
        defer { nextNumber += 1 }
        return nextNumber
    }

    static func persists(marker: Bool, bugReport: Bool) -> Bool { marker || bugReport }

    mutating func clear(_ strokes: inout [RecordingInkCapture], at time: TimeInterval) {
        let visible = strokes.indices.filter { strokes[$0].visible(at: time) }
        guard !visible.isEmpty else { return }
        for i in visible { strokes[i].toggleVisibility(at: time) }
        edits.append(.cleared(visible))
    }

    mutating func undo(_ strokes: inout [RecordingInkCapture], at time: TimeInterval) {
        while let edit = edits.popLast() {
            switch edit {
            case .added(let i):
                guard strokes[i].visible(at: time) else { continue }
                strokes[i].toggleVisibility(at: time)
            case .cleared(let indices):
                for i in indices { strokes[i].toggleVisibility(at: time) }
            }
            return
        }
    }
}

nonisolated extension RecordingInkCapture {
    func visible(at time: TimeInterval) -> Bool {
        RecordingInkTimeline.isVisible(visibilityChanges, at: time) &&
        RecordingInkTimeline.opacity(hideTime: hideUptime, fadesOut: fadesOut, at: time) > 0
    }

    mutating func toggleVisibility(at time: TimeInterval) {
        if visibilityChanges == nil { visibilityChanges = [] }
        visibilityChanges?.append(time)
    }
}

nonisolated enum RecordingPenButtonClick {
    /// The listen-only tap records the bar click that turns the pen on
    /// before the button acts. That click, however long it was held, is the
    /// newest press-down on the bar, its duplicate from the AppKit monitors,
    /// and what followed it on the bar. Presses anywhere else are real.
    static func remove<Press>(
        from presses: inout [Press],
        bar: CGRect,
        duplicateWindow: TimeInterval,
        uptime: (Press) -> TimeInterval,
        point: (Press) -> CGPoint,
        isDown: (Press) -> Bool
    ) {
        guard let down = presses.last(where: { isDown($0) && bar.contains(point($0)) }) else { return }
        let start = uptime(down) - duplicateWindow
        presses.removeAll { uptime($0) >= start && bar.contains(point($0)) }
    }
}

nonisolated enum RecordingPressCopies {
    /// One physical click reaches the capture from both the event tap and the AppKit monitors, and
    /// a monitor's copy can arrive after the tap has already delivered the release (sd-k0g0). So a
    /// press is a copy when any press within `window` of it, not only the last, matches it. A
    /// person's double-click repeats far slower than the window.
    static func isCopy<Press>(_ press: Press, of presses: [Press], window: TimeInterval,
                              uptime: (Press) -> TimeInterval, matches: (Press, Press) -> Bool) -> Bool {
        copyIndex(press, of: presses, window: window, uptime: uptime, matches: matches) != nil
    }

    /// The index of the press `press` copies, if any.
    static func copyIndex<Press>(_ press: Press, of presses: [Press], window: TimeInterval,
                                 uptime: (Press) -> TimeInterval, matches: (Press, Press) -> Bool) -> Int? {
        for index in presses.indices.reversed() {
            let earlier = presses[index]
            // Presses arrive in time order, give or take a copy's delay.
            if uptime(press) - uptime(earlier) >= window { return nil }
            if abs(uptime(press) - uptime(earlier)) < window, matches(earlier, press) { return index }
        }
        return nil
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
            guard Self.isVisible(stroke.visibilityChanges, at: time), opacity > 0, let last = stroke.points.lastIndex(atOrBefore: time, by: \.t) else { return nil }
            return Frame(stroke: stroke, pointCount: last + 1, opacity: opacity)
        }
    }

    static func isVisible(_ changes: [TimeInterval]?, at time: TimeInterval) -> Bool {
        (changes?.prefix(while: { $0 <= time }).count ?? 0).isMultiple(of: 2)
    }

    static func opacity(hideTime: TimeInterval?, fadesOut: Bool, at time: TimeInterval) -> Double {
        guard let hideTime, time >= hideTime else { return 1 }
        guard fadesOut else { return 0 }
        return max(0, 1 - (time - hideTime) / fadeDuration)
    }
}

nonisolated enum RecordingInkPath {
    static func smoothed(_ samples: [CGPoint]) -> [CGPoint] {
        guard samples.count >= 3 else { return samples }
        var result = samples
        for i in 1..<(samples.count - 1) {
            let radius = min(2, i, samples.count - 1 - i)
            var x = 0.0, y = 0.0, sum = 0.0
            for offset in -radius...radius {
                let weight = Double(3 - abs(offset))
                x += samples[i + offset].x * weight
                y += samples[i + offset].y * weight
                sum += weight
            }
            result[i] = CGPoint(x: x / sum, y: y / sum)
        }
        return result
    }

    /// Quadratic curves through the midpoints of successive samples, so the
    /// live pen, Studio and export draw the same line. One point is a dot.
    static func path(_ samples: [CGPoint]) -> CGPath {
        let points = smoothed(samples)
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

    /// Receives top-left drawing coordinates from every output, including the live panel.
    static func fitsOval(_ points: [CGPoint]) -> Bool {
        guard points.count >= 5, let first = points.first, let last = points.last else { return false }
        let box = bounds(of: points)
        guard min(box.width, box.height) >= 8,
              hypot(first.x - last.x, first.y - last.y) <= min(box.width, box.height) * 0.35 else { return false }
        let twiceArea = zip(points, points.dropFirst() + [first]).reduce(0.0) { sum, pair in
            sum + (pair.0.x - first.x) * (pair.1.y - first.y) - (pair.1.x - first.x) * (pair.0.y - first.y)
        }
        return abs(twiceArea) >= box.width * box.height * 0.65
    }

    private static func bounds(of points: [CGPoint]) -> CGRect {
        points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    static func draw(_ points: [CGPoint], oval: Bool = false, marker: Int?, color: RecordingInkColor, opacity: Double,
                     width: CGFloat, bounds: CGRect, in context: CGContext) {
        guard let number = marker, let tip = points.first else {
            let geometry = oval ? CGPath(ellipseIn: Self.bounds(of: points), transform: nil) : path(points)
            stroke(geometry, color: color, opacity: opacity, width: width, in: context)
            return
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(opacity)
        context.translateBy(x: tip.x, y: tip.y)
        let scale = width / 6
        context.scaleBy(x: scale, y: scale)
        let center = CGPoint(x: tip.x + 36 * scale <= bounds.maxX ? 22 : -22,
                             y: tip.y - 40 * scale >= bounds.minY ? -26 : 26)
        let navy = CGColor(srgbRed: 0.09, green: 0.13, blue: 0.19, alpha: 1)
        let white = CGColor(gray: 1, alpha: 1)
        context.setLineCap(.round)
        for (ink, thickness) in [(white, 4.0), (navy, 1.5)] {
            context.setStrokeColor(ink)
            context.setLineWidth(thickness)
            context.move(to: .zero)
            context.addLine(to: center)
            context.strokePath()
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(number), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 13, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white
        ]))
        let glyph = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let radius = max(10, glyph.width / 2 + 3)
        for (position, r) in [(CGPoint.zero, 2.6), (center, radius)] {
            context.setFillColor(navy)
            context.setStrokeColor(white)
            context.setLineWidth(1.5)
            context.addEllipse(in: CGRect(x: position.x - r, y: position.y - r, width: 2*r, height: 2*r))
            context.drawPath(using: .fillStroke)
        }
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -glyph.midX, y: -glyph.midY)
        CTLineDraw(line, context)
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
