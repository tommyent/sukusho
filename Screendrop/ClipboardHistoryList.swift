import Foundation

/// What the popup's and the Library page's type menu shows.
nonisolated enum ClipboardFilter: String, CaseIterable, Identifiable, Sendable {
    case all, images, text, links, colors, files, snippets

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All Types"
        case .images: "Images"
        case .text: "Text"
        case .links: "Links"
        case .colors: "Colours"
        case .files: "Files"
        case .snippets: "Snippets"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.stack"
        case .images: "photo"
        case .text: "text.alignleft"
        case .links: "link"
        case .colors: "paintpalette"
        case .files: "doc"
        case .snippets: "text.badge.star"
        }
    }
}

/// Sorting, grouping, naming and searching entries, kept apart from AppKit
/// so tests can check them.
nonisolated enum ClipboardList {
    struct Section: Identifiable, Equatable, Sendable {
        let title: String
        let entries: [ClipboardEntry]
        var id: String { title }
    }

    static func textForm(of entry: ClipboardEntry) -> ClipboardTextForm? {
        entry.kind == .text ? ClipboardCapturePolicy.textForm(entry.text ?? "") : nil
    }

    static func matches(_ entry: ClipboardEntry, filter: ClipboardFilter) -> Bool {
        switch filter {
        case .all: entry.kind != .snippet
        case .images: entry.kind == .image
        case .text: textForm(of: entry) == .plain
        case .links: textForm(of: entry) == .link
        case .colors: if case .color = textForm(of: entry) { true } else { false }
        case .files: entry.kind == .files
        case .snippets: entry.kind == .snippet
        }
    }

    /// The Library's own search rules, `app:` included.
    static func matches(_ entry: ClipboardEntry, query: CaptureLibraryQuery, appName: String?) -> Bool {
        guard !query.isEmpty else { return true }
        let source = entry.sourceBundleID.map { CaptureSource(bundleIdentifier: $0, appName: appName ?? $0) }
        return query.matches(fields: [title(of: entry), entry.text ?? "", appName ?? ""], foldedText: nil, source: source)
    }

    /// Pinned first, in the order they were pinned; then Today, Yesterday and
    /// Earlier, newest first. Snippets have their own list.
    static func sections(
        _ entries: [ClipboardEntry],
        filter: ClipboardFilter,
        query: CaptureLibraryQuery,
        appName: (String?) -> String? = { _ in nil },
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [Section] {
        let shown = entries.filter { matches($0, filter: filter) && matches($0, query: query, appName: appName($0.sourceBundleID)) }
        let pinned = shown.filter { $0.pinnedAt != nil }.sorted { $0.pinnedAt! > $1.pinnedAt! }
        let rest = shown.filter { $0.pinnedAt == nil }.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
        var sections = pinned.isEmpty ? [] : [Section(title: "Pinned", entries: pinned)]
        if filter == .snippets {
            if !rest.isEmpty { sections.append(Section(title: "Snippets", entries: rest.sorted { title(of: $0) < title(of: $1) })) }
            return sections
        }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let groups: [(String, (Date) -> Bool)] = [
            ("Today", { $0 >= today }),
            ("Yesterday", { $0 >= yesterday && $0 < today }),
            ("Earlier", { $0 < yesterday }),
        ]
        for (name, contains) in groups {
            let group = rest.filter { contains($0.lastCopiedAt) }
            if !group.isEmpty { sections.append(Section(title: name, entries: group)) }
        }
        return sections
    }

    /// One line for the list: "Image (2880×1800)", a colour's hex, a text's
    /// first line, file names, or a snippet's name.
    static func title(of entry: ClipboardEntry) -> String {
        switch entry.kind {
        case .image:
            return entry.pixelWidth > 0 ? "Image (\(entry.pixelWidth)×\(entry.pixelHeight))" : "Image"
        case .files:
            let names = (entry.text ?? "").split(separator: "\n").map { ($0 as NSString).lastPathComponent }
            return names.count > 3 ? "\(names.count) files" : names.joined(separator: ", ")
        case .snippet:
            return entry.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled Snippet"
        case .text:
            if case .color(let hex) = textForm(of: entry) { return hex }
            let line = (entry.text ?? "").split(whereSeparator: \.isNewline)
                .first { !$0.allSatisfy(\.isWhitespace) }.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return String(line.prefix(300))
        }
    }

    /// The Information block's "Content type".
    static func typeName(of entry: ClipboardEntry) -> String {
        switch entry.kind {
        case .image:
            let ext = (entry.imageURL?.pathExtension ?? entry.libraryPath.map { ($0 as NSString).pathExtension } ?? "").uppercased()
            return ext.isEmpty ? "Image" : "\(ext == "JPG" ? "JPEG" : ext) image"
        case .files:
            let count = (entry.text ?? "").split(separator: "\n").count
            return count == 1 ? "File" : "\(count) files"
        case .snippet:
            return "Snippet"
        case .text:
            switch textForm(of: entry) {
            case .link: return "Link"
            case .color: return "Colour"
            default: return "Text"
            }
        }
    }
}
