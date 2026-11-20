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
            #expect(backdrop.blur > 0 && backdrop.ink == .auto, "\(glass.id)")
        }
    }

    @Test func onlyGlassPaintsAPictureOrTakesMacOSGlass() {
        for theme in AppTheme.builtIns where !theme.id.hasPrefix("glass") {
            #expect(theme.ground.backdrop == nil && !theme.chrome.glass && theme.card.recipe.frost == nil, "\(theme.id)")
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

    // MARK: - Text on the picture

    /// Auto keeps the appearance's ink while it reads at 4.5:1 and switches only when the other ink reads better.
    @Test func autoInkFollowsThePictureOnlyWhenTheAppearancesWouldFail() throws {
        let folder = try temporaryFolder()
        let white = try picture(white: 1, in: folder), black = try picture(white: 0, in: folder)
        let light = AppTheme.glassLight.ground, dark = AppTheme.glassDark.ground
        let lightBackdrop = try #require(light.backdrop), darkBackdrop = try #require(dark.backdrop)
        // Each appearance over its own kind of picture keeps its ink.
        #expect(!GlassPicture.lightInk(lightBackdrop, picture: white, ground: light.workspace, dark: false))
        #expect(GlassPicture.lightInk(darkBackdrop, picture: black, ground: dark.workspace, dark: true))
        // Over the other kind, dark text on black or white on white, it switches.
        #expect(GlassPicture.lightInk(lightBackdrop, picture: black, ground: light.workspace, dark: false))
        #expect(!GlassPicture.lightInk(darkBackdrop, picture: white, ground: dark.workspace, dark: true))
        // A chosen ink is kept whatever the picture.
        var forced = lightBackdrop
        forced.ink = .dark
        #expect(!GlassPicture.lightInk(forced, picture: black, ground: light.workspace, dark: false))
        forced.ink = .light
        #expect(GlassPicture.lightInk(forced, picture: white, ground: light.workspace, dark: false))
    }

    @Test func pictureBrightnessIsMeasured() throws {
        let folder = try temporaryFolder()
        #expect(try #require(GlassPicture.meanLuminance(try picture(white: 1, in: folder))) > 0.99)
        #expect(try #require(GlassPicture.meanLuminance(try picture(white: 0, in: folder))) < 0.01)
        #expect(GlassPicture.meanLuminance(folder.appendingPathComponent("missing.png")) == nil)
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
