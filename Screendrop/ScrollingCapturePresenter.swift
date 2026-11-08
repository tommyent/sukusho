//
//  ScrollingCapturePresenter.swift
//  Screendrop
//

import AppKit
import CoreGraphics
import ScreenCaptureKit
import SwiftUI

/// Runs a scrolling capture: the user draws a region, scrolls under it, and
/// clicks Done. Frames go to `ScrollingCaptureFeed`: Vision proposes, exact
/// pixels confirm, and a frame that doesn't fit is skipped until one does.
/// The region stays highlighted, with `ScrollingCaptureBar` below it; the
/// scrolled app keeps the keyboard, so the bar or the shortcut ends a session,
/// or auto-scroll reaching the end of the page or the height limit.
@Observable
final class ScrollingCapturePresenter {
    static let shared = ScrollingCapturePresenter()

    struct Capture {
        let image: CGImage
        let displayID: CGDirectDisplayID
        /// Pixels per point of the captured display.
        let scale: CGFloat
    }

    private enum Outcome { case done, cancelled }

    /// ponytail: stops at 16,384 px, the GPU texture limit on Apple silicon:
    /// the editor isn't verified with taller images. Raise once it is.
    private static let maximumHeight = 16_384
    /// Right-edge strip left out of matching, where the overlay scroll bar
    /// appears while scrolling.
    private static let scrollBarWidth: CGFloat = 20
    /// How long frames must keep being refused before the bar says so: a hover
    /// or a frame mid-scroll is refused briefly and needs nothing from the user.
    /// Corpus (28 pages, stream-timed user pages): the longest short run, a
    /// hover on X (user-1011-x-auto 86-90), lasted 0.48 s; at 1 s none of the
    /// short runs shows, and 195 of 277 refused frames still do, all in runs
    /// of 1 s or more (x-manual 128 of 146).
    static let quietWait: TimeInterval = 1

    private(set) var isRunning = false
    private(set) var stitchedHeight = 0
    /// The latest frame didn't fit the last one placed; scrolling back a
    /// little brings the view back to where it does. Auto-scroll pauses on it.
    private(set) var isWaiting = false
    /// Frames have been refused for `quietWait`: the bar says so.
    private(set) var showsWaiting = false
    /// The capture is as tall as it can get; scrolled by hand, only Done or Cancel are left.
    private(set) var hasReachedLimit = false
    /// Waiting, and the page keeps changing: the bar asks for it to be paused.
    private(set) var keepsChanging = false
    /// Screendrop is scrolling the region itself, a step at a time.
    private(set) var isAutoScrolling = false
    /// Frames are coming in, so auto-scroll has something to follow.
    private(set) var canAutoScroll = false
    /// Auto-scroll was asked for without the Accessibility permission it
    /// needs to post scroll events; the user scrolls by hand.
    private(set) var needsScrollPermission = false

    @ObservationIgnored private var outcome: Outcome?
    /// Auto-scroll finished the session at the end of the page.
    @ObservationIgnored private var reachedEndOfPage = false
    @ObservationIgnored private var isSelectingArea = false
    @ObservationIgnored private var isCapturing = false
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var stream: ScrollingCaptureStream?
    /// Done's or Cancel's click, on the stream's clock: frames shown after it aren't kept.
    @ObservationIgnored private var cutoff: TimeInterval?
    @ObservationIgnored private var autoScroller: ScrollingCaptureAutoScroller?
    /// The display time of the newest frame placed or skipped, which
    /// auto-scroll waits for before each step.
    @ObservationIgnored private var lastFrameTime: TimeInterval = 0
    /// The display time of the first frame refused since the last one placed.
    @ObservationIgnored private var waitingSince: TimeInterval = 0
    /// macOS shows the Accessibility prompt at most once, so it's asked for
    /// on the first press only; after that the button opens Settings.
    @ObservationIgnored private var didRequestScrollPermission = false

    private init() {}

    /// Returns the stitched capture, or nil if the user cancelled or nothing
    /// could be captured.
    func run() async -> Capture? {
        // An area recording is using the region highlight.
        guard !isRunning, !ScreenRecordingManager.shared.isActive else {
            NSSound.beep()
            return nil
        }
        isRunning = true
        outcome = nil
        reachedEndOfPage = false
        defer { isRunning = false }

        guard ScreenRecordingManager.ensureScreenCapturePermission(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        let pointerDisplayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        guard let display = content.displays.first(where: { $0.displayID == pointerDisplayID }) ?? content.displays.first,
              outcome == nil, let rect = await selectArea(on: display), outcome != .cancelled else {
            return nil
        }

        // Screendrop's own windows are always left out, whatever the
        // app-windows preference says: the capture bar and highlight sit on
        // screen the whole time and must never end up in a frame.
        let filter = ScreenRecordingCapture.displayFilter(display: display, content: content, includesAppWindows: false)
        let screen = ActiveDisplayResolver.screen(for: display.displayID)
        // Whole points, so every frame maps 1:1 onto screen pixels with no
        // resampling. Stitching relies on rows matching exactly.
        let selectionRect = ScreenRecordingManager.sourceRect(forAppKitSelectionRect: rect, screenFrame: screen?.frame,
            contentRect: filter.contentRect).integral.intersection(filter.contentRect)
        let targets = Set(content.windows.filter {
            $0.windowLayer == 0 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }.map(\.windowID))
        let windows = ScrollingCaptureRegion.frontToBackWindows(on: display.displayID, targets: targets)
        let matching = ScrollingCaptureRegion.matching(selection: selectionRect, display: filter.contentRect,
                                                       frontToBackWindows: windows)
        let sourceRect = matching.rect
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let output = ScrollingCaptureRegion.output(selection: selectionRect, matching: sourceRect, scale: scale)
        let usableBottom = screen.map { ScreenRecordingManager.sourceRect(forAppKitSelectionRect: $0.visibleFrame,
            screenFrame: $0.frame, contentRect: filter.contentRect).maxY } ?? sourceRect.maxY
        let rowsBelow = ScrollingCaptureRegion.rowsBelow(output: output, matching: sourceRect,
            windowBottom: matching.target.map { windows[$0].frame.maxY }, usableBottom: usableBottom, scale: scale)

        stitchedHeight = output.rows.count
        isWaiting = false
        showsWaiting = false
        hasReachedLimit = false
        keepsChanging = false
        RecordingAreaHighlightPresenter.shared.show(display: display, rect: rect)
        panel = ScrollingCaptureBar.makePanel(below: rect, on: screen)
        panel?.orderFrontRegardless()
        defer {
            panel?.orderOut(nil)
            panel = nil
            RecordingAreaHighlightPresenter.shared.hide()
        }

        let source = ScrollingCaptureStream()
        stream = source
        cutoff = nil
        defer { source.stop(); stream = nil }
        var events = source.events.makeAsyncIterator()
        // Its monitors start before the stream; leaving by any path, a failed
        // start or Cancel included, removes them.
        autoScroller = ScrollingCaptureAutoScroller(region: rect, scale: scale, state: { [unowned self] in
            .init(height: stitchedHeight, lastFrameTime: lastFrameTime, isWaiting: isWaiting,
                  canContinue: outcome == nil && !hasReachedLimit)
        }, bar: { [weak self] in self?.panel?.frame }, onStop: { [weak self] in self?.isAutoScrolling = false },
           onEndOfPage: { [weak self] in
            self?.reachedEndOfPage = true
            self?.finish()
        })
        defer { endAutoScroll() }
        let feed: ScrollingCaptureFeed
        let firstTime: TimeInterval
        do {
            try await source.start(filter: filter, configuration: ScrollingCaptureStream.configuration(
                sourceRect: sourceRect, scale: scale))
            // Cancel, or Done before capturing starts, ends the stream here.
            var first: ScrollingCaptureStream.Frame?
            while first == nil, let event = await events.next() {
                if case .frame(let frame) = event { first = frame }
            }
            guard let firstFrame = first, outcome == nil,
                  let firstFeed = ScrollingCaptureFeed(firstFrame: firstFrame.image, at: firstFrame.time, selection: output,
                      ignoredTrailingColumns: Int((Self.scrollBarWidth * scale).rounded())) else { return nil }
            feed = firstFeed
            firstTime = firstFrame.time
        } catch {
            FailureAlert.present(message: "Scrolling capture couldn't start", error: error)
            return nil
        }

        isCapturing = true
        defer { isCapturing = false }
        canAutoScroll = true
        // Frames arrive until Done, Cancel, the height limit or a stream error
        // stops the stream. Idle ticks say nothing moved, so there's nothing to
        // place, but a wait still grows.
        var sawInput = false
        events: while let event = await events.next() {
            guard outcome != .cancelled, !hasReachedLimit else { break }
            guard case .frame(let frame) = event else {
                if case .idle(let time) = event { updateShowsWaiting(at: time) }
                continue
            }
            guard frame.time <= cutoff ?? .infinity else { break events }
            // Until the first input that could scroll the view, a frame that doesn't fit may take the first
            // one's place (`ScrollingCaptureFeed.add`). The window server answers at once, and this frame
            // was shown before the answer, so it can't show a scroll the answer missed.
            if !sawInput { sawInput = isAutoScrolling || Self.lastInputTime() > firstTime }
            // A frame that repeats the one before is an idle tick: nothing on screen changed there.
            guard let update = await feed.add(frame.image, at: frame.time, mayReplaceFirst: !sawInput) else {
                updateShowsWaiting(at: frame.time)
                continue
            }
            lastFrameTime = frame.time
            // What will be saved: the output stops at the limit.
            stitchedHeight = min(update.height, Self.maximumHeight)
            if update.placement == .skipped, !isWaiting { waitingSince = frame.time }
            isWaiting = update.placement == .skipped
            updateShowsWaiting(at: frame.time)
            keepsChanging = update.keepsChanging
            hasReachedLimit = update.height >= Self.maximumHeight
            // Auto-scroll saves at the limit, as at the end of the page; by hand, the bar waits for Done.
            if hasReachedLimit { isAutoScrolling ? finish() : source.stop() }
        }
        // The stream has ended (Done, Cancel, the height limit or an error):
        // nothing more can be captured, so nothing more may be scrolled.
        endAutoScroll()

        // ponytail: after a stream error the bar doesn't say capture stopped;
        // it waits for Done, which keeps what's captured, or Cancel.
        while outcome == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // At the end of the page the window below the selection is kept too; Done by hand, or a
        // hand-back, may come before the page has ended.
        guard outcome != .cancelled, let image = await feed.makeImage(rowsBelow: reachedEndOfPage ? rowsBelow : nil)
        else { return nil }
        let capped = image.height > Self.maximumHeight
            ? image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: Self.maximumHeight)) : image
        return capped.map { Capture(image: $0, displayID: display.displayID, scale: scale) }
    }

    /// When the last input that can scroll a view reached the window server, from any app, on the capture
    /// clock: the wheel or trackpad, a key (Space, Page Down, the arrows) or the left button (a scroll
    /// bar). Pointer moves don't count: the hand still moving off the selection's drag would count before
    /// a stale first frame clears. Needs no permission (VM, macOS 27.0.1).
    private static func lastInputTime() -> TimeInterval {
        let since = [CGEventType.scrollWheel, .keyDown, .leftMouseDown, .leftMouseDragged].map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? .infinity
        return ScrollingCaptureSampleTiming.now() - since
    }

    /// Set only on a change: idle ticks arrive at the frame rate.
    private func updateShowsWaiting(at time: TimeInterval) {
        let shows = isWaiting && time - waitingSince >= Self.quietWait
        if shows != showsWaiting { showsWaiting = shows }
    }

    /// Ends the session, keeping what was captured. Until frames are being
    /// captured - the region still being drawn, or not yet on screen - there
    /// is nothing to keep, so it cancels instead.
    func finish() {
        autoScroller?.stop()
        if isCapturing {
            cutoff = cutoff ?? ScrollingCaptureSampleTiming.now()
            outcome = outcome ?? .done
            stream?.stop()
        } else {
            cancel()
        }
    }

    func cancel() {
        autoScroller?.stop()
        cutoff = cutoff ?? ScrollingCaptureSampleTiming.now()
        outcome = .cancelled
        stream?.stop()
        if isSelectingArea {
            RecordingAreaSelectionPresenter.shared.cancel()
        }
    }

    // MARK: - Auto-scroll

    /// The bar's auto-scroll button: starts scrolling, or pauses it.
    func toggleAutoScroll() {
        guard let autoScroller else { return }
        if isAutoScrolling { return autoScroller.stop() }
        guard AXIsProcessTrusted() else {
            if didRequestScrollPermission, let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            } else {
                didRequestScrollPermission = true
                // kAXTrustedCheckOptionPrompt's value, spelled out: the imported
                // constant is a mutable global.
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            needsScrollPermission = true
            return
        }
        needsScrollPermission = false
        autoScroller.start()
        isAutoScrolling = autoScroller.isRunning
    }

    private func endAutoScroll() {
        autoScroller?.invalidate()
        autoScroller = nil
        canAutoScroll = false
    }

    private func selectArea(on display: SCDisplay) async -> CGRect? {
        isSelectingArea = true
        defer { isSelectingArea = false }
        return await withCheckedContinuation { continuation in
            RecordingAreaSelectionPresenter.shared.selectArea(on: display) { rect in
                continuation.resume(returning: rect)
            }
        }
    }
}
