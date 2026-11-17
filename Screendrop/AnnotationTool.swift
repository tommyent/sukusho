//
//  AnnotationTool.swift
//  Screendrop
//

enum AnnotationTool: String, CaseIterable, Identifiable, Codable {
    case select
    case rectangle
    case filledRectangle
    case ellipse
    case line
    case arrow
    case freehand
    case highlighter
    case numberedCircle
    case text
    case highlight
    case pixelate
    case blur
    case magnifier

    var id: String { rawValue }

    /// Keep the old raw value readable without giving a fill style its own tool.
    var paletteTool: AnnotationTool { self == .filledRectangle ? .rectangle : self }

    static var paletteTools: [AnnotationTool] { allCases.filter { $0 != .select && $0 != .filledRectangle } }

    var title: String {
        switch self {
        case .select:
            "Select"
        case .rectangle:
            "Rectangle"
        case .filledRectangle:
            "Solid rectangle"
        case .ellipse:
            "Circle"
        case .line:
            "Straight line"
        case .arrow:
            "Arrow"
        case .freehand:
            "Freehand"
        case .highlighter:
            "Highlighter"
        case .numberedCircle:
            "Numbered circle"
        case .pixelate:
            "Pixelate"
        case .blur:
            "Blur"
        case .text:
            "Text"
        case .highlight:
            "Spotlight"
        case .magnifier:
            "Magnifier"
        }
    }

    var systemImage: String {
        switch self {
        case .select:
            "cursorarrow"
        case .rectangle:
            "rectangle"
        case .filledRectangle:
            "square.fill"
        case .ellipse:
            "circle"
        case .line:
            "line.diagonal"
        case .arrow:
            "arrow.up.right"
        case .freehand:
            "scribble"
        case .highlighter:
            "highlighter"
        case .numberedCircle:
            "1.circle.fill"
        case .pixelate:
            "app.background.dotted"
        case .blur:
            "drop.fill"
        case .text:
            "textformat"
        case .highlight:
            "square.dashed.inset.filled"
        case .magnifier:
            "plus.magnifyingglass"
        }
    }

    var helpText: String {
        let shortcut: String
        switch self {
        case .select, .filledRectangle, .freehand: return title
        case .highlighter: return "Highlighter: draw a horizontal or vertical line"
        case .rectangle: shortcut = "R"
        case .ellipse: shortcut = "O"
        case .line: shortcut = "L"
        case .arrow: shortcut = "A"
        case .numberedCircle: shortcut = "N"
        case .text: shortcut = "T"
        case .highlight: return "Spotlight: keep this area visible and dim everything outside"
        case .pixelate: shortcut = "P"
        case .blur: shortcut = "B"
        case .magnifier: shortcut = "M"
        }
        return "\(title) (\(shortcut))"
    }

    var isRedactionTool: Bool {
        self == .pixelate || self == .blur
    }

    var supportsColorStyle: Bool {
        switch self {
        case .rectangle, .filledRectangle, .ellipse, .line, .arrow, .freehand, .highlighter, .numberedCircle, .text, .magnifier:
            true
        case .select, .pixelate, .blur, .highlight:
            false
        }
    }

    var supportsStrokeStyle: Bool {
        switch self {
        case .rectangle, .ellipse, .line, .arrow, .freehand, .highlighter, .magnifier:
            true
        case .select, .filledRectangle, .numberedCircle, .pixelate, .blur, .text, .highlight:
            false
        }
    }

    var supportsRedactionDensityStyle: Bool {
        isRedactionTool
    }

    var supportsHandDrawnStyle: Bool {
        [.rectangle, .filledRectangle, .ellipse, .line, .arrow].contains(self)
    }


    var createsAnnotation: Bool {
        self != .select
    }

    /// Whether a press on a pasted picture draws on it instead of grabbing it (sd-zt9e). Blur,
    /// pixelate and the magnifier read the screenshot's own pixels, so they grab it as Select does.
    var drawsOverPictures: Bool {
        createsAnnotation && ![.blur, .pixelate, .magnifier].contains(self)
    }
}

/// What the inspector's pinned tool slot is about: an annotation tool (the one drawn with, or the
/// one annotation selected), several annotations, or one of the dock's modes, which outrank both.
enum AnnotationToolSlot: Equatable {
    case tool(AnnotationTool)
    case annotations(Int)
    case crop
    case pickColor
    case measure

    static func current(
        tool: AnnotationTool?, selectionCount: Int,
        isCropping: Bool, isPickingColor: Bool, isMeasuring: Bool
    ) -> AnnotationToolSlot {
        if isCropping { return .crop }
        if isPickingColor { return .pickColor }
        if isMeasuring { return .measure }
        return selectionCount > 1 ? .annotations(selectionCount) : .tool(tool ?? .select)
    }

    var heading: String {
        switch self {
        case .tool(let tool): tool.title
        case .annotations(let count): "\(count) Annotations"
        case .crop: "Crop"
        case .pickColor: "Pick Color"
        case .measure: "Measure"
        }
    }

    /// One line of help, shown where the tool's options leave room.
    var line: String {
        switch self {
        case .tool(let tool):
            switch tool {
            case .select: "Click an annotation to change it, or drag across several."
            case .numberedCircle: "Click to place the next number. Its color is in the toolbar."
            case .text: "Click to type. Drag a corner to resize."
            case .highlight: "Keeps an area visible and dims everything outside."
            case .highlighter: "Draws a straight line across or down. Color and width are in the toolbar."
            case .pixelate, .blur: "Drag over what to hide."
            case .rectangle, .filledRectangle, .ellipse, .line, .arrow, .freehand, .magnifier:
                "Color and width are in the toolbar."
            }
        case .annotations: "Their color and width are in the toolbar."
        case .crop: "Drag the edges, or ⌘-click a box in the image. Press Return to crop."
        case .pickColor: "Click the image to copy a color’s hex. Tab copies the color under the pointer any time."
        case .measure: "Point at the image for width and height. Hold 1 or 2 with any tool."
        }
    }
}
