import Foundation

/// Vision proposes, exact pixels confirm, no frame is lost: each frame is
/// placed against the last reference frame, or skipped until one fits.
/// Frames are tightly packed BGRA, all the size of the first.
///
/// The output is the first frame down to the cut, every row appended since,
/// then the last reference frame from the cut down: the rows below the cut are
/// held back (see `ScrollingCaptureOffsetVerifier.heldBackFraction`). A sidebar
/// pinned while the content moved is shown once (`PinnedRun`).
actor ScrollingCaptureFrameStitcher {
    enum Placement: Equatable, Sendable {
        /// Moved up by this many rows; they were appended.
        case appended(Int)
        /// Didn't move: the page redrew in place, nothing appended.
        case redrawn
        /// Moved back down this far (negative), the first frame in a row to
        /// do so: nothing changes yet, so one stray frame can't trim.
        case upward(Int)
        /// Moved back down again: the output was cut back to end with it.
        case trimmed(Int)
        /// Moved back down again, above where the output began: it starts
        /// over from this frame.
        case restarted(Int)
        /// Not verified: the reference stays, and the next frame is compared
        /// with it.
        case skipped

        var offset: Int? {
            switch self {
            case .appended(let k), .upward(let k), .trimmed(let k), .restarted(let k): k
            case .redrawn: 0
            case .skipped: nil
            }
        }

        /// The frame became the reference the next one is compared with.
        var isReference: Bool {
            switch self {
            case .appended, .redrawn, .trimmed, .restarted: true
            case .upward, .skipped: false
            }
        }
    }

    private let width: Int
    private let height: Int
    private let ignoredTrailingColumns: Int
    /// Rows above it are appended; rows below it are held back.
    // ponytail: a sticky footer taller than the held-back quarter is appended
    // into every slice; cut at the top of the footer (`ScrollingCaptureOffsetVerifier.unmovedEdges`) when
    // a capture shows one.
    private let cut: Int
    private var first: [UInt8]
    private var appended: [UInt8] = []
    private var last: [UInt8]
    /// The last frame was verified moving back down: the next one that does trims.
    private var lastWasUpward = false
    /// The last offset appended: tried when Vision's candidate doesn't verify.
    private var lastStep: Int?
    /// Side columns that stayed put while the content between them moved (`Verified.pinnedLeft` and
    /// `pinnedRight`), stuck at output row `start`, over output rows `from` to `end` (nil: still pinned).
    /// There the output shows the frame they stuck in from the cut down, once, then the side's most
    /// common colour in that frame (a column one colour down most of it, a divider, keeps that),
    /// instead of a slice of the same sidebar per step. A run that loses columns goes on in fewer from
    /// that row, as another run with the same `start`.
    private struct PinnedRun {
        let isLeft: Bool
        let columns: Range<Int>
        let start: Int
        var from: Int
        var end: Int?
        /// The frame's columns `stored`, rows 0..<height.
        let stored: Range<Int>
        let frame: [UInt8]
    }
    private var pinnedRuns: [PinnedRun] = []

    init?(firstFrame: [UInt8], width: Int, height: Int, ignoredTrailingColumns: Int) {
        guard width > 0, height > 0, firstFrame.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.ignoredTrailingColumns = ignoredTrailingColumns
        cut = ScrollingCaptureOffsetVerifier.cut(in: 0..<height)
        first = firstFrame
        last = firstFrame
    }

    var stitchedHeight: Int { height + appended.count / (width * 4) }

    /// Where the frame went, and Vision's candidate against the reference
    /// (nil when it had none), for the frame dump and the bar's message.
    func add(_ frame: [UInt8]) -> (placement: Placement, candidate: ScrollingCaptureOffsetEstimator.Candidate?) {
        guard frame.count == last.count else { lastWasUpward = false; return (.skipped, nil) }
        let candidate = ScrollingCaptureOffsetEstimator.candidate(from: last, to: frame,
            width: width, height: height, ignoredTrailingColumns: ignoredTrailingColumns)
        return (place(frame, candidate: candidate?.offset, alternatives: candidate?.alternatives ?? [],
                      bands: candidate?.bands ?? []), candidate)
    }

    /// Places a frame against the reference at Vision's candidate.
    /// - It says the view didn't move: a shift two of Vision's bands agree on, confirmed exactly,
    ///   wins instead. With a sidebar pinned on each side, the pinned columns alone confirm 0.
    /// - It doesn't verify: the last step appended and those shifts are tried. On repeating rows
    ///   (log lines, table rows) Vision can land a whole repeat off, and steady scrolling
    ///   (auto-scroll's equal steps) repeats the last step.
    /// The last step never overrides a confirmed 0 (at rest, rows repeating at that distance would
    /// confirm it too), unless still side columns alone confirmed it: then the content between them
    /// moved, and the last step and each band's own shift are tried there. Of two shifts far apart that
    /// both verify, the one most of Vision's bands saw wins (`ScrollingCaptureOffsetVerifier`'s votes).
    func place(_ frame: [UInt8], candidate: Int?, alternatives: [Int] = [], bands: [Int] = []) -> Placement {
        func verified(_ candidates: [Int]) -> ScrollingCaptureOffsetVerifier.Verified? {
            ScrollingCaptureOffsetVerifier.verifiedOffset(candidates: candidates, votes: bands, from: last, to: frame,
                width: width, height: height, ignoredTrailingColumns: ignoredTrailingColumns)
        }
        let moved = alternatives.filter { $0 != 0 && $0 != candidate }
        var found = candidate.flatMap { verified([$0]) }
        if found?.sidesOnly == true {
            found = verified(Array(Set(moved + bands + [lastStep].compactMap { $0 }).filter { $0 != 0 })) ?? found
        } else if found?.offset == 0, !moved.isEmpty {
            found = verified(moved) ?? found
        } else if found == nil {
            found = verified(Array(Set(moved + [lastStep].compactMap { $0 }.filter { $0 != candidate })))
        }
        guard frame.count == last.count, let found else {
            // A skipped frame breaks a run of upward frames.
            lastWasUpward = false
            return .skipped
        }
        let k = found.offset, rowBytes = width * 4
        if k < 0 {
            defer { lastWasUpward = true }
            guard lastWasUpward else { return .upward(k) }
            last = frame
            guard -k * rowBytes <= appended.count else {
                first = frame
                appended = []
                pinnedRuns = []
                return .restarted(k)
            }
            appended.removeLast(-k * rowBytes)
            // Runs past the new end are gone; the one it ends in is current again.
            let end = cut + appended.count / rowBytes
            pinnedRuns.removeAll { $0.from >= end }
            for i in pinnedRuns.indices where pinnedRuns[i].end ?? end >= end { pinnedRuns[i].end = nil }
            return .trimmed(k)
        }
        lastWasUpward = false
        // Never true: the verifier only confirms overlap above the cut.
        guard k < cut else { return .skipped }
        let previous = last
        last = frame
        guard k > 0 else { return .redrawn }
        updatePinnedRuns(left: found.pinnedLeft, right: found.pinnedRight, from: cut + appended.count / rowBytes,
                         previous: previous, offset: k)
        appended.append(contentsOf: frame[((cut - k) * rowBytes)..<(cut * rowBytes)])
        lastStep = k
        return .appended(k)
    }

    /// Packed BGRA, `stitchedHeight` rows, then `below`: more rows, the same width, that go on under
    /// the last frame, with `pinnedRuns` applied.
    func makeImage(appending below: [UInt8] = []) -> [UInt8] {
        let split = cut * width * 4
        var image = Array(first[..<split]) + appended + Array(last[split...]) + below
        let rows = image.count / (width * 4)
        image.withUnsafeMutableBytes { out in
            for run in pinnedRuns where run.from < rows {
                run.frame.withUnsafeBytes { frame in
                    func stored(_ x: Int, _ y: Int) -> UInt32 {
                        frame.loadUnaligned(fromByteOffset: (y * run.stored.count + x - run.stored.lowerBound) * 4, as: UInt32.self)
                    }
                    func mostCommon(_ counts: [UInt32: Int]) -> (colour: UInt32, count: Int) {
                        counts.max { ($0.value, $0.key) < ($1.value, $1.key) }.map { ($0.key, $0.value) } ?? (0, 0)
                    }
                    var side: [UInt32: Int] = [:]
                    let columns = run.columns.map { x in
                        var counts: [UInt32: Int] = [:]
                        for y in 0..<height { counts[stored(x, y), default: 0] += 1 }
                        side.merge(counts, uniquingKeysWith: +)
                        return mostCommon(counts)
                    }
                    let background = mostCommon(side).colour
                    // A column that is one colour down most of the frame (a divider, a border) goes on in it.
                    let fill = columns.map { $0.count * 4 >= height * 3 ? $0.colour : background }
                    for row in run.from..<min(run.end ?? rows, rows) {
                        let y = cut + row - run.start
                        for (i, x) in run.columns.enumerated() {
                            out.storeBytes(of: y < height ? stored(x, y) : fill[i], toByteOffset: (row * width + x) * 4, as: UInt32.self)
                        }
                    }
                }
            }
        }
        return image
    }

    /// Opens, narrows or ends each side's run for a frame appended at output row `row`, `offset` below
    /// `previous`. The right side takes the ignored trailing columns too: the overlay scroll bar's strip.
    private func updatePinnedRuns(left: Int, right: Int, from row: Int, previous: [UInt8], offset k: Int) {
        let usable = ScrollingCaptureOffsetVerifier.hashedWidth(width: width, ignoredTrailingColumns: ignoredTrailingColumns)
        /// The rows that changed in these columns, if most didn't move with the content: a sidebar redrawn
        /// in place (Wikipedia's contents reflowing as the current section turns bold), still pinned.
        func redrawnInPlace(_ columns: Range<Int>) -> Bool {
            func row(_ pixels: [UInt8], _ y: Int) -> ArraySlice<UInt8> {
                pixels[((y * width + columns.lowerBound) * 4)..<((y * width + columns.upperBound) * 4)]
            }
            var changed = 0, moved = 0
            for y in 0..<(height - k) where row(last, y) != row(previous, y) {
                changed += 1
                if row(last, y) == row(previous, y + k) { moved += 1 }
            }
            return changed == 0 || moved * 2 < changed
        }
        for (isLeft, pinned) in [(true, left), (false, right)] {
            let columns = isLeft ? 0..<pinned : (usable - pinned)..<(pinned > 0 ? width : usable - pinned)
            if let i = pinnedRuns.lastIndex(where: { $0.isLeft == isLeft && $0.end == nil }) {
                // The run's columns that aren't pinned this time leave it only when they moved with the
                // content (a footer pushing the sidebar up, say): from here it goes on in the rest, if any.
                let run = pinnedRuns[i]
                let kept = run.columns.clamped(to: columns.isEmpty ? (isLeft ? 0..<0 : width..<width) : columns)
                let dropped = isLeft ? kept.upperBound..<run.columns.upperBound : run.columns.lowerBound..<kept.lowerBound
                guard !dropped.isEmpty, !redrawnInPlace(dropped) else { continue }
                pinnedRuns[i].end = row
                if !kept.isEmpty {
                    pinnedRuns.append(PinnedRun(isLeft: isLeft, columns: kept, start: run.start, from: row,
                                                stored: run.stored, frame: run.frame))
                }
            } else if !columns.isEmpty {
                // `last` matches the new frame there, so its rows from the cut down go on from the rows above.
                let frame = (0..<height).flatMap { y in last[((y * width + columns.lowerBound) * 4)..<((y * width + columns.upperBound) * 4)] }
                pinnedRuns.append(PinnedRun(isLeft: isLeft, columns: columns, start: row, from: row, stored: columns, frame: frame))
            }
        }
    }
}
