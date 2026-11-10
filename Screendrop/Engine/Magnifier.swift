import CoreGraphics
import Foundation
import SwiftUI

/// The outline of a magnifier's ring and loupe.
enum MagnifierShape: String, Codable, CaseIterable {
    case roundedSquare, circle, rectangle

    var label: String {
        switch self {
        case .roundedSquare: "Rounded"
        case .circle: "Circle"
        case .rectangle: "Rectangle"
        }
    }
}

struct MagnifierProps: Codable, Equatable {
    var ring = Vec(0, 0)
    var ringSize: Double = 60
    var loupe = Vec(140, 0)
    var loupeSize: Double = 180
    var swatch: AnnotationSwatch = .red
    var strokeWidth: Double = 4
    /// Nil in documents saved before shapes: a rounded square.
    var shape: MagnifierShape?
    /// Width over height of a `.rectangle`, set by the drag that drew it; the sizes are widths.
    var aspect: Double?

    /// Height over width of the ring and the loupe, which always share a shape.
    var heightRatio: Double { shape == .rectangle ? 1 / (aspect ?? 1.6) : 1 }
    var zoom: Double { loupeSize / ringSize }
    var ringRect: CGRect { rect(center: ring, size: ringSize) }
    var loupeRect: CGRect { rect(center: loupe, size: loupeSize) }
    var isValid: Bool {
        [ring.x, ring.y, loupe.x, loupe.y, ringSize, loupeSize, strokeWidth].allSatisfy(\.isFinite)
            && ringSize >= 1 && loupeSize >= 1 && strokeWidth >= 0 && heightRatio.isFinite && heightRatio > 0
    }

    private func rect(center: Vec, size: Double) -> CGRect {
        CGRect(x: center.x - size / 2, y: center.y - size * heightRatio / 2, width: size, height: size * heightRatio)
    }

    func path(_ rect: CGRect) -> CGPath {
        switch shape ?? .roundedSquare {
        case .roundedSquare: Path(roundedRect: rect, cornerRadius: rect.width * 0.22, style: .continuous).cgPath
        case .circle: CGPath(ellipseIn: rect, transform: nil)
        case .rectangle:
            Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.08, style: .continuous).cgPath
        }
    }

    var handles: [(AnnoSelectionHandle, Vec)] {
        [(.magnifierRingResize, Vec(ringRect.maxX, ringRect.maxY)),
         (.magnifierLoupeResize, Vec(loupeRect.maxX, loupeRect.maxY)),
         (.magnifierRing, ring), (.magnifierLoupe, loupe)]
    }

    var geometry: Geometry2d {
        guard isValid else { return Rectangle2d(width: 0, height: 0, isFilled: false) }
        return Group2d(children: [
            Polygon2d(points: PathBuilder(cgPath: path(ringRect)).vertices(), isFilled: true),
            Polygon2d(points: PathBuilder(cgPath: path(loupeRect)).vertices(), isFilled: true),
            Polyline2d(points: [ring, loupe]),
        ])
    }
}

/// One sanitized bitmap per canvas, invalidated by source or redaction edits.
final class AnnoMagnifierPreviewCache {
    private var source: CGImage?
    private var redactions: [AnnoShape] = []
    private var image: CGImage?

    func image(source: CGImage, redactions: [AnnoShape], render: () -> CGImage?) -> CGImage? {
        if self.source === source, self.redactions == redactions { return image }
        self.source = source
        self.redactions = redactions
        image = render()
        return image
    }

    func clear() { source = nil; redactions = []; image = nil }
}
