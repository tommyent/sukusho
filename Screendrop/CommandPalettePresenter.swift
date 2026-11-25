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

/// A Studio control the command palette opens in its own place, with its own options (sd-458l): a toolbar popover,
/// the inspector's Translate Captions picker, the timeline's Reset All Clip Edits confirmation or a zoom step. The
/// control that owns it watches `RecordingStudioModel.paletteRequest` and clears it as it opens.
struct StudioPaletteRequest: Equatable {
    enum Kind { case exportOptions, uploadOptions, translateCaptions, resetClips, zoomIn, zoomOut, fitTimeline }
    let kind: Kind
    /// Each request is its own, so a control that appears later never takes an old one (Sol's second review).
    let id = UUID()

    init(_ kind: Kind) { self.kind = kind }
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
    /// Why the toolbar's Upload isn't there to press now, or nil.
    var uploadUnavailable: () -> String?
    /// Opens the toolbar Upload's options, on its button.
    var openUpload: () -> Void
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
    static let width = CommandPalettePanel.width

    private var panel: CommandPalettePanel?
    private var hosting: NSHostingView<CommandPaletteView>?
    /// The panel's size and place, set a turn after whatever asked for them: never inside a window's layout pass, where
    /// AppKit throws if a view's constraints change. Resizing it inside its parent's didResize, as Settings animated to
    /// another pane, crashed 1.3.0 (32.261125.0651) on the owner's Air (2026-11-25).
    private lazy var placement = PaletteDeferredUpdate { [weak self] in self?.place() }
    /// The height the list asked for, for the next `place()`.
    private var askedHeight: CGFloat?
    private(set) var model: CommandPaletteModel?
    private var keyMonitor: Any?
    /// The window it opened over, given the keyboard back as it closes from the keys.
    private weak var parent: NSWindow?
    private var contexts: [ObjectIdentifier: (window: WeakWindowBox, context: () -> PaletteWindowContext)] = [:]
    /// What a command does once the palette is gone: a capture mustn't catch it, and the window's own keys and
    /// responder chain need that window key again.
    private var afterClose: [() -> Void] = []

    private init() {
        let center = NotificationCenter.default
        // A closing window takes its context and the palette over it along, without fronting it again (Sol's finding 8).
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let closing = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.windowWillClose(closing) }
        }
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(refocus: false) }
        }
        // The panel stays under the toolbar and inside the screen as the window it's over resizes or changes screen.
        for name in [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let moved = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated { self?.parentMoved(moved) }
            }
        }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func register(_ window: NSWindow?, context: @escaping () -> PaletteWindowContext) {
        contexts = contexts.filter { $0.value.window.window != nil }
        guard let window else { return }
        contexts[ObjectIdentifier(window)] = (WeakWindowBox(window), context)
    }

    private func windowWillClose(_ id: ObjectIdentifier?) {
        guard let id else { return }
        contexts[id] = nil
        if let parent, ObjectIdentifier(parent) == id { close(refocus: false) }
    }

    private func parentMoved(_ id: ObjectIdentifier?) {
        guard let parent, let id, ObjectIdentifier(parent) == id else { return }
        placement.request()
    }

    /// ⇧⌘P (View › Command Palette…): closes it when it's open, else opens it over the Sukusho window in front. With no
    /// window open, there is nothing to open it over.
    func toggle() {
        if isVisible { return close() }
        guard NSApp.isActive, let front = NSApp.keyWindow ?? NSApp.mainWindow, front.isVisible else { return NSSound.beep() }
        show(over: front)
    }

    func show(over window: NSWindow, start: PaletteStep = .commands) {
        close(refocus: false)
        let context = contexts[ObjectIdentifier(window)]?.context()
        let host = AppCommandPaletteHost(context: context, windowTitle: window.title.isEmpty ? nil : window.title)
        let model = CommandPaletteModel(host: host, start: start)
        model.onClose = { [weak self] in self?.close() }
        self.model = model
        parent = window

        let panel = CommandPalettePanel()
        let place = Self.frame(height: 1, over: window)
        model.maxHeight = place.maxHeight
        let hosting = NSHostingView(rootView: CommandPaletteView(model: model) { [weak self] size in self?.fit(size) })
        // Measured with its intrinsic size (with none, `fittingSize` is 0 × 0), then sized by `fit` as the list changes.
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.fittingSize
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.onResign = { [weak self, weak panel] in
            // A click elsewhere closes it, as a menu would, and leaves the keyboard where the click put it: on another
            // window, an alert, or another app (Sol's finding 8).
            guard let self, let panel, self.panel === panel else { return }
            self.close(refocus: false)
        }
        self.panel = panel
        self.hosting = hosting

        panel.setFrame(Self.frame(height: max(1, size.height), over: window).rect, display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        focusField()
        DispatchQueue.main.async { [weak self] in self?.focusField() }
    }

    /// Closes it, once however often it's asked. `refocus` gives the window it opened over the keyboard back: after Esc,
    /// ↩ or its keys, not after a click elsewhere or the window closing.
    func close(refocus: Bool = true) {
        guard let panel else { return runAfterClose() }
        self.panel = nil
        hosting = nil
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
        if refocus, let parent, parent.isVisible, NSApp.isActive, NSApp.modalWindow == nil { parent.makeKeyAndOrderFront(nil) }
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

    /// The list's measured size, reported from inside the panel's own layout: placed a turn later.
    private func fit(_ size: CGSize) {
        guard size.height > 0 else { return }
        askedHeight = size.height
        placement.request()
    }

    /// Sizes and places the panel for the list's height under its window, and tells the list how tall it may be. Only
    /// from `placement`, outside any layout pass.
    private func place() {
        guard let panel, let parent, let model else { return }
        let frame = Self.frame(height: askedHeight ?? panel.frame.height, over: parent)
        askedHeight = nil
        if abs(model.maxHeight - frame.maxHeight) > 0.5 { model.maxHeight = frame.maxHeight }
        let now = panel.frame
        guard abs(now.minX - frame.rect.minX) > 0.5 || abs(now.maxY - frame.rect.maxY) > 0.5
            || abs(now.height - frame.rect.height) > 0.5 else { return }
        panel.setFrame(frame.rect, display: true)
        panel.invalidateShadow()
    }

    /// Under the window's toolbar, centered on it, kept inside the screen the window is on: a window partly off it, or
    /// across two displays, would put the list out of sight (Sol's other notes). The list stays inside the window too.
    static func frame(height: CGFloat, over window: NSWindow) -> (rect: NSRect, maxHeight: CGFloat) {
        let margin: CGFloat = 8
        var top = window.frame.minY + window.contentLayoutRect.maxY - margin
        var x = window.frame.midX - width / 2
        var room = window.contentLayoutRect.height - 24
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, visible.minX + margin), visible.maxX - width - margin)
            top = min(top, visible.maxY - margin)
            room = min(room, top - visible.minY - margin)
        }
        let maxHeight = max(220, room)
        let shown = min(height, maxHeight)
        return (NSRect(x: x, y: top - shown, width: width, height: shown), maxHeight)
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

    /// The palette's keys reach the model before the field or the menus: ↑↓, ↩, →, Esc, ⌘C and ⌘Y, each only where it
    /// does something. Everything else goes on: its own shortcut to View › Command Palette…, which closes it, so the
    /// keys that open it close it on any layout, as the menu item matches them (Sol's reviews, finding 4 and 7).
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel, event.window === panel, let model else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // Keys mid-composition (Japanese input and the like) are the input method's.
            if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
            let key: PaletteKey?
            switch (Int(event.keyCode), flags) {
            case (kVK_UpArrow, []): key = .up
            case (kVK_DownArrow, []): key = .down
            case (kVK_RightArrow, []): key = .right
            case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []): key = .enter
            case (kVK_Escape, []): key = .escape
            case (_, [.command]) where event.charactersIgnoringModifiers?.lowercased() == "c": key = .copy
            case (_, [.command]) where event.charactersIgnoringModifiers?.lowercased() == "y": key = .quickLook
            default: key = nil
            }
            guard let key else { return event }
            return model.press(key) ? nil : event
        }
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
