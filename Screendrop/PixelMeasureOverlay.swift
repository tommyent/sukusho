import SwiftUI

/// The arrow-key ruler over the canvas (sd-p31), Shottr's way: while ↑/↓ or
/// ←/→ is held, one line through the pointer from edge to edge, with end
/// bars and one horizontal label. Shift includes the border pixels. It
/// takes no clicks; the canvas handles those.
struct PixelMeasureOverlay: View {
    let probe: PixelProbe
    let axis: PixelMeasureAxis
    /// The rect the image occupies, in canvas points.
    let imageFrame: CGRect
    /// The pointer in canvas points, after the camera's unproject.
    let pointer: CGPoint?
    /// Set by the render check; otherwise Shift as held.
    var forcesBorder = false
    /// The dock's crosshair draws both rulers with one shared label.
    var crossAxis: PixelMeasureAxis?

    @State private var shiftHeld = false

    static let tint = Color(red: 0.93, green: 0.29, blue: 0.07)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let ruler {
                line(ruler)
                if let crossAxis, let other = self.ruler(crossAxis), let pointer {
                    line(other)
                    crosshairLabel(ruler, other, pointer: pointer)
                } else {
                    label(ruler)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .onModifierKeysChanged(mask: .shift) { _, keys in shiftHeld = keys.contains(.shift) }
        .accessibilityHidden(true)
    }

    var ruler: PixelRuler? { ruler(axis) }

    private func ruler(_ axis: PixelMeasureAxis) -> PixelRuler? {
        guard let pointer, let buffer = probe.buffer else { return nil }
        return PixelRuler(buffer: buffer, imageFrame: imageFrame, pointer: pointer, axis: axis,
                          includingBorder: shiftHeld || forcesBorder, pixelsPerPoint: probe.pixelsPerPoint)
    }

    /// One bubble for both rulers, in the quadrant below and right of the crossing, where
    /// neither line runs; it flips to the other side near the canvas's right or bottom edge.
    private func crosshairLabel(_ first: PixelRuler, _ second: PixelRuler, pointer: CGPoint) -> some View {
        let horizontal = first.axis == .horizontal ? first : second
        let vertical = first.axis == .horizontal ? second : first
        let text = PixelMeasurement.label(width: horizontal.pixels, height: vertical.pixels,
                                          pixelsPerPoint: probe.pixelsPerPoint)
        let room = CGSize(width: 220, height: 20), gap: CGFloat = 10
        return GeometryReader { proxy in
            let right = pointer.x + gap + room.width <= proxy.size.width
            let below = pointer.y + gap + room.height <= proxy.size.height
            pill(text)
                .frame(width: room.width, height: room.height, alignment: right ? .leading : .trailing)
                .position(x: pointer.x + (right ? 1 : -1) * (gap + room.width / 2),
                          y: pointer.y + (below ? 1 : -1) * (gap + room.height / 2))
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Self.tint, in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }

    private func line(_ ruler: PixelRuler) -> some View {
        Canvas { context, _ in
            var path = Path()
            path.move(to: ruler.start)
            path.addLine(to: ruler.end)
            let half: CGFloat = 5
            for point in [ruler.start, ruler.end] {
                // A bar across each end.
                if ruler.axis == .vertical {
                    path.move(to: CGPoint(x: point.x - half, y: point.y))
                    path.addLine(to: CGPoint(x: point.x + half, y: point.y))
                } else {
                    path.move(to: CGPoint(x: point.x, y: point.y - half))
                    path.addLine(to: CGPoint(x: point.x, y: point.y + half))
                }
            }
            // A white halo under the line, so it reads on any colour.
            context.stroke(path, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            context.stroke(path, with: .color(Self.tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }

    /// Beside the middle of a vertical line, left unless that runs off the
    /// canvas; above a horizontal one, below near the top.
    private func label(_ ruler: PixelRuler) -> some View {
        let mid = CGPoint(x: (ruler.start.x + ruler.end.x) / 2, y: (ruler.start.y + ruler.end.y) / 2)
        let room: CGFloat = 130, gap: CGFloat = 8
        let pill = self.pill(ruler.label)
        return Group {
            if ruler.axis == .vertical {
                if mid.x - gap - room >= 0 {
                    pill.frame(width: room, alignment: .trailing).position(x: mid.x - gap - room / 2, y: mid.y)
                } else {
                    pill.frame(width: room, alignment: .leading).position(x: mid.x + gap + room / 2, y: mid.y)
                }
            } else {
                pill.position(x: mid.x, y: mid.y < 24 ? mid.y + 16 : mid.y - 16)
            }
        }
    }
}
