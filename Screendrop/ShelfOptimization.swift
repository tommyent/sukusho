//
//  ShelfOptimization.swift
//  Screendrop
//
//  The files the shake shelf holds after a drop on Optimize or WebP, and what
//  has been made of each so far. Apart from the shelf's views, so it can be
//  tested: a choice on the list (save, copy, share) works on result files that
//  another format choice would delete, so the two must never overlap.
//

import CoreGraphics
import Foundation
import ImageIO
import Observation

/// Which list the shelf is showing, and the rule for a choice that is done only after the shelf has moved
/// on: put away, or opened again for other files. Such a choice still finishes with its own list's
/// results, but it may dismiss the shelf, clear it or change what it shows only if its list is still the
/// one on show. `finish` says whether it is.
@MainActor
@Observable
final class ShelfStage {
    private(set) var holding: ShelfOptimization?

    func show(_ model: ShelfOptimization) {
        holding = model
    }

    /// The shelf is put away or goes on to something else. The list it showed stops, and keeps its
    /// results: a choice may still be working with them.
    func putAway() {
        holding?.stop()
        holding = nil
    }

    /// Carries out a choice on `model` (`ShelfOptimization.finishing`). Returns what `work` gave and
    /// whether `model` is still the list on show now that it is done; nil while an earlier choice on it
    /// is still going.
    func finish<Value>(_ model: ShelfOptimization, _ work: ([ShelfOptimization.Row]) async -> Value) async -> (value: Value, isShowing: Bool)? {
        guard let value = await model.finishing(work) else { return nil }
        return (value, holding === model)
    }
}

@MainActor
@Observable
final class ShelfOptimization {
    enum Format: CaseIterable, Sendable {
        case same, webP, jpeg
    }

    nonisolated struct Row: Identifiable, Sendable {
        let id = UUID()
        let file: URL
        /// The file's size, once it has been read; 0 until then, or when it can't be.
        var bytes: Int64 = 0
        var result: ImageOptimizationResult?
        /// Set when converting or optimizing came out larger than the original: the larger file is discarded
        /// and the original is kept.
        var largerFormat: Format?

        /// The result, while the file still holds the contents it was made from: the shelf can sit for a
        /// while, and an older result must not stand in for a newer file. Reads the file.
        var currentResult: ImageOptimizationResult? {
            guard let result, let source = result.source, source == FileIdentity(file) else { return nil }
            return result
        }

        /// True once the optimizer has finished this row, whether it produced a result or kept the original.
        var isSettled: Bool { result != nil || largerFormat != nil }
        /// A smaller or converted file was made for it: something to save.
        var hasNewFile: Bool { result?.outcome == .optimized || result?.outcome == .converted }
        /// Sukusho wasn't allowed to open it, so there is nothing of it to copy, share or save.
        var isUnreadable: Bool { result?.outcome == .failed(ImageOptimizer.unreadableReason) }
    }

    private(set) var rows: [Row]
    private(set) var format: Format
    private(set) var isWorking = false
    /// True while a choice on the list is being carried out with these results. Until it is done the
    /// results are that work's: no other format and no second choice.
    private(set) var isFinishing = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let optimizer: ImageOptimizer
    @ObservationIgnored private let effort: ImageOptimizationEffort
    @ObservationIgnored private let target: (Format) -> ImageOptimizationTarget

    /// `target` says what each format is made with (the app's Optimize settings).
    init(files: [URL], format: Format, optimizer: ImageOptimizer, effort: ImageOptimizationEffort,
         target: @escaping (Format) -> ImageOptimizationTarget) {
        // Nothing about the files is read here, on the main actor. A file in a folder macOS guards (Desktop,
        // Documents, Downloads) makes its first read wait for the person's answer to a prompt, and the app
        // would wait with it: on the test Mac the shelf stayed stuck on its tiles that way.
        rows = files.map { Row(file: $0) }
        self.format = format
        self.optimizer = optimizer
        self.effort = effort
        self.target = target
        readSizes()
        start()
    }

    /// The shelf's small reads, one after the other on a queue of their own. Not in Swift's pool of threads,
    /// which is small: a read waiting on a macOS prompt would hold one of those as long as the prompt is up.
    private nonisolated static let reads = DispatchQueue(label: "com.tommyent.Sukusho.shelf.reads", qos: .utility)

    private nonisolated static func reading<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            reads.async { continuation.resume(returning: work()) }
        }
    }

    /// The ones of `urls` that are files, not folders, asked off the main actor.
    nonisolated static func regularFiles(_ urls: [URL]) async -> [URL] {
        await reading { urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } }
    }

    private func readSizes() {
        let files = rows.map(\.file)
        Task { [weak self] in
            let sizes = await Self.reading {
                files.map { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value ?? 0 }
            }
            guard let self else { return }
            for (index, size) in sizes.enumerated() where index < self.rows.count && self.rows[index].file == files[index] {
                self.rows[index].bytes = size
            }
        }
    }

    /// A small picture of the file for its row, read off the main actor; nil when it isn't an image or
    /// can't be read.
    nonisolated static func thumbnail(of url: URL) async -> CGImage? {
        await reading {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 120,
            ] as CFDictionary)
        }
    }

    /// The row being worked on.
    var currentIndex: Int? { isWorking ? rows.firstIndex { !$0.isSettled } : nil }
    var originalBytes: Int64 { rows.reduce(0) { $0 + $1.bytes } }
    /// What the files come to now: a smaller result's size where one was made, the file's own size otherwise.
    var resultBytes: Int64 {
        rows.reduce(0) { total, row in
            guard let result = row.result, result.outcome == .optimized || result.outcome == .converted else { return total + row.bytes }
            return total + result.resultByteCount
        }
    }

    /// True when a new file came out strictly larger than the original and must not be offered.
    nonisolated static func isLarger(_ result: ImageOptimizationResult) -> Bool {
        (result.outcome == .optimized || result.outcome == .converted)
            && result.originalByteCount > 0
            && result.resultByteCount > result.originalByteCount
    }

    /// Carries out a choice on the list. `work` gets the rows as they are now, and until it returns they
    /// stay as they are: `rerun` does nothing meanwhile, so no result file `work` is reading can be
    /// deleted under it. Returns nil, without running `work`, while an earlier choice is still going.
    func finishing<Value>(_ work: ([Row]) async -> Value) async -> Value? {
        guard !isFinishing else { return nil }
        stop()
        isFinishing = true
        defer { isFinishing = false }
        return await work(rows)
    }

    /// Save has something to write: at least one file came out smaller or converted.
    var canSave: Bool { rows.contains(where: \.hasNewFile) }
    /// Copy, Share and Upload have something to take: at least one file Sukusho could read.
    var canHandOver: Bool { rows.contains { !$0.isUnreadable } }

    /// What goes on from the shelf: each file's result, or the file itself where there is none or where the
    /// file has changed since. A file Sukusho wasn't allowed to read is left out: it couldn't be copied or
    /// sent either. Finding the rest out reads every file, so it is done off the main actor.
    nonisolated static func currentFiles(of rows: [Row]) async -> [URL] {
        await Task.detached { rows.filter { !$0.isUnreadable }.map { $0.currentResult?.url ?? $0.file } }.value
    }

    /// The same files again, from the originals, in another format. Not while a choice is being carried
    /// out: its results are in use.
    func rerun(as format: Format) {
        guard !isFinishing else { return }
        stop()
        discard()
        for index in rows.indices {
            rows[index].result = nil
            rows[index].largerFormat = nil
        }
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
        let target = target(format)
        // One file at a time: each encoder already uses every core.
        task = Task { [weak self, optimizer, effort] in
            while let file = self?.rows.first(where: { !$0.isSettled })?.file {
                guard let result = try? await optimizer.optimize(file, to: target, effort: effort) else { return }
                // Stopped, or run again in another format, while this one was finishing.
                guard !Task.isCancelled, let self,
                      let index = self.rows.firstIndex(where: { $0.file == file && !$0.isSettled }) else {
                    result.discard()
                    return
                }
                self.record(result, at: index)
            }
            self?.isWorking = false
            self?.task = nil
        }
    }

    private func record(_ result: ImageOptimizationResult, at index: Int) {
        if rows[index].bytes == 0, result.originalByteCount > 0 {
            rows[index].bytes = result.originalByteCount
        }
        if Self.isLarger(result) {
            result.discard()
            rows[index].largerFormat = format
        } else {
            rows[index].result = result
        }
    }
}
