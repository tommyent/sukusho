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
enum LibrarySavedCard: Identifiable {
    case capture(CaptureLibraryItem)
    case clip(ClipboardEntry)

    var id: String {
        switch self {
        case .capture(let item): "capture:\(item.id)"
        case .clip(let entry): "clip:\(entry.id)"
        }
    }

    var clipEntry: ClipboardEntry? {
        if case .clip(let entry) = self { return entry }
        return nil
    }

    var captureItem: CaptureLibraryItem? {
        if case .capture(let item) = self { return item }
        return nil
    }

    var clipID: String? { clipEntry?.id }
    var captureID: String? { captureItem?.id }

    var previewURLs: [URL] {
        switch self {
        case .capture(let item): [item.fileURL]
        case .clip(let entry): ClipboardHistoryModel.shared.quickLookURLs(for: entry)
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
        let clips = filter == .all || filter == .clips ? clips.filter { $0.isArchived } : []
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

    /// What the page shows, and the status bar counts: saved captures the search finds, and saved clips, as the
    /// Clipboard page's Saved section lists them.
    var cards: [LibrarySavedCard] {
        let library = CaptureLibraryModel.shared
        let clips = ClipboardHistoryModel.shared.sections(filter: .saved, query: library.searchText)
            .first { $0.title == "Saved" }?.entries ?? []
        return LibrarySavedCard.cards(captures: library.visibleItems, clips: clips, filter: filter)
    }
}

struct LibrarySavedPage: View {
    let cardWidth: CGFloat
    let layout: CaptureLibraryLayout
    @State private var saved = LibrarySavedModel.shared
    @State private var library = CaptureLibraryModel.shared
    @State private var clipboard = ClipboardHistoryModel.shared
    @State private var history = ScreenshotHistoryStore.shared
    var body: some View {
        let cards = saved.cards
        VStack(spacing: 0) {
            // In a sideways scroll, as the Clipboard page's chips are, so they never set the column's minimum width.
            ScrollView(.horizontal, showsIndicators: false) { filterChips }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(LibrarySecondaryBarSurface())
            // The marks file can't be fully read: Saved shows what could be read and won't change it (Astra M1).
            // One line, the full reason in its help tag. Sized to its text (fixedSize(vertical:)), the page asked for
            // more height than the window and the Library slid up out of it (Astra F1); wrapped, its height followed
            // the width, so resizing changed the split view's minimum size inside AppKit's constraint pass, which
            // looped until it crashed (VM, 2026-11-17).
            if let problem = history.savedMarksProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.TypeScale.label)
                    .symbolRenderingMode(.multicolor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .help(problem)
                    .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.s)
                    .background(.bar)
                    .overlay(alignment: .bottom) { Divider() }
            }
            if cards.isEmpty {
                emptyPage.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LibraryClipCollection(cards: cards, cardWidth: cardWidth, layout: layout, sections: [], isSavedPage: true)
            }
        }
        .onChange(of: cards.map(\.id)) { _, _ in
            clipboard.librarySelectionIDs.formIntersection(cards.compactMap(\.clipID))
            library.selection.formIntersection(cards.compactMap(\.captureID))
        }
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
        if let title = ClipboardList.emptyResultsTitle(filter: saved.filter == .all ? nil : saved.filter.title, query: library.searchText) {
            LibraryEmptyResults(title: title) {
                saved.filter = .all
                library.searchText = ""
            }
        } else {
            ContentUnavailableView {
                Label("Nothing Saved Yet", systemImage: "star")
            } description: {
                Text("Choose Move to Saved on a capture or clipboard entry to keep it here.")
            }
            .workspaceTextPlate()
        }
    }
}
