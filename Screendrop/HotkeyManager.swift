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
    private var hotKeyRefs: [CaptureHotkeyAction: EventHotKeyRef] = [:]
    private(set) var registrationErrors: [CaptureHotkeyAction: String] = [:]
    /// Keys that exist only while something is on screen, such as the
    /// recording pen's Esc and ⌘Z. Their IDs start above the actions'.
    /// No ref while Settings records a shortcut: they're suspended too.
    @ObservationIgnored private var temporaryHotKeys: [UInt32: (ref: EventHotKeyRef?, shortcut: HotkeyShortcut, action: () -> Void)] = [:]
    @ObservationIgnored private var nextTemporaryHotKeyID: UInt32 = 1000
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
        for action in CaptureHotkeyAction.allCases {
            guard let shortcut = CaptureHotkeyPreferences.shortcut(for: action) else { continue }
            // An off feature mustn't take ⌃⌘V from other apps.
            if action == .clipboardHistory, !ScreendropPreferences.clipboardHistoryEnabled { continue }
            guard !registeredShortcuts.contains(where: shortcut.overlaps) else {
                registrationErrors[action] = "\(shortcut.displayString) is already used by another action."
                continue
            }
            registeredShortcuts.append(shortcut)
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
        watchModifierTaps()
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
        for (id, entry) in temporaryHotKeys where entry.ref == nil {
            temporaryHotKeys[id]?.ref = registerCarbonHotKey(entry.shortcut, id: id)
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
            if let oldRef = hotKeyRefs.removeValue(forKey: action) { UnregisterEventHotKey(oldRef) }
            CaptureHotkeyPreferences.saveShortcut(nil, for: action)
            registrationErrors[action] = nil
            stopWatchingTap(for: action)
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
        let newRef = try registerHotKey(action: action, shortcut: shortcut)
        if let oldRef = hotKeyRefs[action] { UnregisterEventHotKey(oldRef) }
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

    private func registerHotKey(action: CaptureHotkeyAction, shortcut: HotkeyShortcut) throws -> EventHotKeyRef {
        guard eventHandlerRef != nil else {
            throw NSError(domain: "Screendrop.Hotkeys", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Keyboard shortcuts could not be initialized. Try reopening Sukusho."
            ])
        }
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: action.hotKeyID)
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
        return hotKeyRef
    }

    private func unregisterHotkeys() {
        for hotKeyRef in hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }

        hotKeyRefs.removeAll()
        tapActions.removeAll()
        modifierTaps.stop()
    }
    
    /// Nil when the key is taken; the caller goes on without it. While Settings records a shortcut, it's registered when
    /// the recording ends.
    func registerTemporaryHotKey(_ shortcut: HotkeyShortcut, action: @escaping () -> Void) -> UInt32? {
        installEventHandlerIfNeeded()
        let id = nextTemporaryHotKeyID
        nextTemporaryHotKeyID &+= 1
        let ref = isPaused ? nil : registerCarbonHotKey(shortcut, id: id)
        guard isPaused || ref != nil else { return nil }
        temporaryHotKeys[id] = (ref, shortcut, action)
        return id
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
        if let entry = temporaryHotKeys[id] {
            if entry.ref != nil { entry.action() }
            return
        }
        guard let action = CaptureHotkeyAction(hotKeyID: id), hotKeyRefs[action] != nil else { return }
        action.perform()
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
