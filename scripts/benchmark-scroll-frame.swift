// Compile -O with ScrollingCapture{Raster,OffsetEstimator,OffsetVerifier,FrameStitcher}.swift.
import Foundation
import ImageIO

@main struct ScrollFrameBenchmark {
    static func frame(_ index: Int) -> [UInt8] {
        let url = URL(fileURLWithPath: "ScreendropTests/Fixtures/wikipedia-scroll-\(index).png")
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        return ScrollingCapturePixels.bytes(of: image, in: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }

    static func main() async {
        let first = frame(3), next = frame(4)
        var times: [Double] = []
        for _ in 0..<12 {
            let stitcher = ScrollingCaptureFrameStitcher(firstFrame: first, width: 600, height: 400, ignoredTrailingColumns: 0)!
            let start = DispatchTime.now().uptimeNanoseconds
            let (placement, _) = await stitcher.add(next)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            precondition(placement == .appended(180))
        }
        let sorted = times.dropFirst().sorted()
        print(String(format: "600x400 stitcher.add median %.3f ms, p95 %.3f ms", sorted[5], sorted.last!))
    }
}
