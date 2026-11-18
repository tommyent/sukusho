//
//  QuickLookPreviewPresenter.swift
//  Screendrop
//
//  Created by Codex on 26/04/26.
//

import AppKit
import QuickLookUI

@MainActor
final class QuickLookPreviewPresenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreviewPresenter()
    
    private var previewURLs: [NSURL] = []
    /// What Quick Look's title bar says for each file: the capture's Library title where it has one, rather than the
    /// stored `screenshot_…` name (Fable #8).
    private var previewTitles: [String?] = []
    private var preparationTask: Task<Void, Never>?
    /// Set when Quick Look itself tucked an expanded stack into its peek tab,
    /// so closing Quick Look expands only a stack it tucked. It records that
    /// first collapse, not later changes: if the stack is expanded and tucked
    /// again by something else while Quick Look stays open, closing still
    /// expands it.
    private var collapsedPreviewStack = false
    /// Whether the open preview came from the Library and not the floating stack.
    private var openedFromLibrary = false
    
    static var isShown: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    private var sourceURLs: [URL] = []
    private weak var libraryWindow: NSWindow?

    static func toggleLibrarySelection(_ urls: [URL]) {
        if shared.openedFromLibrary, shared.sourceURLs == urls {
            dismiss()
        } else if !urls.isEmpty {
            show(urls: urls)
        }
    }

    /// Pass `collapsingPreviewStack: true` when previewing from the floating
    /// stack, so its cards don't sit on top of the Quick Look window.
    static func show(url: URL, collapsingPreviewStack: Bool = false) {
        shared.show(urls: [url], collapsingPreviewStack: collapsingPreviewStack)
    }

    /// Several files, stepped through with the arrow keys as in Finder.
    static func show(urls: [URL]) {
        guard !urls.isEmpty else { return }
        shared.show(urls: urls, collapsingPreviewStack: false)
    }
    
    /// Whether the Library's Quick Look is open, which shows whatever the Library has selected.
    static var followsLibrary: Bool { shared.openedFromLibrary && (isShown || shared.preparationTask != nil) }

    /// The Library's selection changed under its open Quick Look: shows it in
    /// the same panel, as Finder does, and leaves the key window alone.
    static func follow(urls: [URL]) {
        guard followsLibrary else { return }
        guard !urls.isEmpty else { dismiss(); return }
        shared.show(urls: urls, collapsingPreviewStack: false, keepingFocus: isShown)
    }

    static func dismiss() {
        shared.dismiss()
    }
    
    /// What Quick Look can show right away: the fresh render, or the screen
    /// master when no redaction would be missing from it (it lacks the
    /// pointer, camera and edits, but opens without a full encode). Nil
    /// means the recording has to be rendered first: pending redactions, or
    /// edits that can't be read.
    static func immediateURL(for url: URL) -> URL? {
        guard let source = try? RecordingPreviewSource(url), source.redactions.isEmpty else { return nil }
        return source.url
    }

    private func show(urls: [URL], collapsingPreviewStack: Bool, keepingFocus: Bool = false) {
        preparationTask?.cancel()
        preparationTask = nil
        sourceURLs = urls
        openedFromLibrary = !collapsingPreviewStack
        if openedFromLibrary, !keepingFocus {
            libraryWindow = NSApp.windows.first { $0.identifier?.rawValue == "CAPTURE_LIBRARY" }
        }
        if urls.contains(where: { RecordingDeliverable.session(for: $0) != nil }) {
            StudioProjectRegistry.shared.flushDrafts()
        }
        let immediate = urls.map(Self.immediateURL)
        guard immediate.contains(nil) else {
            present(urls: immediate.compactMap { $0 }, collapsingPreviewStack: collapsingPreviewStack, keepingFocus: keepingFocus)
            return
        }
        preparationTask = Task { [weak self] in
            do {
                var prepared: [URL] = []
                for (url, ready) in zip(urls, immediate) {
                    if let ready { prepared.append(ready) } else { prepared.append(try await RecordingDeliverable.resolve(for: url)) }
                }
                guard !Task.isCancelled else { return }
                self?.preparationTask = nil
                self?.present(urls: prepared, collapsingPreviewStack: collapsingPreviewStack, keepingFocus: keepingFocus)
            } catch {
                guard !Task.isCancelled else { return }
                self?.preparationTask = nil
                self?.openedFromLibrary = false
                FailureAlert.present(message: "The recording preview could not be prepared", error: error)
            }
        }
    }

    private func present(urls: [URL], collapsingPreviewStack: Bool, keepingFocus: Bool) {
        // Following the selection never reopens a panel that closed while a recording rendered.
        if keepingFocus, !Self.isShown { return }
        previewURLs = urls.map { $0 as NSURL }
        previewTitles = urls.map(Self.libraryTitle)
        openedFromLibrary = !collapsingPreviewStack
        
        guard let panel = QLPreviewPanel.shared() else {
            restorePreviewStack()
            return
        }

        // Activate the app *before* presenting the panel so macOS considers
        // it the frontmost process. Without this, the QuickLook window opens
        // unfocused and videos won't autoplay until manually clicked.
        if collapsingPreviewStack, !keepingFocus { NSApp.activate() }

        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        // Collapse the floating overlay into the peek tab so it doesn't sit on
        // top of the Quick Look window. Expanded again when Quick Look closes.
        let stack = ScreenshotPreviewStack.shared
        if collapsingPreviewStack, !stack.isCollapsed {
            stack.collapse()
            collapsedPreviewStack = stack.isCollapsed
        }
        if panel.isVisible {
            panel.refreshCurrentPreviewItem()
        } else if openedFromLibrary {
            panel.orderFront(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        guard !keepingFocus, collapsingPreviewStack else { return }

        // Re-assert key status on the next runloop pass. The window server
        // sometimes needs a tick to finish processing the activation, so an
        // immediate makeKey can be silently dropped when the app was inactive.
        DispatchQueue.main.async {
            panel.makeKeyAndOrderFront(nil)
        }
    }
    
    private func dismiss() {
        preparationTask?.cancel()
        preparationTask = nil
        sourceURLs = []
        openedFromLibrary = false
        // Only restore (expand) the overlay if Quick Look is actually on screen.
        // This method doubles as generic cleanup that's called whenever cards are
        // inserted or removed; in those cases there's no Quick Look window to
        // close, and unconditionally expanding would pop the collapsed peek stack
        // back open (e.g. when an auto-close timer fires in peek mode).
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible else {
            previewURLs = []
            return
        }

        panel.orderOut(nil)
        previewURLs = []
        restorePreviewStack()
    }

    /// Fires when Quick Look closes on its own (e.g. the user clicks its close
    /// button or it loses key focus), which bypasses `dismiss()`.
    func windowWillClose(_ notification: Notification) {
        preparationTask?.cancel()
        preparationTask = nil
        previewURLs = []
        sourceURLs = []
        openedFromLibrary = false
        restorePreviewStack()
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        MainActor.assumeIsolated {
            guard openedFromLibrary, sourceURLs.count == 1, event.type == .keyDown,
                  [123, 124, 125, 126].contains(Int(event.keyCode)),
                  let responder = libraryWindow?.firstResponder else { return false }
            responder.keyDown(with: event)
            return true
        }
    }

    /// Expands the stack only if Quick Look tucked it (see `collapsedPreviewStack`).
    private func restorePreviewStack() {
        guard collapsedPreviewStack else { return }
        collapsedPreviewStack = false
        ScreenshotPreviewStack.shared.expand()
    }
    
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            previewURLs.count
        }
    }
    
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            guard previewURLs.indices.contains(index) else { return nil }
            let url = previewURLs[index]
            guard previewTitles.indices.contains(index), let title = previewTitles[index] else { return url }
            return TitledPreviewItem(url: url as URL, title: title)
        }
    }

    /// The Library's title for a capture's file (its name, a model's title, its app and window, or the date), or nil
    /// for a file that isn't a capture.
    private static func libraryTitle(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        return CaptureLibraryModel.shared.items.first { item in
            item.fileURL.standardizedFileURL.path == path || item.ownedURL.standardizedFileURL.path == path
        }?.title
    }
}

/// A file Quick Look shows under a title of its own.
private final class TitledPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL!
    let previewItemTitle: String!

    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
    }
}
