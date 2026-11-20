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

    @Test func onlyApplesOwnPicturesAreReadWithoutAsking() {
        #expect(GlassPicture.readsWithoutPrompt(URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")))
        #expect(GlassPicture.readsWithoutPrompt(URL(fileURLWithPath: "/Library/Desktop Pictures/Lake.heic")))
        #expect(!GlassPicture.readsWithoutPrompt(URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/photo.heic")))
        #expect(!GlassPicture.readsWithoutPrompt(URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/photo.jpg")))
        #expect(!GlassPicture.readsWithoutPrompt(URL(fileURLWithPath: "/System/../Users/someone/Downloads/photo.heic")))
    }

    @Test func aPickedPictureIsUsedWhileItExists() throws {
        let folder = try temporaryFolder()
        let picked = try picture(white: 0.5, in: folder)
        #expect(GlassPicture.url(picked: picked.path, dark: false) == picked)
        let gone = folder.appendingPathComponent("gone.png").path
        #expect(GlassPicture.url(picked: gone, dark: false).path != gone)
        #expect(GlassPicture.url(picked: "", dark: true).path != gone)
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
