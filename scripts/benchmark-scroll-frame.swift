// Compile -O with ScrollingCapture{Raster,OffsetEstimator,OffsetVerifier,FrameStitcher}.swift.
import Foundation
import ImageIO
import CoreText
import CryptoKit

@main struct ScrollFrameBenchmark {
    static func frame(_ index: Int) -> [UInt8] {
        let url = URL(fileURLWithPath: "ScreendropTests/Fixtures/wikipedia-scroll-\(index).png")
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        return ScrollingCapturePixels.bytes(of: image, in: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }

    // A native Retina page with a heading and three columns of selectable text.
    static func article(width: Int, height: Int) -> [UInt8] {
        let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: ScrollingCapturePixels.bitmapInfo)!
        c.setFillColor(gray: 1, alpha: 1)
        c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 25, nil)]
        for y in stride(from: 0, to: height, by: 38) {
            for x in stride(from: 20, to: width, by: width / 3) {
                c.textPosition = CGPoint(x: x, y: y)
                let text = "\(y * 37 + x): Screenshot notes for the next review."
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), c)
            }
        }
        return Array(UnsafeRawBufferPointer(start: c.data!, count: width * height * 4))
    }

    static func measure(_ first: [UInt8], _ next: [UInt8], _ w: Int, _ h: Int, _ step: Int) async {
        var times: [Double] = []
        var digest = "", shifts: [Int] = []
        for _ in 0..<12 {
            let stitcher = ScrollingCaptureFrameStitcher(firstFrame: first, width: w, height: h, ignoredTrailingColumns: 0)!
            let start = DispatchTime.now().uptimeNanoseconds
            let (placement, candidate) = await stitcher.add(next)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            precondition(placement == .appended(step))
            if digest.isEmpty {
                shifts = candidate?.bands ?? []
                digest = SHA256.hash(data: await stitcher.makeImageData()).map { String(format: "%02x", $0) }.joined()
            }
        }
        let sorted = times.dropFirst().sorted()
        print(String(format: "%dx%d stitcher.add median %.3f ms, p95 %.3f ms", w, h, sorted[5], sorted.last!))
        print("Bands \(shifts), stitched BGRA SHA256 \(digest)")
    }

    static func main() async {
        await measure(frame(3), frame(4), 600, 400, 180)
        let w = 2400, h = 1400, step = 211
        let page = article(width: w, height: h + step)
        await measure(Array(page.prefix(w * h * 4)), Array(page.suffix(w * h * 4)), w, h, step)
    }
}
