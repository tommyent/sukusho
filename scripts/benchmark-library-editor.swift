import AppKit
import CryptoKit
import ImageIO
import SwiftUI
@testable import Screendrop

// From the worktree root, under heavy: python3 scripts/benchmark-library-editor.py <Release DD> library|editor
@main @MainActor struct LibraryEditorBenchmark {
    static let count = 2048
    static let fixture = URL(fileURLWithPath: "ScreendropTests/Fixtures/capture-library-light.png")
    static let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!, isDirectory: true)
    static let samples = 11

    static func report(_ name: String, _ ns: [UInt64]) {
        let ms = ns.dropFirst().sorted().map { Double($0) / 1e6 }
        print(String(format: "%@ median %.3f ms, p95 %.3f ms", name, ms[ms.count / 2], ms[Int(ceil(0.95 * Double(ms.count))) - 1]))
    }

    static func measure<T>(_ name: String, _ run: () -> T, check: (T) -> Void) {
        var ns: [UInt64] = []
        for _ in 0...samples {
            autoreleasepool {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = run()
                ns.append(DispatchTime.now().uptimeNanoseconds - start)
                check(result)
            }
        }
        report(name, ns)
    }

    static func main() async throws {
        precondition(home.lastPathComponent.hasPrefix("library-editor-"))
        precondition(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL == home.standardizedFileURL)
        precondition(ScreendropStorage.applicationSupportDirectory.path.hasPrefix(home.path + "/"))
        switch CommandLine.arguments.last {
        case "library": try await library()
        case "first-library":
            let ns = try await libraryReady(reload: false)
            precondition(CaptureLibraryModel.shared.visibleItems.count == count - (count + 10) / 11)
            print(ns)
        case "editor": try editor()
        default: fatalError("Choose library or editor")
        }
    }

    static func libraryReady(reload: Bool) async throws -> UInt64 {
        let start = DispatchTime.now().uptimeNanoseconds
        if reload { ScreenshotHistoryStore.shared.reload() }
        let model = CaptureLibraryModel.shared
        model.refresh()
        let deadline = ContinuousClock.now + .seconds(30)
        while model.isLoading {
            precondition(ContinuousClock.now < deadline, "Library scan did not finish")
            try await Task.sleep(for: .milliseconds(1))
        }
        return DispatchTime.now().uptimeNanoseconds - start
    }

    static func library() async throws {
        let directory = ScreenshotHistoryStore.historyDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Only file existence and metadata are read by these paths.
        let tile = home.appendingPathComponent("tile.png")
        try FileManager.default.copyItem(at: fixture, to: tile)
        var rows: [ScreenshotHistoryItem] = []
        var saved: [String: Date] = [:]
        for i in 0..<count {
            let date = Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(i * 3600))
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", i))!
            let app = i % 3 == 0 ? "Safari" : "Mail"
            let video = i % 8 == 0
            var item = ScreenshotHistoryItem(id: id, createdAt: date, updatedAt: date,
                fileName: "capture_\(i).\(video ? "mov" : "png")", pixelWidth: 2560, pixelHeight: 1600,
                kind: video ? .video : .image, duration: video ? 15 : nil,
                displayName: i % 13 == 0 ? "Review \(i)" : nil, source: i % 3 == 2 ? nil :
                    CaptureSource(bundleIdentifier: "com.apple.\(app)", appName: app, windowTitle: "Project \(i)"))
            if i % 10 == 0 { item.tags = ["Design"] }
            if i % 11 == 0 { saved[id.uuidString] = date }
            try FileManager.default.linkItem(at: tile, to: directory.appendingPathComponent(item.fileName))
            rows.append(item)
        }
        let support = directory.deletingLastPathComponent()
        let indexURL = support.appendingPathComponent("history.json")
        try JSONEncoder().encode(Array(rows.reversed())).write(to: indexURL)
        try JSONEncoder().encode(saved).write(to: support.appendingPathComponent("library-saved.json"))
        let history = ScreenshotHistoryStore.shared
        let model = CaptureLibraryModel.shared
        let all = rows.indices.reversed().filter { $0 % 11 != 0 }
        func ids(_ indices: [Int]) -> [String] { indices.map { rows[$0].id.uuidString } }
        let everyday = ids(all), recordings = ids(all.filter { $0 % 8 == 0 })
        let fromSafari = ids(all.filter { $0 % 3 == 0 }), tagged = ids(all.filter { $0 % 10 == 0 })
        var reload: [UInt64] = []
        for _ in 0...samples {
            reload.append(try await libraryReady(reload: true))
            precondition(model.visibleItems.map(\.id) == everyday)
        }
        report("History reload → All Captures model ready", reload)
        measure("History reload only", { history.reload() }) { precondition(history.items.count == count) }
        measure("History JSON load only", {
            var metadata = ScreenshotHistoryMetadata<ScreenshotHistoryItem>()
            return metadata.load(from: indexURL)
        }) { precondition($0.count == count) }
        // The setter performs the complete synchronous filter/sort/reconciliation.
        // Restore the prior page in check(), outside the timed interval.
        model.filter = .recordings
        measure("Recordings → All Captures", { model.filter = .all }) {
            precondition(model.visibleItems.map(\.id) == everyday)
            model.filter = .recordings
            precondition(model.visibleItems.map(\.id) == recordings)
        }
        model.filter = .all
        func search(_ query: String, ids: [String]) {
            measure("Search \(query) (model work)", {
                model.searchText = query
                model.textIndexDidChange() // same update as after the search field's debounce
            }) {
                precondition(model.visibleItems.map(\.id) == ids)
                model.searchText = ""
                model.filter = .all
            }
        }
        search("app:safari", ids: fromSafari)
        search("design", ids: tagged)
        model.searchText = "app:"
        model.filter = .all
        precondition(model.visibleItems.map(\.id) == everyday)
        LibrarySavedModel.shared.isShown = true
        model.tagFilter = "Design"
        precondition(model.visibleItems.map(\.id) == ids(rows.indices.reversed().filter { $0 % 110 == 0 }))

        let page = Array(model.items.lazy.filter { !$0.isVideo }.prefix(24))
        let cache = CaptureLibraryThumbnails(disk: .init(directory: home.appendingPathComponent("thumbnails")))
        var thumbnails: [UInt64] = []
        for _ in 0...samples {
            let start = DispatchTime.now().uptimeNanoseconds
            await withTaskGroup(of: Bool.self) { group in
                for item in page {
                    group.addTask { await cache.image(for: item, maxPixelSize: 320)?.width == 320 }
                }
                for await ok in group { precondition(ok) }
            }
            thumbnails.append(DispatchTime.now().uptimeNanoseconds - start)
        }
        report("24 memory-warm Library thumbnails", thumbnails)
    }

    static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        precondition(CGImageDestinationFinalize(dest))
        return data as Data
    }

    static func editor() throws {
        let tile = ScreenshotImageLoader.uprightImage(at: fixture)!
        for (w, h) in [(3840, 2160), (5120, 2880)] {
            let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for y in stride(from: 0, to: h, by: tile.height) {
                for x in stride(from: 0, to: w, by: tile.width) {
                    context.draw(tile, in: CGRect(x: x, y: y, width: tile.width, height: tile.height))
                }
            }
            let file = home.appendingPathComponent("editor-\(w).png")
            try png(context.makeImage()!).write(to: file)
            func load() -> AnnotationEditorModel {
                let editor = AnnotationEditorModel()
                editor.load(url: file, dismiss: EnvironmentValues().dismiss)
                return editor
            }
            measure("\(w) PNG → editor model ready", load) { model in
                precondition(model.previewCGImage?.width == 2880 && model.previewCGImage?.height == 1620)
                model.releaseEditorResources()
            }
            func digest() -> String {
                let editor = load()
                defer { editor.releaseEditorResources() }
                return SHA256.hash(data: png(editor.previewCGImage!)).map { String(format: "%02x", $0) }.joined()
            }
            print("Opaque \(w) preview PNG SHA256 \(digest())")
            // A single translucent pixel near the end must still select straight-colour scaling.
            context.clear(CGRect(x: w - 2, y: 0, width: 1, height: 1))
            try png(context.makeImage()!).write(to: file)
            print("Late alpha \(w) preview PNG SHA256 \(digest())")
            let export = home.appendingPathComponent("export.png")
            let box = AnnoShape(id: AnnoShapeID("benchmark-box"), x: 100, y: 40, kind: .geo(GeoProps()))
            try AnnotationRenderer.render(sourceURL: file, shapes: [box], bindings: [], destinationURL: export, contentType: .png)
            let hash = SHA256.hash(data: try Data(contentsOf: export))
            print("Annotated \(w) export PNG SHA256 " + hash.map { String(format: "%02x", $0) }.joined())
        }
    }
}
