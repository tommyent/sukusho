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
    /// There the output shows the frame they stuck in from the cut down to the band's bottom, once, then
    /// the side's most common colour in that frame (a column one colour down most of it, a divider, keeps
    /// that), instead of a slice of the same sidebar per step. A run that loses columns goes on in fewer from
    /// that row, as another run with the same `start`.
    private struct PinnedRun {
        let isLeft: Bool
        let columns: Range<Int>
        let start: Int
        var from: Int
        var end: Int?
        /// The frame's columns `stored`, from its top down to the band's bottom.
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
    func add(_ frame: [UInt8], allowUpward: Bool = true) -> (placement: Placement, candidate: ScrollingCaptureOffsetEstimator.Candidate?) {
        guard frame.count == last.count else { lastWasUpward = false; return (.skipped, nil) }
        let candidate = ScrollingCaptureOffsetEstimator.candidate(from: last, to: frame,
            width: width, height: height, ignoredTrailingColumns: ignoredTrailingColumns)
        let wasUpward = lastWasUpward
        let placement = place(frame, candidate: candidate?.offset, alternatives: candidate?.alternatives ?? [],
                              bands: candidate?.bands ?? [], allowUpward: allowUpward)
        if placement == .skipped,
           let fallback = ScrollingCaptureOffsetVerifier.uniqueLineUpCandidate(from: last, to: frame, width: width,
               height: height, ignoredTrailingColumns: ignoredTrailingColumns),
           let found = ScrollingCaptureOffsetVerifier.verifiedOffset(candidates: [fallback],
               votes: candidate?.bands ?? [], from: last, to: frame, width: width, height: height,
               ignoredTrailingColumns: ignoredTrailingColumns),
           found.offset != 0, abs(found.offset - fallback) <= ScrollingCaptureOffsetVerifier.search {
            lastWasUpward = wasUpward
            return (apply(found, to: frame, allowUpward: allowUpward), candidate)
        }
        return (placement, candidate)
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
    func place(_ frame: [UInt8], candidate: Int?, alternatives: [Int] = [], bands: [Int] = [],
               allowUpward: Bool = true) -> Placement {
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
        return apply(found, to: frame, allowUpward: allowUpward)
    }

    private func apply(_ found: ScrollingCaptureOffsetVerifier.Verified, to frame: [UInt8], allowUpward: Bool = true) -> Placement {
        let k = found.offset, rowBytes = width * 4
        if k < 0 {
            guard allowUpward else {
                lastWasUpward = false
                return .skipped
            }
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

    /// The capture so far, shrunk for the live preview: every `step`th pixel of every `step`th
    /// row, packed like `makeImage`, with `step` the smallest that fits `maxWidth`.
    // shortcut: nearest-neighbour and without `pinnedRuns`, which reads fine at thumbnail
    // size and costs nothing per frame; average the pixels if the preview ever gets large.
    func preview(maxWidth: Int) -> (pixels: [UInt8], width: Int, height: Int) {
        let step = Swift.max(1, (width + Swift.max(1, maxWidth) - 1) / Swift.max(1, maxWidth))
        let outWidth = (width + step - 1) / step, outHeight = (stitchedHeight + step - 1) / step
        let rowBytes = width * 4, appendedRows = appended.count / rowBytes
        var out = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        out.withUnsafeMutableBytes { out in
            first.withUnsafeBytes { first in
                appended.withUnsafeBytes { appended in
                    last.withUnsafeBytes { last in
                        for outY in 0..<outHeight {
                            let y = outY * step
                            // The same three pieces `makeImage` joins: the first frame down to the
                            // cut, what was appended, the last frame from the cut.
                            let (source, base) = y < cut ? (first, y * rowBytes)
                                : y < cut + appendedRows ? (appended, (y - cut) * rowBytes)
                                : (last, (y - appendedRows) * rowBytes)
                            for outX in 0..<outWidth {
                                out.storeBytes(of: source.loadUnaligned(fromByteOffset: base + outX * step * 4, as: UInt32.self),
                                               toByteOffset: (outY * outWidth + outX) * 4, as: UInt32.self)
                            }
                        }
                    }
                }
            }
        }
        return (out, outWidth, outHeight)
    }

    /// Packed BGRA, `stitchedHeight` rows, then `below`: more rows, the same width, that go on under
    /// the last frame. Pinned runs apply only to rows from captured frames.
    func makeImage(appending below: [UInt8] = []) -> [UInt8] {
        let split = cut * width * 4
        var image: [UInt8] = []
        image.reserveCapacity(split + appended.count + (last.count - split) + below.count)
        image.append(contentsOf: first[..<split])
        image.append(contentsOf: appended)
        image.append(contentsOf: last[split...])
        image.append(contentsOf: below)
        image.withUnsafeMutableBytes { applyPinnedRuns(to: $0) }
        return image
    }

    /// Same pixels as `makeImage(appending:)`, built directly into `Data` so `CGDataProvider`
    /// takes it without a second full-image copy.
    func makeImageData(appending below: [UInt8] = []) -> Data {
        let split = cut * width * 4
        var data = Data()
        data.reserveCapacity(split + appended.count + (last.count - split) + below.count)
        if split > 0 {
            first.withUnsafeBytes { data.append($0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: split) }
        }
        data.append(contentsOf: appended)
        if last.count > split {
            last.withUnsafeBytes { data.append($0.baseAddress!.advanced(by: split).assumingMemoryBound(to: UInt8.self), count: last.count - split) }
        }
        data.append(contentsOf: below)
        data.withUnsafeMutableBytes { applyPinnedRuns(to: $0) }
        return data
    }

    /// What a run paints in each of its columns below its stored rows: the side's most common colour in its
    /// frame, or the column's own where it is one colour down most of the frame (a divider, a border).
    private func fill(of run: PinnedRun) -> [UInt32] {
        let storedRows = run.frame.count / (run.stored.count * 4)
        return run.frame.withUnsafeBytes { frame in
            func mostCommon(_ counts: [UInt32: Int]) -> (colour: UInt32, count: Int) {
                counts.max { ($0.value, $0.key) < ($1.value, $1.key) }.map { ($0.key, $0.value) } ?? (0, 0)
            }
            var side: [UInt32: Int] = [:]
            let columns = run.columns.map { x in
                var counts: [UInt32: Int] = [:]
                for y in 0..<storedRows {
                    counts[frame.loadUnaligned(fromByteOffset: (y * run.stored.count + x - run.stored.lowerBound) * 4, as: UInt32.self), default: 0] += 1
                }
                side.merge(counts, uniquingKeysWith: +)
                return mostCommon(counts)
            }
            let background = mostCommon(side).colour
            return columns.map { $0.count * 4 >= storedRows * 3 ? $0.colour : background }
        }
    }

    private func applyPinnedRuns(to out: UnsafeMutableRawBufferPointer) {
        let end = stitchedHeight
        let tail = cut + appended.count / (width * 4)
        for run in pinnedRuns where run.from < end {
            let storedRows = run.frame.count / (run.stored.count * 4)
            let fill = self.fill(of: run)
            run.frame.withUnsafeBytes { frame in
                func stored(_ x: Int, _ y: Int) -> UInt32 {
                    frame.loadUnaligned(fromByteOffset: (y * run.stored.count + x - run.stored.lowerBound) * 4, as: UInt32.self)
                }
                var runEnd = min(run.end ?? end, end)
                if run.end == nil {
                    let judged = run.columns.clamped(to: 0..<ScrollingCaptureOffsetVerifier.hashedWidth(
                        width: width, ignoredTrailingColumns: ignoredTrailingColumns))
                    if !judged.isEmpty {
                        var firstFooterRow = height
                        // shortcut: infer a footer only when it replaces most of the side for eight
                        // rows; use row provenance if sparse footers need support.
                        self.last.withUnsafeBytes { last in
                            self.first.withUnsafeBytes { first in
                                for y in stride(from: height - 1, through: cut, by: -1) {
                                    let changed = judged.reduce(0) { count, x in
                                        let at = (y * width + x) * 4
                                        let actual = last.loadUnaligned(fromByteOffset: at, as: UInt32.self)
                                        let original = first.loadUnaligned(fromByteOffset: at, as: UInt32.self)
                                        let pinned = y < storedRows ? stored(x, y) : fill[x - run.columns.lowerBound]
                                        return count + (actual != original && actual != pinned ? 1 : 0)
                                    }
                                    guard changed * 4 >= judged.count * 3 else { break }
                                    firstFooterRow = y
                                }
                            }
                        }
                        if height - firstFooterRow >= 8 {
                            runEnd = min(runEnd, tail + firstFooterRow - cut)
                        }
                    }
                }
                for row in run.from..<max(run.from, runEnd) {
                    let y = cut + row - run.start
                    for (i, x) in run.columns.enumerated() {
                        out.storeBytes(of: y < storedRows ? stored(x, y) : fill[i], toByteOffset: (row * width + x) * 4, as: UInt32.self)
                    }
                }
            }
        }
    }

    /// Opens, narrows or ends each side's run for a frame appended at output row `row`, `offset` below
    /// `previous`. The right side takes the ignored trailing columns too: the overlay scroll bar's strip.
    private func updatePinnedRuns(left: Int, right: Int, from row: Int, previous: [UInt8], offset k: Int) {
        let usable = ScrollingCaptureOffsetVerifier.hashedWidth(width: width, ignoredTrailingColumns: ignoredTrailingColumns)
        func line(_ pixels: [UInt8], _ y: Int, _ columns: Range<Int>) -> ArraySlice<UInt8> {
            pixels[((y * width + columns.lowerBound) * 4)..<((y * width + columns.upperBound) * 4)]
        }
        /// Row `y` of the new frame changed in these columns and moved there with the content.
        func moved(_ y: Int, _ columns: Range<Int>) -> Bool {
            line(last, y, columns) != line(previous, y, columns) && line(last, y, columns) == line(previous, y + k, columns)
        }
        /// These columns, left out of the pinned ones this time, still are: most rows that changed there
        /// didn't move with the content (a sidebar redrawn in place: Wikipedia's contents reflowing as the
        /// current section turns bold), or none changed and the slice still shows something there (a
        /// sidebar that happened to fit the offset). Blank columns that didn't change hold no sidebar.
        func stillPinned(_ columns: Range<Int>) -> Bool {
            let changed = (0..<(height - k)).filter { line(last, $0, columns) != line(previous, $0, columns) }
            guard !changed.isEmpty else { return showsInSlice(columns) }
            return changed.filter { moved($0, columns) }.count * 2 < changed.count
        }
        /// The output row, from `start` on, where content moving with the page first shows in these columns:
        /// a row of the new frame that moved there, and that the rows already appended show too when it lands
        /// above this frame's slice (a footer appended while a redraw beside it kept the run). It can lie below
        /// the slice: the run then covers the side down to it. A row in the run's own `plain` colours says
        /// nothing: the run paints it the same, and a sidebar's blank lines would line up with any others.
        func entry(_ columns: Range<Int>, from start: Int, plain: [UInt8]) -> Int? {
            let top = row - (cut - k)
            // Above this slice, only a solid page band can end the run early; pushed sidebar
            // text can line up with an older slice without entering the output here.
            return (max(0, start - top)..<(height - k)).first { y in
                moved(y, columns) && !line(last, y, columns).elementsEqual(plain)
                    && (top + y >= row || (line(appended, top + y - cut, columns) == line(last, y, columns)
                        && line(last, y, columns).dropFirst(4).elementsEqual(line(last, y, columns).dropLast(4))))
            }.map { top + $0 }
        }
        /// The appended slice shows stationary content in these columns: only then can a pinned
        /// sidebar repeat into every slice. Moving text in a blank side margin cannot open a run.
        func showsInSlice(_ all: Range<Int>) -> Bool {
            // Not the strip left out of matching: the overlay scroll bar's thumb passes there.
            let columns = all.clamped(to: 0..<usable)
            guard !columns.isEmpty else { return false }
            let colour = last.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: ((cut - k) * width + columns.lowerBound) * 4, as: UInt32.self) }
            return last.withUnsafeBytes { pixels in
                previous.withUnsafeBytes { previous in
                    ((cut - k)..<cut).contains { y in
                        columns.contains { x in
                            let at = (y * width + x) * 4
                            let pixel = pixels.loadUnaligned(fromByteOffset: at, as: UInt32.self)
                            return pixel != colour && pixel == previous.loadUnaligned(fromByteOffset: at, as: UInt32.self)
                        }
                    }
                }
            }
        }
        for (isLeft, pinned) in [(true, left), (false, right)] {
            let columns = isLeft ? 0..<pinned : (usable - pinned)..<(pinned > 0 ? width : usable - pinned)
            if let i = pinnedRuns.lastIndex(where: { $0.isLeft == isLeft && $0.end == nil }) {
                // The run's columns that aren't pinned this time leave it when they aren't still pinned anyway
                // (a footer coming in, or pushing the sidebar up): where the content moving with the page first
                // shows there, else from this frame's slice. It goes on in the rest, if any. The overlay scroll
                // bar's strip says nothing either way: its thumb fades and moves on its own.
                let run = pinnedRuns[i]
                let kept = run.columns.clamped(to: columns.isEmpty ? (isLeft ? 0..<0 : width..<width) : columns)
                let dropped = isLeft ? kept.upperBound..<run.columns.upperBound : run.columns.lowerBound..<kept.lowerBound
                let judged = dropped.clamped(to: 0..<usable)
                guard !dropped.isEmpty, !stillPinned(judged) else { continue }
                let fill = self.fill(of: run)
                let plain = judged.flatMap { x in withUnsafeBytes(of: fill[x - run.columns.lowerBound]) { Array($0) } }
                let end = max(run.from, entry(judged, from: run.from, plain: plain) ?? row)
                pinnedRuns[i].end = end
                if !kept.isEmpty {
                    pinnedRuns.append(PinnedRun(isLeft: isLeft, columns: kept, start: run.start, from: end,
                                                stored: run.stored, frame: run.frame))
                }
            } else if !columns.isEmpty, showsInSlice(columns) {
                // The new frame's rows from the cut down go on from the rows above, down to the band's bottom:
                // rows both frames share at the bottom (a sticky bar, a cookie banner) belong to no sidebar. Not
                // when none of them shows anything between the sides: those are the page's blank lines, lined up.
                let shared = ScrollingCaptureOffsetVerifier.unmovedEdges(height: height) {
                    line(last, $0, 0..<usable) == line(previous, $0, 0..<usable)
                }.bottom
                let between = left..<max(left, usable - right)
                let textured = ((height - shared)..<height).contains { y in
                    let pixels = line(last, y, between)
                    return !pixels.dropFirst(4).elementsEqual(pixels.dropLast(4))
                }
                let solid = shared >= 8 && line(last, height - shared, 0..<usable).dropFirst(4)
                    .elementsEqual(line(last, height - shared, 0..<usable).dropLast(4))
                    && !(0..<(height - shared)).contains { line(last, $0, between) == line(last, height - shared, between) }
                let bar = textured || solid
                let frame = (0..<(bar ? height - shared : height)).flatMap { line(last, $0, columns) }
                pinnedRuns.append(PinnedRun(isLeft: isLeft, columns: columns, start: row, from: row, stored: columns, frame: frame))
            }
        }
    }
}
