import Foundation

/// Vision proposes, exact pixels confirm, no frame is lost: each frame is
/// placed against the last reference frame, or skipped until one fits.
/// Frames are tightly packed BGRA, all the size of the first.
///
/// The output is the first frame down to the cut, every row appended since,
/// then the last reference frame from the cut down: the rows below the cut are
/// held back (see `ScrollingCaptureOffsetVerifier.heldBackFraction`).
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
        return (place(frame, candidate: candidate?.offset, alternatives: candidate?.alternatives ?? []), candidate)
    }

    /// Places a frame against the reference at Vision's candidate.
    /// - It says the view didn't move: a shift two of Vision's bands agree on, confirmed exactly,
    ///   wins instead. With a sidebar pinned on each side, the pinned columns alone confirm 0.
    /// - It doesn't verify: the last step appended and those shifts are tried. On repeating rows
    ///   (log lines, table rows) Vision can land a whole repeat off, and steady scrolling
    ///   (auto-scroll's equal steps) repeats the last step.
    /// The last step never overrides a confirmed 0: at rest, rows repeating at that distance
    /// would confirm it too.
    func place(_ frame: [UInt8], candidate: Int?, alternatives: [Int] = []) -> Placement {
        func verified(_ candidates: [Int]) -> Int? {
            ScrollingCaptureOffsetVerifier.verifiedOffset(candidates: candidates, from: last, to: frame,
                width: width, height: height, ignoredTrailingColumns: ignoredTrailingColumns)?.offset
        }
        let moved = alternatives.filter { $0 != 0 && $0 != candidate }
        var k = candidate.flatMap { verified([$0]) }
        if k == 0, !moved.isEmpty {
            k = verified(moved) ?? 0
        } else if k == nil {
            k = verified(Array(Set(moved + [lastStep].compactMap { $0 }.filter { $0 != candidate })))
        }
        guard frame.count == last.count, let k else {
            // A skipped frame breaks a run of upward frames.
            lastWasUpward = false
            return .skipped
        }
        let rowBytes = width * 4
        if k < 0 {
            defer { lastWasUpward = true }
            guard lastWasUpward else { return .upward(k) }
            last = frame
            guard -k * rowBytes <= appended.count else {
                first = frame
                appended = []
                return .restarted(k)
            }
            appended.removeLast(-k * rowBytes)
            return .trimmed(k)
        }
        lastWasUpward = false
        // Never true: the verifier only confirms overlap above the cut.
        guard k < cut else { return .skipped }
        last = frame
        guard k > 0 else { return .redrawn }
        appended.append(contentsOf: frame[((cut - k) * rowBytes)..<(cut * rowBytes)])
        lastStep = k
        return .appended(k)
    }

    /// Packed BGRA, `stitchedHeight` rows, then `below`: more rows, the same width, that go on under
    /// the last frame.
    func makeImage(appending below: [UInt8] = []) -> [UInt8] {
        let split = cut * width * 4
        return Array(first[..<split]) + appended + Array(last[split...]) + below
    }
}
