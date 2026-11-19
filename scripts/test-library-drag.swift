// Compile against the Debug Dev product as in test-library-card-press.swift. Run in an isolated home.
import AppKit
import SwiftUI
@testable import Screendrop

private let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Sukusho-drag-\(UUID())", isDirectory: true)

extension FileManager {
    // Foundation's per-user temp directory can ignore TMPDIR, even in a disposable home.
    @objc fileprivate var dragTestTemporaryDirectory: URL { fixtureDirectory }
}

@MainActor private var sessions: [[NSPasteboardWriting]] = []

extension NSView {
    // Intercept the handoff to WindowServer. The collection still owns hit testing, tracking,
    // selection, the movement threshold, and construction of every dragging item.
    @objc fileprivate func recordLibraryDrag(_ items: [NSDraggingItem], event: NSEvent,
                                             source: NSDraggingSource) -> NSDraggingSession {
        LibraryDragTest.require(items.allSatisfy { !$0.draggingFrame.isEmpty }, "missing drag image frame")
        sessions.append(items.map { $0.item as! NSPasteboardWriting })
        return NSDraggingSession()
    }
}

@MainActor private final class TestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@main @MainActor struct LibraryDragTest {
    nonisolated static func require(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }

    static func collection(in view: NSView) -> LibraryCollectionView? {
        if let collection = view as? LibraryCollectionView { return collection }
        return view.subviews.lazy.compactMap { collection(in: $0) }.first
    }

    static func gesture(on index: Int, distance: CGFloat, flags: NSEvent.ModifierFlags = [], clicks: Int = 1,
                        title: Bool = false, collection: LibraryCollectionView, root: NSView) {
        let window = root.window!
        let path = IndexPath(item: index, section: 0)
        let cell = collection.item(at: path) as! LibraryCollectionItem
        let frame = collection.collectionViewLayout!.layoutAttributesForItem(at: path)!.frame
        var origin = collection.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        if title {
            guard let text = stride(from: frame.minY, through: frame.maxY, by: 2).lazy.flatMap({ y in
                stride(from: frame.minX, through: frame.maxX, by: 2).map { collection.convert(NSPoint(x: $0, y: y), to: nil) }
            }).first(where: cell.titleContains) else { print("FAIL missing title frame"); exit(1) }
            origin = text
        }
        let card = root.hitTest(root.superview!.convert(origin, from: nil))!
        func event(_ kind: NSEvent.EventType, _ dx: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: kind, location: NSPoint(x: origin.x + dx, y: origin.y),
                               modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                               clickCount: clicks, pressure: 1)!
        }
        let down = event(.leftMouseDown, 0)
        NSApp.postEvent(event(.leftMouseUp, distance), atStart: true)
        if distance > 0 { NSApp.postEvent(event(.leftMouseDragged, distance), atStart: true) }
        _ = collection.trackMouseEvent(down)
        card.mouseDown(with: down)
        while let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast,
                                          inMode: .default, dequeue: true) {
            _ = collection.trackMouseEvent(event)
            if event.type == .leftMouseDragged { card.mouseDragged(with: event) }
            else { card.mouseUp(with: event) }
        }
        require(!cell.isPressed, "card stayed pressed after \(distance)-point motion, \(clicks) click(s)")
    }

    static func files(in session: [NSPasteboardWriting]) -> [URL] {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        require(board.writeObjects(session), "pasteboard refused dragging items")
        return board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    static func writeError(_ start: (@escaping @Sendable (Error?) -> Void) -> Void) -> NSError? {
        var finished = false
        var result: NSError?
        start { error in
            DispatchQueue.main.async {
                result = error as NSError?
                finished = true
            }
        }
        let deadline = Date().addingTimeInterval(3)
        while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        require(finished, "file write timed out")
        return result
    }

    static func checkSaveCollision(in folder: URL) throws {
        let source = folder.appendingPathComponent("source.mov")
        let destination = folder.appendingPathComponent("existing.mov")
        let incoming = Data("incoming recording".utf8)
        let existing = Data("existing destination".utf8)
        try incoming.write(to: source)
        try existing.write(to: destination)
        func drop(at url: URL) -> NSError? {
            writeError { complete in
                Task {
                    do {
                        try await VideoFileActions.save(from: source, to: url, replacingExisting: false)
                        complete(nil)
                    } catch { complete(error) }
                }
            }
        }
        let error = drop(at: destination)
        require(try Data(contentsOf: destination) == existing, "exclusive save replaced the existing bytes")
        require(error?.domain == NSPOSIXErrorDomain && error?.code == Int(EEXIST), "exclusive save must return EEXIST")
        print("PASS occupied name returned EEXIST and kept its original bytes")
        let free = folder.appendingPathComponent("free.mov")
        let freeError = drop(at: free)
        require(freeError == nil, "drop on a free name failed: \(String(describing: freeError))")
        require(try Data(contentsOf: free) == incoming, "drop on a free name delivered the wrong bytes")
        print("PASS free name received the recording")
        let save = writeError { complete in
            Task {
                do {
                    try await VideoFileActions.save(from: source, to: destination)
                    complete(nil)
                } catch { complete(error) }
            }
        }
        require(save == nil, "ordinary Save failed")
        require(try Data(contentsOf: destination) == incoming, "ordinary Save did not replace the file")
        print("PASS save-level collision, EEXIST, byte preservation and ordinary Save")
    }

    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--save-volume" {
            let mount = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let folder = mount.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            try checkSaveCollision(in: folder)
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            require(Set(names.filter { !$0.hasPrefix("._") }) == ["source.mov", "existing.mov", "free.mov"],
                    "save left unexpected files: \(names)")
            return
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original = class_getInstanceMethod(NSView.self, #selector(NSView.beginDraggingSession(with:event:source:)))!
        let recorder = class_getInstanceMethod(NSView.self, #selector(NSView.recordLibraryDrag(_:event:source:)))!
        method_exchangeImplementations(original, recorder)
        defer { method_exchangeImplementations(original, recorder) }

        let folder = fixtureDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        atexit { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let systemTemp = class_getInstanceMethod(FileManager.self, #selector(getter: FileManager.temporaryDirectory))!
        let testTemp = class_getInstanceMethod(FileManager.self, #selector(getter: FileManager.dragTestTemporaryDirectory))!
        method_exchangeImplementations(systemTemp, testTemp)
        defer { method_exchangeImplementations(systemTemp, testTemp) }
        require(FileManager.default.temporaryDirectory == folder, "snapshot directory escaped the fixture")
        try checkSaveCollision(in: folder)
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z4xkAAAAASUVORK5CYII=")!
        let url = folder.appendingPathComponent("history-id.png")
        try bytes.write(to: url)
        let date = Date()
        func clip(_ kind: ClipboardEntryKind, text: String? = nil) -> ClipboardEntry {
            ClipboardEntry(id: kind.rawValue, kind: kind, text: text, title: nil, imageURL: kind == .image ? url : nil,
                           byteSize: bytes.count, pixelWidth: 1, pixelHeight: 1, sourceBundleID: nil, isRemote: false,
                           firstCopiedAt: date, lastCopiedAt: date, timesCopied: 1, pinnedAt: date)
        }
        let image = clip(.image)
        func capture(_ file: URL, name: String, session: RecordingSession? = nil) -> LibrarySavedCard {
            .capture(CaptureLibraryItem(id: file.path, historyIDs: [], name: name, customName: name,
                        fileURL: file, session: session, createdAt: date, modifiedAt: date, pixelWidth: 1,
                        pixelHeight: 1, duration: nil, isVideo: session != nil, hasEdits: false, hasDraft: false,
                        cloudURL: "https://example.invalid", tags: [], thumbnailKey: file.path))
        }
        @discardableResult
        func check(_ cards: [LibrarySavedCard], selection: Set<Int> = [], on index: Int, distance: CGFloat,
                   flags: NSEvent.ModifierFlags = [], clicks: Int = 1, title: Bool = false,
                   expected: Set<Int>? = nil, capturesPage: Bool = false) -> [CaptureLibraryAction] {
            let chosen = selection.map { cards[$0] }
            ClipboardHistoryModel.shared.librarySelectionIDs = Set(chosen.compactMap(\.clipID))
            CaptureLibraryModel.shared.selection = Set(chosen.compactMap(\.captureID))
            let page: AnyView
            if capturesPage {
                page = AnyView(LibraryCaptureCollection(items: cards.compactMap(\.captureItem), layout: .grid,
                                                        cardWidth: 180, model: CaptureLibraryModel.shared))
            } else {
                page = AnyView(LibraryClipCollection(cards: cards, cardWidth: 180, layout: .grid,
                                                     sections: [], isSavedPage: true))
            }
            let root = NSHostingView(rootView: page)
            let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 400),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.10))
            root.layoutSubtreeIfNeeded()
            let grid = collection(in: root)!
            grid.layoutSubtreeIfNeeded()
            require(grid.selectionIndexPaths == Set(selection.map { IndexPath(item: $0, section: 0) }), "initial selection")
            var commands: [CaptureLibraryAction] = []
            grid.command = { commands.append($0) }
            gesture(on: index, distance: distance, flags: flags, clicks: clicks, title: title, collection: grid, root: root)
            if title { RunLoop.main.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.05)) }
            if let expected {
                require(grid.selectionIndexPaths == Set(expected.map { IndexPath(item: $0, section: 0) }),
                        "click selected \(grid.selectionIndexPaths), expected \(expected)")
            }
            return commands
        }
        let cards: [LibrarySavedCard] = [.clip(image), capture(url, name: "Renamed shot")]
        check(cards, on: 0, distance: 32)
        require(sessions.count == 1 && files(in: sessions[0]).count == 1, "clipboard image control did not start a file drag")
        print("PASS clipboard image control")
        check(cards, on: 1, distance: 1, expected: [1])
        require(sessions.count == 1, "small motion should select")
        check(cards, selection: [1], on: 1, distance: 32)
        require(sessions.count == 2, "saved screenshot did not request a drag session")
        let urls = files(in: sessions[1])
        require(urls.map(\.lastPathComponent) == ["Renamed shot.png"], "wrong capture file: \(urls)")
        require(try Data(contentsOf: urls[0]) == bytes, "wrong capture bytes")
        check(cards, selection: [0, 1], on: 1, distance: 32)
        require(sessions.count == 3, "no multi-selection drag")
        let multiple = files(in: sessions[2])
        require(multiple.count == 2 && Set(multiple.map(\.lastPathComponent)) == Set([urls[0].lastPathComponent, files(in: sessions[0])[0].lastPathComponent]),
                "mixed selection lost files: \(multiple)")
        let other = folder.appendingPathComponent("second.txt")
        try Data("other".utf8).write(to: other)
        check([.clip(clip(.files, text: "\(url.path)\n\(other.path)")), .clip(clip(.snippet, text: "snippet")), .clip(clip(.text, text: "plain"))],
              selection: [0, 1, 2], on: 0, distance: 32)
        require(sessions.count == 4, "no file group drag")
        let group = files(in: sessions[3])
        require(group.count == 4 && group.contains(url) && group.contains(other), "clipboard group lost files: \(group)")
        let texts = group.filter { $0.lastPathComponent == "Text.txt" }
        let clipboard = folder.appending(path: "\(ScreendropStorage.directoryName)/Clipboard", directoryHint: .isDirectory)
        let roots = texts.map { $0.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path }
        require(roots == Array(repeating: clipboard.standardizedFileURL.path, count: 2),
                "text and snippet snapshots must be under the app's Clipboard folder")
        require(try Set(texts.map { try String(contentsOf: $0, encoding: .utf8) }) == ["plain", "snippet"], "text and snippet contents")

        let session = RecordingSession(directoryURL: folder.appendingPathComponent("Project.sukushorec", isDirectory: true))
        try FileManager.default.createDirectory(at: session.directoryURL, withIntermediateDirectories: false)
        try Data("raw".utf8).write(to: session.screenURL)
        var manifest = CaptureManifest()
        manifest.pointerSynthesized = true
        try session.writeCaptureManifest(manifest)
        let movie = capture(session.screenURL, name: "Movie", session: session)
        check([movie], on: 0, distance: 32)
        require(sessions.count == 5 && sessions[4].count == 1, "no recording drag")
        guard let promise = sessions[4][0] as? NSFilePromiseProvider, let delegate = promise.delegate else {
            print("FAIL: unrendered recording must promise the deliverable"); exit(1)
        }
        let name = delegate.filePromiseProvider(promise, fileNameForType: promise.fileType)
        require(["Movie.mov", "Movie.mp4"].contains(name), "wrong promised name: \(name)")
        let destination = folder.appendingPathComponent(name)
        let fixture = folder.appendingPathComponent("flattened." + destination.pathExtension)
        let flattened = Data("flattened with pointer".utf8)
        try flattened.write(to: fixture)
        _ = try session.installFinalVideo(movingFrom: fixture)
        let occupied = Data("earlier drop".utf8)
        try occupied.write(to: destination)
        let collision = writeError { delegate.filePromiseProvider(promise, writePromiseTo: destination, completionHandler: $0) }
        require(collision?.domain == NSPOSIXErrorDomain && collision?.code == Int(EEXIST), "promise must return EEXIST")
        require(try Data(contentsOf: destination) == occupied, "promise replaced the earlier drop")
        let empty = folder.appendingPathComponent("new." + destination.pathExtension)
        let write = writeError { delegate.filePromiseProvider(promise, writePromiseTo: empty, completionHandler: $0) }
        require(write == nil, "recording promise failed: \(String(describing: write))")
        require(try Data(contentsOf: empty) == flattened, "promise exposed raw footage")
        check([movie], on: 0, distance: 32)
        require(sessions.count == 6, "no cached recording drag")
        let cached = files(in: sessions[5])
        require(cached.count == 1 && cached[0].lastPathComponent == name, "wrong ready movie: \(cached)")
        require(try Data(contentsOf: cached[0]) == flattened, "ready movie exposed raw footage")
        print("PASS grouped files, snippet, deferred recording and ready recording")
        print("PASS capture threshold, named screenshot bytes, mixed selection and press release")
        check(cards, on: 1, distance: 0, expected: [1])
        check(cards, selection: [0], on: 1, distance: 0, flags: [.command], expected: [0, 1])
        check(cards, selection: [0], on: 1, distance: 0, flags: [.shift], expected: [0, 1])
        require(check(cards, selection: [1], on: 1, distance: 0, clicks: 2) == [.edit], "double-click edit")
        require(check(cards, selection: [1], on: 1, distance: 0, title: true) == [.rename], "single-click rename")
        require(check(cards, selection: [1], on: 1, distance: 32, title: true).isEmpty, "drag renamed the card")
        require(sessions.count == 7, "expected one title drag")
        print("PASS plain, command, shift, double click, title rename and title drag")
        check([capture(url, name: "Captures page")], on: 0, distance: 32, capturesPage: true)
        require(sessions.count == 8, "Captures page did not request a drag session")
        let capturesPageFiles = files(in: sessions[7])
        require(capturesPageFiles.map(\.lastPathComponent) == ["Captures page.png"], "wrong file from Captures page")
        require(try Data(contentsOf: capturesPageFiles[0]) == bytes, "wrong bytes from Captures page")
        print("PASS Captures-page card, Clipboard snapshot paths and promise collision")
    }
}
