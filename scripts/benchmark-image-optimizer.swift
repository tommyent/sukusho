import Foundation
import AppKit
import ImageIO

@main enum OptimizerBenchmark {
    static let clock = ContinuousClock()
    static func ms(_ start: ContinuousClock.Instant) -> String {
        let d = (clock.now - start).components
        return String(format: "%.3f", Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
    }

    static func waitForMark(_ url: URL, seconds: Int) async throws -> Bool {
        let until = clock.now + .seconds(seconds)
        while OptimizedMark.originalBytes(of: url) == nil && clock.now < until {
            try await Task.sleep(for: .milliseconds(10))
        }
        return OptimizedMark.isCurrent(url)
    }

    static func main() async throws {
        let home = URL(filePath: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!).standardizedFileURL.path + "/"
        precondition(ScreenshotHistoryStore.historyDirectory.standardizedFileURL.path.hasPrefix(home))
        precondition(ImageOptimizer.shared.outputDirectory.standardizedFileURL.path.hasPrefix(home))
        precondition(Bundle.main.bundleIdentifier == nil && FileManager.default.isExecutableFile(atPath: ImageOptimizer.shared.toolsDirectory.appending(path: "oxipng").path))
        let args = Array(CommandLine.arguments.dropFirst())
        let input = URL(fileURLWithPath: args[1])
        let optimizer = ImageOptimizer.shared
        if args[0] == "paths" {
            for (label, target): (String, ImageOptimizationTarget) in [
                ("same", .lossless), ("webp", .webP(quality: nil)), ("qwebp", .webP(quality: 80)), ("jpeg", .jpeg(quality: 80)),
            ] {
                let start = clock.now
                let result = try await optimizer.optimize(input, to: target)
                defer { result.discard() }
                print(label, input.lastPathComponent, ms(start), result.outcome, result.resultByteCount, FileIdentity(result.url)!.digest)
                if case .failed = result.outcome { throw CocoaError(.fileReadCorruptFile) }
                if args.count == 3 {
                    let dest = URL(fileURLWithPath: args[2]).appending(path: input.lastPathComponent + "-" + label + "." + result.url.pathExtension)
                    try FileManager.default.copyItem(at: result.url, to: dest)
                }
            }
            return
        }
        if args[0] == "shelf" {
            let start = clock.now
            let shelf = ShelfOptimization(files: [input], format: .same, optimizer: optimizer, effort: .balanced) { _ in .lossless }
            while shelf.isWorking { try await Task.sleep(for: .milliseconds(2)) }
            let result = shelf.rows[0].result!
            print("shelf", ms(start), result.outcome, result.resultByteCount, FileIdentity(result.url)!.digest)
            shelf.discard()
            return
        }
        precondition(OptimizePreferences.newCaptures && OptimizePreferences.quietEffort == .balanced)
        let store = ScreenshotHistoryStore.shared
        let start = clock.now
        if ["scroll", "scroll-oracle"].contains(args[0]) {
            let url = try store.prepareUniqueHistoryURL()
            try FileManager.default.copyItem(at: input, to: url)
            store.registerImportedScreenshot(at: url, pixelSize: ScreenshotImageLoader.imageSize(at: input)!)
            let marked = try await waitForMark(url, seconds: args[0] == "scroll" ? 30 : 5)
            print("scroll", ms(start), marked, FileIdentity(url)!.digest)
            if args[0] == "scroll" { precondition(marked) }
            return
        }
        let url = store.importScreenshot(from: input)
        precondition(store.isHistoryURL(url))
        switch args[0] {
        case "background":
            let ready = try await waitForMark(url, seconds: 30)
            precondition(ready)
            print("background", ms(start), FileIdentity(url)!.byteCount, FileIdentity(url)!.digest)
            let copied = clock.now
            let candidate = await CaptureOptimizer.smallerForFirstCopy(url)
            precondition(candidate?.source == nil && candidate?.result == nil)
            print("marked-copy-candidate", ms(copied), candidate?.saving ?? "none")
        case "early", "during":
            if args[0] == "during" { try await Task.sleep(for: .milliseconds(2100)) }
            let copied = clock.now
            let candidate = await CaptureOptimizer.smallerForFirstCopy(url)
            precondition(candidate?.output == FileIdentity(url)?.digest && candidate?.result == nil && OptimizedMark.isCurrent(url))
            print("joined-copy", ms(copied), ms(start), candidate!.saving)
        case "idle", "close":
            CaptureLibraryOpenEditors.add(url)
            let edited = try store.commitAnnotations(displayURL: url, baseURL: url, renderedURL: input,
                                                     document: .init(shapes: [], background: .init()))
            try await Task.sleep(for: .seconds(3))
            precondition(!OptimizedMark.isCurrent(edited))
            if args[0] == "close" { CaptureLibraryOpenEditors.remove(edited) }
            let ready = try await waitForMark(edited, seconds: args[0] == "idle" ? 80 : 30)
            precondition(ready)
            print(args[0], ms(start), FileIdentity(edited)!.digest)
        default: fatalError("Unknown workload")
        }
    }
}
