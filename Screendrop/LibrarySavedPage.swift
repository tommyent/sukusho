import AppKit
import SwiftUI

/// What Library › Saved shows: All, or one kind.
nonisolated enum LibrarySavedFilter: String, CaseIterable, Identifiable, Sendable {
    case all, captures, clips, recordings
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All"
        case .captures: "Captures"
        case .clips: "Clips"
        case .recordings: "Recordings"
        }
    }
}

/// One saved thing: a capture (screenshot or recording) or a clip.
nonisolated enum LibrarySavedCard: Identifiable, Equatable {
    case capture(CaptureLibraryItem)
    case clip(ClipboardEntry)

    var id: String {
        switch self {
        case .capture(let item): "capture:\(item.id)"
        case .clip(let entry): "clip:\(entry.id)"
        }
    }

    var savedAt: Date {
        switch self {
        case .capture(let item): item.savedAt ?? item.createdAt
        case .clip(let entry): entry.pinnedAt ?? entry.lastCopiedAt
        }
    }

    /// Saved captures and clips in one list, most recently saved first. Captures are screenshots, as in the
    /// mockup's chips; Recordings are their own filter.
    static func cards(captures: [CaptureLibraryItem], clips: [ClipboardEntry], filter: LibrarySavedFilter) -> [Self] {
        let captures = captures.filter { $0.isSaved && (filter == .all || filter == (($0.isVideo) ? .recordings : .captures)) }
        let clips = filter == .all || filter == .clips ? clips.filter { $0.pinnedAt != nil && $0.kind != .snippet } : []
        return (captures.map(Self.capture) + clips.map(Self.clip)).sorted {
            $0.savedAt != $1.savedAt ? $0.savedAt > $1.savedAt : $0.id < $1.id
        }
    }
}

/// Library › Saved (option A, sd-ogtp.1.1): what the user chose to keep, captures and clips in one grid.
/// A capture's selection and inspector are the captures page's, a clip's the Clipboard page's, so every
/// action works as it does there.
@Observable final class LibrarySavedModel {
    static let shared = LibrarySavedModel()
    var isShown = false
    var filter: LibrarySavedFilter = .all
    private init() {}
}

struct LibrarySavedPage: View {
    let cardWidth: CGFloat
    @State private var saved = LibrarySavedModel.shared
    @State private var library = CaptureLibraryModel.shared
    @State private var clipboard = ClipboardHistoryModel.shared
    @State private var gridWidth: CGFloat = 0

    /// The clips the search finds, as the Clipboard page's Saved section lists them.
    private var clips: [ClipboardEntry] {
        clipboard.sections(filter: .all, query: library.searchText).first { $0.title == "Saved" }?.entries ?? []
    }

    var cards: [LibrarySavedCard] {
        LibrarySavedCard.cards(captures: library.visibleItems, clips: clips, filter: saved.filter)
    }

    var body: some View {
        let cards = cards
        let grid = LibraryGridMetrics(width: gridWidth, cardWidth: cardWidth)
        VStack(spacing: 0) {
            filterChips
                .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            if cards.isEmpty {
                emptyPage.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(grid.cellWidth), spacing: grid.spacing), count: grid.columns),
                              alignment: .leading, spacing: grid.lineSpacing) {
                        ForEach(cards) { card in
                            cardView(card, grid: grid).id(card.id)
                        }
                    }
                    .padding(.leading, grid.leftInset).padding(.trailing, grid.rightInset)
                    .padding(.vertical, LibraryGridMetrics.edgeMargin)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            }
        }
        // A filter or search that hides the selection clears it, so the inspector never shows what the page doesn't.
        .onChange(of: cards.map(\.id)) { _, shown in
            if let id = clipboard.librarySelection, !shown.contains("clip:\(id)") { clipboard.librarySelection = nil }
            library.selection.formIntersection(Set(shown.compactMap { $0.hasPrefix("capture:") ? String($0.dropFirst(8)) : nil }))
        }
    }

    @ViewBuilder private func cardView(_ card: LibrarySavedCard, grid: LibraryGridMetrics) -> some View {
        switch card {
        case .capture(let item):
            LibraryCellContent(item: item, selected: library.selection == [item.id])
                .frame(width: grid.cellWidth, height: grid.cardHeight)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { select(item); library.perform(.edit) }
                .onTapGesture { select(item) }
                .contextMenu {
                    ForEach([CaptureLibraryAction.preview, .edit, .copy, .reveal], id: \.self) { action in
                        Button(action.rawValue) { select(item); library.perform(action) }
                    }
                    Divider()
                    Button("Remove from Saved") { select(item); library.setSaved(false) }
                }
        case .clip(let entry):
            ClipboardCard(entry: entry, model: clipboard, faceHeight: grid.pictureHeight,
                          isSelected: clipboard.librarySelection == entry.id)
                .frame(width: grid.cellWidth)
                .simultaneousGesture(TapGesture().onEnded { library.selection = [] })
        }
    }

    private func select(_ item: CaptureLibraryItem) {
        clipboard.librarySelection = nil
        library.selection = [item.id]
    }

    private var filterChips: some View {
        HStack(spacing: DS.Space.m) {
            ForEach(LibrarySavedFilter.allCases) { item in
                Button { saved.filter = item } label: {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, DS.Space.ml).padding(.vertical, DS.Space.xs)
                        .background(saved.filter == item ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(saved.filter == item ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var emptyPage: some View {
        if !library.searchText.isEmpty {
            ContentUnavailableView.search(text: library.searchText).workspaceTextPlate()
        } else {
            ContentUnavailableView {
                Label("Nothing Saved Yet", systemImage: "star")
            } description: {
                Text("Save a capture or a copy with ★ to keep it here. Naming, tagging or sharing a capture saves it too. Saved items are never cleared out.")
            }
            .workspaceTextPlate()
        }
    }
}
