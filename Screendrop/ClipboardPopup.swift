import AppKit
import Carbon.HIToolbox
import SwiftUI

/// What the popup is showing: its search, type filter and selected entry.
@MainActor
@Observable
final class ClipboardPopupState {
    var query = ""
    var filter: ClipboardFilter = .all
    var selection: ClipboardEntry.ID?

    var sections: [ClipboardList.Section] {
        // A search under All Types finds snippets too (Astra, 2026-11-16); the list without one stays history.
        ClipboardHistoryModel.shared.sections(filter: filter, query: query, includesSnippets: !query.isEmpty)
    }

    var visibleEntries: [ClipboardEntry] { sections.flatMap(\.entries) }

    var selected: ClipboardEntry? {
        let entries = visibleEntries
        return entries.first { $0.id == selection } ?? entries.first
    }

    func reset() {
        query = ""
        filter = .all
        selection = nil
    }

    func move(by offset: Int) {
        let entries = visibleEntries
        guard !entries.isEmpty else { return }
        let current = entries.firstIndex { $0.id == selected?.id } ?? 0
        selection = entries[min(max(current + offset, 0), entries.count - 1)].id
    }


}

/// The clipboard popup on its shortcut: a panel that takes the keyboard
/// without bringing Sukusho forward, so the app in front stays the paste target.
@MainActor
final class ClipboardPopupPresenter {
    static let shared = ClipboardPopupPresenter()
    static let size = CGSize(width: 800, height: 520)

    let state = ClipboardPopupState()
    /// Where Paste goes: the app that was in front when the popup opened.
    private(set) var target: NSRunningApplication?
    private var panel: ClipboardPopupPanel?
    private var keyMonitor: Any?
    private var confirmingDeletion = false

    private init() {}

    var isVisible: Bool { panel?.isVisible == true }
    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        present(panel)
    }

    private func present(_ panel: ClipboardPopupPanel) {
        target = NSWorkspace.shared.frontmostApplication
        state.reset()
        ClipboardHistoryModel.shared.popupWillOpen()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // A little above the middle, where Spotlight and launchers open.
            panel.setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2,
                                         y: visible.minY + visible.height * 0.62 - Self.size.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        // SwiftUI asks for the search field's focus before the reused panel is key, and on the first opening after
        // launch the request can be lost: typing then went nowhere (Astra B3, 2026-11-16). Once the panel is key,
        // and after SwiftUI's first layout, the field takes the keyboard.
        focusSearchField()
        DispatchQueue.main.async { [weak self] in self?.focusSearchField() }
    }

    /// Makes the popup's search field the first responder, unless it already is.
    private func focusSearchField() {
        guard let panel, panel.isKeyWindow, let field = Self.searchField(in: panel.contentView) else { return }
        if let editor = field.currentEditor(), panel.firstResponder === editor { return }
        panel.makeFirstResponder(field)
    }

    private static func searchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { searchField(in: $0) }.first
    }

    func close() {
        panel?.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func deliver(_ entry: ClipboardEntry?, as delivery: ClipboardHistoryModel.Delivery) {
        guard let entry else { return }
        if delivery == .pastePlain, entry.kind == .image { return deliver(entry, as: .copy) }
        ClipboardHistoryModel.shared.deliver(entry, as: delivery, to: target) { [weak self] in self?.close() }
    }

    private func confirmDelete(_ entry: ClipboardEntry) {
        guard let panel, !confirmingDeletion else { return }
        confirmingDeletion = true
        CaptureLibraryModel.shared.deleteSelection([.clip(entry)], in: panel) { [weak self] in
            self?.confirmingDeletion = false
            self?.focusSearchField()
        }
    }

    private func makePanel() -> ClipboardPopupPanel {
        let panel = ClipboardPopupPanel(size: Self.size)
        panel.contentView = NSHostingView(rootView: ClipboardPopupView(state: state, presenter: self))
        panel.onResign = { [weak self] in
            guard let self, !confirmingDeletion else { return }
            close()
        }
        PreviewWindowCaptureExclusion.shared.registerPrivate(window: panel)
        return panel
    }

    /// Keys reach the popup while its search field has the focus.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !confirmingDeletion, event.window === panel else { return event }
            guard handle(event) else {
                // A keystroke the popup doesn't handle is typing: it goes to the search field, focused first if
                // something took the focus away, so a quick first word isn't lost.
                focusSearchField()
                return event
            }
            return nil
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (Int(event.keyCode), flags) {
        case (kVK_UpArrow, []): state.move(by: -1)
        case (kVK_DownArrow, []): state.move(by: 1)
        case (kVK_Escape, []): close()
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []): deliver(state.selected, as: .paste)
        case (kVK_Return, [.command]): deliver(state.selected, as: .copy)
        // ⇧⌘C: the clip as it was first copied, before it was optimized.
        case (kVK_ANSI_C, [.command, .shift]): deliver(state.selected.map(ClipboardHistoryModel.shared.original), as: .copy)
        case (kVK_Return, [.control, .command]): deliver(state.selected, as: .pastePlain)
        case (kVK_ANSI_Period, [.command]): if let entry = state.selected { ClipboardHistoryModel.shared.moveToSaved(entry) }
        case (kVK_ANSI_X, [.control]), (kVK_Delete, [.command]): if let entry = state.selected { confirmDelete(entry) }
        case (kVK_ANSI_K, [.command]): showActions()
        default:
            let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                          kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0]
            guard flags == [.command], let index = digits.firstIndex(of: Int(event.keyCode)) else { return false }
            let entries = ClipboardList.numberedEntries(state.sections)
            guard entries.indices.contains(index) else { return false }
            deliver(entries[index], as: .paste)
        }
        return true
    }

    /// ⌘K: what can be done with the selected entry, with the keys that do it.
    func showActions() {
        guard let entry = state.selected, let view = panel?.contentView else { return }
        let model = ClipboardHistoryModel.shared
        let menu = NSMenu()
        func add(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [], _ run: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(ClipboardMenuAction.run), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            let action = ClipboardMenuAction(run)
            item.target = action
            item.representedObject = action
            menu.addItem(item)
        }
        add("Paste to \(target?.localizedName ?? "App")", "\r") { [weak self] in self?.deliver(entry, as: .paste) }
        add("Copy to Clipboard", "\r", .command) { [weak self] in self?.deliver(entry, as: .copy) }
        if entry.kind != .image {
            add("Paste as Plain Text", "\r", [.control, .command]) { [weak self] in self?.deliver(entry, as: .pastePlain) }
        }
        menu.addItem(.separator())
        if entry.pinnedAt == nil, entry.kind != .snippet {
            add("Move to Saved", ".", .command) { model.moveToSaved(entry) }
        }
        if entry.kind == .image { add("Open in Editor") { [weak self] in self?.close(); model.openInEditor(entry) } }
        if entry.kind == .text { add("Save as Snippet") { model.saveAsSnippet(entry) } }
        menu.addItem(.separator())
        add("Delete Entry…", "x", .control) { [weak self] in self?.confirmDelete(entry) }
        // The point is the menu's top-left: put its bottom just above the 46 pt footer, its right edge
        // under the Actions button's, so it opens upward inside the popup.
        let top = 46 + 4 + menu.size.height
        let point = NSPoint(x: view.bounds.width - menu.size.width - 12,
                            y: view.isFlipped ? view.bounds.height - top : top)
        _ = menu.popUp(positioning: nil, at: point, in: view)
    }
}

/// Runs a closure for an NSMenuItem.
final class ClipboardMenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

/// Borderless and non-activating, yet able to hold the keyboard for the search field.
final class ClipboardPopupPanel: NSPanel {
    var onResign: (() -> Void)?

    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A click in another app, or another Sukusho window, closes it, as a menu would.
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

struct ClipboardPopupView: View {
    @Bindable var state: ClipboardPopupState
    let presenter: ClipboardPopupPresenter
    @State private var model = ClipboardHistoryModel.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        let sections = state.sections
        let selected = state.selected
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list(sections, selected: selected).frame(width: 300)
                Divider()
                detail(selected)
            }
            Divider()
            footer(selected)
        }
        .frame(width: ClipboardPopupPresenter.size.width, height: ClipboardPopupPresenter.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .onAppear { searchFocused = true }
        .onChange(of: model.popupOpenings) { _, _ in searchFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clipboard history")
    }

    private var header: some View {
        HStack(spacing: DS.Space.ml) {
            Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(.secondary)
            TextField(state.filter == .snippets ? "Search snippets…" : "Search clipboard…", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($searchFocused)
                .onChange(of: state.query) { _, _ in state.selection = nil }
            Button {
                state.filter = state.filter == .saved ? .all : .saved
            } label: {
                Label("Saved", systemImage: state.filter == .saved ? "star.fill" : "star")
            }
            .accessibilityAddTraits(state.filter == .saved ? .isSelected : [])
            Menu {
                Picker("Type", selection: $state.filter) {
                    ForEach(ClipboardFilter.allCases) { filter in
                        Label(filter.title, systemImage: filter.symbol).tag(filter)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(state.filter.title, systemImage: "line.3.horizontal.decrease")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .onChange(of: state.filter) { _, _ in state.selection = nil }
        }
        .padding(.horizontal, DS.Space.xl)
        .frame(height: 52)
    }

    private func list(_ sections: [ClipboardList.Section], selected: ClipboardEntry?) -> some View {
        let numbered = ClipboardList.numberedEntries(sections).map(\.id)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if sections.isEmpty { emptyList }
                    ForEach(sections) { section in
                        Text(section.title)
                            .font(DS.TypeScale.labelSemibold).foregroundStyle(.secondary)
                            .padding(.horizontal, DS.Space.ml).padding(.top, DS.Space.ml).padding(.bottom, DS.Space.xs)
                        ForEach(section.entries) { entry in
                            row(entry, isSelected: entry.id == selected?.id,
                                pinNumber: numbered.firstIndex(of: entry.id).map { ($0 + 1) % 10 })
                                .id(entry.id)
                        }
                    }
                }
                .padding(DS.Space.m)
            }
            .onChange(of: state.selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private var emptyList: some View {
        Text(!model.hasLoaded ? "Loading…" : !ScreendropPreferences.clipboardHistoryEnabled
             ? "Clipboard history is off. Turn it on in Settings › Clipboard."
             : state.query.isEmpty ? "Nothing here yet. Copy something." : "No matches.")
            .font(DS.TypeScale.body).foregroundStyle(.secondary)
            .padding(DS.Space.ml)
    }

    private func row(_ entry: ClipboardEntry, isSelected: Bool, pinNumber: Int?) -> some View {
        HStack(spacing: DS.Space.ml) {
            ClipboardRowTile(entry: entry)
            Text(ClipboardList.title(of: entry))
                .font(ClipboardList.looksLikeCode(entry) ? .system(size: 12.5, design: .monospaced) : .system(size: 13.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if entry.pinnedAt != nil { Image(systemName: "star.fill").accessibilityLabel("Saved") }
            if let pinNumber { Text("⌘\(pinNumber)").font(DS.TypeScale.label).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, DS.Space.ml)
        .frame(height: 36)
        .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { presenter.deliver(entry, as: .paste) }
        .onTapGesture { state.selection = entry.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Paste") { presenter.deliver(entry, as: .paste) }
    }

    @ViewBuilder
    private func detail(_ entry: ClipboardEntry?) -> some View {
        if let entry {
            VStack(spacing: 0) {
                ClipboardPreview(entry: entry).frame(maxWidth: .infinity, maxHeight: .infinity)
                ClipboardInfo(entry: entry, model: model)
                    .padding(.horizontal, DS.Space.xl).padding(.bottom, DS.Space.m)
            }
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func footer(_ entry: ClipboardEntry?) -> some View {
        HStack(spacing: DS.Space.m) {
            if let message = model.feedback.message {
                Label(message, systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                Text("⌘1–⌘0 paste by position").foregroundStyle(.tertiary)
            }
            Spacer()
            Button { presenter.deliver(entry, as: .paste) } label: {
                HStack(spacing: DS.Space.s) {
                    Text("Paste to \(presenter.target?.localizedName ?? "App")")
                    KeyCap("↩")
                }
            }
            .buttonStyle(.bordered)
            .disabled(entry == nil)
            Button { presenter.showActions() } label: {
                HStack(spacing: DS.Space.s) { Text("Actions"); KeyCap("⌘"); KeyCap("K") }
            }
            .buttonStyle(.plain)
            .disabled(entry == nil)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, DS.Space.l)
        .frame(height: 46)
    }
}

/// A key's symbol in a small rounded cap.
private struct KeyCap: View {
    let symbol: String
    init(_ symbol: String) { self.symbol = symbol }
    var body: some View {
        Text(symbol).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            .frame(minWidth: 20, minHeight: 20)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
    }
}
