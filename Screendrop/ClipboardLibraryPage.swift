import AppKit
import SwiftUI

/// The Library's Clipboard pages: History, Snippets, and the setup page while history is off.
struct ClipboardLibraryPage: View {
    @Bindable var model: ClipboardHistoryModel
    /// The status bar's card-size slider, shared with the captures and Cloud grids.
    let cardWidth: CGFloat
    let layout: CaptureLibraryLayout
    @AppStorage(ScreendropPreferences.clipboardHistoryEnabledKey) private var enabled = false
    @State private var library = CaptureLibraryModel.shared
    var body: some View {
        if !enabled {
            ClipboardSetupPage()
        } else if !model.hasLoaded {
            ProgressView("Loading Clipboard…").workspaceTextPlate().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let sections = model.librarySections(query: library.searchText)
            // The captures grid's layout: the strip a fixed column count left on the right is shared out instead.
            let cards = sections.flatMap { $0.entries.map(LibrarySavedCard.clip) }
            VStack(spacing: 0) {
                // On a bar of its own, as the Cloud page's rows are, so the grid scrolls under it, never over it.
                HStack(spacing: DS.Space.m) {
                    Group { if model.showsSnippets { snippetBar } else { filterBar } }
                }
                    .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.m)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                    .overlay(alignment: .bottom) { Divider() }
                if sections.isEmpty {
                    emptyPage.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LibraryClipCollection(cards: cards, cardWidth: cardWidth, layout: layout,
                        sections: model.showsSnippets ? [] : sections.map { LibraryCollectionSection(title: $0.title, count: $0.entries.count) },
                        isSavedPage: false)
                }
            }
            .onChange(of: cards.map(\.id)) { _, _ in
                model.librarySelectionIDs.formIntersection(sections.flatMap { $0.entries.map(\.id) })
            }
        }
    }

    private var snippetBar: some View {
        HStack {
            Spacer()
            // With no snippets yet, the empty page's own New Snippet button is the one (Fable #10).
            if model.snippetCount > 0 {
                Button("New Snippet", systemImage: "plus") {
                    Task { await model.newSnippet() }
                }
                .controlSize(.small)
            }
        }
    }

    /// Whole chips on one line; when the window is too narrow for all six, the row scrolls sideways
    /// rather than breaking their names mid-word (Astra, 2026-11-16).
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) { filterChips }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private var filterChips: some View {
        HStack(spacing: DS.Space.m) {
            ForEach(ClipboardFilter.types.filter { $0 != .snippets }) { item in
                Button { model.libraryFilter = item } label: {
                    Label(item == .all ? "All" : item.title, systemImage: item.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, DS.Space.ml).padding(.vertical, DS.Space.xs)
                        .background(model.libraryFilter == item ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.libraryFilter == item ? .isSelected : [])
            }
        }
    }

    /// A search with no match says so, on Snippets too, rather than saying there are none (Astra, 2026-11-16).
    @ViewBuilder
    private var emptyPage: some View {
        if let title = ClipboardList.emptyResultsTitle(filter: model.showsSnippets || model.libraryFilter == .all ? nil : model.libraryFilter.title,
                                                      query: library.searchText) {
            LibraryEmptyResults(title: title) {
                library.searchText = ""
                model.libraryFilter = .all
            }
        } else if model.showsSnippets {
            ContentUnavailableView {
                Label("No Snippets", systemImage: "text.badge.star")
            } description: {
                if let shortcut = CaptureHotkeyPreferences.shortcut(for: .clipboardHistory) {
                    Text("Save text you paste often. Open the clipboard popup with \(shortcut.displayTokens.joined()) to paste a snippet.")
                } else {
                    Text("Save text you paste often. Paste a snippet from the clipboard popup like any copy.")
                }
            } actions: {
                Button("New Snippet") { Task { await model.newSnippet() } }
                    .buttonStyle(.borderedProminent)
            }
            .workspaceTextPlate()
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
struct ClipboardCard: View {
    let entry: ClipboardEntry
    let model: ClipboardHistoryModel
    let isSelected: Bool
    @Environment(\.selectLibraryCell) private var select
    @State private var isHovering = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        LibraryGridCard(marks: LibraryCardMarks(clip: entry, upload: CloudLibraryModel.shared.upload(for: entry.cloudLinks.first)),
                        cloudAction: { select(); CloudShareLinks.copy(entry.cloudLinks, feedback: CaptureLibraryModel.shared.actionFeedback) }) {
            face
        } caption: {
            LibraryGridCaption(date: entry.kind == .snippet ? entry.snippetEditedAt ?? entry.firstCopiedAt : entry.lastCopiedAt,
                               bundleID: entry.sourceBundleID, saveAction: entry.canMoveToSaved ? { model.moveToSaved([entry]) } : nil) {
                Text(ClipboardList.gridTitle(of: entry))
            }
        }
        .background(Color.primary.opacity(isSelected ? 0.075 : isHovering ? 0.035 : 0.012),
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .background(WorkspaceChrome.background, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay { LibraryCardBorder(selected: isSelected) }
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())

        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
        .accessibilityAction(named: "Copy") { select(); CaptureLibraryModel.shared.copySelection([.clip(entry)]) }
        .accessibilityAction(named: "Share") { select(); CaptureLibraryModel.shared.shareSelection([.clip(entry)]) }
        .accessibilityActions {
            if entry.canMoveToSaved { Button("Move to Saved") { model.moveToSaved([entry]) } }
            if !entry.cloudLinks.isEmpty {
                Button("Copy Cloud Link") { select(); CloudShareLinks.copy(entry.cloudLinks, feedback: CaptureLibraryModel.shared.actionFeedback) }
            }
        }
        .accessibilityAction(named: "Export") { select(); CaptureLibraryModel.shared.export([.clip(entry)]) }
        .accessibilityAction(named: "Quick Look") {
            let followed = QuickLookPreviewPresenter.followsLibrary && !isSelected
            select()
            if !followed { model.quickLook(entry) }
        }
    }

    /// A tall image's long side, decoded so its width still fills a card sharply.
    private static func tallPixelSize(_ entry: ClipboardEntry) -> Int {
        min(8192, 640 * entry.pixelHeight / max(entry.pixelWidth, 1))
    }

    @ViewBuilder private var face: some View {
        switch entry.kind {
        case .image:
            if let url = entry.imageURL {
                // Whole, as capture cards show an image: filling cropped the sides off text (owner, 2026-11-16).
                // A much taller one shows its top at full width instead of a thin strip.
                let tall = TallCapture.isTall(width: entry.pixelWidth, height: entry.pixelHeight)
                GeometryReader { geometry in
                    // A small image, such as an icon, shows at its own size rather than blown up and blurred.
                    let natural = CGSize(width: CGFloat(entry.pixelWidth) / displayScale, height: CGFloat(entry.pixelHeight) / displayScale)
                    let shrinksOnly = !tall && natural.width > 0 && natural.height > 0
                    ClipboardThumbnail(url: url, maxPixelSize: tall ? Self.tallPixelSize(entry) : 640,
                                       contentMode: tall ? .fill : .fit)
                        .id(CaptureLibraryModel.shared.contentRevision)
                        .frame(maxWidth: shrinksOnly ? min(geometry.size.width, natural.width) : .infinity,
                               maxHeight: shrinksOnly ? min(geometry.size.height, natural.height) : .infinity)
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
                    // Room for the kind word in the bottom corner, so it never sits over the last line (Astra R2).
                    .padding(.bottom, ClipboardList.kindWord(of: entry) == nil ? 0 : 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(.background)
            }
        }
    }
}

/// One copy as a row of the list view, as the popup lists them: its tile, what it is, and when (mockup 08 B).
struct ClipboardListRow: View {
    let entry: ClipboardEntry
    let model: ClipboardHistoryModel
    let isSelected: Bool
    @Environment(\.selectLibraryCell) private var select
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.Space.ml) {
            ClipboardRowTile(entry: entry, size: 24, imageURL: entry.imageURL)
                .id(CaptureLibraryModel.shared.contentRevision)
            Text(ClipboardList.cardTitle(of: entry) ?? ClipboardList.title(of: entry))
                .font(ClipboardList.looksLikeCode(entry) ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DS.Space.m)
            Text(entry.kind == .snippet ? (model.appName(entry.sourceBundleID) ?? "") : ClipboardInfo.shortWhen(entry.lastCopiedAt))
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: 34)
        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.22)) : isHovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }

        .help(model.appName(entry.sourceBundleID).map { "From \($0)" } ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
        .accessibilityAction(named: "Copy") { select(); CaptureLibraryModel.shared.copySelection([.clip(entry)]) }
        .accessibilityAction(named: "Share") { select(); CaptureLibraryModel.shared.shareSelection([.clip(entry)]) }
        .accessibilityAction(named: "Export") { select(); CaptureLibraryModel.shared.export([.clip(entry)]) }
        .accessibilityAction(named: "Quick Look") {
            let followed = QuickLookPreviewPresenter.followsLibrary && !isSelected
            select()
            if !followed { model.quickLook(entry) }
        }
    }
}

/// The same actions in a card's context menu and the inspector.
/// The inspector beside the Clipboard page: the preview and Information,
/// and for a snippet, its name and text to edit.
struct ClipboardLibraryInspector: View {
    @Bindable var model: ClipboardHistoryModel

    var body: some View {
        // History's selection doesn't show on Snippets, nor the other way round.
        if let entry = model.entry(model.librarySelection), (entry.kind == .snippet) == model.showsSnippets || LibrarySavedModel.shared.isShown {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    if entry.kind == .snippet {
                        SnippetEditor(entry: entry, model: model)
                    } else {
                        // Clicking the picture opens Quick Look, as in a capture's inspector.
                        Button { model.quickLook(entry) } label: {
                            ClipboardPreview(entry: entry, imageURL: entry.imageURL)
                                .id(CaptureLibraryModel.shared.contentRevision)
                                .frame(height: 220)
                        }
                            .buttonStyle(.plain)
                            .help("Quick Look")
                        HStack {
                            Button("Copy") { CaptureLibraryModel.shared.copySelection([.clip(entry)]) }.buttonStyle(.borderedProminent)
                            if entry.pinnedAt == nil {
                                Button("Move to Saved", systemImage: "star") { model.moveToSaved([entry]) }
                            } else {
                                Button("Delete…", systemImage: "trash") { CaptureLibraryModel.shared.deleteSelection([.clip(entry)]) }
                            }
                            if entry.kind == .image { Button("Edit") { model.openInEditor(entry) }.help("Open in the editor") }
                        }
                        .controlSize(.small)
                        if !entry.earlierVersions.isEmpty { ClipboardVersionList(entry: entry, model: model) }
                        ClipboardInfo(entry: entry, model: model)
                    }
                    if let message = model.feedback.message {
                        Label(message, systemImage: "checkmark.circle").font(DS.TypeScale.label).foregroundStyle(.secondary)
                    }
                }
                .padding(DS.Space.l)
            }
        } else {
            // The Library's own empty inspector, small, as on every other page. ContentUnavailableView drew a large
            // heading in a lighter band (Fable #8; on macOS 26 and on 27.2 alike).
            LibraryInspectorPlaceholder(
                symbol: model.showsSnippets ? "text.badge.star" : "doc.on.clipboard",
                title: model.showsSnippets ? "Snippet details" : "Copy details",
                message: model.showsSnippets ? "Select a snippet\nto edit it." : "Select a copy\nto see it here."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @FocusState private var textFocused: Bool
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            TextField("Name", text: $title).focused($nameFocused).textFieldStyle(.roundedBorder).font(DS.TypeScale.title)
            TextEditor(text: $text)
                .focused($textFocused)
                .font(.system(size: 13))
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(DS.Space.s)
                .background(.background, in: RoundedRectangle(cornerRadius: DS.Radius.m))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.m).strokeBorder(.separator, lineWidth: 0.5))
            HStack {
                Button("Copy") { CaptureLibraryModel.shared.copySelection([.clip(entry)]) }.buttonStyle(.borderedProminent)
                Spacer()
                Button("Delete", role: .destructive) { CaptureLibraryModel.shared.deleteSelection([.clip(entry)]) }
            }
            .controlSize(.small)
        }
        .task(id: entry.id) {
            title = entry.title ?? ""
            text = entry.text ?? ""
            // Just made with New Snippet: typing goes into its text, not to the Library (Astra R3).
            if model.snippetAwaitingFocus == entry.id {
                model.snippetAwaitingFocus = nil
                textFocused = true
            }
        }
        .onChange(of: model.snippetAwaitingName, initial: true) { _, id in
            guard id == entry.id else { return }
            nameFocused = true
            model.snippetAwaitingName = nil
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

/// A card's earlier versions, one click away: another app (such as Clop) put a re-encode back on the clipboard, which
/// became the newest version; the original is kept here with its own image and Library link (owner, 2026-11-16).
private struct ClipboardVersionList: View {
    let entry: ClipboardEntry
    let model: ClipboardHistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Versions").font(DS.TypeScale.labelSemibold).foregroundStyle(.secondary)
            Text(entry.isOptimizedHere
                 ? "Optimized here, with the same pixels. The smaller copy is shown and pasted; the original is kept."
                 : "Another app put a re-encoded copy back on the clipboard. The newest is shown and pasted; the earlier one is kept.")
                .font(DS.TypeScale.label).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(entry.earlierVersions.enumerated()), id: \.element.hash) { index, version in
                let earlier = model.entry(entry, at: version)
                HStack(spacing: DS.Space.m) {
                    Button { model.quickLook(earlier) } label: {
                        Group {
                            if let url = earlier.imageURL {
                                ClipboardThumbnail(url: url, maxPixelSize: 160, contentMode: .fit)
                            } else {
                                Image(systemName: "photo").foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 56, height: 40)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("Quick Look")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(index == entry.earlierVersions.count - 1 ? "Original" : "Earlier version")
                            .font(DS.TypeScale.labelMedium)
                        Text([ByteCountFormatter.string(fromByteCount: Int64(version.byteSize), countStyle: .file),
                              ClipboardInfo.when(version.copiedAt)]
                            .joined(separator: " · "))
                            .font(DS.TypeScale.label).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button("Copy") { CaptureLibraryModel.shared.copySelection([.clip(earlier)]) }.controlSize(.small)
                }
            }
        }
    }
}

struct LibraryEmptyResults: View {
    let title: String
    let clear: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "line.3.horizontal.decrease")
        } actions: {
            Button("Clear Filters", action: clear)
        }
        .workspaceTextPlate()
    }
}
