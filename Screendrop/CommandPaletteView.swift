//
//  CommandPaletteView.swift
//  Screendrop
//
//  The command palette as Hashbrown draws it (sd-458l, the owner's revision of 2026-11-24): one column under the
//  toolbar, group headings, a key line at the bottom, and the selected row filled with the accent. Typed letters are
//  swiped with the Highlighter's see-through yellow. The panel is drawn on the theme's own surfaces. The model is
//  `CommandPaletteModel`; this view only draws it.
//

import AppKit
import QuickLookThumbnailing
import SwiftUI

struct CommandPaletteView: View {
    @Bindable var model: CommandPaletteModel
    /// The tallest the palette may be: it stays inside the window it opens over.
    let maxHeight: CGFloat
    let onSize: (CGSize) -> Void

    @CurrentTheme private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var focused: Bool

    static let rowHeight: CGFloat = 30
    static let captureRowHeight: CGFloat = 46
    static let headingHeight: CGFloat = 24
    private static let fieldHeight: CGFloat = 48
    private static let keyLineHeight: CGFloat = 30

    private var ink: Color { theme.ink.primary.color }
    private var increasedContrast: Bool { contrast == .increased }
    private var frosted: Bool { theme.card.recipe.frost != nil && !reduceTransparency && !increasedContrast }
    private var radius: CGFloat { theme.card.recipe.flatEdge != nil ? 0 : DS.Radius.card }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    var body: some View {
        let rows = model.rows
        VStack(spacing: 0) {
            field
            hairline
            if model.isNoMatch, let offer = rows.first {
                noMatch(offer)
            } else {
                list(rows)
            }
            hairline
            keyLine
        }
        .frame(width: CommandPalettePresenter.width)
        .background { surface }
        .clipShape(shape)
        .overlay { edge }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .onAppear { focused = true }
        .onChange(of: model.steps) { _, _ in focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 10) {
            if model.isFirstList {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ink.opacity(0.55)).accessibilityHidden(true)
            } else {
                Button { model.back() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                        Text(stepTitle).font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(ink.opacity(0.85))
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(ink.opacity(0.12), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Back (Esc)")
                .accessibilityLabel("Back to \(model.steps.count > 2 ? "the step before" : "all commands")")
            }
            TextField(model.placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(ink)
                .focused($focused)
                .accessibilityLabel(model.placeholder)
            PaletteKeyCaps(keys: model.isFirstList ? openingKeys : ["esc"], ink: ink)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.fieldHeight)
    }

    private var stepTitle: String {
        PaletteCommand.catalog.first { $0.step == model.step }?.title ?? ""
    }

    /// The keys that open and close it, as Settings › Shortcuts holds them (⇧⌘P unless changed); none when cleared.
    private var openingKeys: [String] {
        let _ = HotkeyManager.shared.revision
        return CaptureHotkeyPreferences.shortcut(for: .commandPalette)?.displayTokens ?? []
    }

    // MARK: List

    private func list(_ rows: [PaletteRow]) -> some View {
        let showsHeadings = model.isFirstList && model.query.trimmingCharacters(in: .whitespaces).isEmpty
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        Text(model.step == .searchCaptures ? "Type what to look for." : model.step == .addTag ? "Type a tag’s name."
                             : model.query.isEmpty ? "Nothing here yet." : "Nothing matches.")
                            .font(.system(size: 13)).foregroundStyle(ink.opacity(0.55))
                            .padding(.horizontal, 10).frame(height: Self.rowHeight)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if showsHeadings, let group = row.group, index == 0 || rows[index - 1].group != group {
                            heading(group)
                        }
                        button(row, selected: index == model.selected) {
                            model.selected = index
                            model.submit()
                        }
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
            .frame(height: listHeight(rows, headings: showsHeadings))
            .onChange(of: model.selected) { _, index in
                if rows.indices.contains(index) { proxy.scrollTo(rows[index].id) }
            }
            .onChange(of: model.steps) { _, _ in
                let rows = model.rows
                if rows.indices.contains(model.selected) { proxy.scrollTo(rows[model.selected].id, anchor: .center) }
            }
        }
    }

    private func height(of row: PaletteRow) -> CGFloat {
        row.subtitle.isEmpty && row.thumbnail == nil ? Self.rowHeight : Self.captureRowHeight
    }

    private func listHeight(_ rows: [PaletteRow], headings: Bool) -> CGFloat {
        var height: CGFloat = 12
        var group: PaletteGroup?
        for row in rows {
            if headings, row.group != group { height += Self.headingHeight; group = row.group }
            height += self.height(of: row)
        }
        let room = maxHeight - Self.fieldHeight - Self.keyLineHeight - 2
        return min(max(height, Self.rowHeight + 12), room)
    }

    private func heading(_ group: PaletteGroup) -> some View {
        Text(group == .selection ? model.host.selectionTitle ?? group.title : group.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ink.opacity(0.55))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .frame(height: Self.headingHeight, alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }

    /// A row as a plain native button, so VoiceOver's press runs it as a click does; a switch says it's a switch and its
    /// state, a grey row why it can't run, and pressing that does nothing (Sol's finding 10).
    private func button(_ row: PaletteRow, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { line(row, selected: selected) }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel(row))
            .accessibilityValue(accessibilityValue(row))
            .accessibilityHint(row.reason.map { "Unavailable: \($0)" } ?? (row.opens != nil ? "Opens a list" : ""))
            .accessibilityAddTraits(row.isOn != nil ? [.isToggle] : [])
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A row; the selected one is filled with the accent, as Hashbrown's is, and its words are white on it, all of them
    /// at full strength: at 70 and 85 % a grey row's words fell below 4.5:1 on a yellow accent (Sol's finding 11). There
    /// its reason says it's grey.
    private func line(_ row: PaletteRow, selected: Bool) -> some View {
        let enabled = row.isEnabled
        let onFill = selected
        let titleInk: Color = onFill ? .white.opacity(PaletteAccent.textOnFill) : enabled ? ink.opacity(0.9) : ink.opacity(0.36)
        let muted: Color = onFill ? .white.opacity(PaletteAccent.textOnFill) : ink.opacity(enabled ? 0.55 : 0.45)
        return HStack(spacing: 10) {
            leading(row, ink: onFill ? .white : enabled ? ink.opacity(0.75) : ink.opacity(0.32), onFill: onFill)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(marked(row, onFill: onFill)).font(.system(size: 13, weight: .medium)).foregroundStyle(titleInk)
                        .lineLimit(1).truncationMode(.middle)
                    if !row.detail.isEmpty {
                        Text(row.detail).font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
                    }
                    if row.isBeta { BetaTag() }
                    if let reason = row.reason {
                        Text(reason).font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
                    }
                }
                if !row.subtitle.isEmpty {
                    Text(row.subtitle).font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if let isOn = row.isOn {
                Text(isOn ? "On" : "Off").font(.system(size: 11)).foregroundStyle(muted)
                PaletteSwitchGlyph(isOn: isOn, ink: onFill ? .white : ink)
            }
            if row.ticked && model.step != .addTag {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(onFill ? .white : Color.accentColor)
            }
            if !row.keys.isEmpty {
                PaletteKeyCaps(keys: row.keys, ink: onFill ? .white : ink, dimmed: !enabled && !onFill, onFill: onFill)
            }
            if row.opens != nil {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height(of: row))
        .background {
            if selected { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(liftedAccent) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
    }

    @ViewBuilder
    private func leading(_ row: PaletteRow, ink: Color, onFill: Bool) -> some View {
        if let url = row.thumbnail {
            PaletteThumbnail(url: url).frame(width: 52, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else if model.step == .changeTheme {
            PaletteThemeSwatch(theme: AppTheme.named(row.choiceID, dark: scheme == .dark)).frame(width: 30, height: 20)
        } else if model.step == .addTag {
            Image(systemName: row.ticked ? "checkmark.square.fill" : row.id == "new-tag" ? "plus.square" : "square")
                .font(.system(size: 14)).foregroundStyle(row.ticked && !onFill ? Color.accentColor : ink).frame(width: 18)
        } else if let symbol = row.symbol {
            // Record's red dot, except on the fill, where only white reads.
            Image(systemName: symbol).font(.system(size: 13))
                .foregroundStyle(symbol == "record.circle" && !onFill ? Palette.record : ink)
                .frame(width: 18)
        } else {
            Color.clear.frame(width: 18, height: 1)
        }
    }

    /// The title with the typed letters swiped by the Highlighter: its yellow at the strength the editor draws it. On the
    /// selected row's fill the see-through yellow leaves white letters at about 3.6:1, so there it's solid, under dark
    /// letters.
    private func marked(_ row: PaletteRow, onFill: Bool) -> AttributedString {
        var text = AttributedString(row.title)
        let characters = text.characters
        let yellow = Color(red: 1, green: 0.82, blue: 0.18)
        for range in row.marks where range.upperBound <= characters.count {
            let start = characters.index(characters.startIndex, offsetBy: range.lowerBound)
            let end = characters.index(characters.startIndex, offsetBy: range.upperBound)
            text[start ..< end].backgroundColor = onFill ? yellow : yellow.opacity(0.35)
            if onFill { text[start ..< end].foregroundColor = .black }
        }
        return text
    }

    private func accessibilityLabel(_ row: PaletteRow) -> String {
        var parts = [row.title]
        if !row.detail.isEmpty { parts.append(row.detail) }
        if !row.subtitle.isEmpty { parts.append(row.subtitle) }
        if !row.keys.isEmpty { parts.append(row.keys.joined()) }
        return parts.joined(separator: ", ")
    }

    /// A switch's state, a step's choice in use, and a grey row's reason, read as the row's value.
    private func accessibilityValue(_ row: PaletteRow) -> String {
        var parts: [String] = []
        if let isOn = row.isOn { parts.append(isOn ? "on" : "off") }
        if row.ticked { parts.append("in use") }
        if let reason = row.reason { parts.append("unavailable, \(reason)") }
        return parts.joined(separator: ", ")
    }

    // MARK: No match

    /// What no command matches can still do: search the captures for it.
    private func noMatch(_ offer: PaletteRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No command matches “\(model.query.trimmingCharacters(in: .whitespaces))”.")
                .font(.system(size: 12)).foregroundStyle(ink.opacity(0.6))
                .padding(.horizontal, 10).frame(height: Self.headingHeight, alignment: .bottomLeading)
            button(offer, selected: true) { model.submit() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Key line

    private var keyLine: some View {
        HStack(spacing: 14) {
            ForEach(Array(model.hints.enumerated()), id: \.offset) { _, hint in
                HStack(spacing: 5) {
                    PaletteKeyCaps(keys: hint.keys, ink: ink)
                    Text(hint.label).font(.system(size: 11)).foregroundStyle(ink.opacity(0.6))
                }
            }
            Spacer(minLength: 8)
            Text(model.place).font(.system(size: 11)).foregroundStyle(ink.opacity(0.6)).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.keyLineHeight)
        .background {
            // Chip's paper is on the key line only: never under a row's words.
            if theme.card.paper > 0 && !increasedContrast { CardPaperGrain().opacity(theme.card.paper) }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Surface

    private var hairline: some View {
        Rectangle().fill(ink.opacity(increasedContrast ? 0.4 : 0.1)).frame(height: 1)
    }

    private var face: LinearGradient {
        LinearGradient(colors: theme.card.face.map(\.color), startPoint: .top, endPoint: .bottom)
    }

    /// The theme's own surface, as its cards are drawn: Classic's stock face with its gloss, Chip's flat face, or Glass's
    /// frost over the window behind. Reduce Transparency and Increase Contrast draw Glass's opaque face, Classic's.
    @ViewBuilder private var surface: some View {
        if frosted, let frost = theme.card.recipe.frost {
            ZStack {
                shape.fill(frost.material.material)
                shape.fill(frost.tint.color)
            }
        } else if case .stock(let stock) = theme.card.recipe {
            ZStack(alignment: .top) {
                shape.fill(face)
                // The gloss along the face's top, as on a Classic card.
                Rectangle().fill(stock.gloss.color).frame(height: 1).padding(.horizontal, radius)
            }
        } else {
            shape.fill(face)
        }
    }

    @ViewBuilder private var edge: some View {
        if increasedContrast {
            shape.strokeBorder(ink.opacity(0.65), lineWidth: 1)
        } else if let flat = theme.card.recipe.flatEdge {
            shape.strokeBorder(flat.color, lineWidth: 1)
        } else if frosted {
            // The ⌃⌘V popup's rim: Glass's own is clear, and a floating panel needs its edge.
            shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        } else if case .stock(let stock) = theme.card.recipe {
            shape.strokeBorder(stock.upperLip.color, lineWidth: 0.5)
        }
    }

    /// The accent, darkened until white text reads on it at 4.5:1.
    private var liftedAccent: Color {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let lifted = PaletteAccent.liftedForWhiteText(.init(red: accent.redComponent, green: accent.greenComponent, blue: accent.blueComponent))
        return Color(red: lifted.red, green: lifted.green, blue: lifted.blue)
    }
}

// MARK: - Parts

/// One keycap per key, as Settings › Shortcuts draws a recorded shortcut.
struct PaletteKeyCaps: View {
    let keys: [String]
    let ink: Color
    var dimmed = false
    /// On the selected row's fill, where the letters need full white.
    var onFill = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(ink.opacity(onFill ? PaletteAccent.textOnFill : dimmed ? 0.35 : 0.7))
                    .padding(.horizontal, key.count > 1 ? 4 : 0)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(ink.opacity(dimmed ? 0.08 : 0.16), lineWidth: 0.5))
            }
        }
        .fixedSize()
    }
}

/// A switch's state, drawn and not a control: the row is what flips it.
struct PaletteSwitchGlyph: View {
    let isOn: Bool
    let ink: Color

    var body: some View {
        Capsule()
            .fill(isOn ? Palette.success : ink.opacity(0.18))
            .frame(width: 26, height: 15)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 12, height: 12).shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5).padding(1.5)
            }
            .accessibilityHidden(true)
    }
}

/// A theme as a tiny card on its ground, for Change Theme.
struct PaletteThemeSwatch: View {
    let theme: AppTheme

    var body: some View {
        let radius: CGFloat = theme.card.recipe.flatEdge != nil ? 0 : 4
        ZStack {
            if theme.chrome.glass {
                LinearGradient(colors: theme.isDark ? [Color(red: 0.1, green: 0.25, blue: 0.3), Color(red: 0.3, green: 0.15, blue: 0.4)]
                                                    : [Color(red: 0.6, green: 0.8, blue: 0.95), Color(red: 0.95, green: 0.8, blue: 0.7)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                theme.ground.workspace.color
            }
            RoundedRectangle(cornerRadius: radius)
                .fill(theme.chrome.glass ? AnyShapeStyle(.white.opacity(theme.isDark ? 0.2 : 0.55))
                                         : AnyShapeStyle(LinearGradient(colors: theme.card.face.map(\.color), startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder((theme.card.recipe.flatEdge ?? .black).color.opacity(0.3), lineWidth: 0.5))
                .padding(4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// A capture's picture, made by Quick Look so recordings get one too.
struct PaletteThumbnail: View {
    let url: URL
    @State private var image: CGImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let image { Image(decorative: image, scale: scale).resizable().scaledToFill() }
        }
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 104, height: 68), scale: scale,
                                                       representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
        }
        .accessibilityHidden(true)
    }
}
