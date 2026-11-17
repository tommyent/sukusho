//
//  AnnotationTextStyleControls.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// Text's options in the inspector. There is no size control: a label is sized by its corner
/// handles, which show the size while dragging and snap to other labels' sizes (sd-g18y).
struct AnnotationTextStyleControls: View {
    @Bindable var model: AnnotationEditorModel

    var body: some View {
        VStack(spacing: InspectorMetrics.rowSpacing) {
            fontFamilyMenu
                .frame(minWidth: 0, maxWidth: .infinity)

            // With the size gone from this row, the two controls share its width.
            HStack(spacing: 6) {
                InspectorSegmented(
                    options: TextBoxStyle.allCases,
                    isSelected: { $0 == model.selectedTextBoxStyle },
                    onTap: { model.selectedTextBoxStyle = $0 },
                    label: { style in
                        TextBoxStyleIcon(style: style)
                            .help(style.title)
                            .accessibilityLabel(style.title)
                    }
                )
                .frame(maxWidth: .infinity)

                InspectorSegmented(
                    options: TextStyleSegment.allCases,
                    isSelected: { segment in
                        switch segment {
                        case .bold: model.selectedTextIsBold
                        case .italic: model.selectedTextIsItalic
                        case .underline: model.selectedTextIsUnderline
                        }
                    },
                    onTap: { segment in
                        switch segment {
                        case .bold: model.selectedTextIsBold.toggle()
                        case .italic: model.selectedTextIsItalic.toggle()
                        case .underline: model.selectedTextIsUnderline.toggle()
                        }
                    },
                    label: { segment in
                        // A named face has no bold or italic of its own, and none is
                        // synthesized; the setting is kept for when the font changes back.
                        let isInert = model.selectedTextFontFace != nil && segment != .underline
                        Text(segment.title)
                            .font(segment.font)
                            .underline(segment == .underline)
                            .opacity(isInert ? 0.35 : 1)
                            .help(isInert ? "Not available in this font" : "")
                            .accessibilityLabel(segment.accessibilityTitle)
                    }
                )
                .frame(maxWidth: .infinity)
            }

            InspectorSegmented(
                options: TextAlignmentSegment.allCases,
                isSelected: { $0 == TextAlignmentSegment(model.selectedTextAlignment) },
                onTap: { model.selectedTextAlignment = $0.nsTextAlignment },
                label: { segment in
                    Image(systemName: segment.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var fontFamilyMenu: some View {
        Menu {
            ForEach(AnnoFontFamily.allCases) { family in
                fontMenuItem(
                    family.title,
                    isSelected: model.selectedTextFontFace == nil && model.selectedTextFontFamily == family
                ) {
                    model.setTextFont(family)
                }
            }
            fontMenuItem(
                AnnoFontFace.title(AnnoFontFace.markerFelt),
                isSelected: model.selectedTextFontFace == AnnoFontFace.markerFelt
            ) {
                model.setTextFont(.pro, face: AnnoFontFace.markerFelt)
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.selectedTextFontFace.map { AnnoFontFace.title($0) } ?? model.selectedTextFontFamily.title)
                    .font(.inspectorValue)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, InspectorMetrics.fieldInset)
            .inspectorField()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Font family")
    }

    private func fontMenuItem(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

}

extension TextBoxStyle {
    var title: String {
        switch self {
        case .plain: "Plain text"
        case .box: "Text on a box"
        }
    }
}

/// A "T" on its own, or knocked out of a filled square, in the segment's own colour so it follows
/// the selected and hover states like the other segments.
struct TextBoxStyleIcon: View {
    let style: TextBoxStyle

    var body: some View {
        switch style {
        case .plain:
            Text("T")
                .font(.system(size: 12, weight: .bold))
        case .box:
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .frame(width: 14, height: 14)
                .overlay {
                    Text("T")
                        .font(.system(size: 10, weight: .bold))
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}

private enum TextStyleSegment: CaseIterable, Hashable {
    case bold
    case italic
    case underline

    var accessibilityTitle: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .underline: "Underline"
        }
    }

    var title: String {
        switch self {
        case .bold: "B"
        case .italic: "I"
        case .underline: "U"
        }
    }

    var font: Font {
        switch self {
        case .bold:
            .system(size: 12, weight: .bold)
        case .italic:
            .system(size: 12, weight: .regular, design: .serif).italic()
        case .underline:
            .system(size: 12, weight: .regular)
        }
    }
}

private enum TextAlignmentSegment: CaseIterable, Hashable {
    case left
    case center
    case right
    case justified

    init(_ alignment: NSTextAlignment) {
        switch alignment {
        case .center:
            self = .center
        case .right:
            self = .right
        case .justified:
            self = .justified
        default:
            self = .left
        }
    }

    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
    }

    var systemImage: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justified: "text.justify.leading"
        }
    }
}
