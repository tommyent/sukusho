// Built twice by check-classic-render.sh, against beta 5's sources and against today's: the same fixture of
// Classic's surfaces, rendered with each, raw RGBA bytes out. Only APIs that both revisions have.
// Usage: check-classic-render <output folder>
import AppKit
import SwiftUI

@main enum ClassicRender {
    @MainActor static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .dark ? "dark" : "light"
            try render(ChromeFixture(scheme: scheme), "chrome-\(name)", to: out, scheme: scheme)
            for width in [140, 220, 320] as [CGFloat] {
                try render(LibraryGridCardPreview(width: width, scheme: scheme), "cards-\(Int(width))-\(name)", to: out, scheme: scheme)
            }
        }
    }

    @MainActor static func render(_ view: some View, _ name: String, to out: URL, scheme: ColorScheme) throws {
        for scale in [1.0, 2.0] {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
            renderer.scale = scale
            // Dynamic NSColors resolve against the drawing appearance, which a windowless renderer doesn't set.
            var image: CGImage?
            NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { image = renderer.cgImage }
            guard let image else { throw CocoaError(.fileWriteUnknown) }
            let flags = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: flags)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let file = "\(name)-\(Int(scale))x"
            try Data(bytes: context.data!, count: image.width * image.height * 4).write(to: out.appending(path: "\(file).rgba"))
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: out.appending(path: "\(file).png"))
            print("\(file) \(image.width)x\(image.height)")
        }
    }
}

/// Every chrome colour Classic holds, the workspace ground, list rows, borders, marks and raised text. The card
/// previews draw the rest: faces, lips, shadows, picture and text wells, pills and badges.
private struct ChromeFixture: View {
    let scheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                ForEach(Array(swatches.enumerated()), id: \.offset) { _, colour in
                    Rectangle().fill(colour).frame(width: 22, height: 22)
                }
            }
            HStack(spacing: 10) {
                AnnotationEditorWorkspaceBackground().frame(width: 180, height: 80)
                Rectangle().fill(WorkspaceChrome.background).frame(width: 80, height: 80)
                Text("Raised title").font(.system(size: 14, weight: .medium)).libraryRaisedText()
                Image(systemName: "star").libraryRaisedIcon()
            }
            HStack(spacing: 10) {
                ForEach(0 ..< 3, id: \.self) { row in   // rest, hover, selected
                    Text("List row").frame(width: 160, height: 36)
                        .modifier(LibraryCardSurface(layout: .list, selected: row == 2, hovering: row == 1))
                }
            }
            HStack(spacing: 10) {
                LibraryCardBorder(selected: true).frame(width: 60, height: 40)
                LibraryCardBorder(selected: false).frame(width: 60, height: 40)
                CardCloudBadge(isShared: true, action: {})
                CardCloudBadge(isShared: false, action: {})
                Label("1:24", systemImage: "play.fill").cardPill()
                Text("Expired").cardPill(.red)
                Rectangle().fill(CardMark.green).frame(width: 20, height: 20)
                Rectangle().fill(CardMark.kindSymbol).frame(width: 20, height: 20)
            }
        }
        .padding(20)
        .background(Palette.workspace)
    }

    private var swatches: [Color] {
        [Color.ink, .inkInverse, Palette.panel, Palette.workspace, Palette.label, Palette.secondaryLabel,
         Palette.tertiaryLabel, Palette.disabledLabel, Palette.fill, Palette.hoverFill, Palette.pressedFill,
         Palette.selectedFill, Palette.hairline, Palette.strongHairline, Palette.onAccent, Palette.record,
         Palette.success, Palette.warning]
    }
}
