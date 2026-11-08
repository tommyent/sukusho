import CoreGraphics
import Foundation

/// Scrolling Capture's frames on their way to the stitcher: each stream frame
/// is cropped to the selection, placed (Vision proposes, exact pixels confirm,
/// the stitcher skips what doesn't fit) and written to the frame dump when it's
/// on. The presenter drives it, and so does the corpus replay
/// (scripts/scroll-corpus-replay.swift), so both take this one path.
actor ScrollingCaptureFeed {
    struct Update: Sendable {
        let placement: ScrollingCaptureFrameStitcher.Placement
        /// The stitched height so far, in pixels.
        let height: Int
        /// The frame was skipped, though Vision's bands agree on an offset the
        /// verifier could confirm: the view still overlaps the reference, so
        /// something on the page changed (a video, an animation, a hover)
        /// rather than the view scrolling past what fits. Over the corpus's
        /// 277 refused frames this says 78 changing and 117 not at 1 s
        /// (no-overlap jumps say not); Vision's candidate alone said
        /// changing for all but 6, jumps included (scroll-corpus-run).
        let keepsChanging: Bool
    }

    private let stitcher: ScrollingCaptureFrameStitcher
    private let dump: ScrollingCaptureFrameDump?
    private let selection: CGRect
    private let frameSize: CGSize
    private let colorSpace: CGColorSpace
    private let ignoredTrailingColumns: Int
    private var index = 0
    private var reference = 0
    /// The reference frame as captured, uncropped: what lies below the selection at the end of the page.
    private var referenceFrame: CGImage
    /// The last frame added, placed or not.
    private var previous: [UInt8]?
    /// The last frame was placed `.upward`: a repeat of it is the second look that trims.
    private var previousWasUpward = false

    init?(firstFrame: CGImage, at time: TimeInterval = ScrollingCaptureSampleTiming.now(),
          selection rect: ScrollingCaptureOutputRect, ignoredTrailingColumns: Int) {
        let selection = CGRect(x: rect.columns.lowerBound, y: rect.rows.lowerBound,
                               width: rect.columns.count, height: rect.rows.count)
        let space = ScrollingCapturePixels.colorSpace(of: firstFrame)
        guard let cropped = Self.crop(firstFrame, to: selection),
              let pixels = ScrollingCapturePixels.bytes(of: cropped, in: space),
              let stitcher = ScrollingCaptureFrameStitcher(firstFrame: pixels, width: cropped.width,
                  height: cropped.height, ignoredTrailingColumns: ignoredTrailingColumns) else { return nil }
        self.stitcher = stitcher
        self.selection = selection
        frameSize = CGSize(width: firstFrame.width, height: firstFrame.height)
        colorSpace = space
        self.ignoredTrailingColumns = ignoredTrailingColumns
        referenceFrame = firstFrame
        previous = pixels
        dump = ScrollingCaptureFrameDump(width: cropped.width, height: cropped.height,
                                         ignoredTrailingColumns: ignoredTrailingColumns)
        dump?.write(index: 0, time: time, frame: cropped, verifiedOffset: 0, action: "first")
    }

    /// Nil when the frame repeats the one before over the compared columns: nothing new to
    /// place, and auto-scroll mustn't take it for the view still moving. A repeat of a frame
    /// placed `.upward` still goes through: one notch back up gives a single distinct frame,
    /// and its repeat at rest is what confirms it and trims, as on main.
    func add(_ frame: CGImage, at time: TimeInterval) async -> Update? {
        let cropped = CGSize(width: frame.width, height: frame.height) == frameSize ? Self.crop(frame, to: selection) : nil
        let pixels = cropped.flatMap { ScrollingCapturePixels.bytes(of: $0, in: colorSpace) }
        if !previousWasUpward, let pixels, let previous, ScrollingCaptureOffsetVerifier.sameView(pixels, previous,
               width: Int(selection.width), height: Int(selection.height), ignoredTrailingColumns: ignoredTrailingColumns) {
            return nil
        }
        previous = pixels
        index += 1
        // A frame that can't be read goes to the stitcher as one that doesn't
        // fit, so it also breaks a run of upward frames.
        let (placement, candidate) = await stitcher.add(pixels ?? [])
        let keepsChanging = placement == .skipped && candidate.map {
            $0.bandsAgree && ScrollingCaptureOffsetVerifier.canConfirm($0.offset, height: Int(selection.height))
        } ?? false
        dump?.write(index: index, time: time, frame: cropped, reference: reference, candidateOffset: candidate?.offset,
                    verifiedOffset: placement.offset, action: String(String(describing: placement).prefix { $0 != "(" }))
        if placement.isReference {
            reference = index
            referenceFrame = frame
        }
        if case .upward = placement { previousWasUpward = true } else { previousWasUpward = false }
        return Update(placement: placement, height: await stitcher.stitchedHeight, keepsChanging: keepsChanging)
    }

    /// The stitched capture; with `rowsBelow` (frame rows), the reference frame's rows there go on under
    /// it, over the selection's columns: the window below the selection at the end of the page.
    func makeImage(rowsBelow: Range<Int>? = nil) async -> CGImage? {
        let width = Int(selection.width)
        let below = rowsBelow.flatMap { rows in
            referenceFrame.cropping(to: CGRect(x: Int(selection.minX), y: rows.lowerBound, width: width, height: rows.count))
        }.flatMap { ScrollingCapturePixels.bytes(of: $0, in: colorSpace) } ?? []
        let pixels = await stitcher.makeImage(appending: below)
        return ScrollingCapturePixels.image(pixels, width: width, height: pixels.count / (width * 4), colorSpace: colorSpace)
    }

    private static func crop(_ frame: CGImage, to selection: CGRect) -> CGImage? {
        guard CGRect(x: 0, y: 0, width: frame.width, height: frame.height).contains(selection) else { return nil }
        return frame.cropping(to: selection)
    }
}
