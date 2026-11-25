import AppKit
import Foundation

extension OptimizerBenchmark {
    static func checkTrashRace(_ input: URL) async throws {
        let store = ScreenshotHistoryStore.shared
        let file = try store.prepareUniqueHistoryURL()
        try FileManager.default.copyItem(at: input, to: file)
        UserDefaults.standard.setVolatileDomain([OptimizePreferences.newCapturesKey: false], forName: UserDefaults.argumentDomain)
        store.registerImportedScreenshot(at: file, pixelSize: ScreenshotImageLoader.imageSize(at: input)!)
        let item = CaptureLibraryScanner.scan(history: store.items.map(CaptureLibraryHistorySnapshot.init),
                                              historyDirectory: ScreenshotHistoryStore.historyDirectory, excludingSessionPath: nil)
            .items.first { $0.fileURL.standardizedFileURL == file.standardizedFileURL }!
        let key = file.standardizedFileURL
        let original = FileIdentity(file)!
        let trash = FileManager.default.homeDirectoryForCurrentUser.appending(path: "deleted.png")
        for shouldFail in [true, false] {
            let result = try await ImageOptimizer.shared.optimize(file)
            precondition(result.outcome == .optimized && result.source == original)
            let (events, gate) = AsyncStream<Void>.makeStream()
            let resume = DispatchSemaphore(value: 0)
            let moving = Task {
                try await CaptureLibraryFiles.trash(item) { source in
                    gate.yield(); gate.finish()
                    guard resume.wait(timeout: .now() + 15) == .success else { throw POSIXError(.ETIMEDOUT) }
                    if shouldFail { throw POSIXError(.EACCES) }
                    try FileManager.default.moveItem(at: source, to: trash)
                    return trash
                }
            }
            for await _ in events { break } // the detached move owns the path but the original is still there
            let installation = CaptureOptimizer.finishInPlace(result, at: file, effort: .balanced, whileEditing: false)
            resume.signal()
            if case .failed = installation {} else { fatalError("Installed a result during Trash") }
            do {
                try await moving.value
                precondition(!shouldFail && FileIdentity(file) == nil && FileIdentity(trash) == original)
                store.removeTrashedItems(ids: item.historyIDs)
                precondition(store.item(for: file) == nil)
            } catch {
                precondition(shouldFail && FileIdentity(file) == original && !OptimizedMark.isCurrent(file))
            }
            precondition(!CaptureLibraryFiles.movingToTrash.contains(key) && FileIdentity(result.url) == nil)
        }
        print("trash-race: failed and successful moves protected")
    }

    /// Use a fixture that actually shrinks (the Retina workload). The oracle is main's copy-only
    /// behavior for scrolling: the production encoder at the requested effort on the original file.
    static func checkCopyRaces(_ input: URL) async throws {
        let store = ScreenshotHistoryStore.shared
        let raw = try Data(contentsOf: input)
        let oracle = try await ImageOptimizer.shared.optimize(input, effort: .balanced)
        defer { oracle.discard() }
        let expected = try Data(contentsOf: oracle.url)
        precondition(expected.count < raw.count)
        func effort(_ value: ImageOptimizationEffort) {
            UserDefaults.standard.setVolatileDomain([OptimizePreferences.effortKey: value.rawValue], forName: UserDefaults.argumentDomain)
        }
        for route in ["pending", "open", "during-read", "upgrade", "upgrade-during-read", "edited", "overtaken"] {
            effort(route == "upgrade" ? .fast : .balanced)
            let file = try store.prepareUniqueHistoryURL()
            try raw.write(to: file)
            store.registerImportedScreenshot(at: file, pixelSize: ScreenshotImageLoader.imageSize(at: input)!)
            if route == "open" { CaptureLibraryOpenEditors.add(file) }
            defer { if route == "open" { CaptureLibraryOpenEditors.remove(file) } }
            if route == "upgrade" {
                let ready = try await waitForMark(file, seconds: 30)
                precondition(ready && OptimizedMark.isCurrent(file, effort: .fast))
                effort(.balanced)
            }
            let ticket = CaptureOptimizer.firstCopy(file)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let copier = OptimizedImageCopy()
            var read: Data?, candidateFile: URL?, temporary: ImageOptimizationResult?
            defer { temporary?.discard() }
            let (action, swap) = try await copier.copyNow(to: board, first: {
                let item = try await ScreenshotFileActions.clipboardItem(for: file)
                read = item.data(forType: .png)
                if ["during-read", "upgrade-during-read"].contains(route) {
                    if route == "upgrade-during-read" { effort(.fast) }
                    let ready = try await waitForMark(file, seconds: 30)
                    precondition(ready && read == raw)
                    effort(.balanced)
                }
                return .init(item: item, key: await OptimizedImageCopy.key(of: item))
            }, smaller: {
                guard let candidate = await ticket(read) else { return nil }
                temporary = candidate.result
                candidateFile = candidate.file
                if route == "edited" { try! raw.write(to: file) }  // between verified install and swap read
                let item = try! await ScreenshotFileActions.clipboardItem(for: candidate.file)
                if route == "overtaken" {
                    board.clearContents()
                    board.setString("newer copy", forType: .string)
                }
                return .init(item: item, source: candidate.source, output: candidate.output)
            })
            let swapped = await swap?.value
            precondition(action == .written)
            if route == "overtaken" {
                precondition(swapped == false && board.string(forType: .string) == "newer copy")
            } else {
                let edited = route == "edited"
                let data = board.data(forType: .png)
                let named = URL(string: board.string(forType: .fileURL)!)!
                let namedData = try Data(contentsOf: named)
                precondition(swapped == !edited && data == (edited ? raw : expected) && data == namedData)
                precondition(named.standardizedFileURL == (edited ? file : candidateFile!).standardizedFileURL)
                if route == "open" {
                    let unchanged = try Data(contentsOf: file)
                    precondition(temporary != nil && unchanged == raw)
                }
                if edited { precondition(!OptimizedMark.isCurrent(file)) }
            }
            print("copy-race", route, "passed")
        }
    }
}
