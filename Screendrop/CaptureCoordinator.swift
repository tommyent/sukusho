//
//  CaptureCoordinator.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import AppKit
import ScreenCaptureKit
import SwiftUI

/// What a Capture Text run produced. `cancelled` and `noTextFound` look the
/// same to a caller handed a plain optional, but a Shortcut needs to tell the
/// user which one happened.
enum CaptureTextOutcome {
    case cancelled
    case noTextFound
    case copied(String)
}

/// Single long-lived coordinator that manages the capture → preview flow.
@Observable
final class CaptureCoordinator {
    
    static let shared = CaptureCoordinator()
    
    /// Set by the App to open the preview window. Returns the URL the
    /// capture was imported to in history, so awaitable capture callers
    /// (App Intents) can hand the finished file to their result.
    var onShowPreview: ((URL, CGDirectDisplayID?, CaptureSource?) async -> URL)?
    
    private init() {}
    
    // MARK: - Capture Actions

    func captureFullscreen() {
        Task { await performCaptureFullscreen() }
    }

    func captureWindow() {
        Task { await performCaptureWindow() }
    }

    func captureArea() {
        Task { await performCaptureArea() }
    }

    func captureText() {
        Task { await performCaptureText() }
    }

    /// Starts a scrolling capture, or finishes the one in progress: the app
    /// being scrolled has the keyboard, so pressing the shortcut again is the
    /// keyboard way to say Done.
    func captureScrolling() {
        if ScrollingCapturePresenter.shared.isRunning {
            ScrollingCapturePresenter.shared.finish()
        } else {
            Task { await performCaptureScrolling() }
        }
    }

    // MARK: - Awaitable Capture Actions

    /// Awaitable variants for callers (App Intents / Shortcuts) that need the
    /// resulting file back to hand off to a following action. Both routes
    /// funnel through the same finish-capture path as the hotkey/menu bar
    /// triggers, so history import, sound, and preview behavior stay
    /// identical either way.
    @discardableResult
    func captureFullscreenAwaiting() async -> URL? {
        await performCaptureFullscreen()
    }

    @discardableResult
    func captureWindowAwaiting() async -> URL? {
        await performCaptureWindow()
    }

    @discardableResult
    func captureAreaAwaiting() async -> URL? {
        await performCaptureArea()
    }

    /// Returns the recognized text rather than a URL - Capture Text produces
    /// no file, and a Shortcuts action that hands back a string is what makes
    /// it composable with the rest of a workflow. The outcome distinguishes a
    /// cancelled selection from a region that simply had no text in it, which
    /// a Shortcut needs to report accurately.
    @discardableResult
    func captureTextAwaiting() async -> CaptureTextOutcome {
        await performCaptureText()
    }

    @discardableResult
    private func performCaptureFullscreen() async -> URL? {
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        PreviewWindowPlacement.shared.setTargetDisplayID(displayID)

        guard await CaptureCountdownPresenter.shared.runIfNeeded(
            seconds: ScreendropPreferences.captureDelaySeconds,
            displayID: displayID
        ) else { return nil }
        let source = CaptureSourceProbe(tracksPointer: false).finish(.display(displayID))
        guard let url = await ScreenshotManager.shared.captureFullscreen(displayID: displayID) else { return nil }
        return await finishCapture(url: url, displayID: displayID, source: source)
    }

    @discardableResult
    private func performCaptureWindow() async -> URL? {
        // The self-timer is handled by screencapture's `-T` so the delay
        // happens *after* the window is picked, not before.
        let probe = CaptureSourceProbe(tracksPointer: true)
        let captured = await ScreenshotManager.shared.captureWindow(
            includeShadow: ScreendropPreferences.captureWindowShadow,
            delaySeconds: ScreendropPreferences.captureDelaySeconds
        )
        let source = probe.finish(.window)
        guard let url = captured else { return nil }
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        return await finishCapture(url: url, displayID: displayID, source: source)
    }

    /// Sukusho's own picker draws the area (Shift snaps to a box, Option
    /// magnifies); `screencapture` then takes it, so the file, its DPI and the
    /// self-timer are the same as with the system crosshair.
    @discardableResult
    private func performCaptureArea() async -> URL? {
        guard !ScreendropPreferences.areaCaptureUsesSystemPicker else { return await performSystemCaptureArea() }
        // The windows as they are before the picker's own panels go up.
        let probe = CaptureSourceProbe(tracksPointer: false)
        let picked = await RecordingAreaSelectionPresenter.shared.selectScreenshotArea(windows: probe.windows.map(\.bounds))
        guard let rect = picked else { return nil }
        let source = probe.finish(.region(rect))
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        guard let url = await ScreenshotManager.shared.captureArea(
            rect, delaySeconds: ScreendropPreferences.captureDelaySeconds
        ) else { return nil }
        return await finishCapture(url: url, displayID: displayID, source: source)
    }

    /// The system crosshair, kept behind `areaCaptureUsesSystemPicker`.
    @discardableResult
    private func performSystemCaptureArea() async -> URL? {
        // The self-timer is handled by screencapture's `-T` so the delay
        // happens *after* the area is drawn, not before.
        let probe = CaptureSourceProbe(tracksPointer: true)
        let captured = await ScreenshotManager.shared.captureArea(
            delaySeconds: ScreendropPreferences.captureDelaySeconds
        )
        let source = probe.finish(captured.flatMap(CaptureSourceProbe.capturedRect).map { .region($0) } ?? .area)
        guard let url = captured else { return nil }
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        return await finishCapture(url: url, displayID: displayID, source: source)
    }

    /// No self-timer: the capture runs for as long as the user scrolls.
    @discardableResult
    private func performCaptureScrolling() async -> URL? {
        // The app being scrolled is frontmost when the capture starts.
        let probe = CaptureSourceProbe(tracksPointer: false)
        guard let capture = await ScrollingCapturePresenter.shared.run() else { return nil }
        let source = probe.finish(.display(capture.displayID))
        guard let url = await ScreenshotManager.shared.writeCapture(capture.image, scale: capture.scale) else {
            FailureAlert.present(message: "Scrolling capture couldn't be saved", error: CocoaError(.fileWriteUnknown))
            return nil
        }
        return await finishCapture(url: url, displayID: capture.displayID, source: source)
    }

    /// Capture Text is the odd one out: it recognizes the text inside the drawn
    /// area, puts it on the clipboard, and throws the image away. It
    /// deliberately skips `finishCapture` - there is no file to import into
    /// history, no preview card to raise, and no after-capture action to run -
    /// so the toast and the capture sound are its only feedback.
    ///
    /// The area is drawn in the same picker as Capture Area (Shift snaps to a
    /// box, Option magnifies), or with the system crosshair behind
    /// `areaCaptureUsesSystemPicker`. The self-timer is handled by
    /// screencapture's `-T`, so the delay happens after the area is drawn,
    /// matching Capture Area.
    @discardableResult
    private func performCaptureText() async -> CaptureTextOutcome {
        ImageTextWarmUp.shared.start()
        let delay = ScreendropPreferences.captureDelaySeconds
        var captured: URL?
        if ScreendropPreferences.areaCaptureUsesSystemPicker {
            captured = await ScreenshotManager.shared.captureArea(delaySeconds: delay)
        } else {
            let windows = CaptureSourceProbe(tracksPointer: false).windows.map(\.bounds)
            if let rect = await RecordingAreaSelectionPresenter.shared.selectScreenshotArea(windows: windows) {
                captured = await ScreenshotManager.shared.captureArea(rect, delaySeconds: delay)
            }
        }
        guard let url = captured else { return .cancelled }
        defer { try? FileManager.default.removeItem(at: url) }

        // Resolved before recognition runs, so the toast lands on the display
        // the user was just drawing on rather than wherever the pointer
        // drifted to while Vision worked.
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        CaptureTextFeedbackPresenter.shared.showReading(displayID: displayID)
        // A table or a list keeps its shape; anything else is read line by line, as always.
        var blocks: [CapturedTextBlock]?
        if let image = ScreenshotImageLoader.uprightImage(at: url) { blocks = await CapturedDocumentText.structuredBlocks(in: image) }
        let text: String
        if let blocks { text = CapturedDocumentText.plainText(blocks) } else { text = await ImageTextRecognizer.recognizeText(at: url) }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            CaptureTextFeedbackPresenter.shared.showNoTextFound(displayID: displayID)
            if ScreendropPreferences.playSounds {
                NSSound.beep()
            }
            return .noTextFound
        }

        NSPasteboard.general.clearContents()
        // Paste takes the structured version where an app accepts it; Paste and Match Style
        // takes the plain one.
        if let blocks { NSPasteboard.general.setString(CapturedDocumentText.html(blocks), forType: .html) }
        NSPasteboard.general.setString(text, forType: .string)
        CaptureTextFeedbackPresenter.shared.showCopied(text: text, displayID: displayID)
        if ScreendropPreferences.playSounds {
            CaptureFeedbackSound.play()
        }
        return .copied(text)
    }

    func recordFullscreen(_ display: SCDisplay) {
        Task {
            guard await CaptureCountdownPresenter.shared.runIfNeeded(
                seconds: ScreendropPreferences.recordingStartDelaySeconds,
                displayID: display.displayID,
                beforeRecording: true
            ) else { return }
            ScreenRecordingManager.shared.startRecording(source: ScreenRecordingSource(kind: .fullscreen(display)))
        }
    }

    func recordWindow(_ window: SCWindow) {
        Task {
            let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
            guard await CaptureCountdownPresenter.shared.runIfNeeded(
                seconds: ScreendropPreferences.recordingStartDelaySeconds,
                displayID: displayID,
                beforeRecording: true
            ) else { return }
            ScreenRecordingManager.shared.startRecording(source: ScreenRecordingSource(kind: .window(window)))
        }
    }

    func recordArea(_ display: SCDisplay) {
        // The picker already left to make room for the selection, so when
        // the selection or its countdown is cancelled nothing else turns off
        // the camera it warmed.
        RecordingAreaSelectionPresenter.shared.selectArea(on: display) { rect in
            guard let rect else {
                Task { await CameraRecordingManager.shared.stopPreview() }
                return
            }
            Task {
                guard await CaptureCountdownPresenter.shared.runIfNeeded(
                    seconds: ScreendropPreferences.recordingStartDelaySeconds,
                    displayID: display.displayID,
                    beforeRecording: true
                ) else {
                    await CameraRecordingManager.shared.stopPreview()
                    return
                }
                ScreenRecordingManager.shared.startRecording(
                    source: ScreenRecordingSource(kind: .area(display: display, rect: rect))
                )
            }
        }
    }
    
    // MARK: - Preview

    @discardableResult
    @MainActor
    private func finishCapture(url: URL, displayID: CGDirectDisplayID?, source: CaptureSource?) async -> URL {
        if ScreendropPreferences.playSounds {
            CaptureFeedbackSound.play()
        }
        let historyURL = await showPreview(url: url, displayID: displayID, source: source)
        // History keeps its own copy, and the preview card, editor, copy, save,
        // upload, pin and Shortcuts all get that copy, so the temp original is
        // no longer used. Keep it only when the import failed and it is still
        // the file the preview points at.
        if historyURL != url {
            try? FileManager.default.removeItem(at: url)
        }
        return historyURL
    }

    @discardableResult
    private func showPreview(url: URL, displayID: CGDirectDisplayID?, source: CaptureSource?) async -> URL {
        guard let onShowPreview else {
            let historyURL = ScreenshotHistoryStore.shared.importScreenshot(from: url, source: source)
            await ScreenshotPreviewStack.shared.add(url: historyURL)
            if AfterCaptureActions.isEnabled(.showOverlay, for: .screenshot) {
                PreviewPanelPresenter.shared.show(displayID: displayID)
            }
            return historyURL
        }

        return await onShowPreview(url, displayID, source)
    }
}

@MainActor
private enum CaptureFeedbackSound {
    private static let sound: NSSound? = {
        let url = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif")
        return NSSound(contentsOf: url, byReference: true)
    }()

    static func play() {
        guard let sound else { return }

        sound.stop()
        sound.currentTime = 0
        sound.play()
    }
}
