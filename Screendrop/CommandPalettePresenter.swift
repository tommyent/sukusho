//
//  CommandPalettePresenter.swift
//  Screendrop
//
//  The command palette's own panel, inside Sukusho only (the owner, 2026-11-24): ⇧⌘P, or the keys Settings › Shortcuts
//  holds for it, opens it under the toolbar of the Sukusho window in front, as a child of that window, with that
//  window's commands.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// What a Sukusho window hands the palette as it opens over it.
enum PaletteWindowContext {
    case library(LibraryPaletteHooks)
    case editor(EditorPaletteHooks)
    case studio(StudioPaletteHooks)
}

/// The Library window's own state the palette reaches: the sidebar, the inspector, the search field and ⌘R.
struct LibraryPaletteHooks {
    var sidebarShown: () -> Bool
    var toggleSidebar: () -> Void
    var inspectorShown: () -> Bool
    var toggleInspector: () -> Void
    var find: () -> Void
    var refresh: () -> Void
}

struct EditorPaletteHooks {
    weak var model: AnnotationEditorModel?
    var selectTool: (AnnotationTool) -> Void
    var pickColor: () -> Void
    var measure: () -> Void
    var inspectorShown: () -> Bool
    var toggleInspector: () -> Void
}

struct StudioPaletteHooks {
    weak var model: RecordingStudioModel?
    var inspectorShown: () -> Bool
    var toggleInspector: () -> Void
}

extension View {
    /// Lets ⇧⌘P open the palette over this view's window with what `context` says about it at that moment.
    func commandPaletteContext(_ context: @escaping () -> PaletteWindowContext) -> some View {
        onWindowChange { CommandPalettePresenter.shared.register($0, context: context) }
    }
}

@MainActor
final class CommandPalettePresenter {
    static let shared = CommandPalettePresenter()
    static let width: CGFloat = 600

    private var panel: CommandPalettePanel?
    private(set) var model: CommandPaletteModel?
    private var keyMonitor: Any?
    /// The window it opened over, given the keyboard back as it closes.
    private weak var parent: NSWindow?
    private var contexts: [ObjectIdentifier: (window: WeakWindowBox, context: () -> PaletteWindowContext)] = [:]
    /// What a command does once the palette is gone: a capture mustn't catch it, and the window's own keys and
    /// responder chain need that window key again.
    private var afterClose: [() -> Void] = []

    private init() {}

    var isVisible: Bool { panel?.isVisible == true }

    func register(_ window: NSWindow?, context: @escaping () -> PaletteWindowContext) {
        contexts = contexts.filter { $0.value.window.window != nil }
        guard let window else { return }
        contexts[ObjectIdentifier(window)] = (WeakWindowBox(window), context)
    }

    /// ⇧⌘P (View › Command Palette…): closes it when it's open, else opens it over the Sukusho window in front. With no
    /// window open, there is nothing to open it over.
    func toggle() {
        if isVisible { return close() }
        guard NSApp.isActive, let front = NSApp.keyWindow ?? NSApp.mainWindow, front.isVisible else { return NSSound.beep() }
        show(over: front)
    }

    func show(over window: NSWindow, start: PaletteStep = .commands) {
        close()
        let context = contexts[ObjectIdentifier(window)]?.context()
        let host = AppCommandPaletteHost(context: context, windowTitle: window.title.isEmpty ? nil : window.title)
        let model = CommandPaletteModel(host: host, start: start)
        model.onClose = { [weak self] in self?.close() }
        self.model = model
        parent = window

        let panel = CommandPalettePanel()
        let maxHeight = Self.maxHeight(over: window)
        let hosting = NSHostingView(rootView: CommandPaletteView(model: model, maxHeight: maxHeight) { [weak self] size in
            self?.fit(size)
        })
        // Measured with its intrinsic size (with none, `fittingSize` is 0 × 0), then sized by `fit` as the list changes.
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.fittingSize
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.onResign = { [weak self] in
            // A click elsewhere closes it, as a menu would; a sheet or alert a command raised doesn't count.
            guard let self, self.panel === panel, NSApp.modalWindow == nil else { return }
            self.close()
        }
        PreviewWindowCaptureExclusion.shared.registerPrivate(window: panel)
        self.panel = panel

        panel.setContentSize(NSSize(width: Self.width, height: max(1, size.height)))
        panel.setFrameTopLeftPoint(Self.topLeft(width: Self.width, over: window))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        focusField()
        DispatchQueue.main.async { [weak self] in self?.focusField() }
    }

    func close() {
        guard let panel else { return runAfterClose() }
        self.panel = nil
        panel.onResign = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        // Puts a theme being tried on back before anything else can read it.
        let closing = model
        model = nil
        closing?.onClose = {}
        closing?.close()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        if let parent, parent.isVisible, NSApp.isActive { parent.makeKeyAndOrderFront(nil) }
        parent = nil
        runAfterClose()
    }

    /// Runs `action` once the palette is gone.
    func whenClosed(_ action: @escaping () -> Void) {
        afterClose.append(action)
    }

    private func runAfterClose() {
        let actions = afterClose
        afterClose = []
        guard !actions.isEmpty else { return }
        // A turn later, so the window server has taken the panel down before a capture starts.
        DispatchQueue.main.async { actions.forEach { $0() } }
    }

    /// Keeps the panel's top edge where it is as the list grows or shrinks.
    private func fit(_ size: CGSize) {
        guard let panel, size.height > 0, abs(panel.frame.height - size.height) > 0.5 else { return }
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: Self.width, height: size.height), display: true)
        panel.invalidateShadow()
    }

    /// Under the window's toolbar, centered on it.
    private static func topLeft(width: CGFloat, over window: NSWindow) -> NSPoint {
        let contentTop = window.frame.minY + window.contentLayoutRect.maxY
        return NSPoint(x: window.frame.midX - width / 2, y: contentTop - 8)
    }

    /// The list stays inside the window it opens over.
    private static func maxHeight(over window: NSWindow) -> CGFloat {
        max(220, window.contentLayoutRect.height - 24)
    }

    // MARK: Keys

    private func focusField() {
        guard let panel, panel.isKeyWindow, let field = Self.field(in: panel.contentView) else { return }
        if let editor = field.currentEditor(), panel.firstResponder === editor { return }
        panel.makeFirstResponder(field)
    }

    private static func field(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { field(in: $0) }.first
    }

    /// The palette's keys reach the model before the field or the menus: ↑↓, ↩, →, Esc and ⌘C. Its own shortcut, as
    /// Settings › Shortcuts holds it, closes it.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel, event.window === panel, let model else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // Keys mid-composition (Japanese input and the like) are the input method's.
            if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
            let pressed = HotkeyShortcut(modifiers: HotkeyShortcut.Modifiers(from: flags), keyCode: Int(event.keyCode))
            if CaptureHotkeyPreferences.shortcut(for: .commandPalette) == pressed {
                close()
                return nil
            }
            let key: PaletteKey?
            switch (Int(event.keyCode), flags) {
            case (kVK_UpArrow, []): key = .up
            case (kVK_DownArrow, []): key = .down
            case (kVK_RightArrow, []): key = .right
            case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []): key = .enter
            case (kVK_Escape, []): key = .escape
            case (kVK_ANSI_C, [.command]): key = .copy
            default: key = nil
            }
            guard let key else { return event }
            return model.press(key) ? nil : event
        }
    }
}

/// Borderless, a child of the window it opens over, and able to hold the keyboard for its field.
final class CommandPalettePanel: NSPanel {
    var onResign: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: CommandPalettePresenter.width, height: 400),
                   styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        hidesOnDeactivate = true
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        // The window server's shadow, from the palette's own shape, as the ⌃⌘V popup has.
        hasShadow = true
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
        setAccessibilityLabel("Command palette")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

/// View › Command Palette… in every Sukusho window, on the keys Settings › Shortcuts holds for it (⇧⌘P unless changed).
struct CommandPaletteCommand: View {
    var body: some View {
        // Shortcuts change in Settings; this re-reads them, as the Capture menu does.
        let _ = HotkeyManager.shared.revision
        Button("Command Palette…") { CommandPalettePresenter.shared.toggle() }
            .keyboardShortcut(MenuBarView.shortcut(for: .commandPalette))
    }
}
