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

    /// Optimizes `url`, then writes the pasteboard item made from the result. Returns nil, and writes
    /// nothing, when something newer reached the pasteboard while optimizing: a later copy from here,
    /// or anything copied in another app. `optimize` falls back to the original by itself
    /// (see `ImageOptimizer.optimize`), so a failed or slow optimization still copies.
    func copy(_ url: URL, to pasteboard: NSPasteboard = .general,
              optimize: (URL) async throws -> ImageOptimizationResult,
              item: (URL) async throws -> NSPasteboardItem) async throws -> ImageOptimizationResult? {
        latest += 1
        let mine = latest
        let countAtStart = pasteboard.changeCount
        // shortcut: a copy that is overtaken finishes optimizing before it is dropped; cancel it here if
        // copies ever run without a time limit.
        let result = try await optimize(url)
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
