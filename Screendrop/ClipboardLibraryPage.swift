import AppKit
import SwiftUI

/// The Library's Clipboard pages: History, Snippets, and the setup page while history is off.
struct ClipboardLibraryPage: View {
    @Bindable var model: ClipboardHistoryModel
    /// The status bar's card-size slider, shared with the captures and Cloud grids.
    let cardWidth: CGFloat
    @AppStorage(ScreendropPreferences.clipboardHistoryEnabledKey) private var enabled = false
    @State private var library = CaptureLibraryModel.shared

    var body: some View {
        if !enabled {
            ClipboardSetupPage()
        } else if !model.hasLoaded {
            ProgressView("Loading Clipboard…").workspaceTextPlate().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let sections = model.librarySections(query: library.searchText)
            VStack(spacing: 0) {
                // On a bar of its own, as the Cloud page's rows are, so the grid scrolls under it, never over it.
                Group { if model.showsSnippets { snippetBar } else { filterBar } }
                    .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.m)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                    .overlay(alignment: .bottom) { Divider() }
                if sections.isEmpty {
                    emptyPage.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DS.Space.l, pinnedViews: []) {
                            ForEach(sections) { section in
                                // A capsule as wide as its words: the page plate is 520 pt wide and drawn past its
                                // text, which put a bar over the filters and past the grid (owner, 2026-11-16).
                                Text(section.title).font(DS.TypeScale.labelSemibold).foregroundStyle(.secondary)
                                    .padding(.horizontal, DS.Space.ml).padding(.vertical, 2)
                                    .workspaceTextPlate(capsule: true)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: DS.Space.l)],
                                          alignment: .leading, spacing: DS.Space.l) {
                                    ForEach(section.entries) { entry in
                                        // The captures grid's proportions: a 16:10 picture over the labels.
                                        ClipboardCard(entry: entry, model: model, faceHeight: (cardWidth * 0.625).rounded(.down),
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
    }

    private var filterBar: some View {
        HStack(spacing: DS.Space.m) {
            ForEach(ClipboardFilter.allCases.filter { $0 != .snippets }) { item in
                Button { model.libraryFilter = item } label: {
                    Label(item == .all ? "All" : item.title, systemImage: item.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, DS.Space.ml).padding(.vertical, DS.Space.xs)
                        .background(model.libraryFilter == item ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.libraryFilter == item ? .isSelected : [])
            }
            Spacer()
        }
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
    let faceHeight: CGFloat
    let isSelected: Bool
    @State private var isHovering = false

    /// Built like a capture card (LibraryCellContent): a solid backing in the chrome color, the image edge to
    /// edge at the top, the same border and selection ring. Without the backing, the workspace wallpaper
    /// showed through the cards (owner, 2026-11-16).
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            face
                .frame(maxWidth: .infinity)
                .frame(height: faceHeight)
                .clipShape(libraryCardImageShape)
                .overlay { libraryCardImageShape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
                .overlay(alignment: .bottomLeading) {
                    if entry.libraryPath != nil { Text("In Library").cardPill().padding(6) }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(ClipboardList.title(of: entry)).font(DS.TypeScale.labelMedium).lineLimit(1)
                HStack(spacing: DS.Space.xs) {
                    if let icon = model.appIcon(entry.sourceBundleID) { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
                    Text([model.appName(entry.sourceBundleID), entry.kind == .snippet ? nil : ClipboardInfo.when(entry.lastCopiedAt)]
                        .compactMap { $0 }.joined(separator: " · "))
                    if entry.pinnedAt != nil { Image(systemName: "pin.fill").font(.system(size: 9)) }
                }
                .font(DS.TypeScale.label).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
        .background(Color.primary.opacity(isSelected ? 0.075 : isHovering ? 0.035 : 0.012),
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .background(WorkspaceChrome.background, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay { LibraryCardBorder(selected: isSelected) }
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.deliver(entry, as: .copy, to: nil) }
        .onTapGesture { model.librarySelection = entry.id }
        .contextMenu { ClipboardEntryMenu(entry: entry, model: model) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Copy") { model.deliver(entry, as: .copy, to: nil) }
    }

    /// A tall image's long side, decoded so its width still fills a card sharply.
    private static func tallPixelSize(_ entry: ClipboardEntry) -> Int {
        min(8192, 640 * entry.pixelHeight / max(entry.pixelWidth, 1))
    }

    @ViewBuilder private var face: some View {
        switch entry.kind {
        case .image:
            if let url = entry.imageFileURL {
                // Whole, as capture cards show an image: filling cropped the sides off text (owner, 2026-11-16).
                // A much taller one shows its top at full width instead of a thin strip.
                let tall = TallCapture.isTall(width: entry.pixelWidth, height: entry.pixelHeight)
                GeometryReader { geometry in
                    ClipboardThumbnail(url: url, maxPixelSize: tall ? Self.tallPixelSize(entry) : 640,
                                       contentMode: tall ? .fill : .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: tall ? .top : .center)
                        .clipped()
                }
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
            }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                Text("Set Up Clipboard History").font(.system(size: 22, weight: .bold))
                Text(ClipboardSetupSteps.intro).foregroundStyle(.secondary)
                ClipboardSetupSteps()
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
    }
}

/// What turning history on involves, on the Library's setup page and in the sheet Settings shows
/// when history is turned on there.
struct ClipboardSetupSteps: View {
    @State private var access = NSPasteboard.general.accessBehavior
    @State private var canPaste = AXIsProcessTrusted()

    static var intro: String {
        let shortcut = CaptureHotkeyPreferences.shortcut(for: .clipboardHistory)?.displayTokens.joined() ?? "its shortcut"
        return "Sukusho keeps the images, text, links and files you copy, on this Mac, and pastes them again from \(shortcut). Nothing is recorded until you turn it on."
    }

    var body: some View {
        VStack(spacing: 0) {
            step(done: true, "Private items are skipped",
                 "Concealed copies and copies from password apps are never kept. Settings › Clipboard lists the apps to ignore.")
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
        .onAppear(perform: recheck)
        // Back from System Settings with the permission granted, the steps say so.
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
