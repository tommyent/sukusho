//
//  AnnotationMetrics.swift
//  Screendrop
//

import AppKit

enum AnnotationTextMetrics {
    static let minimumFontSize: CGFloat = 9
    /// The largest text size kept for new text.
    static let maximumFontSize: CGFloat = 999

    /// Keeps a text style's font size in range. An unbounded size can't be shown as a whole
    /// number, so it would crash every editor that displays it once saved to the style preset.
    static func clampedFontSize(_ size: CGFloat) -> CGFloat {
        size.isNaN ? minimumFontSize : min(max(size, minimumFontSize), maximumFontSize)
    }
    static let defaultFontName: String = "SF Pro"

    /// One ⌘⌥+ or ⌘⌥− step for a label's size: about a tenth of it, at least a point, landing on
    /// whole points.
    static func steppedFontSize(_ size: CGFloat, by direction: Int) -> CGFloat {
        let step = max(1, (size * 0.1).rounded())
        return clampedFontSize(size.rounded() + step * CGFloat(direction.signum()))
    }
}

enum AnnotationSizeStops {
    static let lineWidths: [CGFloat] = [1, 2, 3, 4, 6, 8, 12, 16]

    static func value(at fraction: CGFloat, in stops: [CGFloat]) -> CGFloat {
        guard stops.count > 1 else { return stops.first ?? 0 }
        let clamped = min(max(fraction, 0), 1)
        return stops[Int((clamped * CGFloat(stops.count - 1)).rounded())]
    }

    /// Off-stop saved values sit between their neighbours without changing the value.
    static func fraction(for value: CGFloat, in stops: [CGFloat]) -> CGFloat {
        guard stops.count > 1, let first = stops.first, value > first else { return 0 }
        guard let upper = stops.firstIndex(where: { $0 >= value }) else { return 1 }
        let lower = upper - 1
        let between = (value - stops[lower]) / (stops[upper] - stops[lower])
        return (CGFloat(lower) + between) / CGFloat(stops.count - 1)
    }

    /// An off-stop value moves in the requested direction, without rounding first.
    static func step(from value: CGFloat, by direction: Int, in stops: [CGFloat]) -> CGFloat {
        if direction < 0 { return stops.last(where: { $0 < value }) ?? value }
        return stops.first(where: { $0 > value }) ?? value
    }
}
