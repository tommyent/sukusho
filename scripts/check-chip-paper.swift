// Chip's paper grain stays on the paper: built by check-chip-paper.sh with the app's sources and run twice, with the
// grain tile beside the binary and without it (the app then draws none). Real cards whose picture is one flat colour,
// in Chip and Classic, light and dark, at 140, 220 and 320 pt, rendered at 2x:
// - Chip: the picture's pixels are the same in both runs (no grain on a capture) and the strip under it differs.
// - Classic: every pixel is the same in both runs (no paper).
// "The same" allows the stray pixel ImageRenderer moves between processes: under 0.1% of a region may differ.
//   check-chip-paper render <folder>
//   check-chip-paper compare <folder with the tile> <folder without it>
import AppKit
import SwiftUI

@main enum CheckChipPaper {
    static let themes = ["chip-light", "chip-dark", "classic-light", "classic-dark"]
    static let widths: [CGFloat] = [140, 220, 320]

    @MainActor static func main() throws {
        let a = CommandLine.arguments
        if a[1] == "render" { try render(to: URL(fileURLWithPath: a[2])) } else { compare(a[2], a[3]) }
    }

    static func height(_ width: CGFloat) -> CGFloat {
        LibraryGridMetrics(width: width + 2 * LibraryGridMetrics.edgeMargin, cardWidth: width).cardHeight
    }

    @MainActor static func render(to folder: URL) throws {
        for theme in themes {
            let dark = theme.hasSuffix("dark")
            UserDefaults.standard.set(theme, forKey: dark ? "appTheme.dark" : "appTheme.light")
            // @AppStorage hears of the change on a later turn of the run loop; without this, a card can draw the last theme.
            RunLoop.main.run(until: .now + 0.3)
            for width in widths {
                let card = LibraryGridCard(marks: LibraryCardMarks(cloud: nil, upload: nil, tall: false), cloudAction: {}) {
                    Color(red: 0.35, green: 0.55, blue: 0.75)
                } caption: {
                    LibraryGridCaption(date: Date(timeIntervalSinceReferenceDate: 816_000_000), saveAction: {}) { Text("Card") }
                }
                .modifier(LibraryCardSurface(layout: .grid, selected: false, hovering: false))
                .frame(width: width, height: height(width))
                .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: card)
                renderer.scale = 2
                var image: CGImage?
                NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { image = renderer.cgImage }
                let flags = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                let context = CGContext(data: nil, width: image!.width, height: image!.height, bitsPerComponent: 8,
                                        bytesPerRow: image!.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: flags)!
                context.draw(image!, in: CGRect(x: 0, y: 0, width: image!.width, height: image!.height))
                try Data(bytes: context.data!, count: image!.width * image!.height * 4)
                    .write(to: folder.appending(path: "\(theme)-\(Int(width)).rgba"))
            }
        }
    }

    static func compare(_ with: String, _ without: String) {
        var failures: [String] = []
        for theme in themes {
            for width in widths {
                let file = "\(theme)-\(Int(width)).rgba", name = "\(theme) \(Int(width)) pt"
                guard let a = FileManager.default.contents(atPath: "\(with)/\(file)"),
                      let b = FileManager.default.contents(atPath: "\(without)/\(file)"), a.count == b.count else {
                    failures.append("\(name): renders missing or of different sizes"); continue
                }
                let row = Int(width * 2) * 4
                let picture = Int((height(width) - LibraryGridMetrics.captionHeight) * 2) * row   // the picture's rows
                // ImageRenderer isn't exactly repeatable between processes: a pixel or two can move a level or two. Grain
                // moves most of the pixels it covers, so count changed pixels, not bytes.
                func changed(_ range: Range<Int>) -> Double {
                    let pixels = Array(stride(from: range.lowerBound, to: range.upperBound, by: 4))
                    let moved = pixels.filter { a[$0 ..< $0 + 4] != b[$0 ..< $0 + 4] }.count
                    return Double(moved) / Double(max(1, pixels.count))
                }
                let percent = { (share: Double) in String(format: "%.2f%%", share * 100) }
                if theme.hasPrefix("chip") {
                    let onPicture = changed(0 ..< picture), onStrip = changed(picture ..< a.count)
                    if onPicture > 0.001 { failures.append("\(name): the grain reaches the picture (\(percent(onPicture)) of its pixels)") }
                    if onStrip < 0.05 { failures.append("\(name): no grain on the paper strip (\(percent(onStrip)) of its pixels)") }
                } else {
                    let anywhere = changed(0 ..< a.count)
                    if anywhere > 0.001 { failures.append("\(name): Classic draws paper (\(percent(anywhere)) of its pixels)") }
                }
            }
        }
        if failures.isEmpty {
            print("Chip paper check passed: the grain is on the paper strip and never the picture in Chip, and Classic has none, light and dark, 140 to 320 pt")
        } else {
            failures.forEach { print("Chip paper check FAILED: \($0)") }
            exit(1)
        }
    }
}
