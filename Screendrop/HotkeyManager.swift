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
    @ObservationIgnored private var temporaryHotKeys: [UInt32: (ref: EventHotKeyRef, action: () -> Void)] = [:]
    @ObservationIgnored private var nextTemporaryHotKeyID: UInt32 = 1000
    /// Bumped whenever a shortcut changes, so the menu shows the current ones.
    private(set) var revision = 0
    
    private init() {}

    deinit {
        unregisterHotkeys()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
    
    func registerHotkeys() {
        installEventHandlerIfNeeded()
        reloadHotkeys()
    }

    func reloadHotkeys() {
        defer { revision += 1 }
        unregisterHotkeys()
        registrationErrors.removeAll()

        var registeredShortcuts: Set<HotkeyShortcut> = []
        for action in CaptureHotkeyAction.allCases {
            guard let shortcut = CaptureHotkeyPreferences.shortcut(for: action) else { continue }
            guard registeredShortcuts.insert(shortcut).inserted else {
                registrationErrors[action] = "\(shortcut.displayString) is already used by another action."
                continue
            }

            do {
                hotKeyRefs[action] = try registerHotKey(action: action, shortcut: shortcut)
            } catch {
                registrationErrors[action] = error.localizedDescription
            }
        }
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
        actions.forEach { CaptureHotkeyPreferences.resetToDefault($0) }
        reloadHotkeys()
    }

    /// Nil clears the action's shortcut and releases its binding.
    func setShortcut(_ shortcut: HotkeyShortcut?, for action: CaptureHotkeyAction) throws {
        defer { revision += 1 }
        guard let shortcut else {
            if let oldRef = hotKeyRefs.removeValue(forKey: action) { UnregisterEventHotKey(oldRef) }
            CaptureHotkeyPreferences.saveShortcut(nil, for: action)
            registrationErrors[action] = nil
            return
        }
        if shortcut == CaptureHotkeyPreferences.shortcut(for: action), hotKeyRefs[action] != nil { return }
        installEventHandlerIfNeeded()
        let newRef = try registerHotKey(action: action, shortcut: shortcut)
        if let oldRef = hotKeyRefs[action] { UnregisterEventHotKey(oldRef) }
        hotKeyRefs[action] = newRef
        CaptureHotkeyPreferences.saveShortcut(shortcut, for: action)
        registrationErrors[action] = nil
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
    }
    
    /// Nil when the key is taken; the caller goes on without it.
    func registerTemporaryHotKey(_ shortcut: HotkeyShortcut, action: @escaping () -> Void) -> UInt32? {
        installEventHandlerIfNeeded()
        let id = nextTemporaryHotKeyID
        nextTemporaryHotKeyID &+= 1
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), shortcut.modifiers.carbonEventModifiers,
            EventHotKeyID(signature: Self.hotKeySignature, id: id), GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else { return nil }
        temporaryHotKeys[id] = (hotKeyRef, action)
        return id
    }

    func unregisterTemporaryHotKey(_ id: UInt32) {
        guard let entry = temporaryHotKeys.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(entry.ref)
        // A capture shortcut set to this key while it was taken failed to
        // register; with the key free again, try once more.
        if !registrationErrors.isEmpty { reloadHotkeys() }
    }

    func handleHotKey(id: UInt32) {
        if let action = temporaryHotKeys[id]?.action { return action() }
        CaptureHotkeyAction(hotKeyID: id)?.perform()
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
