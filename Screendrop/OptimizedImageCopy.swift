//
//  OptimizedImageCopy.swift
//  Screendrop
//
//  Copies images, optimized. One image (`copyNow`) goes on the pasteboard at
//  once, as it is, and its optimized file takes its place when it is ready:
//  the owner's choice (2026-11-18), since waiting made ⌘C feel unresponsive.
//  Its caller marks that second write as auto-generated and updates the one
//  history entry in place, so clipboard managers that follow the convention
//  keep one entry for one copy. Several files (`copyAll`) are still written
//  once, when every one is ready.
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

    /// What `copyNow` did.
    enum InstantCopy: Equatable {
        /// The original is on the pasteboard; the swap, if one comes, follows.
        case written
        /// The pasteboard still held this copier's write of the same `key`, the original or its swap:
        /// nothing was written and no second optimization started.
        case alreadyThere
        /// Something newer reached the pasteboard while the original was read: nothing was written.
        case overtaken
    }

    /// The last write here and what it was a copy of, for as long as the pasteboard still holds it.
    private var held: (key: AnyHashable, count: Int)?

    /// A copy nobody waits for: the item `first` makes goes on the pasteboard as soon as it is read, and
    /// this returns. The item `smaller` makes, if it makes one, then takes its place, after `beforeSwap`
    /// (given the original's change count) and only while the pasteboard still holds the original: it
    /// never lands on a later copy from here or on anything copied in another app. This copy takes its
    /// turn before it reads anything, so the original never lands on something newer either. `swapped` is
    /// told whether the swap happened, and the returned task ends with it; nil from `smaller` (nothing
    /// smaller came out, the optimizer failed or is off) leaves the original there.
    ///
    /// `key` names what is copied, a file as it is now: copying the same key again while the pasteboard
    /// still holds this copier's write of it writes nothing and doesn't start the work again (a second ⌘C).
    func copyNow(key: AnyHashable = UUID(), to pasteboard: NSPasteboard = .general,
                 first: () async throws -> NSPasteboardItem,
                 smaller: @escaping () async -> NSPasteboardItem?,
                 beforeSwap: @escaping (_ count: Int) async -> Void = { _ in },
                 swapped: @escaping (Bool) -> Void = { _ in }) async throws -> (InstantCopy, Task<Bool, Never>?) {
        if let held, held.key == key, held.count == pasteboard.changeCount { return (.alreadyThere, nil) }
        latest += 1
        let mine = latest
        let countAtStart = pasteboard.changeCount
        // A copy that was still optimizing is overtaken by this one.
        cancelInFlight?()
        cancelInFlight = nil
        let original = try await first()
        // No suspension between each check and its write, as in `copy`.
        guard mine == latest, pasteboard.changeCount == countAtStart else { return (.overtaken, nil) }
        // The count this clear returns is this copy's own. A count read after the write could already be
        // another app's, which copied in between, and the swap would then take that copy for this one.
        let countAfterWrite = pasteboard.clearContents()
        guard pasteboard.writeObjects([original]) else { throw CocoaError(.fileWriteUnknown) }
        held = (key, countAfterWrite)
        let swap = Task {
            func done(_ result: Bool) -> Bool {
                swapped(result)
                return result
            }
            guard let item = await smaller(), !Task.isCancelled,
                  mine == latest, pasteboard.changeCount == countAfterWrite else { return done(false) }
            await beforeSwap(countAfterWrite)
            // No suspension between this check and the clear. NSPasteboard has no compare-and-replace, so a
            // window is left: another app that copies between this check and `clearContents` loses its copy
            // to the swap. It is the same window Clop's own swap has, a few instructions wide; anything copied
            // before the check, however late, keeps the original or the newer copy where it is.
            guard mine == latest, pasteboard.changeCount == countAfterWrite else { return done(false) }
            let countAfterSwap = pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else { return done(false) }
            if held?.key == key { held = (key, countAfterSwap) }
            return done(true)
        }
        cancelInFlight = { swap.cancel() }
        return (.written, swap)
    }

    /// `copyNow`, waited out: whether the smaller item took the original's place.
    func copyThenSwap(to pasteboard: NSPasteboard = .general, first: () async throws -> NSPasteboardItem,
                      smaller: @escaping () async -> NSPasteboardItem?) async throws -> Bool {
        let (outcome, swap) = try await copyNow(to: pasteboard, first: first, smaller: smaller)
        guard outcome == .written, let swap else { return false }
        return await swap.value
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
