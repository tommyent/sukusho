import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Glass (the theme plan's step 2): frosted cards and macOS's own glass over a picture, Classic's colours underneath.
struct GlassThemeTests {
    /// Everything Glass doesn't frost is Classic's, so windows it doesn't touch, and Reduce Transparency and Increase
    /// Contrast, draw exactly as Classic.
    @Test func glassFrostsOverAPictureAndKeepsClassicsColoursUnderneath() throws {
        for (glass, classic) in [(AppTheme.glassLight, AppTheme.classicLight), (.glassDark, .classicDark)] {
            #expect(glass.isDark == classic.isDark)
            #expect(glass.chrome.glass, "\(glass.id)")
            #expect(glass.chrome.background == classic.chrome.background && glass.chrome.panel == classic.chrome.panel)
            #expect(glass.ink == classic.ink && glass.marks == classic.marks, "\(glass.id)")
            #expect(glass.ground.workspace == classic.ground.workspace, "\(glass.id)")
            #expect(glass.card.face == classic.card.face && glass.card.well == classic.card.well, "\(glass.id)")
            #expect(glass.card.textWell == classic.card.textWell, "\(glass.id)")
            let frost = try #require(glass.card.recipe.frost, "\(glass.id)")
            #expect(frost.material == .regular, "\(glass.id): a standard material, never Liquid Glass per card")
            let backdrop = try #require(glass.ground.backdrop, "\(glass.id)")
            #expect(backdrop.blur > 0, "\(glass.id)")
        }
    }

    @Test func onlyGlassPaintsAPictureOrTakesMacOSGlass() {
        for theme in AppTheme.builtIns where !theme.id.hasPrefix("glass") {
            #expect(theme.ground.backdrop == nil && !theme.chrome.glass && theme.card.recipe.frost == nil, "\(theme.id)")
        }
    }

    /// Reduce Transparency and Increase Contrast take every Glass surface to its opaque colours (Astra 8).
    @Test func glassIsDrawnOnlyWithoutReduceTransparencyOrIncreaseContrast() throws {
        for glass in [AppTheme.glassLight, .glassDark] {
            #expect(glass.drawnBackdrop(reduceTransparency: false, increaseContrast: false) == glass.ground.backdrop)
            #expect(glass.drawnBackdrop(reduceTransparency: true, increaseContrast: false) == nil, "\(glass.id)")
            #expect(glass.drawnBackdrop(reduceTransparency: false, increaseContrast: true) == nil, "\(glass.id)")
        }
        for theme in AppTheme.builtIns where !theme.id.hasPrefix("glass") {
            #expect(theme.drawnBackdrop(reduceTransparency: false, increaseContrast: false) == nil, "\(theme.id)")
        }
    }

    // MARK: - The picture

    /// Only the folders macOS keeps its wallpapers in, both where a picture is named and where its links lead (Astra 5).
    @Test func onlyApplesWallpaperFoldersAreReadUnasked() throws {
        func allowed(_ path: String) -> Bool { GlassPicture.automatic(URL(fileURLWithPath: path)) != nil }
        #expect(allowed("/System/Library/CoreServices/DefaultDesktop.heic"))
        #expect(allowed("/System/Library/Desktop Pictures/Sonoma.heic"))
        #expect(allowed("/Library/Desktop Pictures/Lake.heic"))
        // The one file allowed is that file only, not a name that begins like it (Astra 2-5).
        #expect(!allowed("/System/Library/CoreServices/DefaultDesktop.heic-backup"))
        #expect(!allowed("/Library/ExampleVendor/Marketing.png"))
        #expect(!allowed("/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns"))
        #expect(!allowed(NSHomeDirectory() + "/Downloads/photo.heic"))
        #expect(!allowed(NSHomeDirectory() + "/Desktop/photo.jpg"))
        #expect(!allowed("/System/Library/Desktop Pictures/../../../Users/someone/Downloads/photo.heic"))
        // A link inside the folders that leads out of them, and one outside that leads in, are both refused.
        let folder = try temporaryFolder()
        let inside = folder.appendingPathComponent("Inside"), outside = folder.appendingPathComponent("Outside")
        for f in [inside, outside] { try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true) }
        let target = try picture(white: 0.5, in: outside)
        let leadsOut = inside.appendingPathComponent("out.png"), leadsIn = outside.appendingPathComponent("in.png")
        try FileManager.default.createSymbolicLink(at: leadsOut, withDestinationURL: target)
        let insideTarget = try picture(white: 0.25, in: inside)
        try FileManager.default.createSymbolicLink(at: leadsIn, withDestinationURL: insideTarget)
        let roots = [inside.resolvingSymlinksInPath().path + "/", inside.path + "/"]
        #expect(GlassPicture.automatic(insideTarget, in: roots) != nil)
        #expect(GlassPicture.automatic(leadsOut, in: roots) == nil)
        #expect(GlassPicture.automatic(leadsIn, in: roots) == nil)
    }

    /// The first of the picked picture, the desktop picture and Sukusho's own that decodes, exactly (Astra 2), with a
    /// wallpaper folder of the test's own, so no Mac's own wallpapers are needed (Astra 2-6).
    @Test func theFirstPictureThatDecodesIsShown() async throws {
        let folder = try temporaryFolder()
        let wallpapers = folder.appendingPathComponent("Desktop Pictures")
        try FileManager.default.createDirectory(at: wallpapers, withIntermediateDirectories: true)
        let roots = [wallpapers.resolvingSymlinksInPath().path + "/", wallpapers.path + "/"]
        let picked = try picture(white: 0.5, in: folder)
        let corrupt = folder.appendingPathComponent("not-a-picture.png")
        try Data("plain text, not a PNG".utf8).write(to: corrupt)
        let gone = folder.appendingPathComponent("gone.png").path
        let own = GlassPicture.ownPicture(dark: false)
        let desktop = try picture(white: 0.25, in: wallpapers)
        // In the wallpaper folder, so allowed, but it doesn't decode.
        let undecodableDesktop = wallpapers.appendingPathComponent("Wallpaper.madesktop")
        try Data("a descriptor, not a picture".utf8).write(to: undecodableDesktop)
        func shown(_ path: String, _ desktop: URL?, dark: Bool = false) async -> URL {
            await GlassPicture.resolve(picked: path, desktop: desktop, dark: dark, roots: roots).url
        }

        #expect(await shown(picked.path, desktop) == picked)
        #expect(await shown(corrupt.path, nil) == own)
        #expect(await shown(gone, nil) == own)
        #expect(await shown(corrupt.path, desktop) == desktop)
        #expect(await shown("", undecodableDesktop) == own)
        #expect(await shown(corrupt.path, undecodableDesktop, dark: true) == GlassPicture.ownPicture(dark: true))
        // A desktop picture outside the wallpaper folders is never read, even when it decodes.
        #expect(await shown("", picked) == own)
    }

    /// A picture replaced at the same path has a new version, which the backdrop draws by, so an open window shows
    /// the new one (Astra 2-M3).
    @Test func aPictureReplacedAtTheSamePathHasANewVersion() async throws {
        let folder = try temporaryFolder(), other = try temporaryFolder()
        let url = try picture(white: 1, in: folder)
        let before = await GlassPicture.resolve(picked: url.path, desktop: nil, dark: false)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: try picture(white: 0, in: other))
        let after = await GlassPicture.resolve(picked: url.path, desktop: nil, dark: false)
        #expect(before.url == url && after.url == url)
        #expect(before.version != after.version)
    }

    /// A file is read again when it changes in place, and not while it stays the same (Astra 3, 7).
    @Test func aFileReplacedInPlaceIsReadAgain() throws {
        let folder = try temporaryFolder()
        let url = try picture(white: 1, in: folder)
        #expect(GlassPicture.decodes(url))
        // The same size, rewritten in place: only the date tells it apart.
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        try Data(repeating: 0x41, count: size).write(to: url)
        #expect(!GlassPicture.decodes(url))
        #expect(!GlassPicture.decodes(url))
        try Data("no longer a picture".utf8).write(to: url, options: .atomic)
        #expect(!GlassPicture.decodes(url))
        try FileManager.default.removeItem(at: url)
        #expect(!GlassPicture.decodes(url))
    }

    /// A chosen recent from outside Sukusho's folder is copied in, so moving the original keeps the choice; one
    /// already inside is used as it is (Astra 6).
    @Test func aChosenPictureFromOutsideIsCopiedIn() async throws {
        let folder = try temporaryFolder()
        let wallpapers = folder.appendingPathComponent("Wallpapers"), elsewhere = folder.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let original = try picture(white: 0.5, in: elsewhere)
        let chosen = try AnnotationWallpaperStore.copy(original, into: wallpapers)
        #expect(chosen.deletingLastPathComponent().standardizedFileURL == wallpapers.standardizedFileURL)
        try FileManager.default.moveItem(at: original, to: elsewhere.appendingPathComponent("moved.png"))
        #expect(await GlassPicture.resolve(picked: chosen.path, desktop: nil, dark: false).url == chosen)
        #expect(try AnnotationWallpaperStore.copy(chosen, into: wallpapers) == chosen.standardizedFileURL)

        // A recent that's a link: the file it leads to is copied, so moving that file keeps the choice (Astra 2-6).
        let target = try picture(white: 0.75, in: elsewhere)
        let link = elsewhere.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let viaLink = try AnnotationWallpaperStore.copy(link, into: wallpapers)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: viaLink.path)) == nil)
        try FileManager.default.moveItem(at: target, to: elsewhere.appendingPathComponent("target-moved.png"))
        #expect(GlassPicture.decodes(viaLink))
        // A link inside Sukusho's folder that leads out is copied too, not kept as it is.
        let outward = wallpapers.appendingPathComponent("outward.png")
        try FileManager.default.createSymbolicLink(at: outward, withDestinationURL: elsewhere.appendingPathComponent("moved.png"))
        #expect(try AnnotationWallpaperStore.copy(outward, into: wallpapers) != outward.standardizedFileURL)
    }

    /// Imports at once of pictures with the same name each get a file of their own (Astra 2-M2).
    @Test func importsAtOnceOfOneNameEachGetAFile() async throws {
        let folder = try temporaryFolder()
        let wallpapers = folder.appendingPathComponent("Wallpapers")
        var originals: [URL] = []
        for i in 0..<24 {
            let from = folder.appendingPathComponent("from-\(i)")
            try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
            let same = from.appendingPathComponent("same.png")
            try FileManager.default.moveItem(at: try picture(white: CGFloat(i) / 24, in: from), to: same)
            originals.append(same)
        }
        let copies = try await withThrowingTaskGroup(of: URL.self) { group in
            for original in originals { group.addTask { try AnnotationWallpaperStore.copy(original, into: wallpapers) } }
            return try await group.reduce(into: [URL]()) { $0.append($1) }
        }
        #expect(Set(copies.map(\.path)).count == 24)
    }

    /// A pick whose copy finishes after a newer pick can't undo it, the default included (Astra 2-M1).
    @Test @MainActor func aLatePickCantUndoANewerOne() async {
        @MainActor final class Seen { var started = false, path = "before", errors = 0 }
        let picks = LatestPick(), seen = Seen()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let slow = Task { @MainActor in
            await picks.choose(URL(fileURLWithPath: "/slow.png"), importing: { url in
                seen.started = true
                for await _ in gate {}
                return url
            }, apply: { seen.path = $0 }, failed: { _ in seen.errors += 1 })
        }
        while !seen.started { await Task.yield() }
        await picks.choose(nil, importing: { $0 }, apply: { seen.path = $0 }, failed: { _ in seen.errors += 1 })
        #expect(seen.path == "")
        open.finish()
        await slow.value
        #expect(seen.path == "" && seen.errors == 0)
    }

    // MARK: - The Theme Tuner's Glass values

    @Test func untouchedGlassTuningIsTheBuiltInGlass() {
        var tuning = GlassTuning()
        tuning.on = true
        #expect(tuning.applied(to: .glassLight) == .glassLight)
        #expect(tuning.applied(to: .glassDark) == .glassDark)
    }

    @Test func tunedGlassValuesReachOnlyGlassAndOnlyWhileOn() throws {
        var tuning = GlassTuning()
        tuning.dark.material = .thick
        tuning.dark.tint = 0x102030
        tuning.dark.tintOpacity = 0.4
        tuning.dark.rimOpacity = 0.3
        tuning.dark.blur = 12
        tuning.dark.dim = 0.5
        for theme in AppTheme.builtIns { #expect(tuning.applied(to: theme) == theme, "off: \(theme.id)") }
        tuning.on = true
        let dark = tuning.applied(to: .glassDark)
        let frost = try #require(dark.card.recipe.frost)
        #expect(frost.material == .thick && frost.tint == .rgb(0x102030, opacity: 0.4) && frost.rim == .white(opacity: 0.3))
        #expect(dark.ground.backdrop == AppTheme.Backdrop(blur: 12, dim: 0.5))
        #expect(tuning.applied(to: .glassLight) == .glassLight)
        for theme in AppTheme.builtIns where !theme.id.hasPrefix("glass") { #expect(tuning.applied(to: theme) == theme) }
        #expect(tuning.swift.contains("Backdrop(blur: 12, dim: 0.5)"))
        #expect(tuning.swift.contains("Frost(material: .thick, tint: .rgb(0x102030, opacity: 0.4), rim: .white(opacity: 0.3))"))
        #expect(GlassTuning(tuning.data) == tuning)
        #expect(GlassTuning(Data("not json".utf8)) == GlassTuning())
    }

    // MARK: - Fixtures

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GlassThemeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A flat grey PNG, 64 pixels square.
    private func picture(white: CGFloat, in folder: URL) throws -> URL {
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: white, green: white, blue: white, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let url = folder.appendingPathComponent("grey-\(white).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}
