import Foundation

/// What the popup's and the Library page's type menu shows.
nonisolated enum ClipboardFilter: String, CaseIterable, Identifiable, Sendable {
    case all, images, text, links, colors, files, snippets, saved

    static let types = allCases.filter { $0 != .saved }
    var typeMenuTitle: String { self == .saved ? Self.all.title : title }

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All Types"
        case .images: "Images"
        case .text: "Text"
        case .links: "Links"
        case .colors: "Colors"
        case .files: "Files"
        case .saved: "Saved"
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
        case .saved: "star"
        case .snippets: "text.badge.star"
        }
    }
}

/// Sorting, grouping, naming and searching entries, kept apart from AppKit
/// so tests can check them.
nonisolated enum ClipboardList {
    static func emptyResultsTitle(filter: String?, query: String) -> String? {
        if !query.isEmpty { return "No matches for “\(query)”" }
        return filter.map { "No \($0.lowercased())" }
    }

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
        case .saved: entry.isArchived
        case .snippets: entry.kind == .snippet
        }
    }

    /// The entry `step` places from `selection` in `ids`, kept inside the list; the first one when nothing is
    /// selected. Nil when there's nowhere to go, so the key goes on to whatever else wants it.
    static func move(from selection: String?, by step: Int, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let selection, let index = ids.firstIndex(of: selection) else { return ids[0] }
        let target = min(max(index + step, 0), ids.count - 1)
        return target == index ? nil : ids[target]
    }

    /// The Library's own search rules, `app:` included.
    static func matches(_ entry: ClipboardEntry, query: CaptureLibraryQuery, appName: String?) -> Bool {
        guard !query.isEmpty else { return true }
        let source = entry.sourceBundleID.map { CaptureSource(bundleIdentifier: $0, appName: appName ?? $0) }
        return query.matches(fields: [title(of: entry), entry.text ?? "", appName ?? "", entry.readText ?? "",
                                      entry.keywords.joined(separator: " "), entry.category ?? ""],
                             foldedText: nil, source: source)
    }

    static func sections(
        _ entries: [ClipboardEntry],
        filter: ClipboardFilter,
        query: CaptureLibraryQuery,
        includesSnippets: Bool = false,
        appName: (String?) -> String? = { _ in nil },
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [Section] {
        let shown = entries.filter { matches($0, filter: filter) && matches($0, query: query, appName: appName($0.sourceBundleID)) }
        let pinned = shown.filter { $0.isArchived }.sorted { $0.pinnedAt! > $1.pinnedAt! }
        let rest = shown.filter { !$0.isArchived }.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
        var sections = pinned.isEmpty ? [] : [Section(title: "Saved", entries: pinned)]
        if filter == .saved { return sections }
        if !includesSnippets { sections = [] }
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
        if includesSnippets, filter == .all {
            let snippets = entries.filter { $0.kind == .snippet && matches($0, query: query, appName: appName($0.sourceBundleID)) }
            if !snippets.isEmpty { sections.append(Section(title: "Snippets", entries: snippets.sorted { title(of: $0) < title(of: $1) })) }
        }
        return sections
    }

    static func numberedEntries(_ sections: [Section]) -> [ClipboardEntry] {
        Array(sections.lazy.flatMap(\.entries).prefix(10))
    }

    /// One line for the list: "Image (2880×1800)", a colour's hex, a text's
    /// first line, file names, or a snippet's name.
    static func title(of entry: ClipboardEntry) -> String {
        switch entry.kind {
        case .image:
            // The model's title, or the Library's name for a capture; plain without them.
            if let title = entry.modelTitle, !title.isEmpty { return title }
            return entry.pixelWidth > 0 ? "Image (\(entry.pixelWidth) × \(entry.pixelHeight))" : "Image"
        case .files:
            let names = (entry.text ?? "").split(separator: "\n").map { ($0 as NSString).lastPathComponent }
            return names.count > 3 ? "\(names.count) files" : names.joined(separator: ", ")
        case .snippet:
            // Unnamed, it's called by its first line, as a note is (Fable #10: a fresh one was literally "New Snippet").
            if let name = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
            let line = (entry.text ?? "").split(whereSeparator: \.isNewline)
                .first { !$0.allSatisfy(\.isWhitespace) }.map { $0.trimmingCharacters(in: .whitespaces) }
            return line.map { String($0.prefix(300)) } ?? "Untitled Snippet"
        case .text:
            if case .color(let hex) = textForm(of: entry) { return hex }
            let line = (entry.text ?? "").split(whereSeparator: \.isNewline)
                .first { !$0.allSatisfy(\.isWhitespace) }.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return String(line.prefix(300))
        }
    }

    static func fileTitle(of entry: ClipboardEntry) -> String {
        String(title(of: entry).prefix(60)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// Terminals and code editors: their text shows in a monospaced face.
    static let codeApps: Set<String> = [
        "com.superlogical.rex", "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.sublimetext.4", "dev.zed.Zed",
    ]

    /// Text from a code app, or text that reads as code wherever it came from: Fable's copies were credited to the
    /// app in front, so the source alone missed them (Fable #3).
    static func looksLikeCode(_ entry: ClipboardEntry) -> Bool {
        textForm(of: entry) == .plain && (entry.sourceBundleID.map(codeApps.contains) == true || isCodeLike(entry.text ?? ""))
    }

    /// At least half the lines carry code's own syntax. A keyword or a closing semicolon alone isn't enough: "let me know
    /// tomorrow", "return home before dinner" and "Please send the revised draft;" are prose (Astra R2).
    static func isCodeLike(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return false }
        if first.hasPrefix("#!/") || first.hasPrefix("#! /") { return true }
        if first.hasPrefix("{") || first.hasPrefix("["),
           (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil { return true }
        return lines.filter(isCodeLine).count * 2 >= lines.count
    }

    private static let codeKeywords = ["func ", "def ", "class ", "struct ", "enum ", "import ", "return ", "const ", "let ",
                                       "var ", "fn ", "#include", "public ", "private ", "if ", "for ", "while ", "function "]

    /// One line of code: a lone brace; an arrow, a comparison or another operator prose doesn't use; a keyword or a line
    /// end with brackets, an assignment or a brace near it; an assignment to a name; or a call. A line that starts like a
    /// sentence (a capital, then lowercase) needs one of the operators.
    static func isCodeLine(_ line: String) -> Bool {
        if ["{", "}", "};", "})", "]"].contains(line) { return true }
        let operators = ["->", "=>", "==", "!=", "&&", "||", "::", "+=", "-="]
        if operators.contains(where: line.contains) { return true }
        let first = line.prefix(2)
        if first.first?.isUppercase == true, first.last?.isLowercase == true { return false }
        let syntax = line.contains { "(){}[]=".contains($0) }
        if codeKeywords.contains(where: line.hasPrefix) { return syntax }
        if line.hasSuffix("{") || line.hasSuffix(";") || line.hasSuffix(")") { return syntax }
        return line.range(of: #"^[A-Za-z_$][\w.$]*(\[[^\]]*\])?\s*=\s*\S"#, options: .regularExpression) != nil
            || line.range(of: #"^[A-Za-z_$][\w.$]*\([^)]*\);?$"#, options: .regularExpression) != nil
    }

    /// A card's title line, or nil where the card's face already shows the text, so it isn't said twice (Fable #3).
    static func cardTitle(of entry: ClipboardEntry) -> String? {
        switch entry.kind {
        case .text:
            if case .color = textForm(of: entry) { return (entry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            return nil
        case .image:
            if let title = entry.modelTitle, !title.isEmpty { return title }
            return entry.pixelWidth > 0 ? "\(entry.pixelWidth) × \(entry.pixelHeight)" : "Image"
        case .files, .snippet:
            return title(of: entry)
        }
    }

    /// The small word in the corner of a card that shows its text: what kind of text it is.
    static func kindWord(of entry: ClipboardEntry) -> String? {
        switch textForm(of: entry) {
        case .plain: looksLikeCode(entry) ? "code" : "text"
        case .link: "link"
        default: nil
        }
    }

    /// The Information block's "Content type".
    static func typeName(of entry: ClipboardEntry) -> String {
        switch entry.kind {
        case .image:
            let ext = (entry.imageURL?.pathExtension ?? "").uppercased()
            return ext.isEmpty ? "Image" : "\(ext == "JPG" ? "JPEG" : ext) image"
        case .files:
            let count = (entry.text ?? "").split(separator: "\n").count
            return count == 1 ? "File" : "\(count) files"
        case .snippet:
            return "Snippet"
        case .text:
            switch textForm(of: entry) {
            case .link: return "Link"
            case .color: return "Color"
            default: return "Text"
            }
        }
    }
}

nonisolated struct LibraryDeletionPrompt {
    let captures: Int
    let entries: [ClipboardEntry]

    private var snippets: Int { entries.count { $0.kind == .snippet } }
    private var archived: Int { entries.count(where: \.isArchived) }
    private var history: Int { entries.count - snippets - archived }

    var action: String { entries.isEmpty ? "Move to Trash" : "Delete" }

    var title: String {
        if entries.isEmpty { return captures == 1 ? "Move capture to Trash?" : "Move \(captures) captures to Trash?" }
        if captures == 0 {
            if snippets == entries.count { return snippets == 1 ? "Delete this snippet?" : "Delete \(snippets) snippets?" }
            if archived == entries.count { return archived == 1 ? "Delete this clip from Saved?" : "Delete \(archived) clips from Saved?" }
            if history == entries.count { return history == 1 ? "Delete this clipboard entry?" : "Delete \(history) clipboard entries?" }
        }
        return "Delete \(captures + entries.count) selected items?"
    }

    var message: String {
        var parts: [String] = []
        if snippets > 0 { parts.append(snippets == 1 ? "The snippet will be permanently deleted from Snippets." : "The snippets will be permanently deleted from Snippets.") }
        if archived > 0 { parts.append(archived == 1 ? "The clip will be permanently deleted from Saved." : "The clips will be permanently deleted from Saved.") }
        if history > 0 { parts.append("Selected entries will be deleted from clipboard history.") }
        if captures > 0 { parts.append("Selected captures and their edits will move to Trash. Exported copies and cloud links will remain available.") }
        return parts.joined(separator: " ")
    }
}
