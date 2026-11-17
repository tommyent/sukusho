//
//  OptimizedImageCopy.swift
//  Screendrop
//
//  Copies an image after optimizing it. The pasteboard is written once, with
//  the finished result: never the original first and the smaller file later,
//  which is what makes clipboard managers keep two entries for one copy.
//

import AppKit

@MainActor
final class OptimizedImageCopy {
    static let shared = OptimizedImageCopy()

    /// Counts the copies asked for; only the newest may write.
    private var latest = 0
    /// Stops the copy that is still optimizing, if there is one.
    private var cancelInFlight: (() -> Void)?

    /// Optimizes `url`, then writes the pasteboard item made from the result. Returns nil, and writes
    /// nothing, when something newer reached the pasteboard while optimizing: a later copy from here,
    /// which also stops this one's optimizing, or anything copied in another app. `optimize` falls back
    /// to the original by itself (see `ImageOptimizer.optimize`), so a failed optimization still copies.
    func copy(_ url: URL, to pasteboard: NSPasteboard = .general,
              optimize: @escaping (URL) async throws -> ImageOptimizationResult,
              item: (URL) async throws -> NSPasteboardItem) async throws -> ImageOptimizationResult? {
        latest += 1
        let mine = latest
        let countAtStart = pasteboard.changeCount
        cancelInFlight?()
        let work = Task { try await optimize(url) }
        cancelInFlight = { work.cancel() }
        let result: ImageOptimizationResult
        do {
            result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        } catch is CancellationError where mine != latest {
            return nil
        }
        let item = try await item(result.url)
        // No suspension between this check and the write, so nothing can slip in between them.
        guard mine == latest, pasteboard.changeCount == countAtStart else {
            result.discard()
            return nil
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
        return result
    }

    /// The copy right after a capture, which nobody should wait for: `first` goes on the pasteboard now,
    /// and the item `smaller` makes, if it makes one, takes its place when it is ready. It does so only
    /// while the pasteboard still holds this very write: a later copy from here, or anything copied in
    /// another app meanwhile, stays. Returns whether the swap happened; `smaller` giving nil (nothing
    /// smaller came out, or the optimizer failed) leaves the original there.
    func copyThenSwap(_ first: NSPasteboardItem, to pasteboard: NSPasteboard = .general,
                      smaller: () async -> NSPasteboardItem?) async throws -> Bool {
        latest += 1
        let mine = latest
        // A copy that was still optimizing is overtaken by this write.
        cancelInFlight?()
        cancelInFlight = nil
        pasteboard.clearContents()
        guard pasteboard.writeObjects([first]) else { throw CocoaError(.fileWriteUnknown) }
        let countAfterWrite = pasteboard.changeCount
        guard let item = await smaller() else { return false }
        // No suspension between this check and the write, as in `copy`.
        guard mine == latest, pasteboard.changeCount == countAfterWrite else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
        return true
    }

    /// Several files at once, as the Library copies a selection. Each goes through `ready` in turn (a
    /// screenshot optimized, a recording rendered); then `write` gets the files to put on the pasteboard, in
    /// one go, and must not suspend. The rule is `copy`'s: nil, with nothing written and the results deleted,
    /// when a later copy from here or anything copied in another app got there first. Results that were
    /// written stay the caller's to discard.
    func copyAll(_ urls: [URL], to pasteboard: NSPasteboard = .general,
                 ready: @escaping (URL) async throws -> ImageOptimizationResult,
                 write: ([URL]) throws -> Void) async throws -> [ImageOptimizationResult]? {
        latest += 1
        let mine = latest
        let countAtStart = pasteboard.changeCount
        cancelInFlight?()
        let work = Task {
            var results: [ImageOptimizationResult] = []
            do {
                for url in urls { results.append(try await ready(url)) }
            } catch {
                results.forEach { $0.discard() }
                throw error
            }
            return results
        }
        cancelInFlight = { work.cancel() }
        let results: [ImageOptimizationResult]
        do {
            results = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        } catch is CancellationError where mine != latest {
            return nil
        }
        // No suspension between this check and the write, as in `copy`.
        guard mine == latest, pasteboard.changeCount == countAtStart else {
            results.forEach { $0.discard() }
            return nil
        }
        do {
            try write(results.map(\.url))
        } catch {
            results.forEach { $0.discard() }
            throw error
        }
        return results
    }
}
