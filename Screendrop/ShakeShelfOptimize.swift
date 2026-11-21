//
//  ShakeShelfOptimize.swift
//  Screendrop
//
//  The shake shelf after a drop on Optimize or WebP: the files wait in a short
//  list, each with its sizes as its result lands, and are then shared,
//  uploaded, copied or saved from there (see ShakeToUpload).
//

import AppKit
import ImageIO
import SwiftUI

extension ShelfOptimization.Format {
    var title: String {
        switch self {
        case .same: "Same Format"
        case .webP: "WebP"
        case .jpeg: "JPEG"
        }
    }

    /// On the list's popup, beside the files: what will be done, so a bare "JPEG" or "WebP" there isn't
    /// read as the kind of file that was dropped.
    var actionTitle: String {
        switch self {
        case .same: "Same Format"
        case .webP: "To WebP"
        case .jpeg: "To JPEG"
        }
    }

    /// What Settings › Optimize makes of each format.
    var target: ImageOptimizationTarget {
        switch self {
        case .same: .lossless
        case .webP: OptimizePreferences.webP
        case .jpeg: OptimizePreferences.jpeg
        }
    }

    /// Shown in a file's row when converting or optimizing to this format came out larger than the original.
    var largerNote: String {
        switch self {
        case .same: "Kept original · Result was larger"
        case .webP: "Kept original · WebP was larger"
        case .jpeg: "Kept original · JPEG was larger"
        }
    }
}

struct ShakeShelfHolding: View {
    static let width: CGFloat = 340
    private static let rowHeight: CGFloat = 40
    private static let visibleRows = 6

    let model: ShelfOptimization
    let offersCloud: Bool
    let offersGallery: Bool
    let finish: (ShakeToUpload.Finish) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.ml) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        ShelfRow(row: row, isCurrent: model.currentIndex == index, isWaiting: model.isWorking)
                            .frame(height: Self.rowHeight)
                    }
                }
            }
            .frame(height: CGFloat(min(model.rows.count, Self.visibleRows)) * Self.rowHeight)
            .scrollBounceBehavior(.basedOnSize)
            buttons
        }
        .padding(DS.Space.l)
        .frame(width: Self.width)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .padding(DS.Space.l)
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Text(title)
                .font(DS.TypeScale.body.weight(.semibold))
                .foregroundStyle(Palette.label)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 0)
            if model.isWorking {
                Button("Stop") { model.stop() }
                    .help("Keep what's finished; the rest go on as they are")
            } else {
                Menu(model.format.actionTitle) {
                    ForEach(ShelfOptimization.Format.allCases, id: \.self) { format in
                        Toggle(format.title, isOn: Binding(get: { model.format == format },
                                                           set: { if $0, model.format != format { model.rerun(as: format) } }))
                    }
                }
                .fixedSize()
                // Not while a choice is being carried out: it is working with these results.
                .disabled(model.isFinishing)
                .help("Run the files again in another format")
            }
            Button { finish(.done) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.secondaryLabel)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.isFinishing)
            .help("Dismiss (Esc)")
            .accessibilityLabel("Dismiss")
        }
        .controlSize(.small)
    }

    private var title: String {
        if let index = model.currentIndex {
            return "\(model.format == .same ? "Optimizing" : "Converting") \(index + 1) of \(model.rows.count)"
        }
        let files = model.rows.count == 1 ? "1 file" : "\(model.rows.count) files"
        guard model.resultBytes < model.originalBytes else { return files }
        return "\(files) · \(ShelfRow.size(model.originalBytes)) → \(ShelfRow.size(model.resultBytes))"
    }

    private var buttons: some View {
        HStack(spacing: DS.Space.s) {
            // A choice is on only when it has something to work with: Save and Replace need a smaller file,
            // and Copy, Share and Upload need a file Sukusho could read.
            Button {
                finish(.save(replacing: false, askWhere: NSEvent.modifierFlags.contains(.option)))
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 22)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSave)
            .help("Save beside originals (⌥ to choose folder)")
            .accessibilityLabel("Save")

            actionButton("doc.on.doc", label: "Copy", help: "Copy", disabled: !model.canHandOver) {
                finish(.copy)
            }

            if offersCloud {
                actionButton("square.and.arrow.up", label: "Share", help: "Share with Share Options…", disabled: !model.canHandOver) {
                    finish(.share)
                }
                actionButton("icloud.and.arrow.up", label: "Upload Now", help: "Upload Now", disabled: !model.canHandOver) {
                    finish(.upload)
                }
            }

            actionButton("arrow.left.arrow.right", label: "Replace Originals", help: "Replace originals (originals go to Trash)", disabled: !model.canReplace) {
                finish(.save(replacing: true))
            }

            if offersGallery {
                Menu {
                    Button("Gallery…") { finish(.gallery) }.disabled(!model.canHandOver)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More")
            }
        }
        .disabled(model.isWorking || model.isFinishing)
    }

    private func actionButton(_ symbol: String, label: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 22)
        }
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(label)
    }
}

private struct ShelfRow: View {
    let row: ShelfOptimization.Row
    let isCurrent: Bool
    let isWaiting: Bool

    var body: some View {
        HStack(spacing: DS.Space.ml) {
            ShelfThumbnail(url: row.file)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.file.lastPathComponent)
                    .font(DS.TypeScale.secondary.weight(.medium))
                    .foregroundStyle(Palette.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sizes)
                    .font(DS.TypeScale.caption)
                    .foregroundStyle(Palette.secondaryLabel)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.s)
            status
        }
        .opacity(!row.isSettled && isWaiting && !isCurrent ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    private var isNew: Bool { row.result?.outcome == .optimized || row.result?.outcome == .converted }

    private var sizes: String {
        if let larger = row.largerFormat { return larger.largerNote }
        // Not read yet, or not readable.
        guard let result = row.result, isNew else { return row.bytes > 0 ? Self.size(row.bytes) : "—" }
        return "\(Self.size(result.originalByteCount)) → \(Self.size(result.resultByteCount))"
    }

    @ViewBuilder private var status: some View {
        if row.largerFormat != nil {
            if row.bytes > 0 { note(Self.size(row.bytes)).monospacedDigit() }
        } else {
            switch row.result?.outcome {
            case nil where isCurrent:
                ProgressView().controlSize(.small)
            case nil:
                note(isWaiting ? "Waiting" : "Not optimized")
            case .optimized, .converted:
                let change = Self.change(from: row.result?.originalByteCount ?? 0, to: row.result?.resultByteCount ?? 0)
                Text(change)
                    .font(DS.TypeScale.secondary.weight(.semibold))
                    .foregroundStyle(Palette.success)
                    .monospacedDigit()
            case .alreadyOptimized:
                note("Already optimized")
            case .timedOut:
                note("Not optimized")
            case .failed(let reason):
                // Anything that isn't a picture goes on as it is, which is no failure. A file macOS won't let
                // Sukusho open, such as one in a folder the person said no for, says so.
                note(reason == ImageOptimizer.unreadableReason ? "Couldn’t read the file"
                    : reason.contains("isn't an image") ? "Not an image" : "Couldn’t optimize").help(reason)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(DS.TypeScale.secondary).foregroundStyle(Palette.secondaryLabel)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "−18%".
    static func change(from original: Int64, to result: Int64) -> String {
        guard original > 0 else { return "" }
        let percent = Int((Double(result - original) / Double(original) * 100).rounded())
        return percent > 0 ? "+\(percent)%" : "−\(-percent)%"
    }
}

private struct ShelfThumbnail: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "doc").foregroundStyle(Palette.secondaryLabel)
            }
        }
        .frame(width: 38, height: 27)
        .clipShape(.rect(cornerRadius: 5))
        // Read off the main actor (ShelfOptimization.thumbnail): the file may be behind a macOS prompt.
        .task { image = await ShelfOptimization.thumbnail(of: url) }
        .accessibilityHidden(true)
    }
}
