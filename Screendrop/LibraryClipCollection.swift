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
                    AnyView(LibraryCellContent(item: item, selected: selected, onTitleFrame: titleFrame))
                case .clip(let entry):
                    AnyView(clipView(entry, selected: selected))
                }
            }, menu: { _ in menu() }, onAction: perform)
            .onChange(of: selection.wrappedValue) { _, _ in
                if QuickLookPreviewPresenter.followsLibrary { QuickLookPreviewPresenter.follow(urls: chosen.flatMap(\.previewURLs)) }
            }
    }

    @ViewBuilder private func clipView(_ entry: ClipboardEntry, selected: Bool) -> some View {
        let pick = { selection.wrappedValue = ["clip:\(entry.id)"] }
        if layout == .list {
            ClipboardListRow(entry: entry, model: clipboard, isSelected: selected, select: pick)
        } else {
            GeometryReader { geometry in
                ClipboardCard(entry: entry, model: clipboard,
                              faceHeight: max(1, geometry.size.height - LibraryGridMetrics.pictureInset - LibraryGridMetrics.captionHeight),
                              isSelected: selected, select: pick)
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
            case .clip(let entry): clipboard.openLibraryEntry(entry)
            case .capture: library.perform(.edit)
            }
        case .copy, .copyOriginal:
            library.copySelection(selected, original: action == .copyOriginal)
        default:
            if selected.allSatisfy({ $0.captureID != nil }) { library.perform(action) }
        }
    }

    private func menu() -> [LibraryMenuItem] {
        let selected = chosen
        if selected.count == 1, selected[0].captureID != nil {
            let actions: [CaptureLibraryAction] = [.preview, .edit, .copy, .reveal]
            return actions.map { action in LibraryMenuItem(title: action.rawValue) { perform(action) } }
                + [LibraryMenuItem(title: "Remove from Saved", startsGroup: true) { library.setSaved(false) }]
        }
        var items = [LibraryMenuItem(title: "Copy") { perform(.copy) }, LibraryMenuItem(title: "Quick Look") { perform(.preview) }]
        if selected.count == 1, case .clip(let entry) = selected[0] {
            if entry.kind == .image {
                items += [LibraryMenuItem(title: "Open in Editor") { clipboard.openInEditor(entry) },
                          LibraryMenuItem(title: "Optimize", startsGroup: true) { clipboard.optimize(entry) },
                          LibraryMenuItem(title: "Convert to WebP…") { clipboard.convert(entry, to: .webP) },
                          LibraryMenuItem(title: "Convert to JPEG…") { clipboard.convert(entry, to: .jpeg) }]
            }
            if entry.kind == .text {
                items.append(LibraryMenuItem(title: "Copy as Plain Text") { clipboard.deliver(entry, as: .copyPlain, to: nil) })
                items.append(LibraryMenuItem(title: "Save as Snippet") { clipboard.saveAsSnippet(entry) })
            }
            items.append(LibraryMenuItem(title: entry.pinnedAt == nil ? "Save" : "Remove from Saved", startsGroup: true) {
                clipboard.toggleSaved(entry)
            })
        }
        items.append(LibraryMenuItem(title: selected.contains { $0.captureID != nil } ? "Delete…" : "Delete", startsGroup: true) { perform(.trash) })
        return items
    }
}
