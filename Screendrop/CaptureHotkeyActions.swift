import Foundation

/// What each shortcut does: kept apart from CaptureHotkeys.swift, which the tests compile without the app's
/// coordinators.
extension CaptureHotkeyAction {
    func perform() {
        switch self {
        case .fullscreen:
            CaptureCoordinator.shared.captureFullscreen()
        case .window:
            CaptureCoordinator.shared.captureWindow()
        case .area:
            CaptureCoordinator.shared.captureArea()
        case .drawing:
            RecordingInkPresenter.shared.toggleFromShortcut()
        case .screenRecording:
            Task { @MainActor in
                RecordingBarPresenter.shared.togglePicker()
            }
        case .textCapture:
            CaptureCoordinator.shared.captureText()
        case .scrollingCapture:
            CaptureCoordinator.shared.captureScrolling()
        case .library:
            CaptureLibraryModel.shared.show()
        case .clipboardHistory:
            ClipboardPopupPresenter.shared.toggle()
        case .commandPalette:
            // A menu's shortcut, never registered for every app; here for completeness.
            CommandPalettePresenter.shared.toggle()
        }
    }
}
