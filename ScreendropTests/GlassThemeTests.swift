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

    /// The first of the picked picture, the desktop picture and Sukusho's own that decodes, exactly (Astra 2).
    @Test func theFirstPictureThatDecodesIsShown() async throws {
        let folder = try temporaryFolder()
        let picked = try picture(white: 0.5, in: folder)
        let corrupt = folder.appendingPathComponent("not-a-picture.png")
        try Data("plain text, not a PNG".utf8).write(to: corrupt)
        let gone = folder.appendingPathComponent("gone.png").path
        let own = GlassPicture.ownPicture(dark: false)
        // Not DefaultDesktop.heic, which is also Sukusho's own in a test bundle without Glass's pictures.
        let desktop = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails/Big Sur.heic")
        // A text file Apple keeps in the wallpaper folders: allowed, but it doesn't decode.
        let undecodableDesktop = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Big Sur.madesktop")
        try #require(FileManager.default.fileExists(atPath: desktop.path) && desktop != own)
        try #require(FileManager.default.fileExists(atPath: undecodableDesktop.path))
        try #require(GlassPicture.automatic(undecodableDesktop) != nil)

        #expect(await GlassPicture.resolve(picked: picked.path, desktop: desktop, dark: false) == picked)
        #expect(await GlassPicture.resolve(picked: corrupt.path, desktop: nil, dark: false) == own)
        #expect(await GlassPicture.resolve(picked: gone, desktop: nil, dark: false) == own)
        #expect(await GlassPicture.resolve(picked: corrupt.path, desktop: desktop, dark: false) == desktop)
        #expect(await GlassPicture.resolve(picked: "", desktop: undecodableDesktop, dark: false) == own)
        #expect(await GlassPicture.resolve(picked: corrupt.path, desktop: undecodableDesktop, dark: true)
                == GlassPicture.ownPicture(dark: true))
        // A desktop picture outside Apple's folders is never read, even when it decodes.
        #expect(await GlassPicture.resolve(picked: "", desktop: picked, dark: false) == own)
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
        #expect(await GlassPicture.resolve(picked: chosen.path, desktop: nil, dark: false) == chosen)
        #expect(try AnnotationWallpaperStore.copy(chosen, into: wallpapers) == chosen.standardizedFileURL)
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
