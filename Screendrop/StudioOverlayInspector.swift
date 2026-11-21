//
//  StudioOverlayInspector.swift
//  Screendrop
//
//  The inspector pages for a text, image/GIF, or pixelate/blur redaction
//  picked on the timeline or the canvas. Built from the shared Inspector*
//  controls, like every other Studio page. A text's enter and exit effects
//  are tiles that play themselves on hover (when Reduce Motion is off),
//  drawn by the same Core Text renderer as the canvas.
//

import AppKit
import SwiftUI

private enum StudioOverlaySwatches {
    static let text: [RecordingOverlayColor] = [
        .white,
        .black,
        RecordingOverlayColor(red: 1, green: 0.84, blue: 0.04),
        RecordingOverlayColor(red: 1, green: 0.27, blue: 0.23),
        RecordingOverlayColor(red: 0.04, green: 0.52, blue: 1),
        RecordingOverlayColor(red: 0.2, green: 0.78, blue: 0.35)
    ]

    static let background: [RecordingOverlayColor] = [
        .black,
        RecordingOverlayColor(red: 0, green: 0, blue: 0, alpha: 0.6),
        .white,
        RecordingOverlayColor(red: 1, green: 0.84, blue: 0.04),
        RecordingOverlayColor(red: 0.04, green: 0.52, blue: 1),
        RecordingOverlayColor(red: 0.69, green: 0.32, blue: 0.87)
    ]
}

/// A row of preset swatches and a tile that opens the color panel.
private struct StudioOverlayColorRow: View {
    let presets: [RecordingOverlayColor]
    let selection: RecordingOverlayColor
    let onPick: (RecordingOverlayColor) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(presets, id: \.self) { color in
                InspectorTile(title: "Color", isSelected: color == selection) {
                    onPick(color)
                } content: {
                    swatch(color)
                }
            }
            InspectorTile(title: "Custom color", isSelected: !presets.contains(selection)) {
                AnnotationColorPanelBridge.shared.present(current: selection.nsColor) { color in
                    onPick(RecordingOverlayColor(color))
                }
            } content: {
                Rectangle()
                    .fill(Color.primary.opacity(0.05))
                    .overlay {
                        Image(systemName: "eyedropper")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                    }
            }
        }
    }

    private func swatch(_ color: RecordingOverlayColor) -> some View {
        // Translucent colors sit on a checker so their see-through reads.
        Canvas { context, size in
            if color.alpha < 0.999 {
                let cell = size.width / 4
                for row in 0..<Int(ceil(size.height / cell)) {
                    for column in 0..<4 where (row + column).isMultiple(of: 2) {
                        context.fill(
                            Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                            with: .color(.primary.opacity(0.12))
                        )
                    }
                }
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(cgColor: color.cgColor)))
        }
    }
}

// MARK: - Text

struct StudioTextInspectorControls: View {
    @Bindable var model: RecordingStudioModel
    let text: RecordingTextOverlay

    @State private var side: Side = .enter
    @State private var isAnimationExpanded = false

    private enum Side: Hashable, CaseIterable {
        case enter
        case exit

        var title: String { self == .enter ? "In" : "Out" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupSpacing) {
            TextField("Type something…", text: binding(\.text, action: "Edit Text"), axis: .vertical)
                .lineLimit(1...6)
                .inspectorTextField()

            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Font")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                    ForEach(RecordingTextFont.allCases) { font in
                        InspectorTile(title: font.title, aspectRatio: 2.4, isSelected: text.font == font) {
                            edit("Change Font") { $0.font = font }
                        } content: {
                            Rectangle()
                                .fill(Color.primary.opacity(0.05))
                                .overlay {
                                    Text(font.title)
                                        .font(Font(font.font(size: 12, isBold: text.isBold)))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                        .padding(.horizontal, 4)
                                }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorFieldPair {
                    InspectorSlider(
                        "Size",
                        value: Binding(
                            get: { CGFloat(text.fontSize) },
                            set: { value in edit("Change Text Size") { $0.fontSize = Double(value) } }
                        ),
                        range: CGFloat(RecordingTextOverlay.fontSizeRange.lowerBound)...CGFloat(RecordingTextOverlay.fontSizeRange.upperBound),
                        format: .percent(fractionDigits: 1)
                    )
                    .help("Font size as a share of the video's height")
                } trailing: {
                    InspectorToggleRow("Bold", isOn: Binding(
                        get: { text.isBold },
                        set: { isBold in edit("Change Text Weight") { $0.isBold = isBold } }
                    ))
                }

                StudioOverlayColorRow(presets: StudioOverlaySwatches.text, selection: text.color) { color in
                    edit("Change Text Color") { $0.color = color }
                }
            }

            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorToggleRow("Background", isOn: Binding(
                    get: { text.hasBackground },
                    set: { hasBackground in edit("Change Text Background") { $0.hasBackground = hasBackground } }
                ))
                if text.hasBackground {
                    StudioOverlayColorRow(presets: StudioOverlaySwatches.background, selection: text.backgroundColor) { color in
                        edit("Change Text Background") { $0.backgroundColor = color }
                    }
                    .transition(.opacity)
                }
            }

            animationControls
        }
    }

    // MARK: Animation

    private var animation: RecordingTextAnimation {
        side == .enter ? text.animationIn : text.animationOut
    }

    private var animationControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            animationHeader

            if isAnimationExpanded {
                animationDetails
                    .transition(.opacity)
            }
        }
    }

    /// The section folded to one line naming both effects; a click opens
    /// the pickers.
    private var animationHeader: some View {
        Button {
            withAnimation(.foldIfAllowed) { isAnimationExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                InspectorGroupLabel("Animation")
                Spacer(minLength: 8)
                Text("In: \(text.animationIn.effect.title) · Out: \(text.animationOut.effect.title)")
                    .font(.inspectorLabel)
                    .foregroundStyle(Palette.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.tertiaryLabel)
                    .rotationEffect(.degrees(isAnimationExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isAnimationExpanded ? "Hide the animation settings" : "Show the animation settings")
    }

    private var animationDetails: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSegmented(
                options: Side.allCases,
                isSelected: { $0 == side },
                onTap: { side = $0 },
                label: { Text($0.title).font(.inspectorSegment) }
            )

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 6) {
                ForEach(RecordingTextAnimation.Effect.allCases) { effect in
                    StudioTextEffectTile(
                        text: text,
                        isExit: side == .exit,
                        effect: effect,
                        isSelected: animation.effect == effect
                    ) {
                        editAnimation("Change Text Animation") { $0.effect = effect }
                    }
                }
            }

            InspectorSegmented(
                options: RecordingTextAnimation.Unit.allCases,
                isSelected: { $0 == animation.unit },
                onTap: { unit in editAnimation("Change Text Animation") { $0.unit = unit } },
                label: { Text($0.title).font(.inspectorSegment) }
            )
            .help("Animate the whole text at once, word by word, or letter by letter")

            if animation.unit != .all {
                InspectorSegmented(
                    options: RecordingTextAnimation.Order.allCases,
                    isSelected: { $0 == animation.order },
                    onTap: { order in editAnimation("Change Text Animation") { $0.order = order } },
                    label: { Text($0.title).font(.inspectorSegment) }
                )
                .transition(.opacity)
            }

            InspectorFieldPair {
                InspectorSlider(
                    "Duration",
                    value: animationBinding(\.duration),
                    range: CGFloat(RecordingTextAnimation.durationRange.lowerBound)...CGFloat(RecordingTextAnimation.durationRange.upperBound),
                    format: .seconds
                )
            } trailing: {
                InspectorSlider(
                    "Stagger",
                    value: animationBinding(\.delay),
                    range: CGFloat(RecordingTextAnimation.delayRange.lowerBound)...CGFloat(RecordingTextAnimation.delayRange.upperBound),
                    format: .seconds
                )
                .disabled(animation.unit == .all)
                .help("Time between one word or letter starting and the next")
            }
            .disabled(animation.effect == .none && animation.unit == .all)

            InspectorSegmented(
                options: RecordingTextAnimation.Ease.allCases,
                isSelected: { $0 == animation.ease },
                onTap: { ease in editAnimation("Change Text Animation") { $0.ease = ease } },
                label: { Text($0.shortTitle).font(.inspectorSegment) }
            )
            .disabled(animation.effect == .none)
        }
    }

    // MARK: Editing

    private func edit(_ action: String, _ change: (inout RecordingTextOverlay) -> Void) {
        var edited = text
        change(&edited)
        model.editText(edited, actionName: action)
    }

    private func editAnimation(_ action: String, _ change: (inout RecordingTextAnimation) -> Void) {
        edit(action) { overlay in
            if side == .enter {
                change(&overlay.animationIn)
            } else {
                change(&overlay.animationOut)
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<RecordingTextOverlay, Value>, action: String) -> Binding<Value> {
        Binding(
            get: { text[keyPath: keyPath] },
            set: { value in edit(action) { $0[keyPath: keyPath] = value } }
        )
    }

    private func animationBinding(_ keyPath: WritableKeyPath<RecordingTextAnimation, TimeInterval>) -> Binding<CGFloat> {
        Binding(
            get: { CGFloat(animation[keyPath: keyPath]) },
            set: { value in editAnimation("Change Text Animation") { $0[keyPath: keyPath] = Double(value) } }
        )
    }
}

private extension RecordingTextAnimation.Ease {
    var shortTitle: String {
        switch self {
        case .linear: "Linear"
        case .out: "Out"
        case .inOut: "In Out"
        case .spring: "Spring"
        }
    }
}

/// One effect in the picker. At rest it holds a frame partway through the
/// effect, as a hint of its motion; hovered (when Reduce Motion is off),
/// it plays on a loop.
private struct StudioTextEffectTile: View {
    let text: RecordingTextOverlay
    let isExit: Bool
    let effect: RecordingTextAnimation.Effect
    let isSelected: Bool
    let onPick: () -> Void

    @State private var isHovering = false
    @State private var hoverStart = Date()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The pretend text is long, so the half-length squeeze never applies.
    private static let previewLength: TimeInterval = 100
    private static let hold: TimeInterval = 0.6

    private var playsHoverPreview: Bool {
        isHovering && !reduceMotion
    }

    var body: some View {
        VStack(spacing: 4) {
            InspectorTile(title: effect.title, aspectRatio: 1.6, isSelected: isSelected, action: onPick) {
                TimelineView(.animation(paused: !playsHoverPreview)) { context in
                    Canvas { graphics, size in
                        graphics.withCGContext { cgContext in
                            draw(in: cgContext, size: size, elapsed: context.date.timeIntervalSince(hoverStart))
                        }
                    }
                }
                .background(Color.primary.opacity(0.05))
                .onHover { hovering in
                    if hovering { hoverStart = Date() }
                    isHovering = hovering
                }
            }
            Text(effect.title)
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? Palette.label : Palette.secondaryLabel)
                .lineLimit(1)
        }
    }

    private func draw(in context: CGContext, size: CGSize, elapsed: TimeInterval) {
        var animation = isExit ? text.animationOut : text.animationIn
        animation.effect = effect
        // A letter at a time would take forever in a thumbnail.
        if animation.unit != .all { animation.delay = min(animation.delay, 0.12) }

        var preview = text
        preview.text = "Text"
        preview.center = CGPoint(x: 0.5, y: 0.5)
        preview.fontSize = 0.3
        preview.hasBackground = false
        preview.color = colorScheme == .dark ? .white : RecordingOverlayColor(red: 0.1, green: 0.1, blue: 0.11)
        let still = RecordingTextAnimation(effect: .none)

        if playsHoverPreview {
            let span = animation.span(units: 4)
            let tau = elapsed.truncatingRemainder(dividingBy: span + Self.hold * 2)
            preview.animationIn = isExit ? still : animation
            preview.animationOut = isExit ? animation : still
            let local = isExit ? Self.previewLength - span - Self.hold + tau : tau
            RecordingTextOverlayRenderer.draw(
                preview, local: local, length: Self.previewLength,
                canvasSize: size, in: context, castsShadow: false
            )
        } else {
            // Partway through a plain, linear run of the whole word.
            var rest = animation
            rest.unit = .all
            rest.ease = .linear
            rest.duration = 1
            preview.animationIn = isExit ? still : rest
            preview.animationOut = isExit ? rest : still
            let progress = effect == .none ? 0 : 0.4
            let local = isExit ? Self.previewLength - 1 + progress : progress
            RecordingTextOverlayRenderer.draw(
                preview, local: local, length: Self.previewLength,
                canvasSize: size, in: context, castsShadow: false
            )
        }
    }
}

// MARK: - Pixelate / Blur Redaction

struct StudioRedactionInspectorControls: View {
    @Bindable var model: RecordingStudioModel
    let redaction: RecordingRedaction

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupSpacing) {
            InspectorSegmented(
                options: RecordingRedaction.Mode.allCases,
                isSelected: { $0 == redaction.mode },
                onTap: { mode in
                    var edited = redaction
                    edited.mode = mode
                    model.updateRedaction(edited, actionName: "Change Redaction Mode")
                },
                label: { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .font(.inspectorSegment)
                }
            )

            InspectorSlider(
                "Strength",
                value: Binding(
                    get: { CGFloat(redaction.strength) },
                    set: { value in edit("Change Redaction Strength") { $0.strength = Double(value) } }
                ),
                range: 0.35...1,
                format: .percent()
            )

            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorGroupLabel("Timing (source seconds)")
                timeField("Start", keyPath: \.start)
                timeField("End", keyPath: \.end)
            }

            if let error = model.redactionEditError {
                InspectorHint(error, tint: .orange)
            }

            InspectorHint("Drag the box on the paused canvas to move it, or its handles to resize it. It stays on the picture through zooms and crops.")
        }
        .disabled(!model.isLoaded || model.hasRunningWork)
    }

    private func edit(_ action: String, _ change: (inout RecordingRedaction) -> Void) {
        var edited = redaction
        change(&edited)
        model.editRedaction(edited, actionName: action)
    }

    private func timeField(_ label: String, keyPath: WritableKeyPath<RecordingRedaction, Double>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.inspectorLabel)
                .foregroundStyle(InspectorControlPalette.label)
                .frame(width: 34, alignment: .leading)
            TextField(label, value: Binding(
                get: { redaction[keyPath: keyPath] },
                set: { value in
                    var updated = redaction
                    updated[keyPath: keyPath] = value
                    model.updateRedaction(updated, actionName: "Retiming Redaction")
                }
            ), format: .number.precision(.fractionLength(2)))
            .inspectorTextField()
            .accessibilityLabel("\(label) in source seconds")
            Button("Playhead") {
                var updated = redaction
                updated[keyPath: keyPath] = model.sourceTime(atEditorTime: model.currentTime)
                model.updateRedaction(updated, actionName: "Retiming Redaction")
            }
            .controlSize(.small)
            .help("Set redaction \(label.lowercased()) to the playhead")
        }
    }
}

// MARK: - Image

struct StudioImageInspectorControls: View {
    @Bindable var model: RecordingStudioModel
    let image: RecordingImageOverlay

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupSpacing) {
            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorFieldPair {
                    InspectorSlider(
                        "Size",
                        value: value(\.width, action: "Resize Image"),
                        range: CGFloat(RecordingImageOverlay.widthRange.lowerBound)...CGFloat(RecordingImageOverlay.widthRange.upperBound),
                        format: .percent()
                    )
                    .help("Width as a share of the video's width")
                } trailing: {
                    InspectorSlider("Opacity", value: value(\.opacity, action: "Change Image Opacity"), range: 0...1, format: .percent())
                }
                InspectorFieldPair {
                    InspectorSlider(
                        "Rotation",
                        value: value(\.rotation, action: "Rotate Image"),
                        range: -180...180,
                        format: .degrees(signed: true)
                    )
                } trailing: {
                    InspectorSlider(
                        "Corners",
                        value: value(\.cornerRadius, action: "Change Image Corners"),
                        range: CGFloat(RecordingImageOverlay.cornerRadiusRange.lowerBound)...CGFloat(RecordingImageOverlay.cornerRadiusRange.upperBound),
                        format: .pixels
                    )
                    .help("Corner radius, measured on a 1080p video")
                }
                InspectorHalfField {
                    InspectorSlider("Shadow", value: value(\.shadow, action: "Change Image Shadow"), range: 0...1, format: .percent())
                }
            }

            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorGroupLabel("Fades")
                InspectorFieldPair {
                    InspectorSlider(
                        "In",
                        value: value(\.fadeIn, action: "Change Image Fade"),
                        range: CGFloat(RecordingImageOverlay.fadeRange.lowerBound)...CGFloat(RecordingImageOverlay.fadeRange.upperBound),
                        format: .seconds
                    )
                } trailing: {
                    InspectorSlider(
                        "Out",
                        value: value(\.fadeOut, action: "Change Image Fade"),
                        range: CGFloat(RecordingImageOverlay.fadeRange.lowerBound)...CGFloat(RecordingImageOverlay.fadeRange.upperBound),
                        format: .seconds
                    )
                }
            }
        }
    }

    private func edit(_ action: String, _ change: (inout RecordingImageOverlay) -> Void) {
        var edited = image
        change(&edited)
        model.editImage(edited, actionName: action)
    }

    private func value(_ keyPath: WritableKeyPath<RecordingImageOverlay, Double>, action: String) -> Binding<CGFloat> {
        Binding(
            get: { CGFloat(image[keyPath: keyPath]) },
            set: { value in edit(action) { $0[keyPath: keyPath] = Double(value) } }
        )
    }
}
