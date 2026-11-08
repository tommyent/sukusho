import Foundation

/// Confirms a candidate offset with exact pixels, cut down from R7 (the
/// stitcher before this one, now only the corpus baseline): rows of the
/// new frame are compared byte for byte with the last frame's rows `offset`
/// lower (`new[y] == last[y + offset]`), strip by strip. Frames are tightly
/// packed BGRA, both the same size.
nonisolated enum ScrollingCaptureOffsetVerifier {
    /// Side-by-side strips per row, so a narrow column that changes (a hover,
    /// a gutter line) costs one strip of a row rather than the whole row.
    static let strips = 8
    /// Share of compared strips that must be identical at the offset. Low, so
    /// a hover, overlay or video over part of the frame doesn't refuse it: the
    /// distinct exact rows and the refusal of ties keep it from guessing
    /// (corpus sweep 0.7 to 0.3: correct 355 to 390, wrong 0 throughout).
    // ponytail: inner scrollers, and a video or hover the bands don't agree
    // past, still refuse; step 5's "scroll back a little" hint covers them.
    // ponytail: 0.3 is the sweep's edge and wrong was 0 at every value, so the
    // corpus can't show false positives here; raise it when one appears.
    static let agreement = 0.3
    /// Fewer distinct fully matching rows than this is a coincidence.
    static let minimumMatchedRows = 8
    /// Rows enough to stand in for the share where Vision's bands agree on the offset: a video or
    /// GIF over most of the frame changes every strip it covers between any two frames, so the
    /// share stays low even where the rows around it all match (X with a playing video: 0.23 at
    /// the true offset, with 104 rows there and 1-2 at its neighbours). Over the corpus's frame
    /// pairs, 4 agreeing bands and twice the minimum rows placed 126 more X frames and no wrong one.
    static let consensusMatchedRows = 2 * minimumMatchedRows
    /// Distinct exactly matching strips of a row (any strip, any row) that place a frame no row
    /// matches whole in, where Vision's bands agree: as many as `consensusMatchedRows` whole rows
    /// have. Over the corpus's frame pairs, the true offset had a median of 942 and the wrong ones
    /// tried beside it at most 394; with the margin and peak rules of `segmentPeak`, 251 more X
    /// frames placed and no wrong one, none either with the true offset taken out of the window.
    static let consensusMatchedSegments = consensusMatchedRows * strips
    /// The candidate can be this far off; every offset within it is tried.
    static let search = 2
    /// The bottom quarter of the band is held back rather than appended, so a
    /// floating button or chat bubble that sits there - covering the content
    /// scrolling under it - isn't copied into every slice. That content is
    /// taken from higher up the frame once it has scrolled clear, and the held
    /// rows are added once, from the last frame, at the end. Verifying leaves
    /// it out for the same reason.
    static let heldBackFraction = 4
    /// A pinned side column may change in up to this fraction of the band's rows (1/8).
    static let pinnedChangeFraction = 8

    struct Verified: Equatable, Sendable {
        let offset: Int
        /// Columns at the left and right edges that stayed put over the band while the rest moved
        /// by `offset`, and don't fit it: a sidebar pinned on either side. Zero at rest, and for
        /// columns that fit both (blank, or repeating at the offset, such as a list's icons).
        var pinnedLeft = 0, pinnedRight = 0
        /// Zero passed over the whole width, but not over the columns between the still sides: a
        /// sidebar pinned on each side confirmed it while the content between them moved.
        var sidesOnly = false
    }

    /// The passing offset within `search` of `candidate` with the most
    /// distinct matching rows; nil when none passes, or when two tie: content
    /// that lines up equally well at two offsets doesn't say which it is.
    static func verifiedOffset(candidate: Int, from last: [UInt8], to new: [UInt8], width: Int, height: Int,
                               ignoredTrailingColumns: Int) -> Verified? {
        verifiedOffset(candidates: [candidate], from: last, to: new, width: width, height: height,
                       ignoredTrailingColumns: ignoredTrailingColumns)
    }

    /// As above, over every offset within `search` of any of the candidates, and past them where the best lies at
    /// the edge of those. When none passes over
    /// the whole width, a non-zero one may pass with pinned side columns left out: with a sidebar
    /// pinned on each side, few rows match whole at the offset the content between them moved.
    /// `votes` are Vision's band shifts: when two shifts far apart both pass (a footer pushing a dense
    /// sidebar up at another rate than the article beside it), the one most of the bands saw wins over
    /// the one with the most matching rows; and at an offset `consensusBands` of them saw,
    /// `consensusMatchedRows` rows pass without the share.
    static func verifiedOffset(candidates: [Int], votes: [Int] = [], from last: [UInt8], to new: [UInt8], width: Int,
                               height: Int, ignoredTrailingColumns: Int) -> Verified? {
        guard !candidates.isEmpty, last.count == width * height * 4, new.count == last.count else { return nil }
        let usable = hashedWidth(width: width, ignoredTrailingColumns: ignoredTrailingColumns)
        return last.withUnsafeBytes { old in new.withUnsafeBytes { now in
            func same(_ y: Int, _ oldY: Int, _ x: Range<Int>) -> Bool {
                memcmp(now.baseAddress! + (y * width + x.lowerBound) * 4,
                       old.baseAddress! + (oldY * width + x.lowerBound) * 4, x.count * 4) == 0
            }
            func blank(_ y: Int, _ x: Range<Int>) -> Bool {
                let start = now.baseAddress! + (y * width + x.lowerBound) * 4
                return memcmp(start, start + 4, (x.count - 1) * 4) == 0
            }
            func pixel(_ bytes: UnsafeRawBufferPointer, _ y: Int, _ x: Int) -> UInt32 {
                bytes.loadUnaligned(fromByteOffset: (y * width + x) * 4, as: UInt32.self)
            }
            let edges = unmovedEdges(height: height) { same($0, $0, 0..<usable) }
            let band = edges.top..<(height - edges.bottom)
            let committed = band.lowerBound..<cut(in: band)
            /// How many of Vision's bands saw `k`.
            func saw(_ k: Int) -> Int {
                votes.filter { Double(abs($0 - k)) <= ScrollingCaptureOffsetEstimator.consensusSpread }.count
            }
            /// Offsets that pass over `range`'s columns, the most distinct matching rows first.
            func passing(_ offsets: Set<Int>, over range: Range<Int>) -> [(offset: Int, rows: Int)] {
                let columns = (0..<strips).map {
                    (range.lowerBound + $0 * range.count / strips)..<(range.lowerBound + ($0 + 1) * range.count / strips)
                }.filter { !$0.isEmpty }
                func score(_ k: Int) -> Int? {
                    var compared = 0, agreed = 0
                    var matched = Set<Int>()
                    for y in committed where committed.contains(y + k) {
                        var whole = true, isBlank = true
                        for x in columns where !blank(y, x) {
                            isBlank = false
                            compared += 1
                            if same(y, y + k, x) { agreed += 1 } else { whole = false }
                        }
                        if whole && !isBlank {
                            var hasher = Hasher()
                            hasher.combine(bytes: UnsafeRawBufferPointer(start: now.baseAddress! + (y * width + range.lowerBound) * 4,
                                                                         count: range.count * 4))
                            matched.insert(hasher.finalize())
                        }
                    }
                    guard compared > 0, matched.count >= minimumMatchedRows else { return nil }
                    // Both neighbours tried too, so `k` is a peak rather than the edge of a window that
                    // missed the true offset (27 rows matched 2 px off it on X).
                    let agrees = Double(agreed) / Double(compared) >= agreement
                        || matched.count >= consensusMatchedRows && saw(k) >= ScrollingCaptureOffsetEstimator.consensusBands
                            && offsets.contains(k - 1) && offsets.contains(k + 1)
                    return agrees ? matched.count : nil
                }
                return offsets.compactMap { k in score(k).map { (k, $0) } }.sorted { $0.1 > $1.1 }
            }
            /// The offset, not upward, `consensusBands` of Vision's bands saw, when the most distinct strips of a
            /// row match there exactly: at least `consensusMatchedSegments`, twice as many as at any other offset
            /// tried, with both neighbours tried. For a hover that recolours most of the frame (X greys the
            /// post under the pointer, and moves the grey when the scrolling pauses): no row matches whole
            /// across a grey post's edges, but the strips inside it, its picture or video, do. Zero too, or a
            /// frame placed mid-hover would refuse every frame at rest after it; upward stays out, as it trims.
            func segmentPeak(_ offsets: Set<Int>) -> Int? {
                guard offsets.contains(where: { $0 >= 0 && saw($0) >= ScrollingCaptureOffsetEstimator.consensusBands })
                else { return nil }
                let columns = (0..<strips).map { ($0 * usable / strips)..<(($0 + 1) * usable / strips) }.filter { !$0.isEmpty }
                let counts = offsets.map { k -> (offset: Int, segments: Int) in
                    var matched = Set<Int>()
                    for y in committed where committed.contains(y + k) {
                        for x in columns where !blank(y, x) && same(y, y + k, x) {
                            var hasher = Hasher()
                            hasher.combine(x.lowerBound)
                            hasher.combine(bytes: UnsafeRawBufferPointer(start: now.baseAddress! + (y * width + x.lowerBound) * 4,
                                                                         count: x.count * 4))
                            matched.insert(hasher.finalize())
                        }
                    }
                    return (k, matched.count)
                }
                guard let best = counts.max(by: { $0.segments < $1.segments }), best.offset >= 0,
                      best.segments >= consensusMatchedSegments, offsets.contains(best.offset - 1),
                      offsets.contains(best.offset + 1), saw(best.offset) >= ScrollingCaptureOffsetEstimator.consensusBands,
                      counts.allSatisfy({ $0.offset == best.offset || 2 * $0.segments <= best.segments }) else { return nil }
                return best.offset
            }
            /// Columns from each edge inward that stayed put at offset zero over the band, up to the last
            /// one that didn't change at all. A sidebar may change in a few rows (a highlight that follows
            /// the content, as MDN's table of contents does: 64-128 of 1,542 rows); content beside it that
            /// moved changes in many.
            func stillSides() -> (left: Int, right: Int) {
                func run(_ columns: [Int]) -> Int {
                    var clean = 0
                    for (i, x) in columns.enumerated() {
                        var changed = 0
                        for y in band where pixel(now, y, x) != pixel(old, y, x) {
                            changed += 1
                            if changed > band.count / pinnedChangeFraction { return clean }
                        }
                        if changed == 0 { clean = i + 1 }
                    }
                    return clean
                }
                let left = run(Array(0..<usable)), right = run(Array((0..<usable).reversed()))
                return left + right < usable ? (left, right) : (0, 0)
            }
            var offsets = Set(candidates.flatMap { ($0 - search)...($0 + search) })
            var passed = passing(offsets, over: 0..<usable)
            var sides: (left: Int, right: Int)?
            var range = 0..<usable
            if passed.isEmpty {
                // Only while the stitcher's cut lies in the band: an inner scroller that moves above it
                // while the page stands still would have rows that didn't move appended as if they had.
                guard height - edges.bottom >= cut(in: 0..<height) else { return nil }
                let still = stillSides()
                if still.left + still.right > 0 {
                    sides = still
                    range = still.left..<(usable - still.right)
                    passed = passing(offsets.filter { $0 != 0 }, over: range)
                }
                if passed.isEmpty, let k = segmentPeak(offsets) { passed = [(offset: k, rows: 0)] }
            }
            // The best at the window's edge isn't shown to be a peak: the window may stop short of the offset the view
            // moved (log lines on the Air: 68 matched 2 px off the true 66, at the edge of the last step's window, and
            // a 32 px line came out 34). It grows past the edge by `search` at a time, at most 4 times, until the best
            // has both neighbours.
            for _ in 0..<4 {
                guard let best = passed.first, best.rows > 0,
                      !offsets.contains(best.offset - 1) || !offsets.contains(best.offset + 1) else { break }
                offsets.formUnion((best.offset - search)...(best.offset + search))
                passed = passing(sides == nil ? offsets : offsets.filter { $0 != 0 }, over: range)
            }
            if let best = passed.first, let rival = passed.first(where: { abs($0.offset - best.offset) > 2 * search }) {
                if saw(rival.offset) * 2 > votes.count, saw(rival.offset) > saw(best.offset) {
                    passed = passed.filter { abs($0.offset - rival.offset) < abs($0.offset - best.offset) }
                }
            }
            guard let best = passed.first, passed.dropFirst().first?.rows != best.rows else { return nil }
            let k = best.offset
            guard k != 0 else {
                // Did only the still sides say so? Then the content between them moved.
                let still = stillSides()
                return Verified(offset: 0, sidesOnly: still.left + still.right > 0
                    && passing([0], over: still.left..<(usable - still.right)).isEmpty)
            }
            let still = sides ?? stillSides()
            /// A side counts as pinned when it doesn't fit the offset too.
            func pinned(_ x: Range<Int>) -> Bool {
                !x.isEmpty && committed.contains { committed.contains($0 + k) && !same($0, $0 + k, x) }
            }
            return Verified(offset: k, pinnedLeft: pinned(0..<still.left) ? still.left : 0,
                            pinnedRight: pinned((usable - still.right)..<usable) ? still.right : 0)
        } }
    }

    /// Whether `offset` leaves at least `minimumMatchedRows` rows of overlap
    /// above the cut, the most any frame of this height can: further, the
    /// view has scrolled past what can be confirmed. A sticky header or
    /// footer only shrinks the band.
    static func canConfirm(_ offset: Int, height: Int) -> Bool {
        abs(offset) + minimumMatchedRows <= cut(in: 0..<height)
    }

    /// Whether two frames are byte for byte the same over the compared columns. SCK sends a frame
    /// whenever anything on the display changes, so most frames at rest repeat the one before.
    static func sameView(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, ignoredTrailingColumns: Int) -> Bool {
        guard a.count == width * height * 4, b.count == a.count else { return false }
        let rowBytes = width * 4, compared = hashedWidth(width: width, ignoredTrailingColumns: ignoredTrailingColumns) * 4
        return a.withUnsafeBytes { a in b.withUnsafeBytes { b in
            (0..<height).allSatisfy { memcmp(a.baseAddress! + $0 * rowBytes, b.baseAddress! + $0 * rowBytes, compared) == 0 }
        } }
    }

    // MARK: - From R7

    /// Leading columns that are compared. The trailing ones are left out so
    /// the overlay scroll bar that appears while scrolling doesn't break
    /// otherwise identical rows.
    static func hashedWidth(width: Int, ignoredTrailingColumns: Int) -> Int {
        max(1, width - min(max(ignoredTrailingColumns, 0), width / 4))
    }

    /// Runs of rows at the top and bottom that are identical in both frames: a
    /// sticky header and footer. Capped at a third of the frame each, so a
    /// mostly blank page can't shrink the band that scrolling is matched in.
    /// Overcounting is harmless: the content passing through those rows is
    /// still kept, just later.
    static func unmovedEdges(height: Int, isUnmoved: (Int) -> Bool) -> (top: Int, bottom: Int) {
        let limit = height / 3
        var top = 0
        while top < limit, isUnmoved(top) { top += 1 }
        var bottom = 0
        while bottom < limit, isUnmoved(height - 1 - bottom) { bottom += 1 }
        return (top, bottom)
    }

    /// The row the band is appended up to; the rows below it are held back.
    static func cut(in band: Range<Int>) -> Int {
        band.upperBound - band.count / heldBackFraction
    }
}
