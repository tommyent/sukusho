//
//  ShelfOptimization.swift
//  Screendrop
//
//  The files the shake shelf holds after a drop on Optimize or WebP, and what
//  has been made of each so far. Apart from the shelf's views, so it can be
//  tested: a choice on the list (save, copy, share) works on result files that
//  another format choice would delete, so the two must never overlap.
//

import Foundation
import Observation

@MainActor
@Observable
final class ShelfOptimization {
    enum Format: CaseIterable, Sendable {
        case same, webP, jpeg
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
        rows = files.map { Row(file: $0, bytes: Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)) }
        self.format = format
        self.optimizer = optimizer
        self.effort = effort
        self.target = target
        start()
    }

    /// The row being worked on.
    var currentIndex: Int? { isWorking ? rows.firstIndex { $0.result == nil } : nil }
    var originalBytes: Int64 { rows.reduce(0) { $0 + $1.bytes } }
    var resultBytes: Int64 { rows.reduce(0) { $0 + ($1.result?.resultByteCount ?? $1.bytes) } }

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

    /// What goes on from the shelf: each file's result, or the file itself where there is none or where the
    /// file has changed since. Finding that out reads every file, so it is done off the main actor.
    nonisolated static func currentFiles(of rows: [Row]) async -> [URL] {
        await Task.detached { rows.map { $0.currentResult?.url ?? $0.file } }.value
    }

    /// The same files again, from the originals, in another format. Not while a choice is being carried
    /// out: its results are in use.
    func rerun(as format: Format) {
        guard !isFinishing else { return }
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
        let target = target(format)
        // One file at a time: each encoder already uses every core.
        task = Task { [weak self, optimizer, effort] in
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
