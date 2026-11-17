import AppKit
import SwiftUI

extension ClipboardEntry {
    /// The image's file: the one history kept, or the Sukusho capture in the Library.
    var imageFileURL: URL? { imageURL ?? libraryPath.map { URL(fileURLWithPath: $0) } }
    var filePaths: [String] { kind == .files ? (text ?? "").split(separator: "\n").map(String.init) : [] }
}

extension Color {
    /// #RGB, #RRGGBB or #RRGGBBAA, as `ClipboardCapturePolicy.hexColor` gives them.
    init?(clipboardHex hex: String) {
        var digits = String(hex.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255, opacity: hasAlpha ? Double(value & 0xFF) / 255 : 1)
    }
}

/// A clipboard image, decoded at the size it's drawn through the Library's bounded thumbnail cache.
struct ClipboardThumbnail: View {
    let url: URL
    var maxPixelSize = 128
    var contentMode: ContentMode = .fill
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .task(id: url) { image = await CaptureLibraryThumbnails.shared.image(at: url, maxPixelSize: maxPixelSize) }
    }
}

/// The leading tile of a row: a thumbnail, a colour swatch, or the kind's symbol.
struct ClipboardRowTile: View {
    let entry: ClipboardEntry
    var size: CGFloat = 24

    var body: some View {
        Group {
            if entry.kind == .image, let url = entry.imageFileURL {
                ClipboardThumbnail(url: url, maxPixelSize: Int(size * 2))
            } else if case .color(let hex) = ClipboardList.textForm(of: entry), let color = Color(clipboardHex: hex) {
                color.overlay(RoundedRectangle(cornerRadius: DS.Radius.s).strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
            } else if entry.kind == .files, let path = entry.filePaths.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s))
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch entry.kind {
        case .snippet: "text.badge.star"
        case .files: "doc"
        case .image: "photo"
        case .text:
            ClipboardList.textForm(of: entry) == .link ? "link"
                : ClipboardList.looksLikeCode(entry) ? "chevron.left.forwardslash.chevron.right" : "text.alignleft"
        }
    }
}

/// The big preview: the picture, a colour's swatch, the text, a link or the files.
struct ClipboardPreview: View {
    let entry: ClipboardEntry

    var body: some View {
        switch entry.kind {
        case .image:
            if let url = entry.imageFileURL {
                ClipboardThumbnail(url: url, maxPixelSize: 1080, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.l))
                    .shadow(color: .black.opacity(0.18), radius: 9, y: 4)
                    .padding(DS.Space.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(ClipboardList.title(of: entry))
            }
        case .files:
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    ForEach(entry.filePaths, id: \.self) { path in
                        HStack(spacing: DS.Space.m) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent).font(DS.TypeScale.body)
                                Text((path as NSString).deletingLastPathComponent).font(DS.TypeScale.label).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.xl)
            }
        case .text, .snippet:
            if case .color(let hex) = ClipboardList.textForm(of: entry), let color = Color(clipboardHex: hex) {
                VStack(spacing: DS.Space.l) {
                    RoundedRectangle(cornerRadius: 30).fill(color).frame(width: 132, height: 132)
                        .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    Text(hex).font(.system(size: 19, weight: .semibold)).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(entry.text ?? "")
                        .font(ClipboardList.looksLikeCode(entry) ? .system(size: 12.5, design: .monospaced) : DS.TypeScale.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.l)
                }
                .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: DS.Radius.l))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.l).strokeBorder(.separator, lineWidth: 0.5))
                .padding(DS.Space.l)
            }
        }
    }
}

/// The "Information" block under the preview.
struct ClipboardInfo: View {
    let entry: ClipboardEntry
    let model: ClipboardHistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Information").font(DS.TypeScale.labelSemibold).foregroundStyle(.secondary).padding(.bottom, DS.Space.xs)
            if entry.kind == .snippet {
                row("Name") { Text(ClipboardList.title(of: entry)) }
                textRows
                row("Edited") { Text(Self.when(entry.lastCopiedAt)) }
            } else {
                if let source = model.appName(entry.sourceBundleID) {
                    row("Source") {
                        HStack(spacing: DS.Space.s) {
                            if let icon = model.appIcon(entry.sourceBundleID) {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                            }
                            Text(source)
                            if entry.isRemote { badge("Another device", .gray) }
                        }
                    }
                }
                row("Content type") { Text(ClipboardList.typeName(of: entry)) }
                if let category = entry.category { row("Category") { Text(category) } }
                if !entry.keywords.isEmpty {
                    row("Keywords") { Text(entry.keywords.joined(separator: ", ")).help(entry.keywords.joined(separator: ", ")) }
                }
                fileRows
                if entry.kind == .image, entry.pixelWidth > 0 {
                    row("Dimensions") { Text("\(entry.pixelWidth) × \(entry.pixelHeight)") }
                }
                switch ClipboardList.textForm(of: entry) {
                case .link: if let host = URL(string: entry.text ?? "")?.host() { row("Domain") { Text(host) } }
                case .color(let hex): colorRows(hex)
                case .plain: textRows
                case nil: EmptyView()
                }
                row("Size") { Text(entry.shownByteSize.formatted(.byteCount(style: .file))) }
                row("Times copied") { Text(entry.timesCopied, format: .number) }
                row("First copied") { Text(Self.when(entry.firstCopiedAt)) }
                if entry.lastCopiedAt != entry.firstCopiedAt { row("Last copied") { Text(Self.when(entry.lastCopiedAt)) } }
            }
        }
        .font(.system(size: 12.5))
    }

    /// Where an image's capture or the copied files are: the file name, its folder and a way to Finder.
    @ViewBuilder private var fileRows: some View {
        let paths = entry.kind == .files ? entry.filePaths : entry.libraryPath.map { [$0] } ?? []
        if let first = paths.first {
            row(paths.count == 1 ? "File" : "Files") {
                HStack(spacing: DS.Space.xs) {
                    Text(paths.count == 1 ? (first as NSString).lastPathComponent : "\(paths.count) files")
                        .truncationMode(.middle)
                        .help(paths.joined(separator: "\n"))
                    Button("Show in Finder", systemImage: "arrow.right.circle.fill") {
                        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Show in Finder")
                }
            }
            row("Where") {
                Text(((first as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                    .truncationMode(.head)
                    .help((first as NSString).deletingLastPathComponent)
            }
        }
    }

    @ViewBuilder private var textRows: some View {
        let text = entry.text ?? ""
        row("Characters") { Text(text.count, format: .number) }
        row("Words") { Text(text.split(whereSeparator: { $0.isWhitespace }).count, format: .number) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        if lines > 1 { row("Lines") { Text(lines, format: .number) } }
    }

    @ViewBuilder private func colorRows(_ hex: String) -> some View {
        if let color = Color(clipboardHex: hex).map(NSColor.init)?.usingColorSpace(.sRGB) {
            let rgb = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
            row("RGB") { Text(rgb.map(String.init).joined(separator: ", ")).monospacedDigit() }
            row("HSB") {
                Text("\(Int((color.hueComponent * 360).rounded()))°, \(Int((color.saturationComponent * 100).rounded()))%, \(Int((color.brightnessComponent * 100).rounded()))%")
                    .monospacedDigit()
            }
        }
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(spacing: 0) {
            Divider().opacity(0.6)
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: DS.Space.l)
                value().lineLimit(1)
            }
            .frame(minHeight: 26)
        }
        .accessibilityElement(children: .combine)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
    }

    /// A card's time: "14:38" today, "Yesterday", else the date. The page's Today, Yesterday and Earlier headings
    /// carry the rest, and the card's line has room for the app after it (Fable #3).
    static func shortWhen(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "Today at 14:38", else the date and time.
    static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? "Today at " + date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}
