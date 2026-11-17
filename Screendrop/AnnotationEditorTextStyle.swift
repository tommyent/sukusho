//
//  AnnotationEditorTextStyle.swift
//  Screendrop
//

import AppKit
import CoreGraphics

/// The inspector's text controls. Each setter updates the style new text will use *and* whatever
/// text is selected; the engine re-measures the box from the same layout the glyphs come from, so
/// a font change reflows it without a round trip through a text view.
extension AnnotationEditorModel {
    private var selectedTextShape: AnnoShape? {
        guard engine.selectedIds.count == 1, let shape = engine.selectedShapes.first, shape.isText else {
            return nil
        }
        return shape
    }

    var isTextStyleAvailable: Bool {
        if !engine.selectedIds.isEmpty { return selectedTextShape != nil }
        return selectedTool == .text
    }

    var selectedTextFontFamily: AnnoFontFamily {
        selectedTextShape?.textProps?.fontFamily ?? textFontFamily
    }

    /// A face outside the SF families, by PostScript name; nil is the family.
    var selectedTextFontFace: String? {
        if let props = selectedTextShape?.textProps { return props.fontFace }
        return textFontFace
    }

    var selectedTextIsBold: Bool {
        get { selectedTextShape?.textProps?.isBold ?? textIsBold }
        set { setTextBold(newValue) }
    }

    var selectedTextIsItalic: Bool {
        get { selectedTextShape?.textProps?.isItalic ?? textIsItalic }
        set { setTextItalic(newValue) }
    }

    var selectedTextIsUnderline: Bool {
        get { selectedTextShape?.textProps?.isUnderline ?? textIsUnderline }
        set { setTextUnderline(newValue) }
    }

    var selectedTextAlignment: NSTextAlignment {
        get { selectedTextShape?.textProps?.align.nsTextAlignment ?? textAlignment }
        set { setTextAlignment(newValue) }
    }

    var selectedTextBoxStyle: TextBoxStyle {
        get { selectedTextShape?.textProps.map { $0.boxStyle ?? .plain } ?? textBoxStyle }
        set { setTextBoxStyle(newValue) }
    }

    /// An SF family, or a face (`AnnoFontFace`) with the family to fall back on.
    func setTextFont(_ family: AnnoFontFamily, face: String? = nil) {
        textFontFamily = family
        textFontFace = face
        engine.currentFontFamily = family
        engine.currentFontFace = face
        saveAnnotationPreset()
        updateSelectedText {
            $0.fontFamily = family
            $0.fontFace = face
        }
    }

    /// ⌘⌥+ and ⌘⌥− (⌘+ and ⌘− zoom): with a lone label selected, or nothing selected.
    var canStepTextSize: Bool { engine.selectedIds.isEmpty || selectedTextShape != nil }

    /// One step bigger (1) or smaller (-1) for the selected label, and for the next text.
    func stepTextSize(by direction: Int) {
        let current = selectedTextShape?.textProps.map { CGFloat($0.fontSize) } ?? textFontSize
        let size = AnnotationTextMetrics.steppedFontSize(current, by: direction)
        textFontSize = size
        engine.currentTextFontSize = Double(size)
        saveAnnotationPreset()
        updateSelectedText { $0.fontSize = Double(size) }
    }

    func setTextBold(_ bold: Bool) {
        textIsBold = bold
        engine.currentTextIsBold = bold
        saveAnnotationPreset()
        updateSelectedText { $0.isBold = bold }
    }

    func setTextItalic(_ italic: Bool) {
        textIsItalic = italic
        engine.currentTextIsItalic = italic
        saveAnnotationPreset()
        updateSelectedText { $0.isItalic = italic }
    }

    func setTextUnderline(_ underline: Bool) {
        textIsUnderline = underline
        engine.currentTextIsUnderline = underline
        saveAnnotationPreset()
        updateSelectedText { $0.isUnderline = underline }
    }

    func setTextAlignment(_ alignment: NSTextAlignment) {
        textAlignment = alignment
        engine.currentTextAlign = TextAlign(alignment)
        saveAnnotationPreset()
        updateSelectedText { $0.align = TextAlign(alignment) }
    }

    func setTextBoxStyle(_ style: TextBoxStyle) {
        textBoxStyle = style
        engine.currentTextBoxStyle = style
        saveAnnotationPreset()
        updateSelectedText { $0.boxStyle = style }
    }

    private func updateSelectedText(_ mutate: (inout TextProps) -> Void) {
        guard selectedTextShape != nil else { return }
        engine.applyStyleToSelection { shape in
            guard case var .text(props) = shape.kind else { return }
            mutate(&props)
            shape.kind = .text(props)
        }
    }
}
