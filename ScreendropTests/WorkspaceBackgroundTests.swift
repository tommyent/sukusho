import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@MainActor
struct WorkspaceBackgroundTests {
    @Test func onlyAWallpaperGivesWayToReduceTransparencyAndIncreaseContrast() {
        for style in WorkspaceBackground.Style.allCases {
            #expect(WorkspaceBackground.shown(style, reduceTransparency: false, increaseContrast: false) == style)
        }
        #expect(WorkspaceBackground.shown(.wallpaper, reduceTransparency: true, increaseContrast: false) == .plain)
        #expect(WorkspaceBackground.shown(.wallpaper, reduceTransparency: false, increaseContrast: true) == .plain)
        #expect(WorkspaceBackground.shown(.dots, reduceTransparency: true, increaseContrast: true) == .dots)
        #expect(WorkspaceBackground.Style.allCases.map(\.title) == ["Dots", "Plain", "Wallpaper"])
    }

    @Test func dimIsHalfAsMuchAgainInDarkModeAndStaysInRange() {
        #expect(WorkspaceBackground.defaultDim == 0.3)
        #expect(WorkspaceBackground.dimOpacity(0.3, dark: false) == 0.3)
        #expect(abs(WorkspaceBackground.dimOpacity(0.3, dark: true) - 0.45) < 1e-9)
        #expect(WorkspaceBackground.dimOpacity(-1, dark: true) == 0)
        #expect(WorkspaceBackground.dimOpacity(5, dark: false) == 0.8)
        #expect(WorkspaceBackground.dimOpacity(5, dark: true) == 0.9)
    }

    @Test func photosDecodeAtTheWindowsPixelSizeAndNeverLarger() {
        // A 15-inch Air's full-screen window, 2880 x 1864 px, rounds up to 3072 x 2048.
        let window = WorkspaceBackground.bucketed(CGSize(width: 2880, height: 1864))
        #expect(window == CGSize(width: 3072, height: 2048))
        #expect(WorkspaceBackground.bucketed(CGSize(width: 2900, height: 1900)) == window) // a small resize decodes nothing
        let sixK = CGSize(width: 6144, height: 3456)
        // The height decides: 6144 x 2048 / 3456 = 3640.9.
        #expect(WorkspaceBackground.decodeSize(image: sixK, bounds: window, blurred: false) == 3641)
        #expect(WorkspaceBackground.decodeSize(image: sixK, bounds: window, blurred: true) == 911)
        // A portrait photo: the width decides, 6000 x 3072 / 4000 = 4608.
        #expect(WorkspaceBackground.decodeSize(image: CGSize(width: 4000, height: 6000), bounds: window, blurred: false) == 4608)
        #expect(WorkspaceBackground.decodeSize(image: CGSize(width: 800, height: 600), bounds: window, blurred: false) == 800)
        #expect(WorkspaceBackground.decodeSize(image: .zero, bounds: window, blurred: false) == 0)
    }

    @Test func aWallpapersSizeComesFromItsHeaderTurnedByItsOrientation() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = Self.image(width: 300, height: 200, red: 0.2)
        let plain = directory.appendingPathComponent("plain.png")
        try Self.write(image, to: plain, type: .png)
        let turned = directory.appendingPathComponent("turned.jpg")
        try Self.write(image, to: turned, type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let text = directory.appendingPathComponent("notes.png")
        try Data("not an image".utf8).write(to: text)

        #expect(WorkspaceBackground.pixelSize(of: plain) == CGSize(width: 300, height: 200))
        #expect(WorkspaceBackground.pixelSize(of: turned) == CGSize(width: 200, height: 300))
        // A deleted or unreadable wallpaper has no size, and the workspace shows Dots.
        #expect(WorkspaceBackground.pixelSize(of: directory.appendingPathComponent("deleted.png")) == nil)
        #expect(WorkspaceBackground.pixelSize(of: text) == nil)
    }

    /// Every Add keeps Sukusho's own copy: the bytes are copied, a taken name
    /// gets `_2`, and a file already in the folder isn't copied again.
    @Test func addedWallpapersAreCopiedIntoTheWallpapersFolder() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let picked = directory.appendingPathComponent("Desk photo.png")
        try Self.write(Self.image(width: 40, height: 30, red: 0.7), to: picked, type: .png)
        let wallpapers = directory.appendingPathComponent("Wallpapers", isDirectory: true)

        let first = try AnnotationWallpaperStore.copy(picked, into: wallpapers)
        #expect(first.lastPathComponent == "Desk photo.png")
        #expect(first.deletingLastPathComponent().standardizedFileURL == wallpapers.standardizedFileURL)
        #expect(try Data(contentsOf: first) == Data(contentsOf: picked))
        let second = try AnnotationWallpaperStore.copy(picked, into: wallpapers)
        #expect(second.lastPathComponent == "Desk photo_2.png")
        #expect(try AnnotationWallpaperStore.copy(first, into: wallpapers) == first.standardizedFileURL)
        // The copy outlives the original.
        try FileManager.default.removeItem(at: picked)
        #expect(WorkspaceBackground.pixelSize(of: first) == CGSize(width: 40, height: 30))
        #expect(try FileManager.default.contentsOfDirectory(atPath: wallpapers.path).sorted()
            == ["Desk photo.png", "Desk photo_2.png"])
    }

    /// The workspace wallpaper is drawn only behind the windows' content: the
    /// export (PNG and JPEG), the file Copy and Upload send, Copy's clipboard
    /// item and an Agent Prompt's stills and strips are the same bytes with it on.
    @Test func exportsCopyUploadAndAgentPromptStillsAreTheSameWithAWallpaperOn() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = directory.appendingPathComponent("capture.png")
        try Self.write(Self.image(width: 320, height: 200, red: 0.9), to: capture, type: .png)
        // The screenshot's own background is a wallpaper too, so a mix-up would show.
        let screenshotWallpaper = directory.appendingPathComponent("screenshot-wallpaper.png")
        try Self.write(Self.image(width: 640, height: 400, red: 0.1), to: screenshotWallpaper, type: .png)
        let workspaceWallpaper = directory.appendingPathComponent("workspace-wallpaper.png")
        try Self.write(Self.image(width: 640, height: 400, red: 0.5), to: workspaceWallpaper, type: .png)
        var background = AnnotationBackgroundSettings()
        background.style = .customWallpaper(AnnotationCustomWallpaper(url: screenshotWallpaper))
        var box = GeoProps(); box.w = 120; box.h = 80
        let shapes = [AnnoShape(x: 60, y: 40, kind: .geo(box))]
        let movie = directory.appendingPathComponent("recording.mov")
        try await RecordingAgentPromptTests().makeMovie(at: movie)
        let plan = RecordingAgentPromptPlan(title: "Workspace", timeline: .full(sourceDuration: 3), cues: [], words: [],
            capture: PointerCaptureFile(travel: [.init(time: 0, x: 0.25, y: 0.5), .init(time: 0.9, x: 0.75, y: 0.5)],
                                        presses: [.init(time: 0.9, x: 0.75, y: 0.5, button: 0, phase: .down)]))

        func outputs(_ name: String) async throws -> [String: Data] {
            var files: [String: Data] = [:]
            for type in [UTType.png, .jpeg] {
                let export = directory.appendingPathComponent("\(name)-export.\(type.preferredFilenameExtension!)")
                try AnnotationRenderer.render(sourceURL: capture, shapes: shapes, bindings: [], backgroundSettings: background,
                                              destinationURL: export, contentType: type)
                files["export.\(type.identifier)"] = try Data(contentsOf: export)
            }
            let sent = try AnnotationRenderer.renderToTemporaryFile(sourceURL: capture, shapes: shapes, bindings: [],
                                                                    backgroundSettings: background)
            defer { try? FileManager.default.removeItem(at: sent) }
            files["copy and upload file"] = try Data(contentsOf: sent)
            let item = try await ScreenshotClipboardImage.item(from: sent, dataType: .png, includeTIFF: true)
            files["clipboard png"] = item.data(forType: .png)
            files["clipboard tiff"] = item.data(forType: .tiff)

            let promptParent = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: promptParent, withIntermediateDirectories: false)
            let folder = try await RecordingAgentPromptWriter.write(movie: movie, plan: plan, to: promptParent, master: movie)
            for kind in ["stills", "strips"] {
                let images = folder.appendingPathComponent(kind, isDirectory: true)
                for file in try FileManager.default.contentsOfDirectory(atPath: images.path).sorted() {
                    files["\(kind)/\(file)"] = try Data(contentsOf: images.appendingPathComponent(file))
                }
            }
            return files
        }

        let off = try await outputs("off")
        let on = try await Self.withWorkspaceWallpaper(workspaceWallpaper.path) { try await outputs("on") }
        #expect(off.keys.contains("clipboard tiff") && off.keys.contains { $0.hasPrefix("stills/") }
            && off.keys.contains { $0.hasPrefix("strips/") }, "Outputs: \(off.keys.sorted())")
        #expect(on.keys.sorted() == off.keys.sorted())
        for (name, data) in off { #expect(on[name] == data, "\(name) changed with the workspace wallpaper on") }
    }

    /// Turns the workspace wallpaper on in UserDefaults' argument domain, which
    /// lives in memory only, so no preference is written.
    private static func withWorkspaceWallpaper<T>(_ path: String, _ body: () async throws -> T) async throws -> T {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var on = previous
        on[WorkspaceBackground.styleKey] = WorkspaceBackground.Style.wallpaper.rawValue
        on[WorkspaceBackground.wallpaperPathKey] = path
        on[WorkspaceBackground.dimKey] = 0.8
        on[WorkspaceBackground.blurKey] = true
        defaults.setVolatileDomain(on, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        #expect(defaults.string(forKey: WorkspaceBackground.styleKey) == "wallpaper")
        #expect(defaults.bool(forKey: WorkspaceBackground.blurKey))
        return try await body()
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    /// A left-to-right ramp with a fixed red, so each fixture differs.
    private static func image(width: Int, height: Int, red: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<width {
            context.setFillColor(CGColor(red: red, green: CGFloat(x) / CGFloat(width), blue: 0.4, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return context.makeImage()!
    }

    private static func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }
}
