//
//  RecordingPickerBar.swift
//  Screendrop
//
//  The pre-record mode of the floating bar. "Record" anywhere in the app
//  brings the bar up at the bottom of the active screen; it picks the source
//  (display / window / area) and toggles the capture inputs (camera,
//  microphone, system audio) for the next recording, then hands off to
//  CaptureCoordinator - at which point the same bar morphs into the in-session
//  controls (RecordingControlPresenter.swift). Clicks and keystrokes are always
//  logged to the session sidecar; whether they appear is decided later in
//  Studio.
//
//  The panel, the chrome and the morph live in RecordingBarPresenter.
//

import AppKit
import ScreenCaptureKit
import SwiftUI

// MARK: - Controls

struct RecordingPickerControls: View {
    @State private var sources = RecordingSourceCatalog.shared
    @State private var cameraSelectionGeneration = UUID()
    @AppStorage(ScreendropPreferences.recordingCameraDeviceIDKey) private var cameraID = ""
    @AppStorage(ScreendropPreferences.recordingMicrophoneDeviceIDKey) private var microphoneID = ""
    @AppStorage(ScreendropPreferences.recordingSystemAudioKey) private var systemAudio = false
    @AppStorage(ScreendropPreferences.recordingCleanDesktopKey) private var cleanDesktop = true
    @AppStorage(ScreendropPreferences.recordingBugReportKey) private var bugReport = false
    @AppStorage(ScreendropPreferences.includeAppWindowsInCapturesKey) private var includeAppWindows = false
    @AppStorage(ScreendropPreferences.recordingBugReportAddedAppWindowsKey) private var bugReportAddedAppWindows = false
    @AppStorage(ScreendropPreferences.recordingAppLogsKey) private var appLogs = false
    @AppStorage(ScreendropPreferences.recordingStartDelaySecondsKey) private var startDelaySeconds = 0
    @AppStorage(ScreendropPreferences.recordingTeleprompterEnabledKey) private var teleprompterEnabled = false

    @Environment(BarTooltipModel.self) private var tooltip: BarTooltipModel?

    private static let timerOptions = [0, 1, 3, 5]

    var body: some View {
        HStack(spacing: BarMetrics.itemSpacing) {
            displaySource.disabled(CaptureCountdownPresenter.shared.isRunning)
            windowSource.disabled(CaptureCountdownPresenter.shared.isRunning || sources.isLoading)
            BarActionButton(
                id: .area,
                hover: BarHover("Record an area", "Drag to select the region"),
                systemImage: "rectangle.dashed",
                accessibility: "Area - drag to select the region to record"
            ) {
                startAreaRecording()
            }
            .disabled(!canSelectSource)


            BarDivider()

            cameraToggle

            microphonePicker

            Button {
                tooltipDismiss()
                systemAudio.toggle()
            } label: {
                BarToggleLabel(
                    id: .systemAudio,
                    state: systemAudio ? .on : .off,
                    hover: BarHoverText.systemAudio(isOn: systemAudio),
                    offSymbol: "speaker.slash",
                    onSymbol: "speaker.wave.2.fill",
                    look: .input(BarMetrics.systemAudioOn)
                ) {
                    BarAudioGlyph()
                }
            }
            .buttonStyle(BarButtonStyle())
            .accessibilityLabel(systemAudio
                ? "System audio on - click to stop capturing what you hear"
                : "System audio off - click to capture what you hear")

            Button {
                tooltipDismiss()
                TeleprompterComposerPresenter.shared.toggle()
            } label: {
                BarToggleLabel(
                    id: .teleprompter,
                    state: teleprompterEnabled ? .on : .off,
                    hover: BarHoverText.teleprompter(isOn: teleprompterEnabled),
                    offSymbol: "text.pad.header",
                    onSymbol: "text.pad.header",
                    look: .helper
                )
            }
            .buttonStyle(BarButtonStyle())
            .accessibilityLabel(teleprompterEnabled
                ? "Teleprompter on - click to edit the script"
                : "Teleprompter off - click to write a script")

            timerMenu

            // A bug report shows the whole desktop, so Clean desktop can't be on while it is.
            let cleanState: BarToggleState = bugReport ? .unavailable(.ruledOut) : cleanDesktop ? .on : .off
            Button {
                tooltipDismiss()
                if !bugReport { cleanDesktop.toggle() }
            } label: {
                BarToggleLabel(
                    id: .cleanDesktop,
                    state: cleanState,
                    hover: BarHoverText.cleanDesktop(cleanState),
                    offSymbol: "sparkles",
                    onSymbol: "sparkles",
                    look: .helper
                )
            }
            .buttonStyle(BarButtonStyle())
            .accessibilityLabel("Clean desktop")
            .accessibilityValue(cleanState.isOn ? "On" : "Off")
            .accessibilityHint("Leaves desktop icons, the menu bar, Dock and notification banners out of screen and area recordings. Your desktop stays unchanged.")
            .disabled(CaptureCountdownPresenter.shared.isRunning)

            Button {
                tooltipDismiss()
                bugReport.toggle()
            } label: {
                BarToggleLabel(
                    id: .bugReport,
                    state: bugReport ? .on : .off,
                    hover: BarHoverText.bugReport(isOn: bugReport),
                    offSymbol: "ladybug",
                    onSymbol: "ladybug.fill",
                    look: .helper
                )
            }
            .buttonStyle(BarButtonStyle())
            .accessibilityLabel("Bug report")
            .accessibilityValue(bugReport ? "On" : "Off")
            .accessibilityHint("Stop writes a bug report, with a prompt for your coding agent, instead of opening Studio, and the recording keeps the menu bar, notification banners and Sukusho's own windows.")
            .disabled(CaptureCountdownPresenter.shared.isRunning)
            // A bug in Sukusho needs its windows: Bug report turns them on, with the usual banner and its
            // switch, and turns them back off with itself unless they were on before.
            .onChange(of: bugReport) { _, on in
                if !on { appLogs = false }
                if on, !includeAppWindows {
                    includeAppWindows = true
                    bugReportAddedAppWindows = true
                } else if !on, bugReportAddedAppWindows {
                    includeAppWindows = false
                    bugReportAddedAppWindows = false
                }
            }

            if bugReport {
                Button {
                    tooltipDismiss()
                    appLogs.toggle()
                } label: {
                    BarToggleLabel(
                        id: .appLogs,
                        state: appLogs ? .on : .off,
                        hover: BarHoverText.appLogs(isOn: appLogs),
                        offSymbol: "doc.plaintext",
                        onSymbol: "doc.plaintext.fill",
                        look: .helper
                    )
                }
                .buttonStyle(BarButtonStyle())
                .accessibilityLabel("Include app logs")
                .accessibilityValue(appLogs ? "On" : "Off")
                .accessibilityHint("Adds the recorded app's own log to this take's bug report. You see what was captured before it's saved, and it turns off after the take.")
                .disabled(CaptureCountdownPresenter.shared.isRunning)
            }

            BarActionButton(
                id: .close,
                hover: BarHover("Close", "Esc"),
                systemImage: "xmark",
                accessibility: "Close the recorder - Esc"
            ) {
                dismissPicker()
            }
        }
        .task {
            await sources.refresh()
        }
    }

    private var canSelectSource: Bool {
        !sources.isLoading && !sources.displays.isEmpty && !CaptureCountdownPresenter.shared.isRunning
    }

    // MARK: Sources

    @ViewBuilder
    private var displaySource: some View {
        if sources.isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(width: BarMetrics.controlSize, height: BarMetrics.controlSize)
                .help("Finding screens and windows…")
                .accessibilityLabel("Finding screens and windows")
        } else if sources.errorMessage != nil || sources.displays.isEmpty {
            Menu {
                Text(sources.errorMessage ?? "No screens are available.")
                Button("Retry") { Task { await sources.refresh() } }
                if !CGPreflightScreenCaptureAccess() {
                    Button("Open Screen Recording Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } label: {
                BarActionLabel(id: .display, hover: BarHover("Recording sources unavailable", "Click to retry"),
                               systemImage: "exclamationmark.triangle")
            }
            .menuStyle(.button)
            .buttonStyle(BarButtonStyle())
            .menuIndicator(.hidden)
            .accessibilityLabel("Recording sources unavailable - retry or open permissions")
        } else if sources.displays.count > 1 {
            Menu {
                ForEach(Array(sources.displays.enumerated()), id: \.element.displayID) { index, display in
                    Button(RecordingSourceCatalog.displayTitle(display, index: index)) {
                        startRecording {
                            CaptureCoordinator.shared.recordFullscreen(display)
                        }
                    }
                }
            } label: {
                BarActionLabel(
                    id: .display,
                    hover: BarHover("Record a screen", "Click to pick one"),
                    systemImage: "menubar.rectangle"
                )
            }
            .menuStyle(.button)
            .buttonStyle(BarButtonStyle())
            .menuIndicator(.hidden)
            .accessibilityLabel("Display - choose which screen to record")
        } else {
            BarActionButton(
                id: .display,
                hover: BarHover("Record the whole screen", "Click to start"),
                systemImage: "menubar.rectangle",
                accessibility: "Display - record the whole screen"
            ) {
                guard let display = sources.displays.first else { return }
                startRecording {
                    CaptureCoordinator.shared.recordFullscreen(display)
                }
            }
        }
    }

    private var windowSource: some View {
        Menu {
            if let errorMessage = sources.errorMessage {
                Text("Could not load windows: \(errorMessage)")
            } else if sources.windows.isEmpty {
                Text("No app windows found")
            }
            ForEach(sources.windows, id: \.windowID) { window in
                Button(RecordingSourceCatalog.windowTitle(window)) {
                    startRecording {
                        CaptureCoordinator.shared.recordWindow(window)
                    }
                }
            }

            Divider()

            Button("Refresh Windows") {
                Task {
                    await sources.refresh()
                }
            }
        } label: {
            BarActionLabel(
                id: .window,
                hover: BarHover("Record a window", "Click to pick one"),
                systemImage: "macwindow"
            )
        }
        .menuStyle(.button)
        .buttonStyle(BarButtonStyle())
        .menuIndicator(.hidden)
        .accessibilityLabel("Window - choose an app window to record")
    }

    private func startAreaRecording() {
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        guard let display = sources.displays.first(where: { $0.displayID == displayID })
            ?? sources.displays.first else { return }
        // Area is the one source that can't morph: the bar has to get out of
        // the way of the selection overlay, so it leaves and comes back as the
        // session controls.
        RecordingBarPresenter.shared.hide()
        CaptureCoordinator.shared.recordArea(display)
    }

    /// Leaves the bar on screen: it stays as the picker through any start
    /// delay, then morphs into the session controls the moment capture
    /// actually begins. The warm camera preview (if any) is left running so it
    /// flows straight into the recording instead of restarting and refading.
    private func startRecording(_ start: () -> Void) {
        TeleprompterComposerPresenter.shared.hide()
        start()
    }

    /// Backs out of the picker without recording: stop any warm camera
    /// preview so it doesn't keep running in the background.
    private func dismissPicker() {
        RecordingBarPresenter.shared.dismissPicker()
    }

    // MARK: Input toggles

    private func toggleCamera() {
        if cameraID.isEmpty {
            selectCamera(RecordingDeviceCatalog.cameras().first?.uniqueID)
        } else {
            cameraSelectionGeneration = UUID()
            cameraID = ""
            Task { if cameraID.isEmpty { await CameraRecordingManager.shared.stopPreview() } }
        }
    }

    private var cameraState: BarToggleState {
        BarInputRules.state(
            isSelected: !cameraID.isEmpty,
            selectedIsConnected: RecordingDeviceCatalog.camera(withID: cameraID) != nil,
            hasDevices: !RecordingDeviceCatalog.cameras().isEmpty,
            isBlocked: RecordingInputAuthorization.isBlocked(.camera)
        )
    }

    private var microphoneState: BarToggleState {
        BarInputRules.state(
            isSelected: !microphoneID.isEmpty,
            selectedIsConnected: RecordingDeviceCatalog.microphone(withID: microphoneID) != nil,
            hasDevices: !RecordingDeviceCatalog.microphones().isEmpty,
            isBlocked: RecordingInputAuthorization.isBlocked(.microphone)
        )
    }

    /// Click turns it on or off; right-click picks which camera. Blocked, a click opens the
    /// privacy pane; with no camera at all it does nothing but say so on hover.
    private var cameraToggle: some View {
        let state = cameraState
        let device = RecordingDeviceCatalog.camera(withID: cameraID)?.localizedName
        return Button {
            tooltipDismiss()
            switch state {
            case .unavailable(.blocked): RecordingInputAuthorization.openSettings(for: .camera)
            case .unavailable(.noDevice): NSSound.beep()
            default: toggleCamera()
            }
        } label: {
            BarToggleLabel(
                id: .camera,
                state: state,
                hover: BarHoverText.camera(state, device: device),
                offSymbol: "video.slash",
                onSymbol: "video.fill",
                look: .input(BarMetrics.cameraOn)
            ) {
                BarCameraThumbnail()
            }
        }
        .buttonStyle(BarButtonStyle())
        .accessibilityLabel(BarHoverText.camera(state, device: device).title)
        .accessibilityHint(BarHoverText.camera(state, device: device).detail ?? "")
        .contextMenu {
            cameraDeviceMenu
        }
    }

    private func tooltipDismiss() {
        tooltip?.dismiss()
    }

    @ViewBuilder
    private var cameraDeviceMenu: some View {
        ForEach(RecordingDeviceCatalog.cameras(), id: \.uniqueID) { device in
            Toggle(isOn: Binding(
                get: { cameraID == device.uniqueID },
                set: { selected in
                    if selected {
                        selectCamera(device.uniqueID)
                    } else {
                        cameraSelectionGeneration = UUID()
                        cameraID = ""
                        Task { if cameraID.isEmpty { await CameraRecordingManager.shared.stopPreview() } }
                    }
                }
            )) {
                Text(device.localizedName)
            }
        }
    }

    /// A menu of microphones, as before; blocked, a click opens the privacy pane instead.
    @ViewBuilder
    private var microphonePicker: some View {
        let state = microphoneState
        let hover = BarHoverText.microphone(state, device: RecordingDeviceCatalog.microphone(withID: microphoneID)?.localizedName)
        let label = BarToggleLabel(
            id: .microphone,
            state: state,
            hover: hover,
            offSymbol: "mic.slash",
            onSymbol: "mic.fill",
            look: .input(BarMetrics.microphoneOn)
        ) {
            BarAudioGlyph()
        }
        if state == .unavailable(.blocked) {
            Button {
                tooltipDismiss()
                RecordingInputAuthorization.openSettings(for: .microphone)
            } label: {
                label
            }
            .buttonStyle(BarButtonStyle())
            .accessibilityLabel(hover.title)
            .accessibilityHint(hover.detail ?? "")
        } else {
            Menu {
                Button {
                    microphoneID = ""
                } label: {
                    menuSelectionLabel("Off", isSelected: microphoneID.isEmpty)
                }

                Divider()

                ForEach(RecordingDeviceCatalog.microphones(), id: \.uniqueID) { device in
                    Button {
                        selectMicrophone(device.uniqueID)
                    } label: {
                        menuSelectionLabel(
                            device.localizedName,
                            isSelected: microphoneID == device.uniqueID
                        )
                    }
                }
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(BarButtonStyle())
            .menuIndicator(.hidden)
            .accessibilityLabel(hover.title)
            .accessibilityHint(hover.detail ?? "")
        }
    }

    /// Replaces the old gear button that opened Settings: a self-contained
    /// menu for options that only matter for the next recording, starting
    /// with a start-delay timer.
    private var timerMenu: some View {
        Menu {
            ForEach(Self.timerOptions, id: \.self) { seconds in
                Button {
                    startDelaySeconds = seconds
                } label: {
                    menuSelectionLabel(timerLabel(seconds), isSelected: startDelaySeconds == seconds)
                }
            }
        } label: {
            BarToggleLabel(
                id: .timer,
                state: startDelaySeconds == 0 ? .off : .on,
                hover: BarHoverText.timer(seconds: startDelaySeconds),
                offSymbol: "timer",
                onSymbol: "timer",
                look: .helper
            ) {
                Text("\(startDelaySeconds)s")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
        }
        .menuStyle(.button)
        .buttonStyle(BarButtonStyle())
        .menuIndicator(.hidden)
        .accessibilityLabel(timerAccessibilityLabel)
    }

    private func timerLabel(_ seconds: Int) -> String {
        seconds == 0 ? "None" : "\(seconds) second\(seconds == 1 ? "" : "s")"
    }

    private var timerAccessibilityLabel: String {
        startDelaySeconds == 0
            ? "Timer off - click to add a countdown before recording starts"
            : "Timer: \(timerLabel(startDelaySeconds)) before recording starts"
    }

    @ViewBuilder
    private func menuSelectionLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func selectCamera(_ deviceID: String?) {
        guard let deviceID else { return }
        let selection = UUID(), picker = RecordingBarPresenter.shared.pickerGeneration
        cameraSelectionGeneration = selection
        Task { @MainActor in
            let authorized = await RecordingInputAuthorization.ensureAccess(for: .camera)
            guard selection == cameraSelectionGeneration,
                  picker == RecordingBarPresenter.shared.pickerGeneration,
                  RecordingBarPresenter.shared.mode == .picker else { return }
            cameraID = authorized ? deviceID : ""
            if authorized {
                await warmCameraPreview()
            }
        }
    }

    /// Starts the camera session (and its floating preview) ahead of "Start
    /// Recording", so its exposure/white-balance ramp - the fade-in macOS
    /// shows whenever a capture session starts cold - finishes before
    /// anything is actually being recorded.
    private func warmCameraPreview() async {
        guard !cameraID.isEmpty else { return }
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        await CameraRecordingManager.shared.startPreview(deviceID: cameraID, displayID: displayID)
    }

    private func selectMicrophone(_ deviceID: String?) {
        guard let deviceID else { return }
        Task { @MainActor in
            microphoneID = await RecordingInputAuthorization.ensureAccess(for: .microphone) ? deviceID : ""
        }
    }
}

// MARK: - Countdown

/// The bar while a timer counts down to a recording: the seconds left in red, what the take will
/// record as the same filled chips, and Cancel. The large number in the middle of the screen
/// stays as it was.
struct RecordingCountdownControls: View {
    @State private var countdown = CaptureCountdownPresenter.shared
    @AppStorage(ScreendropPreferences.recordingCameraDeviceIDKey) private var cameraID = ""
    @AppStorage(ScreendropPreferences.recordingMicrophoneDeviceIDKey) private var microphoneID = ""
    @AppStorage(ScreendropPreferences.recordingSystemAudioKey) private var systemAudio = false

    var body: some View {
        HStack(spacing: BarMetrics.itemSpacing) {
            Text("\(countdown.remaining)")
                .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: BarMetrics.chipHeight + 4, height: BarMetrics.chipHeight + 4)
                .background(Circle().fill(BarMetrics.recordTint))
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: countdown.remaining)
                .padding(.leading, 4)
                .accessibilityLabel("Recording starts in \(countdown.remaining)")

            VStack(alignment: .leading, spacing: 0) {
                Text("Get ready")
                    .font(.system(size: 13, weight: .semibold))
                Text(hasInputs ? "Recording with" : "Recording the screen")
                    .font(.system(size: 11))
                    .opacity(0.7)
            }
            .foregroundStyle(BarMetrics.activeTint)
            .padding(.horizontal, 6)
            .fixedSize()

            if !cameraID.isEmpty {
                BarToggleLabel(id: .camera, state: .on, hover: BarHover("Camera will record"),
                               offSymbol: "video.fill", onSymbol: "video.fill", look: .input(BarMetrics.cameraOn)) {
                    BarCameraThumbnail()
                }
            }
            if !microphoneID.isEmpty {
                BarToggleLabel(id: .microphone, state: .on, hover: BarHover("Microphone will record"),
                               offSymbol: "mic.fill", onSymbol: "mic.fill", look: .input(BarMetrics.microphoneOn)) {
                    BarAudioGlyph()
                }
            }
            if systemAudio {
                BarToggleLabel(id: .systemAudio, state: .on, hover: BarHover("System audio will record"),
                               offSymbol: "speaker.wave.2.fill", onSymbol: "speaker.wave.2.fill",
                               look: .input(BarMetrics.systemAudioOn)) {
                    BarAudioGlyph()
                }
            }

            Button {
                countdown.cancel()
            } label: {
                HStack(spacing: 6) {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .semibold))
                    Text("esc")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(BarMetrics.activeTint.opacity(0.12)))
                }
                .foregroundStyle(BarMetrics.activeTint)
                .padding(.horizontal, 12)
                .frame(height: BarMetrics.chipHeight + 2)
                .background(Capsule().fill(BarMetrics.activeTint.opacity(0.08)))
                .contentShape(Capsule())
            }
            .buttonStyle(BarButtonStyle())
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .accessibilityLabel("Cancel countdown")
        }
    }

    private var hasInputs: Bool {
        !cameraID.isEmpty || !microphoneID.isEmpty || systemAudio
    }
}
