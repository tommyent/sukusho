import AppKit
import SwiftUI

/// The Library's Clipboard pages: History, Snippets, and the setup page while history is off.
struct ClipboardLibraryPage: View {
    @Bindable var model: ClipboardHistoryModel
    @AppStorage(ScreendropPreferences.clipboardHistoryEnabledKey) private var enabled = false
    @State private var filter: ClipboardFilter = .all
    @State private var library = CaptureLibraryModel.shared

    var body: some View {
        if !enabled {
            ClipboardSetupPage()
        } else if !model.hasLoaded {
            ProgressView("Loading Clipboard…").workspaceTextPlate().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let shown = model.showsSnippets ? .snippets : filter
            let sections = model.sections(filter: shown, query: library.searchText)
            VStack(spacing: 0) {
                if model.showsSnippets { snippetBar } else { filterBar }
                if sections.isEmpty {
                    emptyPage.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DS.Space.l, pinnedViews: []) {
                            ForEach(sections) { section in
                                Text(section.title).font(DS.TypeScale.labelSemibold).foregroundStyle(.secondary)
                                    .workspaceTextPlate()
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: DS.Space.l)],
                                          alignment: .leading, spacing: DS.Space.l) {
                                    ForEach(section.entries) { entry in
                                        ClipboardCard(entry: entry, model: model,
                                                      isSelected: model.librarySelection == entry.id)
                                    }
                                }
                            }
                        }
                        .padding(DS.Space.xl)
                    }
                }
            }
        }
    }

    private var snippetBar: some View {
        HStack {
            Spacer()
            Button("New Snippet", systemImage: "plus") {
                Task { model.librarySelection = await model.addSnippet(title: "New Snippet") }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, DS.Space.xl).padding(.top, DS.Space.l)
    }

    private var filterBar: some View {
        HStack(spacing: DS.Space.m) {
            ForEach(ClipboardFilter.allCases.filter { $0 != .snippets }) { item in
                Button { filter = item } label: {
                    Label(item == .all ? "All" : item.title, systemImage: item.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, DS.Space.ml).padding(.vertical, DS.Space.xs)
                        .background(filter == item ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == item ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.xl).padding(.top, DS.Space.l)
    }

    @ViewBuilder
    private var emptyPage: some View {
        if model.showsSnippets {
            ContentUnavailableView {
                Label("No Snippets", systemImage: "text.badge.star")
            } description: {
                Text("Save text you paste often. Paste a snippet from the clipboard popup (⌃⌘V) like any copy.")
            } actions: {
                Button("New Snippet") { Task { model.librarySelection = await model.addSnippet(title: "New Snippet") } }
                    .buttonStyle(.borderedProminent)
            }
            .workspaceTextPlate()
        } else if !library.searchText.isEmpty {
            ContentUnavailableView.search(text: library.searchText).workspaceTextPlate()
        } else {
            ContentUnavailableView {
                Label("Nothing Copied Yet", systemImage: "doc.on.clipboard")
            } description: {
                Text("What you copy from now on appears here and in the clipboard popup.")
            }
            .workspaceTextPlate()
        }
    }
}

/// One copy in the Library's grid: its picture, swatch, text or files, and where it came from.
private struct ClipboardCard: View {
    let entry: ClipboardEntry
    let model: ClipboardHistoryModel
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            face
                .frame(height: 124)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.l))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.l)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isSelected ? 3 : 0.5))
                .overlay(alignment: .bottomLeading) {
                    if entry.libraryPath != nil {
                        Text("In Library").font(.system(size: 11, weight: .semibold)).foregroundStyle(.blue)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.background, in: Capsule()).padding(DS.Space.s)
                    }
                }
            Text(ClipboardList.title(of: entry)).font(DS.TypeScale.labelMedium).lineLimit(1)
            HStack(spacing: DS.Space.xs) {
                if let icon = model.appIcon(entry.sourceBundleID) { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
                Text([model.appName(entry.sourceBundleID), entry.kind == .snippet ? nil : ClipboardInfo.when(entry.lastCopiedAt)]
                    .compactMap { $0 }.joined(separator: " · "))
                if entry.pinnedAt != nil { Image(systemName: "pin.fill").font(.system(size: 9)) }
            }
            .font(DS.TypeScale.label).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.deliver(entry, as: .copy, to: nil) }
        .onTapGesture { model.librarySelection = entry.id }
        .contextMenu { ClipboardEntryMenu(entry: entry, model: model) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Copy") { model.deliver(entry, as: .copy, to: nil) }
    }

    @ViewBuilder private var face: some View {
        switch entry.kind {
        case .image:
            if let url = entry.imageFileURL { ClipboardThumbnail(url: url, maxPixelSize: 520) }
        case .files:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ClipboardRowTile(entry: entry, size: 36)
                Text(entry.filePaths.first.map { ($0 as NSString).deletingLastPathComponent } ?? "")
                    .font(DS.TypeScale.label).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            .padding(DS.Space.l).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background)
        case .text, .snippet:
            if case .color(let hex) = ClipboardList.textForm(of: entry), let color = Color(clipboardHex: hex) {
                color
            } else {
                Text(entry.text ?? "")
                    .font(ClipboardList.looksLikeCode(entry) ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                    .lineLimit(6)
                    .padding(DS.Space.l)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(.background)
            }
        }
    }
}

/// The same actions in a card's context menu and the inspector.
struct ClipboardEntryMenu: View {
    let entry: ClipboardEntry
    let model: ClipboardHistoryModel

    var body: some View {
        Button("Copy") { model.deliver(entry, as: .copy, to: nil) }
        if entry.kind == .text { Button("Copy as Plain Text") { model.deliver(entry, as: .copyPlain, to: nil) } }
        Divider()
        Button(entry.pinnedAt == nil ? "Pin" : "Unpin") { model.togglePin(entry) }
        if entry.kind == .image, entry.libraryPath == nil { Button("Add to Library") { model.addToLibrary(entry) } }
        if entry.kind == .text { Button("Save as Snippet") { model.saveAsSnippet(entry) } }
        Divider()
        Button("Delete", role: .destructive) { model.delete(entry) }
    }
}

/// The inspector beside the Clipboard page: the preview and Information,
/// and for a snippet, its name and text to edit.
struct ClipboardLibraryInspector: View {
    @Bindable var model: ClipboardHistoryModel

    var body: some View {
        // History's selection doesn't show on Snippets, nor the other way round.
        if let entry = model.entry(model.librarySelection), (entry.kind == .snippet) == model.showsSnippets {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    if entry.kind == .snippet {
                        SnippetEditor(entry: entry, model: model)
                    } else {
                        ClipboardPreview(entry: entry).frame(height: 220)
                        HStack {
                            Button("Copy") { model.deliver(entry, as: .copy, to: nil) }.buttonStyle(.borderedProminent)
                            Button(entry.pinnedAt == nil ? "Pin" : "Unpin") { model.togglePin(entry) }
                            if entry.kind == .image, entry.libraryPath == nil {
                                Button("Add to Library") { model.addToLibrary(entry) }
                            }
                        }
                        .controlSize(.small)
                        ClipboardInfo(entry: entry, model: model)
                    }
                    if let message = model.feedback.message {
                        Label(message, systemImage: "checkmark.circle").font(DS.TypeScale.label).foregroundStyle(.secondary)
                    }
                }
                .padding(DS.Space.l)
            }
        } else {
            ContentUnavailableView("Nothing Selected", systemImage: "doc.on.clipboard",
                                   description: Text(model.showsSnippets ? "Select a snippet to edit it." : "Select a copy to see it here."))
        }
    }
}

/// A snippet's name and text, saved as they're typed.
private struct SnippetEditor: View {
    let entry: ClipboardEntry
    let model: ClipboardHistoryModel
    @State private var title = ""
    @State private var text = ""
    @State private var saving: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            TextField("Name", text: $title).textFieldStyle(.roundedBorder).font(DS.TypeScale.title)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(DS.Space.s)
                .background(.background, in: RoundedRectangle(cornerRadius: DS.Radius.m))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.m).strokeBorder(.separator, lineWidth: 0.5))
            HStack {
                Button("Copy") { model.deliver(entry, as: .copy, to: nil) }.buttonStyle(.borderedProminent)
                Button(entry.pinnedAt == nil ? "Pin" : "Unpin") { model.togglePin(entry) }
                Spacer()
                Button("Delete", role: .destructive) { model.delete(entry) }
            }
            .controlSize(.small)
        }
        .task(id: entry.id) {
            title = entry.title ?? ""
            text = entry.text ?? ""
        }
        .onChange(of: title) { _, _ in scheduleSave() }
        .onChange(of: text) { _, _ in scheduleSave() }
    }

    private func scheduleSave() {
        guard title != (entry.title ?? "") || text != (entry.text ?? "") else { return }
        saving?.cancel()
        let id = entry.id, title = title, text = text
        saving = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            model.updateSnippet(id, title: title, text: text)
        }
    }
}

/// The Clipboard page while history is off: what turning it on involves, and the switch.
struct ClipboardSetupPage: View {
    @AppStorage(ScreendropPreferences.clipboardHistoryEnabledKey) private var enabled = false
    @State private var access = NSPasteboard.general.accessBehavior
    @State private var canPaste = AXIsProcessTrusted()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                Text("Set Up Clipboard History").font(.system(size: 22, weight: .bold))
                Text("Sukusho keeps the images, text, links and files you copy, on this Mac, and pastes them again from ⌃⌘V. Nothing is recorded until you turn it on.")
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    step(done: true, "Private items are skipped",
                         "Concealed copies and anything from Keychain Access, Passwords or 1Password are never kept.")
                    Divider()
                    step(done: access == .alwaysAllow, "Clipboard access", accessDetail) {
                        if access != .alwaysAllow {
                            Button("Check Again") { access = NSPasteboard.general.accessBehavior }
                        }
                    }
                    Divider()
                    step(done: canPaste, "Paste into apps",
                         canPaste ? "Allowed. Auto-scroll uses the same permission."
                                  : "Optional. Without it, choosing an entry copies it and you press ⌘V yourself.") {
                        if !canPaste {
                            Button("Allow…") {
                                // kAXTrustedCheckOptionPrompt's value, spelled out, as the scrolling bar does.
                                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                                canPaste = AXIsProcessTrusted()
                            }
                        }
                    }
                    Divider()
                    step(done: false, "One history",
                         "Spotlight and other clipboard managers can keep their own history. Turning theirs off keeps one copy of what you copy.")
                }
                .background(.background, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(.separator, lineWidth: 0.5))
                HStack {
                    Button("Turn On Clipboard History") { enabled = true }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Change Shortcut…") { SettingsWindowController.show(tab: .shortcuts) }
                        .controlSize(.large)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(DS.Space.xxl * 1.5)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: recheck)
        // Back from System Settings with the permission granted, the page says so.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in recheck() }
    }

    private func recheck() {
        canPaste = AXIsProcessTrusted()
        access = NSPasteboard.general.accessBehavior
    }

    private var accessDetail: String {
        switch access {
        case .alwaysAllow: "Allowed: macOS lets Sukusho read what other apps copy."
        case .alwaysDeny: "Denied in Privacy & Security. History stays empty until it's allowed there."
        default: "macOS may ask whether Sukusho can read what other apps copy. Choose Always Allow; with Ask, every copy asks again."
        }
    }

    private func step(done: Bool, _ title: String, _ detail: String,
                      @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: DS.Space.l) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18)).foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.l)
            trailing()
        }
        .padding(DS.Space.l)
        .accessibilityElement(children: .combine)
    }
}
