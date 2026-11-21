//
//  HotkeyManager.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import AppKit
import Observation
import Carbon.HIToolbox

/// Registers system-wide global keyboard shortcuts for capture actions.
@Observable
final class HotkeyManager {
    
    static let shared = HotkeyManager()
    
    private static let hotKeySignature = OSType(0x4F53_4854)

    private var eventHandlerRef: EventHandlerRef?
    /// Each with the Carbon ID of its own registration (`newHotKeyID`).
    private var hotKeyRefs: [CaptureHotkeyAction: (ref: EventHotKeyRef, id: UInt32)] = [:]
    private(set) var registrationErrors: [CaptureHotkeyAction: String] = [:]
    /// Keys that exist only while something is on screen, such as the
    /// recording pen's Esc and ⌘Z. Their IDs start above the actions'.
    /// No ref while Settings records a shortcut: they're suspended too. Keyed by the handle the caller keeps; each
    /// registration has its own Carbon ID.
    @ObservationIgnored private var temporaryHotKeys: [UInt32: (ref: EventHotKeyRef?, carbonID: UInt32, shortcut: HotkeyShortcut,
                                                                action: () -> Void)] = [:]
    /// A new Carbon ID for every registration, so a press macOS queued for an older one (before a pause, a resume or a
    /// rebind) matches nothing registered now (Sol's round 7 re-review).
    @ObservationIgnored private var nextHotKeyID: UInt32 = 1
    /// Bumped whenever a shortcut changes, so the menu shows the current ones.
    private(set) var revision = 0
    /// What an action on a modifier key alone still needs from macOS: Input Monitoring, or a relaunch once it's on.
    private(set) var inputMonitoring = InputMonitoringNeed.none
    var needsInputMonitoring: Bool { inputMonitoring != .none }
    /// macOS turned the event tap off and it couldn't come back on: modifier-key shortcuts wait for the next reload.
    @ObservationIgnored private var modifierTapsStopped = false
    /// The clashing actions Use Other Keys left on their keys, because another app holds the new ones: Settings names
    /// them, whether Use Other Keys ran there or from the launch notice.
    var keptKeys: [CaptureHotkeyAction] = []
    /// While Settings records a shortcut nothing fires, so keys that are already Sukusho's reach the recorder.
    @ObservationIgnored private var isPaused = false
    /// Ends that recording: any other change to a shortcut ends it first, so nothing stays paused.
    @ObservationIgnored private var endRecording: (() -> Void)?
    /// Actions on a modifier key alone, which the event tap watches for instead of Carbon.
    @ObservationIgnored private var tapActions: [HotkeyShortcut: CaptureHotkeyAction] = [:]
    @ObservationIgnored private let modifierTaps = ModifierTapMonitor()
    /// Registered Carbon hotkeys for Window Management (empty while the setting is off).
    @ObservationIgnored private let windowHotkeys = WindowHotkeyRegistry<EventHotKeyRef>()
    /// Observed registration state for each window shortcut so Settings and Apps reflect reality.
    private(set) var windowHotkeyStatuses: [WindowAction: WindowHotkeyStatus] = [:]

    func activeWindowShortcutLabel(for action: WindowAction) -> String? {
        windowHotkeyStatuses[action] == .registered ? action.shortcutLabel : nil
    }

    var windowHotkeyIssues: [String] {
        WindowHotkeyRegistry<EventHotKeyRef>.issueMessages(from: windowHotkeyStatuses)
    }
    
    private init() {}

    deinit {
        unregisterHotkeys()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
    
    func registerHotkeys() {
        installEventHandlerIfNeeded()
        CaptureHotkeyPreferences.dropStoredDefaults()
        reloadHotkeys()
        // Back from System Settings with Input Monitoring on: the waiting shortcuts start working.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let manager = HotkeyManager.shared
                if manager.needsInputMonitoring || manager.modifierTapsStopped { manager.reloadHotkeys() }
            }
        }
    }

    func reloadHotkeys() {
        defer { revision += 1 }
        unregisterHotkeys()
        registrationErrors.removeAll()
        modifierTapsStopped = false
        guard !isPaused else { return }

        var registeredShortcuts: [HotkeyShortcut] = []
        var registeredClaims: [WindowHotkeyRegistry<EventHotKeyRef>.Claim] = []
        for action in CaptureHotkeyAction.allCases {
            guard let shortcut = CaptureHotkeyPreferences.shortcut(for: action) else { continue }
            // An off feature mustn't take ⌃⌘V from other apps.
            if action == .drawing, ScreenRecordingManager.shared.state != .recording { continue }
            if action == .clipboardHistory, !ScreendropPreferences.clipboardHistoryEnabled, !ScreendropPreferences.clipboardLauncherEnabled { continue }
            guard !registeredShortcuts.contains(where: shortcut.overlaps) else {
                registrationErrors[action] = "\(shortcut.displayString) is already used by another action."
                continue
            }
            registeredShortcuts.append(shortcut)
            registeredClaims.append(.init(shortcut: shortcut, owner: action.title))
            if shortcut.taps != nil {
                tapActions[shortcut] = action
                continue
            }

            do {
                hotKeyRefs[action] = try registerHotKey(action: action, shortcut: shortcut)
            } catch {
                registrationErrors[action] = error.localizedDescription
            }
        }
        syncWindowHotkeys(excluding: registeredClaims)
        watchModifierTaps()
    }

    private func syncWindowHotkeys(excluding claims: [WindowHotkeyRegistry<EventHotKeyRef>.Claim]) {
        let enabled = ScreendropPreferences.windowManagementEnabled
        windowHotkeys.sync(
            enabled: enabled && !isPaused,
            excluding: claims,
            nextID: newHotKeyID,
            register: { [self] shortcut, id in
                guard eventHandlerRef != nil else { return nil }
                return registerCarbonHotKey(shortcut, id: id)
            },
            unregister: { _ = UnregisterEventHotKey($0) }
        )
        if !enabled {
            windowHotkeyStatuses = [:]
        } else if !isPaused {
            windowHotkeyStatuses = windowHotkeys.statuses
        }
    }

    private func activeCaptureClaims() -> [WindowHotkeyRegistry<EventHotKeyRef>.Claim] {
        CaptureHotkeyAction.allCases.compactMap { action in
            if action == .drawing, ScreenRecordingManager.shared.state != .recording { return nil }
            if action == .clipboardHistory, !ScreendropPreferences.clipboardHistoryEnabled, !ScreendropPreferences.clipboardLauncherEnabled { return nil }
            guard let shortcut = CaptureHotkeyPreferences.shortcut(for: action) else { return nil }
            return .init(shortcut: shortcut, owner: action.title)
        }
    }

    /// Runs the event tap while some action is a modifier key on its own; without Input Monitoring those actions say so.
    private func watchModifierTaps() {
        guard !tapActions.isEmpty else {
            modifierTaps.stop()
            inputMonitoring = .none
            return
        }
        // macOS turned it off on the user's behalf: the monitor won't start again this run.
        guard !modifierTaps.isTurnedOff else {
            inputMonitoring = .turnedOff
            for (shortcut, action) in tapActions {
                registrationErrors[action] = "\(shortcut.displayString) is off until Sukusho relaunches: macOS turned off its watching."
            }
            return
        }
        let watching = modifierTaps.start(onTap: { [weak self] tap in
            self?.tapActions[HotkeyShortcut(tap)]?.perform()
        }, onStop: { [weak self] retryable in
            self?.modifierTapsDidStop(retryable: retryable)
        })
        // macOS applies a new Input Monitoring grant only when the app next opens (it says so, and taps stay silent
        // until then: VM, 27.2.1), so a grant this run can see but not use means a relaunch.
        let granted = CGPreflightListenEventAccess()
        inputMonitoring = .of(hasTapShortcuts: true, watching: watching, granted: granted)
        guard !watching else { return }
        NSLog("[Sukusho] Modifier-key shortcuts wait for Input Monitoring: preflight %@, Accessibility %@",
              granted ? "granted" : "not granted", AXIsProcessTrusted() ? "trusted" : "not trusted")
        for (shortcut, action) in tapActions {
            // Before a relaunch this run may not see a grant at all (VM, 27.2.1), so the row says what is true either way.
            registrationErrors[action] = inputMonitoring == .relaunch
                ? "\(shortcut.displayString) works once Sukusho relaunches."
                : "\(shortcut.displayString) is off until Sukusho has Input Monitoring and relaunches."
        }
    }

    /// Settings says so under each modifier-key shortcut. After a timeout, switching to Sukusho starts the tap again;
    /// turned off for the user, it stays off until Sukusho relaunches.
    private func modifierTapsDidStop(retryable: Bool) {
        NSLog("[Sukusho] macOS turned off the modifier-key shortcuts' event tap (%@)", retryable ? "timeout" : "user input")
        // Already latched in the monitor; this only brings Settings up to date.
        guard retryable else { return reloadHotkeys() }
        modifierTapsStopped = true
        for (shortcut, action) in tapActions {
            registrationErrors[action] = "macOS stopped Sukusho noticing \(shortcut.displayString). It starts again when you next switch to Sukusho."
        }
        revision += 1
    }

    /// Settings records a shortcut: nothing fires, not even a temporary key such as Scrolling Capture's Space, until
    /// `resumeAfterRecording`. `end` stops that recording.
    func pauseForRecording(until end: @escaping () -> Void) {
        endRecording = end
        isPaused = true
        unregisterHotkeys()
        for (id, entry) in temporaryHotKeys {
            entry.ref.map { _ = UnregisterEventHotKey($0) }
            temporaryHotKeys[id]?.ref = nil
        }
    }

    func resumeAfterRecording() {
        guard isPaused else { return }
        isPaused = false
        endRecording = nil
        for (handle, entry) in temporaryHotKeys where entry.ref == nil {
            let id = newHotKeyID()
            temporaryHotKeys[handle]?.carbonID = id
            temporaryHotKeys[handle]?.ref = registerCarbonHotKey(entry.shortcut, id: id)
        }
        reloadHotkeys()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &handlerRef
        )

        if status == noErr {
            eventHandlerRef = handlerRef
        } else {
            print("Failed to install hotkey handler, status=\(status)")
        }
    }
    
    /// Register the replacement before releasing the working shortcut. A
    /// rejected shortcut never changes either the preference or old binding.
    /// Puts every given action back on its default and registers again,
    /// all at once, so defaults never collide with each other mid-way.
    func restoreDefaults(for actions: [CaptureHotkeyAction]) {
        endRecording?()
        actions.forEach { CaptureHotkeyPreferences.resetToDefault($0) }
        reloadHotkeys()
    }

    /// Nil clears the action's shortcut and releases its binding.
    func setShortcut(_ shortcut: HotkeyShortcut?, for action: CaptureHotkeyAction) throws {
        endRecording?()
        defer { revision += 1 }
        guard let shortcut else {
            if let old = hotKeyRefs.removeValue(forKey: action) { UnregisterEventHotKey(old.ref) }
            CaptureHotkeyPreferences.saveShortcut(nil, for: action)
            registrationErrors[action] = nil
            stopWatchingTap(for: action)
            syncWindowHotkeys(excluding: activeCaptureClaims())
            return
        }
        if action == .drawing, ScreenRecordingManager.shared.state != .recording {
            CaptureHotkeyPreferences.saveShortcut(shortcut, for: action)
            registrationErrors[action] = nil
            return
        }
        if shortcut.taps != nil {
            // Nothing to register with macOS: saved, then watched for by the event tap.
            CaptureHotkeyPreferences.saveShortcut(shortcut, for: action)
            reloadHotkeys()
            // macOS's own prompt, once per app, only when a recorded tap needs it: its action is watched for (not an off
            // Clipboard History, not one that clashes). Settings offers the pane after that.
            if tapActions.values.contains(action), !CGPreflightListenEventAccess(), !AXIsProcessTrusted() {
                _ = CGRequestListenEventAccess()
            }
            return
        }
        if shortcut == CaptureHotkeyPreferences.shortcut(for: action), hotKeyRefs[action] != nil { return }
        installEventHandlerIfNeeded()
        let overlappingWindow = windowHotkeys.entries.contains { $0.shortcut.overlaps(shortcut) }
        if overlappingWindow { windowHotkeys.unregisterAll { _ = UnregisterEventHotKey($0) } }
        defer {
            if overlappingWindow || (ScreendropPreferences.windowManagementEnabled && windowHotkeys.entries.count < WindowAction.allCases.count) {
                syncWindowHotkeys(excluding: activeCaptureClaims())
            }
        }
        let newRef = try registerHotKey(action: action, shortcut: shortcut)
        if let old = hotKeyRefs[action] { UnregisterEventHotKey(old.ref) }
        hotKeyRefs[action] = newRef
        CaptureHotkeyPreferences.saveShortcut(shortcut, for: action)
        registrationErrors[action] = nil
        stopWatchingTap(for: action)
    }

    /// The action's shortcut is no longer a modifier tap.
    private func stopWatchingTap(for action: CaptureHotkeyAction) {
        guard let old = tapActions.first(where: { $0.value == action })?.key else { return }
        tapActions[old] = nil
        watchModifierTaps()
    }

    private func newHotKeyID() -> UInt32 {
        defer { nextHotKeyID &+= 1 }
        return nextHotKeyID
    }

    private func registerHotKey(action: CaptureHotkeyAction, shortcut: HotkeyShortcut) throws -> (ref: EventHotKeyRef, id: UInt32) {
        guard eventHandlerRef != nil else {
            throw NSError(domain: "Screendrop.Hotkeys", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Keyboard shortcuts could not be initialized. Try reopening Sukusho."
            ])
        }
        let id = newHotKeyID()
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), shortcut.modifiers.carbonEventModifiers,
            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "\(shortcut.displayString) could not be registered. It may be used by another app. Choose a different shortcut."
            ])
        }
        return (hotKeyRef, id)
    }

    private func unregisterHotkeys() {
        for entry in hotKeyRefs.values {
            UnregisterEventHotKey(entry.ref)
        }

        hotKeyRefs.removeAll()
        tapActions.removeAll()
        modifierTaps.stop()
        windowHotkeys.unregisterAll { _ = UnregisterEventHotKey($0) }
    }
    
    /// Nil when the key is taken; the caller goes on without it. While Settings records a shortcut, it's registered when
    /// the recording ends.
    func registerTemporaryHotKey(_ shortcut: HotkeyShortcut, action: @escaping () -> Void) -> UInt32? {
        installEventHandlerIfNeeded()
        let handle = newHotKeyID()
        let id = newHotKeyID()
        let ref = isPaused ? nil : registerCarbonHotKey(shortcut, id: id)
        guard isPaused || ref != nil else { return nil }
        temporaryHotKeys[handle] = (ref, id, shortcut, action)
        return handle
    }

    private func registerCarbonHotKey(_ shortcut: HotkeyShortcut, id: UInt32) -> EventHotKeyRef? {
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), shortcut.modifiers.carbonEventModifiers,
            EventHotKeyID(signature: Self.hotKeySignature, id: id), GetApplicationEventTarget(), 0, &hotKeyRef
        )
        return status == noErr ? hotKeyRef : nil
    }

    func unregisterTemporaryHotKey(_ id: UInt32) {
        guard let entry = temporaryHotKeys.removeValue(forKey: id) else { return }
        entry.ref.map { _ = UnregisterEventHotKey($0) }
        // A capture shortcut set to this key while it was taken failed to
        // register; with the key free again, try once more.
        if !registrationErrors.isEmpty { reloadHotkeys() }
    }

    func handleHotKey(id: UInt32) {
        // The key went to this shortcut, so the modifier held for it isn't a tap, whether or not the tap saw the key.
        modifierTaps.interrupt()
        // A press macOS queued before Settings started recording, or before this key was let go of, isn't Sukusho's now:
        // only what's registered at this moment runs.
        guard !isPaused else { return }
        if let entry = temporaryHotKeys.values.first(where: { $0.ref != nil && $0.carbonID == id }) { return entry.action() }
        if let action = windowHotkeys.action(for: id) {
            WindowManager.shared.perform(action)
            return
        }
        hotKeyRefs.first { $0.value.id == id }?.key.perform()
    }
}

// MARK: - Carbon Event Handler

private func hotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }
    
    var hotKeyID = EventHotKeyID()
    GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handleHotKey(id: hotKeyID.id)
    
    return noErr
}
