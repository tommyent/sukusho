import AppKit
import Testing

@MainActor
struct TaperedSliderStepsTests {
    @Test func dragStopsHaveEqualSpaceAndClampAtEnds() {
        let widths = AnnotationSizeStops.lineWidths
        #expect(AnnotationSizeStops.value(at: 0.5, in: widths) == 6)
        #expect(AnnotationSizeStops.value(at: -1, in: widths) == 1)
        #expect(AnnotationSizeStops.value(at: 2, in: widths) == 16)
        for (index, stop) in widths.enumerated() {
            let fraction = CGFloat(index) / CGFloat(widths.count - 1)
            #expect(AnnotationSizeStops.value(at: fraction, in: widths) == stop)
            #expect(abs(AnnotationSizeStops.fraction(for: stop, in: widths) - fraction) < 0.0001)
        }
    }

    @Test func offStopThumbPositionInterpolatesBetweenNeighbours() {
        #expect(AnnotationSizeStops.fraction(for: 5, in: AnnotationSizeStops.lineWidths) == 0.5)
    }

    @Test func keysMoveToAnAdjacentStopFromAnExistingOffStopValue() {
        let widths = AnnotationSizeStops.lineWidths
        #expect(AnnotationSizeStops.step(from: 5, by: -1, in: widths) == 4)
        #expect(AnnotationSizeStops.step(from: 5, by: 1, in: widths) == 6)
    }
}
