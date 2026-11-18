import AppKit

extension CaptureLibraryModel {
    /// Preserve display order through preparation. One selection publishes once, including mixed Saved cards.
    func copySelection(_ cards: [LibrarySavedCard], original: Bool) {
        guard !cards.isEmpty else { return }
        let initialChange = NSPasteboard.general.changeCount
        run("Copying…") {
            StudioProjectRegistry.shared.flushDrafts()
            if cards.count == 1, case .capture(let item) = cards[0], !item.isVideo {
                let saving = try await ScreenshotFileActions.copyImageToClipboard(from: item.fileURL, original: original)
                self.actionFeedback.show(original ? "Copied Original" : saving.map { "Copied · \($0)" } ?? "Copied")
                return
            }
            var captures: [CaptureLibraryItem] = []
            var clipItems: [String: [NSPasteboardItem]] = [:]
            for card in cards {
                switch card {
                case .capture(let capture): captures.append(capture)
                case .clip(let entry):
                    if entry.kind == .image, let url = entry.imageFileURL {
                        let item = try await ScreenshotClipboardImage.item(from: url, dataType: ClipboardWriter.imageType(for: url),
                                                                          includeTIFF: ScreendropPreferences.copyTIFF && cards.count == 1)
                        ClipboardWriter.mark(item, source: entry.sourceBundleID)
                        clipItems[card.id] = [item]
                    } else {
                        let rich = try await ClipboardMonitor.shared.store?.richText(for: entry.id) ?? [:]
                        guard let items = ClipboardWriter.items(for: entry, richText: rich, plain: false) else {
                            throw CocoaError(.fileNoSuchFile)
                        }
                        clipItems[card.id] = items
                    }
                }
            }
            guard NSPasteboard.general.changeCount == initialChange else { return }
            let videos = Set(captures.filter(\.isVideo).map(\.fileURL))
            let optimize = !original && OptimizePreferences.whenCopying
            let copied = try await OptimizedImageCopy.shared.copyAll(captures.map(\.fileURL), ready: { url in
                if videos.contains(url) { return .original(try await RecordingDeliverable.resolve(for: url)) }
                return optimize ? try await ScreenshotFileActions.optimizedForCopy(url) : .original(url)
            }, write: { files in
                try VideoFileActions.withClipboardSnapshots(of: files) { snapshots in
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
                    let board = NSPasteboard.general
                    board.clearContents()
                    guard board.writeObjects(payload) else { throw CocoaError(.fileWriteUnknown) }
                }
            })
            guard let copied else { return }
            copied.forEach { $0.discard() }
            self.actionFeedback.show(cards.count == 1 ? "Copied" : "\(cards.count) Items Copied")
        }
    }
}
