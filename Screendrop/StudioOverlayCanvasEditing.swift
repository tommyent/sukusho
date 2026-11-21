//
//  StudioOverlayCanvasEditing.swift
//  Screendrop
//
//  Text, images, and pixelated/blurred regions on the Studio canvas. Images
//  and text are drawn by the same Core Graphics / Core Text routines the
//  exporter uses, through a Canvas; redactions are already filtered into the
//  player's picture, so the canvas only adds their editing chrome. While
//  paused, text and images can be picked and dragged into place (and images
//  scaled from their corner handle), and a redaction moved and resized by its
//  handles.
//

import SwiftUI

/// The images and texts showing at a moment, drawn exactly as the export
/// draws them: images first (above camera), text on top (under subtitles).
struct StudioCanvasOverlayLayer: View {
    let images: [(overlay: RecordingImageOverlay, image: RecordingOverlayImage)]
    let texts: [RecordingTextOverlay]
    let sourceTime: TimeInterval
    let canvasSize: CGSize
    var onImageFrameDecoded: (@MainActor @Sendable () -> Void)? = nil

    var body: some View {
        let onDecoded = onImageFrameDecoded
        Canvas { context, size in
            context.withCGContext { cgContext in
                for (overlay, image) in images {
                    RecordingImageOverlayRenderer.drawForPreview(
                        overlay,
                        image: image,
                        atSourceTime: sourceTime,
                        canvasSize: size,
                        in: cgContext,
                        onFrameDecoded: onDecoded.map { callback in
                            { Task { @MainActor in callback() } }
                        }
                    )
                }
                for overlay in texts {
                    RecordingTextOverlayRenderer.draw(
                        overlay,
                        atSourceTime: sourceTime,
                        canvasSize: size,
                        in: cgContext
                    )
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
    }
}

/// Hit targets over the showing images. A click picks one, a drag moves
/// it, and the selected one's corner handle scales it about its centre.
struct StudioImageEditingLayer: View {
    @Bindable var model: RecordingStudioModel
    let images: [RecordingImageOverlay]
    let canvasSize: CGSize

    @State private var dragBase: RecordingImageOverlay?
    @State private var hoveredID: UUID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(images) { overlay in
                let rect = overlay.rect(canvasSize: canvasSize)
                let isSelected = model.selectedImageID == overlay.id
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .overlay {
                        if isSelected || hoveredID == overlay.id {
                            Rectangle()
                                .strokeBorder(
                                    isSelected ? Palette.highlight : Color.white.opacity(0.7),
                                    lineWidth: isSelected ? 1.5 : 1
                                )
                                .shadow(color: .black.opacity(0.3), radius: 1)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            StudioRegionHandle(isCorner: true, isHorizontal: false)
                                .offset(x: 11, y: 11)
                                .gesture(scaleGesture(for: overlay, rect: rect))
                                .help("Drag to resize image")
                        }
                    }
                    .frame(width: max(rect.width, 8), height: max(rect.height, 8))
                    .rotationEffect(.degrees(overlay.rotation))
                    .position(x: rect.midX, y: rect.midY)
                    .onHover { isHovering in
                        if isHovering {
                            hoveredID = overlay.id
                        } else if hoveredID == overlay.id {
                            hoveredID = nil
                        }
                    }
                    .onTapGesture { model.selectImage(id: overlay.id) }
                    .gesture(moveGesture(for: overlay))
                    .help("Drag to move. Drag the corner handle to resize.")
                    .accessibilityLabel(overlay.isAnimated ? "GIF, \(overlay.displayName)" : "Image, \(overlay.displayName)")
                    .accessibilityValue("Position \(percentText(overlay.center.x)) across, \(percentText(overlay.center.y)) down, width \(percentText(overlay.width))")
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { model.selectImage(id: overlay.id) }
                    .accessibilityAction(named: "Move Left") { accessibleEdit(overlay, action: "Move Image") { $0.nudged(dx: -Self.nudgeStep, dy: 0) } }
                    .accessibilityAction(named: "Move Right") { accessibleEdit(overlay, action: "Move Image") { $0.nudged(dx: Self.nudgeStep, dy: 0) } }
                    .accessibilityAction(named: "Move Up") { accessibleEdit(overlay, action: "Move Image") { $0.nudged(dx: 0, dy: -Self.nudgeStep) } }
                    .accessibilityAction(named: "Move Down") { accessibleEdit(overlay, action: "Move Image") { $0.nudged(dx: 0, dy: Self.nudgeStep) } }
                    .accessibilityAction(named: "Make Larger") { accessibleEdit(overlay, action: "Resize Image") { $0.scaled(by: Double(Self.nudgeStep)) } }
                    .accessibilityAction(named: "Make Smaller") { accessibleEdit(overlay, action: "Resize Image") { $0.scaled(by: -Double(Self.nudgeStep)) } }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private static let nudgeStep: CGFloat = 0.05

    private func accessibleEdit(
        _ overlay: RecordingImageOverlay,
        action: String,
        transform: (RecordingImageOverlay) -> RecordingImageOverlay
    ) {
        model.selectImage(id: overlay.id)
        model.beginImageEdit()
        model.setImage(transform(overlay))
        model.endImageEdit(actionName: action)
    }

    private func begin(_ overlay: RecordingImageOverlay) {
        guard dragBase?.id != overlay.id else { return }
        dragBase = overlay
        model.selectImage(id: overlay.id)
        model.beginImageEdit()
    }

    private func moveGesture(for overlay: RecordingImageOverlay) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                begin(overlay)
                guard let dragBase, canvasSize.width > 0, canvasSize.height > 0 else { return }
                var moved = dragBase
                moved.center = CGPoint(
                    x: dragBase.center.x + value.translation.width / canvasSize.width,
                    y: dragBase.center.y + value.translation.height / canvasSize.height
                )
                model.setImage(moved)
            }
            .onEnded { _ in
                dragBase = nil
                model.endImageEdit(actionName: "Move Image")
            }
    }

    /// Scales by how far the handle travels along the line from the centre
    /// to the corner it started at, which holds however the image is turned.
    private func scaleGesture(for overlay: RecordingImageOverlay, rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                begin(overlay)
                guard let dragBase else { return }
                let angle = dragBase.rotation * .pi / 180
                let half = CGSize(width: rect.width / 2, height: rect.height / 2)
                let corner = CGPoint(
                    x: half.width * cos(angle) - half.height * sin(angle),
                    y: half.width * sin(angle) + half.height * cos(angle)
                )
                let length = max(hypot(corner.x, corner.y), 1)
                let along = (value.translation.width * corner.x + value.translation.height * corner.y) / length
                var scaled = dragBase
                scaled.width = dragBase.width * Double(max(0.05, (length + along) / length))
                model.setImage(scaled)
            }
            .onEnded { _ in
                dragBase = nil
                model.endImageEdit(actionName: "Resize Image")
            }
    }
}

/// Hit targets over the showing texts. A click picks one; a drag picks it
/// and moves it, as one undo step.
struct StudioTextEditingLayer: View {
    @Bindable var model: RecordingStudioModel
    let texts: [RecordingTextOverlay]
    let canvasSize: CGSize

    @State private var dragBase: RecordingTextOverlay?
    @State private var hoveredID: UUID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(texts) { overlay in
                let rect = RecordingTextOverlayRenderer.layout(overlay, canvasSize: canvasSize).rect
                let isSelected = model.selectedTextID == overlay.id
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.001))
                    .overlay {
                        if isSelected || hoveredID == overlay.id {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(
                                    isSelected ? Palette.highlight : Color.white.opacity(0.7),
                                    lineWidth: isSelected ? 1.5 : 1
                                )
                                .shadow(color: .black.opacity(0.3), radius: 1)
                        }
                    }
                    .frame(width: max(rect.width, 8), height: max(rect.height, 8))
                    .position(x: rect.midX, y: rect.midY)
                    .onHover { isHovering in
                        if isHovering {
                            hoveredID = overlay.id
                        } else if hoveredID == overlay.id {
                            hoveredID = nil
                        }
                    }
                    .onTapGesture { model.selectText(id: overlay.id) }
                    .gesture(moveGesture(for: overlay))
                    .help("Drag to move. Edit the text in the inspector.")
                    .accessibilityLabel("Text, \(overlay.text.isEmpty ? "Empty" : overlay.text)")
                    .accessibilityValue("Position \(percentText(overlay.center.x)) across, \(percentText(overlay.center.y)) down")
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { model.selectText(id: overlay.id) }
                    .accessibilityAction(named: "Move Left") { nudge(overlay, dx: -Self.nudgeStep, dy: 0) }
                    .accessibilityAction(named: "Move Right") { nudge(overlay, dx: Self.nudgeStep, dy: 0) }
                    .accessibilityAction(named: "Move Up") { nudge(overlay, dx: 0, dy: -Self.nudgeStep) }
                    .accessibilityAction(named: "Move Down") { nudge(overlay, dx: 0, dy: Self.nudgeStep) }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private static let nudgeStep: CGFloat = 0.05

    private func nudge(_ overlay: RecordingTextOverlay, dx: CGFloat, dy: CGFloat) {
        model.selectText(id: overlay.id)
        model.beginTextEdit()
        model.setText(overlay.nudged(dx: dx, dy: dy))
        model.endTextEdit(actionName: "Move Text")
    }

    private func moveGesture(for overlay: RecordingTextOverlay) -> some Gesture {
        // Global coordinates: the target moves under the pointer, so local
        // translations would chase their own updates.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if dragBase?.id != overlay.id {
                    dragBase = overlay
                    model.selectText(id: overlay.id)
                    model.beginTextEdit()
                }
                guard let dragBase, canvasSize.width > 0, canvasSize.height > 0 else { return }
                var moved = dragBase
                moved.center = CGPoint(
                    x: dragBase.center.x + value.translation.width / canvasSize.width,
                    y: dragBase.center.y + value.translation.height / canvasSize.height
                )
                model.setText(moved)
            }
            .onEnded { _ in
                dragBase = nil
                model.endTextEdit(actionName: "Move Text")
            }
    }
}

/// Editing chrome for the showing pixelated/blurred regions. `pictureRect` is
/// where the whole recorded picture draws on the canvas right now, zoom
/// included, which is what a region's normalized rect is measured against.
struct StudioRedactionEditingLayer: View {
    @Bindable var model: RecordingStudioModel
    let redactions: [RecordingRedaction]
    let pictureRect: CGRect
    let canvasSize: CGSize

    @State private var dragBase: RecordingRedaction?
    @State private var hoveredID: UUID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(redactions) { redaction in
                let rect = canvasRect(for: redaction.rect)
                let isSelected = model.selectedRedactionID == redaction.id
                redactionBox(for: redaction, rect: rect, isSelected: isSelected)

                if isSelected {
                    ForEach(CropHandle.allCases, id: \.self) { handle in
                        StudioRegionHandle(isCorner: handle.isCorner, isHorizontal: handle == .top || handle == .bottom)
                            .position(
                                x: rect.minX + rect.width * handle.unitPoint.x,
                                y: rect.minY + rect.height * handle.unitPoint.y
                            )
                            .gesture(dragGesture(for: redaction, handle: handle))
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private func redactionBox(for redaction: RecordingRedaction, rect: CGRect, isSelected: Bool) -> some View {
        let valueText = "Position \(percentText(redaction.rect.minX)) across, \(percentText(redaction.rect.minY)) down, size \(percentText(redaction.rect.width)) by \(percentText(redaction.rect.height))"
        let base = Rectangle()
            .fill(Color.white.opacity(0.001))
            .overlay {
                if isSelected || hoveredID == redaction.id {
                    Rectangle()
                        .strokeBorder(
                            isSelected ? Color.white.opacity(0.95) : Color.white.opacity(0.6),
                            style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: isSelected ? [] : [4, 3])
                        )
                        .shadow(color: .black.opacity(0.3), radius: 1)
                }
            }
            .frame(width: max(rect.width, 4), height: max(rect.height, 4))
            .position(x: rect.midX, y: rect.midY)
            .onHover { isHovering in
                if isHovering {
                    hoveredID = redaction.id
                } else if hoveredID == redaction.id {
                    hoveredID = nil
                }
            }
            .onTapGesture { model.selectRedaction(id: redaction.id) }
            .gesture(dragGesture(for: redaction, handle: nil))

        let movable = base
            .accessibilityLabel("\(redaction.mode.title) region")
            .accessibilityValue(valueText)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.selectRedaction(id: redaction.id) }
            .accessibilityAction(named: "Move Left") { accessibleEdit(redaction, action: "Move Redaction") { $0.nudged(dx: -Self.nudgeStep, dy: 0) } }
            .accessibilityAction(named: "Move Right") { accessibleEdit(redaction, action: "Move Redaction") { $0.nudged(dx: Self.nudgeStep, dy: 0) } }
            .accessibilityAction(named: "Move Up") { accessibleEdit(redaction, action: "Move Redaction") { $0.nudged(dx: 0, dy: -Self.nudgeStep) } }
            .accessibilityAction(named: "Move Down") { accessibleEdit(redaction, action: "Move Redaction") { $0.nudged(dx: 0, dy: Self.nudgeStep) } }

        return movable
            .accessibilityAction(named: "Widen") { accessibleEdit(redaction, action: "Resize Redaction") { $0.resized(dWidth: Self.nudgeStep, dHeight: 0) } }
            .accessibilityAction(named: "Narrow") { accessibleEdit(redaction, action: "Resize Redaction") { $0.resized(dWidth: -Self.nudgeStep, dHeight: 0) } }
            .accessibilityAction(named: "Make Taller") { accessibleEdit(redaction, action: "Resize Redaction") { $0.resized(dWidth: 0, dHeight: Self.nudgeStep) } }
            .accessibilityAction(named: "Make Shorter") { accessibleEdit(redaction, action: "Resize Redaction") { $0.resized(dWidth: 0, dHeight: -Self.nudgeStep) } }
    }

    private static let nudgeStep: CGFloat = 0.05

    private func accessibleEdit(
        _ redaction: RecordingRedaction,
        action: String,
        transform: (RecordingRedaction) -> RecordingRedaction
    ) {
        model.selectRedaction(id: redaction.id)
        model.beginRedactionEdit()
        model.setRedaction(transform(redaction))
        model.endRedactionEdit(actionName: action)
    }

    private func canvasRect(for rect: CGRect) -> CGRect {
        CGRect(
            x: pictureRect.minX + rect.minX * pictureRect.width,
            y: pictureRect.minY + rect.minY * pictureRect.height,
            width: rect.width * pictureRect.width,
            height: rect.height * pictureRect.height
        )
    }

    /// Moves the region with no handle; otherwise drags the handle's edges,
    /// leaving the opposite ones where they were.
    private func dragGesture(for redaction: RecordingRedaction, handle: CropHandle?) -> some Gesture {
        DragGesture(minimumDistance: handle == nil ? 2 : 0, coordinateSpace: .global)
            .onChanged { value in
                if dragBase?.id != redaction.id {
                    dragBase = redaction
                    model.selectRedaction(id: redaction.id)
                    model.beginRedactionEdit()
                }
                guard let dragBase, pictureRect.width > 0, pictureRect.height > 0 else { return }
                let dx = value.translation.width / pictureRect.width
                let dy = value.translation.height / pictureRect.height
                let base = dragBase.rect
                var edited = dragBase
                if let handle {
                    var minX = base.minX, maxX = base.maxX, minY = base.minY, maxY = base.maxY
                    let side = RecordingRedaction.minimumSide
                    if handle.unitPoint.x == 0 { minX = min(max(0, base.minX + dx), maxX - side) }
                    if handle.unitPoint.x == 1 { maxX = max(min(1, base.maxX + dx), minX + side) }
                    if handle.unitPoint.y == 0 { minY = min(max(0, base.minY + dy), maxY - side) }
                    if handle.unitPoint.y == 1 { maxY = max(min(1, base.maxY + dy), minY + side) }
                    edited.rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                } else {
                    edited.rect = base.offsetBy(dx: dx, dy: dy)
                }
                model.setRedaction(edited)
            }
            .onEnded { _ in
                dragBase = nil
                model.endRedactionEdit(actionName: handle == nil ? "Move Redaction" : "Resize Redaction")
            }
    }
}

private func percentText(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
}

/// A region's resize handle: a square at the corners, a bar on the edges,
/// like the crop tool's but sized for smaller boxes.
private struct StudioRegionHandle: View {
    let isCorner: Bool
    let isHorizontal: Bool

    var body: some View {
        ZStack {
            Color.white.opacity(0.001)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white)
                .frame(
                    width: isCorner ? 9 : (isHorizontal ? 18 : 5),
                    height: isCorner ? 9 : (isHorizontal ? 5 : 18)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
        }
    }
}
