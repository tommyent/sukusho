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

@MainActor
@Observable
final class ShelfOptimization {
    enum Format: CaseIterable {
        case same, webP, jpeg

        var title: String {
            switch self {
            case .same: "Same Format"
            case .webP: "WebP"
            case .jpeg: "JPEG"
            }
        }

        var target: ImageOptimizationTarget {
            switch self {
            case .same: .lossless
            case .webP: OptimizePreferences.webP
            case .jpeg: OptimizePreferences.jpeg
            }
        }
    }

    nonisolated struct Row: Identifiable, Sendable {
        let id = UUID()
        let file: URL
        let bytes: Int64
        var result: ImageOptimizationResult?

        /// The result, while the file still holds the contents it was made from: the shelf can sit for a
        /// while, and an older result must not stand in for a newer file. Reads the file.
        var currentResult: ImageOptimizationResult? {
            guard let result, let source = result.source, source == FileIdentity(file) else { return nil }
            return result
        }
    }

    private(set) var rows: [Row]
    private(set) var format: Format
    private(set) var isWorking = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let optimizer: ImageOptimizer

    init(files: [URL], format: Format, optimizer: ImageOptimizer = .shared) {
        rows = files.map { Row(file: $0, bytes: Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)) }
        self.format = format
        self.optimizer = optimizer
        start()
    }

    /// The row being worked on.
    var currentIndex: Int? { isWorking ? rows.firstIndex { $0.result == nil } : nil }
    /// What goes on from the shelf: each file's result, or the file itself where there is none or where the
    /// file has changed since. Finding that out reads every file, so it is done off the main actor.
    func currentFiles() async -> [URL] {
        let rows = rows
        return await Task.detached { rows.map { $0.currentResult?.url ?? $0.file } }.value
    }
    var originalBytes: Int64 { rows.reduce(0) { $0 + $1.bytes } }
    var resultBytes: Int64 { rows.reduce(0) { $0 + ($1.result?.resultByteCount ?? $1.bytes) } }

    /// The same files again, from the originals, in another format.
    func rerun(as format: Format) {
        stop()
        discard()
        for index in rows.indices { rows[index].result = nil }
        self.format = format
        start()
    }

    /// Keeps what is finished; the rest go on as they are.
    func stop() {
        task?.cancel()
        task = nil
        isWorking = false
    }

    func discard() {
        for row in rows { row.result?.discard() }
    }

    private func start() {
        isWorking = true
        let target = format.target
        let effort = OptimizePreferences.effort
        // One file at a time: each encoder already uses every core.
        task = Task { [weak self, optimizer] in
            while let file = self?.rows.first(where: { $0.result == nil })?.file {
                guard let result = try? await optimizer.optimize(file, to: target, effort: effort) else { return }
                // Stopped, or run again in another format, while this one was finishing.
                guard !Task.isCancelled, let self, let index = self.rows.firstIndex(where: { $0.file == file && $0.result == nil }) else {
                    result.discard()
                    return
                }
                self.rows[index].result = result
            }
            self?.isWorking = false
            self?.task = nil
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
        HStack(spacing: DS.Space.m) {
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
                Menu(model.format.title) {
                    ForEach(ShelfOptimization.Format.allCases, id: \.self) { format in
                        Toggle(format.title, isOn: Binding(get: { model.format == format },
                                                           set: { if $0, model.format != format { model.rerun(as: format) } }))
                    }
                }
                .fixedSize()
                .help("Run the files again in another format")
            }
        }
        .controlSize(.small)
    }

    private var title: String {
        if let index = model.currentIndex {
            return "\(model.format == .same ? "Optimizing" : "Converting") \(index + 1) of \(model.rows.count)"
        }
        let files = model.rows.count == 1 ? "1 file" : "\(model.rows.count) files"
        guard model.resultBytes != model.originalBytes else { return files }
        return "\(files) · \(ShelfRow.size(model.originalBytes)) → \(ShelfRow.size(model.resultBytes))"
    }

    private var buttons: some View {
        HStack(spacing: DS.Space.s) {
            if offersCloud {
                Button { finish(.share) } label: { Text("Share…").frame(maxWidth: .infinity) }
                Button { finish(.upload) } label: { Text("Upload Now").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button { finish(.copy) } label: { Text("Copy").frame(maxWidth: .infinity) }
                Button { finish(.save(replacing: false)) } label: { Text("Save").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            }
            Menu {
                if offersCloud {
                    if offersGallery { Button("Gallery…") { finish(.gallery) } }
                    Button("Copy") { finish(.copy) }
                    Button("Save") { finish(.save(replacing: false)) }
                }
                Button("Save and Replace Originals") { finish(.save(replacing: true)) }
                Divider()
                Button("Done") { finish(.done) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .disabled(model.isWorking)
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
            }
            Spacer(minLength: DS.Space.s)
            status
        }
        .opacity(row.result == nil && isWaiting && !isCurrent ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    private var isNew: Bool { row.result?.outcome == .optimized || row.result?.outcome == .converted }

    private var sizes: String {
        guard let result = row.result, isNew else { return Self.size(row.bytes) }
        return "\(Self.size(result.originalByteCount)) → \(Self.size(result.resultByteCount))"
    }

    @ViewBuilder private var status: some View {
        switch row.result?.outcome {
        case nil where isCurrent:
            ProgressView().controlSize(.small)
        case nil:
            note(isWaiting ? "Waiting" : "Not optimized")
        case .optimized, .converted:
            let change = Self.change(from: row.result?.originalByteCount ?? 0, to: row.result?.resultByteCount ?? 0)
            Text(change)
                .font(DS.TypeScale.secondary.weight(.semibold))
                .foregroundStyle(change.hasPrefix("−") ? Palette.success : Palette.secondaryLabel)
                .monospacedDigit()
        case .alreadyOptimized:
            note("Already optimized")
        case .timedOut:
            note("Not optimized")
        case .failed(let reason):
            // Anything that isn't a picture goes on as it is, which is no failure.
            note(reason.contains("isn't an image") ? "Not an image" : "Couldn’t optimize").help(reason)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(DS.TypeScale.secondary).foregroundStyle(Palette.secondaryLabel)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "−18%", or "+5%" for a conversion that came out larger.
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
        .task { image = await Self.thumbnail(of: url) }
        .accessibilityHidden(true)
    }

    private nonisolated static func thumbnail(of url: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 120,
        ] as CFDictionary)
    }
}
