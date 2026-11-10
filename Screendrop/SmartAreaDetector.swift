//
//  SmartAreaDetector.swift
//  Screendrop
//

import CoreGraphics
import Foundation

/// A frozen frame's pixels, one `UInt32` each, row by row from the top.
nonisolated struct SmartAreaBitmap: Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt32]

    init(width: Int, height: Int, pixels: [UInt32]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Redraws the image at its own size, so every pixel keeps its exact color:
    /// the detector compares colors for equality.
    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt32](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }
}

/// Finds the boxes a person would point at in a screen image (cards, panels,
/// pictures, buttons) from pixels alone.
///
/// Screens draw flat colors exactly, so the image is split into areas of one
/// exact color. An area is a box when it lies along all four sides of its
/// bounds: a filled card, a panel, a border line around a card. Whatever sits
/// on a large area without sharing its color is a box too (a card made of
/// several parts), and so is a stretch with no flat color in it (a photo).
///
/// Measured on 2026-11-10 against Vision's rectangle and contour requests on
/// eight rendered pages: this found card and picture edges to the pixel where
/// Vision's rectangles sat several pixels off and its contours traced letters.
/// It finds nothing on a background that isn't flat (cards over a gradient or
/// a blurred picture), and offers the closed letters of a very large headline.
nonisolated enum SmartAreaDetector {
    /// Boxes in pixels, top-left origin, smallest first. `minSide` is the
    /// shortest side a box may have.
    static func boxes(in bitmap: SmartAreaBitmap, minSide: Int) -> [CGRect] {
        let width = bitmap.width, height = bitmap.height
        guard width >= minSide, height >= minSide, minSide > 0 else { return [] }
        let areas = FlatAreas(bitmap)
        let whole = PixelBox(minX: 0, minY: 0, maxX: width - 1, maxY: height - 1)

        var exact: [PixelBox] = []
        var surfaces: [Int] = []
        let surfaceSize = max(4 * minSide * minSide, width * height / 2000)
        for id in 0..<areas.count {
            let box = areas.box(id)
            guard box.width >= minSide, box.height >= minSide else { continue }
            let size = Int(areas.size[id])
            if size >= surfaceSize { surfaces.append(id) }
            // A border line around a box has at least half its outline's pixels.
            guard box != whole, size >= box.width + box.height, isSolid(box, filled: size, minSide: minSide),
                  size * 2 >= box.area || areas.standsOut(id, in: bitmap),
                  areas.reachesAllSides(id) else { continue }
            exact.append(box)
        }

        var grouped: [PixelBox] = []
        surfaces.sort { areas.size[$0] > areas.size[$1] }
        for id in surfaces.prefix(maxSurfaces) {
            let surface = Int32(id)
            grouped += areas.groups(in: areas.box(id), minSide: minSide) { $0 != surface }
        }
        // A photo has no two neighbours alike: its areas are a pixel or a few,
        // and it fills its bounds, which the grain of a gradient doesn't.
        grouped += areas.groups(in: whole, minSide: minSide, minFill: 85) { areas.size[Int($0)] < 16 }

        // An area's own bounds are exact; a group's may take in a shadow, so
        // it only counts where no area gave nearly the same box.
        var kept = merged(exact, into: [])
        kept = merged(grouped.filter { $0 != whole }, into: kept)
        return kept.map(\.rect).sorted { $0.width * $0.height < $1.width * $1.height }
    }

    /// A small box must be mostly filled: a headline's letters are small and
    /// fill about half their bounds, a button or a picture nearly all of them.
    fileprivate static func isSolid(_ box: PixelBox, filled: Int, minSide: Int) -> Bool {
        min(box.width, box.height) >= 3 * minSide || filled * 10 >= box.area * 6
    }

    /// The largest areas looked at for things lying on them: each costs a pass over its bounds.
    private static let maxSurfaces = 32

    /// Adds `boxes` to `kept`, largest first, leaving out any within four
    /// pixels a side of one already kept: of a card's fill and the border
    /// line around it, the border's box stays.
    private static func merged(_ boxes: [PixelBox], into kept: [PixelBox]) -> [PixelBox] {
        var kept = kept
        for box in boxes.sorted(by: { $0.area > $1.area }) {
            let isRepeat = kept.contains {
                abs($0.minX - box.minX) <= 4 && abs($0.minY - box.minY) <= 4
                    && abs($0.maxX - box.maxX) <= 4 && abs($0.maxY - box.maxY) <= 4
            }
            if !isRepeat { kept.append(box) }
        }
        return kept
    }
}

/// Inclusive pixel bounds.
private nonisolated struct PixelBox: Hashable {
    var minX: Int, minY: Int, maxX: Int, maxY: Int
    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
    var area: Int { width * height }
    var rect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }
}

/// The image split into 4-connected areas of one exact color.
private nonisolated struct FlatAreas {
    let width: Int
    let height: Int
    /// The area each pixel belongs to.
    let label: [Int32]
    let count: Int
    let size: [Int32]
    private let color: [UInt32]
    private let minX: [Int32], minY: [Int32], maxX: [Int32], maxY: [Int32]

    init(_ bitmap: SmartAreaBitmap) {
        let width = bitmap.width, height = bitmap.height, total = width * height
        // Union-find; the root of an area is always its first pixel in reading order.
        var parent = [Int32](repeating: 0, count: total)
        var label = [Int32](repeating: 0, count: total)
        var size: [Int32] = [], color: [UInt32] = []
        var minX: [Int32] = [], minY: [Int32] = [], maxX: [Int32] = [], maxY: [Int32] = []
        bitmap.pixels.withUnsafeBufferPointer { pixels in
            parent.withUnsafeMutableBufferPointer { parent in
                func root(_ start: Int) -> Int {
                    var index = start
                    while Int(parent[index]) != index {
                        parent[index] = parent[Int(parent[index])]
                        index = Int(parent[index])
                    }
                    return index
                }
                for y in 0..<height {
                    let row = y * width
                    for x in 0..<width {
                        let index = row + x
                        let color = pixels[index]
                        var mine = index
                        if x > 0, pixels[index - 1] == color { mine = root(index - 1) }
                        if y > 0, pixels[index - width] == color {
                            let above = root(index - width)
                            if above < mine {
                                if mine != index { parent[mine] = Int32(above) }
                                mine = above
                            } else if mine < above {
                                parent[above] = Int32(mine)
                            }
                        }
                        parent[index] = Int32(mine)
                    }
                }
                label.withUnsafeMutableBufferPointer { label in
                    for y in 0..<height {
                        let row = y * width
                        for x in 0..<width {
                            let index = row + x
                            let top = root(index)
                            if top == index {
                                label[index] = Int32(size.count)
                                size.append(1)
                                color.append(pixels[index])
                                minX.append(Int32(x)); maxX.append(Int32(x))
                                minY.append(Int32(y)); maxY.append(Int32(y))
                            } else {
                                let id = Int(label[top])
                                label[index] = Int32(id)
                                size[id] += 1
                                if Int32(x) < minX[id] { minX[id] = Int32(x) }
                                if Int32(x) > maxX[id] { maxX[id] = Int32(x) }
                                maxY[id] = Int32(y)
                            }
                        }
                    }
                }
            }
        }
        self.width = width
        self.height = height
        self.label = label
        self.count = size.count
        self.size = size
        self.color = color
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }

    func box(_ id: Int) -> PixelBox {
        PixelBox(minX: Int(minX[id]), minY: Int(minY[id]), maxX: Int(maxX[id]), maxY: Int(maxY[id]))
    }

    /// The area lies along most of each side of its bounds, within a band an
    /// eighth of the bounds deep: rounded corners and pills pass, an L or a
    /// letter doesn't.
    func reachesAllSides(_ id: Int) -> Bool {
        let box = box(id), id = Int32(id)
        let bandX = max(1, box.width / 8), bandY = max(1, box.height / 8)
        return label.withUnsafeBufferPointer { label in
            func covers(columns: Range<Int>, rows: Range<Int>, alongX: Bool) -> Bool {
                var hit = 0
                if alongX {
                    for x in columns where rows.contains(where: { label[$0 * width + x] == id }) { hit += 1 }
                    return hit * 10 >= columns.count * 6
                }
                for y in rows where columns.contains(where: { label[y * width + $0] == id }) { hit += 1 }
                return hit * 10 >= rows.count * 6
            }
            let columns = box.minX..<(box.maxX + 1), rows = box.minY..<(box.maxY + 1)
            return covers(columns: columns, rows: box.minY..<(box.minY + bandY), alongX: true)
                && covers(columns: columns, rows: (box.maxY + 1 - bandY)..<(box.maxY + 1), alongX: true)
                && covers(columns: box.minX..<(box.minX + bandX), rows: rows, alongX: false)
                && covers(columns: (box.maxX + 1 - bandX)..<(box.maxX + 1), rows: rows, alongX: false)
        }
    }

    /// For an area that is mostly empty inside, such as a line around a box:
    /// its color differs visibly from what lies just outside the middle of
    /// its sides. A border line does; the bands of a soft shadow, each a
    /// level or two from the next, don't.
    func standsOut(_ id: Int, in bitmap: SmartAreaBitmap) -> Bool {
        let box = box(id), own = color[id]
        let middleX = (box.minX + box.maxX) / 2, middleY = (box.minY + box.maxY) / 2
        var sides = 0, distinct = 0
        for (x, y) in [(middleX, box.minY - 1), (middleX, box.maxY + 1), (box.minX - 1, middleY), (box.maxX + 1, middleY)]
        where x >= 0 && y >= 0 && x < width && y < height {
            let other = bitmap.pixels[y * width + x]
            let difference = (0..<3).map { abs(Int(own >> ($0 * 8) & 0xFF) - Int(other >> ($0 * 8) & 0xFF)) }.max() ?? 0
            sides += 1
            if difference >= 6 { distinct += 1 }
        }
        return distinct * 2 > sides
    }

    /// The bounds of each 8-connected group of pixels inside `bounds` whose
    /// area passes `isMember`. A group cut off by one side of the bounds still
    /// counts (a card half out of view); one that reaches two sides is the
    /// surroundings, not a thing lying there.
    /// `minFill` is the percentage of its bounds a group must cover.
    func groups(in bounds: PixelBox, minSide: Int, minFill: Int = 0, isMember: (Int32) -> Bool) -> [PixelBox] {
        let w = bounds.width, h = bounds.height
        var parent = [Int32](repeating: -1, count: w * h)
        var result: [PixelBox] = []
        label.withUnsafeBufferPointer { label in
            parent.withUnsafeMutableBufferPointer { parent in
                func root(_ start: Int) -> Int {
                    var index = start
                    while Int(parent[index]) != index {
                        parent[index] = parent[Int(parent[index])]
                        index = Int(parent[index])
                    }
                    return index
                }
                func join(_ a: Int, _ b: Int) -> Int {
                    let a = root(a), b = root(b)
                    if a == b { return a }
                    parent[max(a, b)] = Int32(min(a, b))
                    return min(a, b)
                }
                for y in 0..<h {
                    let source = (bounds.minY + y) * width + bounds.minX
                    for x in 0..<w where isMember(label[source + x]) {
                        let index = y * w + x
                        var mine = index
                        parent[index] = Int32(index)
                        if x > 0, parent[index - 1] >= 0 { mine = join(mine, index - 1) }
                        if y > 0 {
                            if parent[index - w] >= 0 { mine = join(mine, index - w) }
                            if x > 0, parent[index - w - 1] >= 0 { mine = join(mine, index - w - 1) }
                            if x < w - 1, parent[index - w + 1] >= 0 { mine = join(mine, index - w + 1) }
                        }
                    }
                }
                // A group's root is its first pixel in reading order, so its slot exists before its other pixels.
                var boxes: [PixelBox] = []
                var filled: [Int] = []
                var slot = [Int32](repeating: 0, count: w * h)
                for y in 0..<h {
                    for x in 0..<w where parent[y * w + x] >= 0 {
                        let index = y * w + x, top = root(index)
                        if top == index {
                            slot[index] = Int32(boxes.count)
                            boxes.append(PixelBox(minX: x, minY: y, maxX: x, maxY: y))
                            filled.append(1)
                        } else {
                            let at = Int(slot[top])
                            if x < boxes[at].minX { boxes[at].minX = x }
                            if x > boxes[at].maxX { boxes[at].maxX = x }
                            boxes[at].maxY = y
                            filled[at] += 1
                        }
                    }
                }
                for (box, filled) in zip(boxes, filled) where box.width >= minSide && box.height >= minSide {
                    guard SmartAreaDetector.isSolid(box, filled: filled, minSide: minSide),
                          filled * 100 >= box.area * minFill else { continue }
                    let sides = [box.minX == 0, box.minY == 0, box.maxX == w - 1, box.maxY == h - 1].filter { $0 }.count
                    guard sides <= 1 else { continue }
                    result.append(PixelBox(minX: box.minX + bounds.minX, minY: box.minY + bounds.minY,
                                      maxX: box.maxX + bounds.minX, maxY: box.maxY + bounds.minY))
                }
            }
        }
        return result
    }
}

/// The boxes Shift can snap to on one display, in the display's points from
/// its top-left corner.
nonisolated struct SmartAreaCandidates: Sendable {
    /// The shortest side of a box worth snapping to, in points: a small button.
    static let minimumSide: CGFloat = 20

    /// Found in the frozen frame's pixels.
    let boxes: [CGRect]
    /// App windows, front to back: exact frames, free from the window server.
    let windows: [CGRect]
    let display: CGRect

    /// `pixelBoxes` are `SmartAreaDetector`'s, `scale` the frame's pixels per point.
    init(pixelBoxes: [CGRect], scale: CGFloat, windows: [CGRect], displaySize: CGSize) {
        display = CGRect(origin: .zero, size: displaySize)
        boxes = pixelBoxes.map {
            CGRect(x: $0.minX / scale, y: $0.minY / scale, width: $0.width / scale, height: $0.height / scale)
        }
        self.windows = windows
    }

    /// The boxes under `point`, smallest first and ending with the whole
    /// display: the first is the one Shift highlights, the rest are what the
    /// scroll wheel steps out to. Of the windows only the one in front at the
    /// point counts; a box within two points of a larger one is left out.
    func stack(at point: CGPoint) -> [CGRect] {
        var stack = boxes.filter { $0.contains(point) }
        if let window = windows.first(where: { $0.contains(point) })?.intersection(display), !window.isEmpty {
            stack.append(window)
        }
        stack.append(display)
        stack.sort { $0.width * $0.height > $1.width * $1.height }
        var kept: [CGRect] = []
        for box in stack where !kept.contains(where: { Self.isNear($0, box) }) { kept.append(box) }
        return kept.reversed()
    }

    private static func isNear(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.maxX - b.maxX) <= 2 && abs(a.maxY - b.maxY) <= 2
    }
}

/// Where the Option loupe goes and which pixels it shows. The view's
/// coordinates start bottom-left, the frozen frame's top-left.
nonisolated struct SmartAreaLoupe {
    /// Pixels shown across, odd so the pointer's pixel is in the middle.
    static let pixels = 25
    /// Points per pixel shown.
    static let cell: CGFloat = 7

    /// The loupe in the view: above and right of the pointer, clear of the
    /// size shown below it; on the other side where the display ends.
    let frame: CGRect
    /// The frame's pixels to show, cut to the frame at a display's edge.
    let source: CGRect
    /// Where those pixels go in the view.
    let destination: CGRect
    /// The pointer inside the loupe: where an edge drawn now would land.
    let crosshair: CGPoint

    init(pointer: CGPoint, viewSize: CGSize, scale: CGFloat, imageSize: CGSize) {
        let side = CGFloat(Self.pixels) * Self.cell, gap: CGFloat = 24
        frame = CGRect(
            x: pointer.x + gap + side <= viewSize.width ? pointer.x + gap : pointer.x - gap - side,
            y: pointer.y + gap + side <= viewSize.height ? pointer.y + gap : pointer.y - 2 * gap - side,
            width: side, height: side
        )
        let x = pointer.x * scale, y = (viewSize.height - pointer.y) * scale
        let wanted = CGRect(x: x.rounded(.down) - CGFloat(Self.pixels / 2), y: y.rounded(.down) - CGFloat(Self.pixels / 2),
                            width: CGFloat(Self.pixels), height: CGFloat(Self.pixels))
        source = wanted.intersection(CGRect(origin: .zero, size: imageSize))
        destination = CGRect(
            x: frame.minX + (source.minX - wanted.minX) * Self.cell,
            y: frame.maxY - (source.maxY - wanted.minY) * Self.cell,
            width: source.width * Self.cell, height: source.height * Self.cell
        )
        crosshair = CGPoint(x: frame.minX + (x - wanted.minX) * Self.cell, y: frame.maxY - (y - wanted.minY) * Self.cell)
    }
}
