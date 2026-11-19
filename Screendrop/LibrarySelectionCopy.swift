import AppKit

extension CaptureLibraryModel {
    /// Preserve display order through preparation. One selection publishes once, including mixed Saved cards.
    func copySelection(_ cards: [LibrarySavedCard], original: Bool = false, plain: Bool = false) {
        // `run` takes no operation while another one runs, so this copy is asked for only when it isn't busy.
        guard !cards.isEmpty, !isBusy else { return }
        // The copy's turn is taken now, as it is asked for, before the task starts and the clip cards are read:
        // anything copied from here on, a repeat of the clipboard's image included, is newer, and this copy doesn't
        // land after it (Astra, round 4).
        let turn = OptimizedImageCopy.shared.takeTurn()
        run("Copying…") {
            defer { OptimizedImageCopy.shared.finish(turn) }
            StudioProjectRegistry.shared.flushDrafts()
            if cards.count == 1, case .capture(let item) = cards[0], !item.isVideo {
                let copied = try await ScreenshotFileActions.copyImageToClipboard(from: item.fileURL, original: original,
                                                                                turn: turn) { saving, bytes in
                    self.actionFeedback.show("Copied · \(saving) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                }
                // Not when something newer reached the clipboard while the image was read: nothing was copied.
                guard copied else { return }
                self.actionFeedback.show(original ? "Copied Original" : "Copied")
                return
            }
            var captures: [CaptureLibraryItem] = []
            var clipItems: [String: [NSPasteboardItem]] = [:]
            for card in cards {
                switch card {
                case .capture(let capture): captures.append(capture)
                case .clip(let entry):
                    let rich = try await ClipboardMonitor.shared.store?.richText(for: entry.id) ?? [:]
                    clipItems[card.id] = try await ClipboardWriter.libraryItems(for: entry, richText: rich, plain: plain,
                        includeTIFF: ScreendropPreferences.copyTIFF && cards.count == 1)
                }
            }
            let videos = Set(captures.filter(\.isVideo).map(\.fileURL))
            let optimize = !original && OptimizePreferences.whenCopying
            // Nil, with nothing written, when something newer was copied meanwhile.
            let copied = try await OptimizedImageCopy.shared.copyAll(captures.map(\.fileURL), turn: turn, ready: { url in
                if videos.contains(url) { return .original(try await RecordingDeliverable.resolve(for: url)) }
                return optimize ? try await ScreenshotFileActions.optimizedForCopy(url) : .original(url)
            }, write: { files, publish in
                try ClipboardFiles.withClipboardSnapshots(of: files) { snapshots in
                    var files = snapshots.makeIterator()
                    var payload: [NSPasteboardWriting] = []
                    for card in cards {
                        switch card {
                        case .capture:
                            guard let url = files.next() else { throw CocoaError(.fileReadUnknown) }
                            payload.append(url as NSURL)
                        case .clip:
                            guard let items = clipItems[card.id] else { throw CocoaError(.fileReadUnknown) }
                            payload.append(contentsOf: items)
                        }
                    }
                    // Written only if nothing was copied while the snapshots were made; otherwise it throws, and the
                    // snapshots go (Astra, round 5).
                    try publish(payload)
                }
            })
            guard let copied else { return }
            copied.forEach { $0.discard() }
            if cards.contains(where: { $0.clipEntry?.isArchived == true }), let store = ClipboardMonitor.shared.store {
                for card in cards {
                    if let entry = card.clipEntry, let items = clipItems[card.id],
                       let replay = ClipboardPasteboardReader.archiveCopy(entry, items: items, historyDirectory: ScreenshotHistoryStore.historyDirectory) {
                        try await store.record(replay)
                    }
                }
                ClipboardHistoryModel.shared.refresh()
            }
            self.actionFeedback.show(cards.count == 1 ? "Copied" : "\(cards.count) Items Copied")
        }
    }
}
