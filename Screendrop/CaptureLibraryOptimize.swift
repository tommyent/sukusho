//
//  CaptureLibraryOptimize.swift
//  Screendrop
//
//  Optimize, Convert to WebP… and Convert to JPEG… for captures. Optimize
//  replaces a capture's stored file with a smaller one holding the same
//  pixels; converting makes a new file to copy or save and leaves the capture
//  as it is.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum CaptureOptimizer {
    enum Outcome {
        case optimized(ImageOptimizationResult)
        case alreadyOptimized
        case failed(String)
    }

    /// Replaces a capture's stored image with a smaller file that decodes to the same pixels. The capture is
    /// left alone when its editor is open, or when it changed while the encoder ran. `whileEditing` is for an
    /// editor that has sat idle: a save that lands meanwhile changes the file's contents, which is what is checked.
    static func optimizeInPlace(_ url: URL, effort: ImageOptimizationEffort, whileEditing: Bool = false) async -> Outcome {
        guard whileEditing || !CaptureLibraryOpenEditors.isEditing(url) else {
            return .failed("Close the capture's editor before optimizing it.")
        }
        guard !OptimizedMark.isCurrent(url) else { return .alreadyOptimized }
        guard let result = try? await ImageOptimizer.shared.optimize(url, effort: effort) else { return .failed("Optimizing was stopped.") }
        defer { result.discard() }
        // Either outcome below replaces or marks the capture only while it still holds the contents the
        // encoder read, by their hash: a save can keep a file's size and date.
        func unchanged() -> Bool {
            guard let source = result.source, source == FileIdentity(url) else { return false }
            return whileEditing || !CaptureLibraryOpenEditors.isEditing(url)
        }
        switch result.outcome {
        case .optimized:
            guard unchanged() else { return .failed("The capture changed while it was being optimized.") }
            do {
                try ScreenshotEditFileTransaction.apply(replacements: [(result.url, url)])
            } catch {
                return .failed(error.localizedDescription)
            }
            OptimizedMark.set(result.originalByteCount, on: url)
            return .optimized(result)
        case .alreadyOptimized:
            // Nothing smaller came out: remembered, so the next pass doesn't run the encoder again. Not for a
            // file saved meanwhile, which the encoder never saw.
            guard unchanged() else { return .failed("The capture changed while it was being optimized.") }
            OptimizedMark.set(result.originalByteCount, on: url)
            return .alreadyOptimized
        case .converted, .timedOut:
            return .alreadyOptimized
        case .failed(let reason):
            return .failed(reason)
        }
    }

    /// Settings › Optimize › Optimize before sharing to Cloud: the smaller file to upload, or nil to upload
    /// the capture as it is (switched off, not a PNG or JPEG, already optimized, or nothing smaller came out).
    static func forCloud(_ url: URL) async -> ImageOptimizationResult? {
        guard OptimizePreferences.beforeCloud, ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()),
              !OptimizedMark.isCurrent(url),
              let result = try? await ImageOptimizer.shared.optimize(url, effort: OptimizePreferences.quietEffort) else { return nil }
        guard result.outcome == .optimized else {
            result.discard()
            return nil
        }
        return result
    }

    /// How long an open editor must go without a save before its capture is optimized under it.
    static let editingIdle: Duration = .seconds(60)
    private static var afterEditing: [URL: Task<Void, Never>] = [:]

    /// An edited capture is optimized once its editing is over, never on each save: two seconds after its
    /// editor closes, or `editingIdle` after the last save while the editor stays open. Every save and the
    /// close call this, and each call replaces the wait before it. A capture that was only opened and closed
    /// is optimized the same way, since the background pass skipped it while its editor was up.
    static func editingChanged(_ url: URL, closed: Bool) {
        let key = url.standardizedFileURL
        afterEditing[key]?.cancel()
        afterEditing[key] = nil
        guard OptimizePreferences.newCaptures, ScreenshotHistoryStore.shared.isHistoryURL(key),
              ["png", "jpg", "jpeg"].contains(key.pathExtension.lowercased()) else { return }
        afterEditing[key] = Task(priority: .utility) {
            try? await Task.sleep(for: closed ? .seconds(2) : editingIdle)
            guard !Task.isCancelled else { return }
            afterEditing[key] = nil
            if case .optimized = await optimizeInPlace(key, effort: OptimizePreferences.quietEffort, whileEditing: !closed) {
                CaptureLibraryModel.shared.refresh()
            }
        }
    }

    /// Settings › Optimize › Optimize new captures: quietly, right after a screenshot reaches the Library.
    static func optimizeNewCapture(_ url: URL) {
        guard OptimizePreferences.newCaptures else { return }
        Task(priority: .utility) {
            // Not while the capture is being copied or saved by its after-capture actions.
            try? await Task.sleep(for: .seconds(2))
            if case .optimized = await optimizeInPlace(url, effort: OptimizePreferences.quietEffort) {
                CaptureLibraryModel.shared.refresh()
            }
        }
    }
}

/// What Convert to WebP… or Convert to JPEG… works on.
struct ImageConversion: Identifiable {
    enum Format {
        case webP, jpeg

        var title: String { self == .webP ? "WebP" : "JPEG" }
        var contentType: UTType { self == .webP ? .webP : .jpeg }
    }

    let id = UUID()
    let format: Format
    /// Each file with the name its result takes, without an extension.
    let files: [(url: URL, name: String)]
    /// "pull-request.png · 2,560 × 1,600", or "3 captures".
    let subtitle: String
}

extension CaptureLibraryModel {
    /// The Optimize group in the captures' menu. Recordings have none.
    func optimizeMenuItems() -> [LibraryMenuItem] {
        let selected = selectedItems
        guard !selected.isEmpty, !selected.contains(where: \.isVideo) else { return [] }
        return [
            LibraryMenuItem(title: "Optimize", isEnabled: !isBusy, startsGroup: true) { self.optimize(selected) },
            LibraryMenuItem(title: "Convert to WebP…", isEnabled: !isBusy) { self.pendingConversion = Self.conversion(.webP, of: selected) },
            LibraryMenuItem(title: "Convert to JPEG…", isEnabled: !isBusy) { self.pendingConversion = Self.conversion(.jpeg, of: selected) },
        ]
    }

    private static func conversion(_ format: ImageConversion.Format, of items: [CaptureLibraryItem]) -> ImageConversion {
        let subtitle = items.count == 1 ? "\(items[0].fileURL.lastPathComponent) · \(items[0].dimensions)" : "\(items.count) captures"
        return ImageConversion(format: format, files: items.map { ($0.fileURL, ($0.name as NSString).deletingPathExtension) }, subtitle: subtitle)
    }

    func optimize(_ items: [CaptureLibraryItem]) {
        run(items.count == 1 ? "Optimizing…" : "Optimizing \(items.count) captures…") {
            var before: Int64 = 0, after: Int64 = 0, optimized = 0, failures: [String] = []
            for item in items {
                switch await CaptureOptimizer.optimizeInPlace(item.fileURL, effort: OptimizePreferences.effort) {
                case .optimized(let result):
                    optimized += 1
                    before += result.originalByteCount
                    after += result.resultByteCount
                case .alreadyOptimized:
                    break
                case .failed(let reason):
                    failures.append(reason)
                }
            }
            self.refresh()
            if let reason = failures.first, items.count == 1 {
                self.errorMessage = "The capture couldn't be optimized. \(reason)"
                return
            }
            let sizes = "\(ByteCountFormatter.string(fromByteCount: before, countStyle: .file)) → "
                + "\(ByteCountFormatter.string(fromByteCount: after, countStyle: .file)) · \(ImageOptimizationResult.saving(from: before, to: after))"
            var message = optimized == 0 ? "Already Optimized"
                : items.count == 1 ? "Optimized · \(sizes)" : "Optimized \(optimized) of \(items.count) · \(sizes)"
            if !failures.isEmpty { message += " · \(failures.count) couldn't be optimized" }
            self.actionFeedback.show(message)
        }
    }
}

/// The small sheet behind Convert to WebP… and Convert to JPEG…: one choice, the size it gives, then Copy File or Save….
struct ImageConversionSheet: View {
    let conversion: ImageConversion
    /// Says what happened, in the window that showed the sheet.
    let done: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(OptimizePreferences.webPLosslessKey) private var webPLossless = true
    @AppStorage(OptimizePreferences.webPQualityKey) private var webPQuality = OptimizePreferences.defaultQuality
    @AppStorage(OptimizePreferences.jpegQualityKey) private var jpegQuality = OptimizePreferences.defaultQuality
    @State private var results: [ImageOptimizationResult] = []
    @State private var isWorking = true
    @State private var failure: String?

    private var isWebP: Bool { conversion.format == .webP }
    private var target: ImageOptimizationTarget {
        isWebP ? .webP(quality: webPLossless ? nil : Int(webPQuality)) : .jpeg(quality: Int(jpegQuality))
    }
    /// Changes with every choice that changes the result, so the size is worked out again.
    private var choice: String { "\(webPLossless)-\(Int(webPQuality))-\(Int(jpegQuality))" }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Convert to \(conversion.format.title)").font(DS.TypeScale.title)
                Text(conversion.subtitle).font(DS.TypeScale.secondary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Form {
                if isWebP {
                    Picker("Quality", selection: $webPLossless) {
                        Text("Lossless").tag(true)
                        Text("Smaller").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if !webPLossless { OptimizeQualitySlider(title: "WebP quality", quality: $webPQuality) }
                } else {
                    OptimizeQualitySlider(title: "JPEG quality", quality: $jpegQuality)
                }
            }
            .formStyle(.columns)
            Text(isWebP ? (webPLossless ? "Keeps every pixel and transparency." : "Smaller, with some detail lost.")
                        : "Smaller, with some detail lost. Transparent areas become white.")
                .font(.caption)
                .foregroundStyle(.secondary)
            result
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(results.count > 1 ? "Copy Files" : "Copy File") { copyFiles() }
                    .disabled(isWorking || failure != nil)
                Button("Save…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || failure != nil)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 400)
        .task(id: choice) { await convert() }
        .onDisappear { discard() }
    }

    private var result: some View {
        HStack(spacing: DS.Space.ml) {
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else if isWorking {
                ProgressView().controlSize(.small)
                Text("Working out the size…").foregroundStyle(.secondary)
            } else {
                let before = results.reduce(0) { $0 + $1.originalByteCount }
                let after = results.reduce(0) { $0 + $1.resultByteCount }
                Text(ByteCountFormatter.string(fromByteCount: after, countStyle: .file)).font(DS.TypeScale.title).monospacedDigit()
                Text("from \(ByteCountFormatter.string(fromByteCount: before, countStyle: .file))").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if after < before {
                    Text(ImageOptimizationResult.saving(from: before, to: after)).fontWeight(.semibold).foregroundStyle(Palette.success)
                } else {
                    Text("Larger than the original").foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .background(Palette.selectedFill, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
    }

    private func convert() async {
        isWorking = true
        failure = nil
        // A dragged slider settles before the encoder starts.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        discard()
        var made: [ImageOptimizationResult] = []
        for file in conversion.files {
            guard let result = try? await ImageOptimizer.shared.optimize(file.url, to: target, effort: OptimizePreferences.effort) else {
                made.forEach { $0.discard() }
                return
            }
            if case .failed(let reason) = result.outcome {
                made.forEach { $0.discard() }
                failure = reason
                isWorking = false
                return
            }
            made.append(result)
        }
        results = made
        isWorking = false
    }

    private func discard() {
        results.forEach { $0.discard() }
        results = []
    }

    /// The results under the names their captures have, in a folder of their own, so a pasted or saved file is well named.
    private func named() throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SukushoConverted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try zip(results, conversion.files).map { result, file in
            try CaptureLibraryFiles.export(result.url, name: file.name, to: folder)
        }
    }

    private func copyFiles() {
        do {
            let files = try named()
            defer { files.first.map { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
            try VideoFileActions.copyFilesToClipboard(from: files)
            done(files.count == 1 ? "\(conversion.format.title) File Copied" : "\(files.count) \(conversion.format.title) Files Copied")
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func save() {
        do {
            let files = try named()
            defer { files.first.map { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
            var saved: [URL] = []
            if files.count == 1 {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [conversion.format.contentType]
                panel.nameFieldStringValue = files[0].lastPathComponent
                panel.directoryURL = ScreendropPreferences.exportDirectory
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                // The panel has already asked about replacing a file of that name. The new file is staged beside
                // it and swapped in whole, and the old one comes back if that fails: it is never deleted first.
                try ScreenshotEditFileTransaction.apply(replacements: [(files[0], destination)])
                saved = [destination]
            } else {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = "Save Here"
                panel.directoryURL = ScreendropPreferences.exportDirectory
                guard panel.runModal() == .OK, let folder = panel.url else { return }
                saved = try files.map { try CaptureLibraryFiles.export($0, name: $0.deletingPathExtension().lastPathComponent, to: folder) }
            }
            NSWorkspace.shared.activateFileViewerSelecting(saved)
            done(saved.count == 1 ? "Saved \(saved[0].lastPathComponent)" : "Saved \(saved.count) \(conversion.format.title) Files")
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
