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
    /// The turns of copies asked for that haven't written yet or given up. A swap waits while the newest is
    /// one of them (`copyNow`); an older one can't write any more.
    private var pending: Set<Int> = []
    /// Stops the copy that is still optimizing, if there is one.
    private var cancelInFlight: (() -> Void)?
    /// Stops the held copy's swap, if one is coming. Only a write replaces the held copy, so only a write
    /// cancels it: a copy that gives way, or turns out to be a repeat, leaves the swap to go in (Astra, round 4).
    private var cancelSwap: (() -> Void)?

    /// Optimizes `url`, then writes the pasteboard item made from the result. Returns nil, and writes
    /// nothing, when something newer reached the pasteboard while optimizing: a later copy from here,
    /// which also stops this one's optimizing, or anything copied in another app. `optimize` falls back
    /// to the original by itself (see `ImageOptimizer.optimize`), so a failed optimization still copies.
    func copy(_ url: URL, to pasteboard: NSPasteboard = .general,
              optimize: @escaping (URL) async throws -> ImageOptimizationResult,
              item: (URL) async throws -> NSPasteboardItem) async throws -> ImageOptimizationResult? {
        latest += 1
        let mine = latest
        pending.insert(mine)
        defer { pending.remove(mine) }
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
        cancelSwap?()
        cancelSwap = nil
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

    /// What `copyNow`'s `smaller` gives for the swap: the optimized item, the digest (`ClipboardPasteboardReader.digest`)
    /// of the bytes the optimizer read, which must be the bytes the copy wrote, and the digest of what the encoder
    /// made, which must be the bytes the item carries: a file read after the encoder left it (an optimized capture,
    /// optimized in place) can have been overwritten since.
    struct Swap {
        let item: NSPasteboardItem
        let source: String?
        let output: String?
    }

    /// The image an item carries, as history reads it: PNG, else JPEG.
    static func imageData(of item: NSPasteboardItem) -> Data? {
        item.data(forType: .png) ?? item.data(forType: .init("public.jpeg"))
    }

    /// What `copyNow`'s `first` read: the item to write, and `key`, what it is a copy of. Copying the same key
    /// again while the pasteboard still holds this copier's write of it writes nothing (a second ⌘C).
    struct Original {
        let item: NSPasteboardItem
        let key: AnyHashable
    }

    /// What an image item is a copy of: the bytes it carries, hashed from the item itself so they are the bytes
    /// written, and the file it names (`public.file-url`), which a file paste uses, so two files with the same
    /// bytes are two copies (Astra, round 3).
    static func key(of item: NSPasteboardItem) async -> AnyHashable {
        guard let bytes = imageData(of: item) else { return AnyHashable(UUID()) }
        let digest = await Task.detached { ClipboardPasteboardReader.digest(bytes) }.value
        return AnyHashable([item.string(forType: .fileURL) ?? "", digest])
    }

    /// A copy nobody waits for: the item `first` makes goes on the pasteboard as soon as it is read, and
    /// this returns. `record` files that write in history at once and names the card it went on. The item
    /// `smaller` makes, if it makes one, then takes its place, only while the pasteboard still holds the
    /// original: never on a later copy from here or on anything copied in another app before the swap's
    /// last check. `stack` then puts it on the card `record` named. This copy takes its turn, and notes the
    /// pasteboard's count, before anything is awaited, `first` included, so the original never lands on
    /// something newer either: anything copied while it reads, here or in another app, overtakes it.
    /// `swapped` is told whether the swap happened, and the returned task ends with it; nil from `smaller`
    /// (nothing smaller came out, the optimizer failed or is off) leaves the original there, as does a swap
    /// made from other bytes than the ones written (the file changed after it was read) or one that holds
    /// those very bytes.
    func copyNow(to pasteboard: NSPasteboard = .general,
                 first: () async throws -> Original,
                 record: @escaping (NSPasteboardItem) async -> String? = { _ in nil },
                 smaller: @escaping () async -> Swap?,
                 stack: @escaping (_ card: String, _ item: NSPasteboardItem) async -> Void = { _, _ in },
                 swapped: @escaping (Bool) -> Void = { _ in }) async throws -> (InstantCopy, Task<Bool, Never>?) {
        // The turn and the count come first, before any await: a copy asked for or made while this one reads
        // is newer (Astra, round 3, for a digest read that came before them).
        latest += 1
        let mine = latest
        let countAtStart = pasteboard.changeCount
        pending.insert(mine)
        defer { pending.remove(mine) }
        let read = try await first()
        // No suspension between each check and its write, as in `copy`.
        guard mine == latest, pasteboard.changeCount == countAtStart else { return (.overtaken, nil) }
        // A repeat of what the pasteboard still holds from here writes nothing, but it is the newest copy asked
        // for all the same: an older one still reading another item can't land after it (Astra, round 3). The
        // held copy's swap, if one is coming, still may, so a genuine repeat keeps its optimization.
        if let held, held.key == read.key, held.count == countAtStart { return (.alreadyThere, nil) }
        let original = read.item
        let key = read.key
        // This copy replaces the held one now: a swap still coming for that one is moot, as is an older copy
        // still optimizing.
        cancelSwap?()
        cancelSwap = nil
        cancelInFlight?()
        cancelInFlight = nil
        // The count this clear returns is this copy's own. A count read after the write could already be
        // another app's, which copied in between, and the swap would then take that copy for this one.
        let countAfterWrite = pasteboard.clearContents()
        guard pasteboard.writeObjects([original]) else { throw CocoaError(.fileWriteUnknown) }
        held = (key, countAfterWrite)
        // History files this copy now, not at the monitor's next poll: a swap before that poll would hide it.
        let card = Task { await record(original) }
        let swap = Task {
            func done(_ result: Bool) -> Bool {
                swapped(result)
                return result
            }
            guard let candidate = await smaller(), !Task.isCancelled,
                  let copiedData = Self.imageData(of: original), let smallerData = Self.imageData(of: candidate.item)
            else { return done(false) }
            // Only the optimized form of the bytes this copy wrote: the file can be rewritten after it was read,
            // and the swap must not publish another picture. Only the bytes the encoder made, too: an edit saved
            // over a capture optimized in place, before the swap read it, isn't them (Astra, round 3). Nor the same
            // bytes again.
            let (copied, made) = await Task.detached {
                (ClipboardPasteboardReader.digest(copiedData), ClipboardPasteboardReader.digest(smallerData))
            }.value
            guard candidate.source == copied, let output = candidate.output, made == output, made != copied,
                  !Task.isCancelled else { return done(false) }
            let item = candidate.item
            // The newest copy, if it is still reading or optimizing, would find the pasteboard moved by the swap and
            // give up: wait until it has written, which moves the count and ends this swap, or found it is a repeat
            // of this copy or given up, which leaves the swap to go in. An older copy can't write any more, so the
            // swap doesn't wait for it.
            while pending.contains(latest), pasteboard.changeCount == countAfterWrite, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
            // No suspension between this check and the clear. NSPasteboard has no compare-and-replace, so a
            // window is left: another app that copies between this check and `clearContents` loses its copy
            // to the swap. It is the same window Clop's own swap has, a few instructions wide; anything copied
            // before the check, however late, keeps the original or the newer copy where it is.
            guard !Task.isCancelled, !pending.contains(latest), pasteboard.changeCount == countAfterWrite else { return done(false) }
            let countAfterSwap = pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else { return done(false) }
            if held?.key == key { held = (key, countAfterSwap) }
            // The card this copy was filed on gets the smaller image, so the copy keeps one entry.
            if let id = await card.value { await stack(id, item) }
            return done(true)
        }
        cancelSwap = { swap.cancel() }
        return (.written, swap)
    }

    /// `copyNow`, waited out: whether the smaller item took the original's place.
    func copyThenSwap(to pasteboard: NSPasteboard = .general, first: () async throws -> NSPasteboardItem,
                      smaller: @escaping () async -> Swap?) async throws -> Bool {
        let (outcome, swap) = try await copyNow(to: pasteboard, first: { .init(item: try await first(), key: UUID()) }, smaller: smaller)
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
        pending.insert(mine)
        defer { pending.remove(mine) }
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
        cancelSwap?()
        cancelSwap = nil
        do {
            try write(results.map(\.url))
        } catch {
            results.forEach { $0.discard() }
            throw error
        }
        return results
    }
}
