import AppKit
import SwiftUI

/// The Clipboard, Snippets and mixed Saved page share the captures grid's responder and selection.
struct LibraryClipCollection: View {
    let cards: [LibrarySavedCard]
    let cardWidth: CGFloat
    let layout: CaptureLibraryLayout
    let sections: [LibraryCollectionSection]
    let isSavedPage: Bool
    @State private var clipboard = ClipboardHistoryModel.shared
    @State private var library = CaptureLibraryModel.shared

    private var selection: Binding<Set<String>> {
        Binding {
            var ids = Set(clipboard.librarySelectionIDs.map { "clip:\($0)" })
            if isSavedPage { ids.formUnion(library.selection.map { "capture:\($0)" }) }
            return ids
        } set: { ids in
            let chosen = LibraryDisplayOrder.selected(cards, ids: ids)
            clipboard.librarySelectionIDs = Set(chosen.compactMap(\.clipID))
            if isSavedPage { library.selection = Set(chosen.compactMap(\.captureID)) }
        }
    }

    private var chosen: [LibrarySavedCard] {
        let ids = selection.wrappedValue
        return LibraryDisplayOrder.selected(cards, ids: ids)
    }

    var body: some View {
        var revision = Hasher()
        revision.combine(clipboard.contentRevision)
        revision.combine(library.contentRevision)
        revision.combine(cards.map(\.id))
        return CaptureLibraryCollection(items: cards, revision: revision.finalize(), layout: layout, cardWidth: cardWidth,
            selection: selection, isBusy: library.isBusy,
            accessibilityLabel: isSavedPage ? "Saved" : clipboard.showsSnippets ? "Snippets" : "Clipboard",
            sections: sections, cell: { card, selected, titleFrame in
                switch card {
                case .capture(let item):
                    AnyView(LibraryCellContent(item: item, selected: selected, layout: layout, onTitleFrame: titleFrame))
                case .clip(let entry):
                    AnyView(clipView(entry, selected: selected))
                }
            }, menu: { _ in menu() }, backgroundMenu: {
                [LibraryMenuItem(title: "Refresh") {
                    clipboard.refresh()
                    if isSavedPage { ScreenshotHistoryStore.shared.reload(); library.refresh() }
                }]
            }, onReturn: {
                if let entry = chosen.first?.clipEntry, chosen.count == 1 {
                    perform(entry.kind == .snippet ? .rename : .edit)
                } else {
                    perform(chosen.contains { $0.clipID != nil } ? .copy : .rename)
                }
            }, onAction: perform)
            .onChange(of: selection.wrappedValue) { _, _ in
                if QuickLookPreviewPresenter.followsLibrary { QuickLookPreviewPresenter.follow(urls: chosen.flatMap(\.previewURLs)) }
            }
    }

    @ViewBuilder private func clipView(_ entry: ClipboardEntry, selected: Bool) -> some View {
        if layout == .list {
            ClipboardListRow(entry: entry, model: clipboard, isSelected: selected)
        } else {
            GeometryReader { geometry in
                ClipboardCard(entry: entry, model: clipboard,
                              faceHeight: max(1, geometry.size.height - LibraryGridMetrics.pictureInset - LibraryGridMetrics.captionHeight),
                              isSelected: selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func perform(_ action: CaptureLibraryAction) {
        let selected = chosen
        guard !selected.isEmpty else { return }
        switch action {
        case .preview:
            if !QuickLookPreviewPresenter.isShown { ClipboardHistoryModel.clearQuickLookFiles() }
            QuickLookPreviewPresenter.toggleLibrarySelection(selected.flatMap(\.previewURLs))
        case .trash:
            library.deleteSelection(selected)
        case .edit:
            guard selected.count == 1 else { return }
            switch selected[0] {
            case .clip(let entry):
                if entry.kind == .image { clipboard.openInEditor(entry) }
                else { library.copySelection(selected) }
            case .capture: library.perform(.edit)
            }
        case .rename:
            if selected.count == 1, let entry = selected[0].clipEntry, entry.kind == .snippet {
                clipboard.snippetAwaitingName = entry.id
            } else if selected.allSatisfy({ $0.captureID != nil }) {
                library.perform(.rename)
            }
        case .share: library.shareSelection(selected)
        case .export: library.export(selected)
        case .copy, .copyOriginal:
            library.copySelection(selected, original: action == .copyOriginal)
        default:
            if selected.allSatisfy({ $0.captureID != nil }) { library.perform(action) }
        }
    }

    private func menu() -> [LibraryMenuItem] {
        let selected = chosen
        if !selected.isEmpty, selected.allSatisfy({ $0.captureID != nil }) {
            return library.menuItems(selected: selected.count)
        }
        var actions: Set<CaptureLibraryAction> = [.preview, .copy, .export, .share]
        if selected.count == 1, selected[0].clipEntry?.kind == .image { actions.insert(.edit) }
        if selected.count == 1, selected[0].clipEntry?.kind == .snippet { actions.insert(.rename) }
        var items = CaptureLibraryAction.menu(selected: selected.count, allowing: actions, perform: perform)
        if selected.count == 1, case .clip(let entry) = selected[0] {
            if entry.kind == .image {
                items += [LibraryMenuItem(title: "Optimize", startsGroup: true) { clipboard.optimize(entry) },
                          LibraryMenuItem(title: "Convert to WebP…") { clipboard.convert(entry, to: .webP) },
                          LibraryMenuItem(title: "Convert to JPEG…") { clipboard.convert(entry, to: .jpeg) }]
            }
            if entry.kind == .text {
                if let copy = items.firstIndex(where: { $0.title == CaptureLibraryAction.copy.rawValue }) {
                    items.insert(LibraryMenuItem(title: "Copy as Plain Text") { library.copySelection([.clip(entry)], plain: true) }, at: copy + 1)
                }
                items.append(LibraryMenuItem(title: "Save as Snippet") { clipboard.saveAsSnippet(entry) })
            }
            if entry.kind != .snippet, entry.pinnedAt == nil {
                items.append(LibraryMenuItem(title: "Move to Saved", startsGroup: true) { clipboard.moveToSaved(entry) })
            }
        }
        if CloudUploader.shared.isConfigured {
            items.append(LibraryMenuItem(title: "Share to Cloud…", isEnabled: CloudLibraryModel.shared.fileUploads == nil) {
                library.prepareClipUpload(selected)
            })
        }
        let links = selected.flatMap { $0.clipEntry?.cloudLinks ?? $0.captureItem?.cloudURL.map { [$0] } ?? [] }
        if !links.isEmpty {
            items.append(LibraryMenuItem(title: links.count == 1 ? "Copy Link" : "Copy Links") { CloudShareLinks.copy(links) })
        }
        items.append(LibraryMenuItem(title: "Delete…", startsGroup: true) { perform(.trash) })
        return items
    }
}
