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
    private var inFlight: Task<ImageOptimizationResult, Error>?

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
        inFlight?.cancel()
        let work = Task { try await optimize(url) }
        inFlight = work
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
}
