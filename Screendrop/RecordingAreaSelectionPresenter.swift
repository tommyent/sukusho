//
//  RecordingAreaSelectionPresenter.swift
//  Screendrop
//
//  Created by Codex on 01/05/26.
//

import AppKit
import ScreenCaptureKit

/// The drag-an-area picker: for an area recording and a scrolling capture on
/// one display, and for the Area screenshot and Capture Text on every display,
/// where Shift snaps to the box under the pointer and Option shows a loupe.
@MainActor
final class RecordingAreaSelectionPresenter {
    static let shared = RecordingAreaSelectionPresenter()

    private var panels: [NSPanel] = []
    private var completion: ((CGRect?) -> Void)?
    private var eventMonitor: Any?
    private var freezeTask: Task<Void, Never>?

    private init() {}

    /// The drawn area in AppKit's global coordinates, or nil when cancelled.
    func selectArea(on display: SCDisplay, completion: @escaping (CGRect?) -> Void) {
        cancel()

        guard let screen = ActiveDisplayResolver.screen(for: display.displayID) ?? NSScreen.main else {
            completion(nil)
            return
        }

        self.completion = completion
        let pixelScale = CGSize(
            width: CGFloat(display.width) / max(screen.frame.width, 1),
            height: CGFloat(display.height) / max(screen.frame.height, 1)
        )
        show(on: screen, pixelScale: pixelScale, isScreenshot: false) { panel, localRect in
            CGRect(
                x: panel.frame.minX + localRect.minX,
                y: panel.frame.minY + localRect.minY,
                width: localRect.width,
                height: localRect.height
            )
        }
    }

    /// The picker of the Area screenshot and Capture Text, on every display:
    /// drag a free area, or hold Shift and click the highlighted box. Returns the area in global
    /// Quartz points (top-left origin), whole pixels, or nil when cancelled.
    /// `windows` are the on-screen app windows, front to back, in the same space.
    func selectScreenshotArea(windows: [CGRect]) async -> CGRect? {
        cancel()

        let showsHint = ScreendropPreferences.takeAreaPickerHint()
        return await withCheckedContinuation { continuation in
            completion = { continuation.resume(returning: $0) }
            for screen in NSScreen.screens {
                guard let displayID = ActiveDisplayResolver.displayID(for: screen) else { continue }
                let scale = screen.backingScaleFactor
                // Above the Dock, when it's at the bottom of this display.
                let hintInset = showsHint ? screen.visibleFrame.minY - screen.frame.minY + 28 : nil
                show(on: screen, pixelScale: CGSize(width: scale, height: scale), isScreenshot: true,
                     hintInset: hintInset) { panel, localRect in
                    // From the display's own top-left corner, so it doesn't matter where AppKit puts the screen.
                    let origin = CGDisplayBounds(displayID).origin
                    return CGRect(
                        x: origin.x + (localRect.minX * scale).rounded() / scale,
                        y: origin.y + ((panel.frame.height - localRect.maxY) * scale).rounded() / scale,
                        width: max(1, (localRect.width * scale).rounded()) / scale,
                        height: max(1, (localRect.height * scale).rounded()) / scale
                    )
                }
            }
            guard !panels.isEmpty else { return finish(rect: nil) }
            freezeTask = Task { await freezeFrames(windows: windows) }
        }
    }

    func cancel() {
        finish(rect: nil)
    }

    private func show(on screen: NSScreen, pixelScale: CGSize, isScreenshot: Bool, hintInset: CGFloat? = nil,
                      globalRect: @escaping (NSPanel, CGRect) -> CGRect) {
        let panel = RecordingAreaSelectionPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        // Set outright, a click on see-through pixels stays with the panel: the
        // box Shift highlights is a clear hole, and the click that takes it
        // must not go to the app underneath.
        panel.ignoresMouseEvents = false

        let selectionView = RecordingAreaSelectionView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            pixelScale: pixelScale,
            isScreenshot: isScreenshot,
            hintInset: hintInset
        )
        selectionView.onCancel = { [weak self] in
            self?.finish(rect: nil)
        }
        selectionView.onSelect = { [weak self, weak panel] localRect in
            guard let self, let panel else {
                self?.finish(rect: nil)
                return
            }
            self.finish(rect: globalRect(panel, localRect))
        }

        panel.contentView = selectionView
        panel.makeFirstResponder(selectionView)
        // The first panel takes the keyboard; the rest only need the pointer.
        if panels.isEmpty {
            installEventMonitor()
            panel.makeKeyAndOrderFront(nil)
        }
        panels.append(panel)
        panel.orderFrontRegardless()
        selectionView.beginSelectionCursorSession()
    }

    private func finish(rect: CGRect?) {
        let completion = completion
        self.completion = nil
        freezeTask?.cancel()
        freezeTask = nil
        removeEventMonitor()
        for panel in panels {
            (panel.contentView as? RecordingAreaSelectionView)?.endSelectionCursorSession()
            panel.orderOut(nil)
        }
        panels = []
        completion?(rect)
    }

    private var views: [RecordingAreaSelectionView] {
        panels.compactMap { $0.contentView as? RecordingAreaSelectionView }
    }

    /// Freezes a frame of each display for the loupe and finds the boxes Shift
    /// snaps to. The picker is already up and usable while this runs.
    private func freezeFrames(windows: [CGRect]) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return
        }
        let overlays = Set(panels.map { CGWindowID($0.windowNumber) })
        let filters = RecordingDesktopFilter(
            content: content,
            includesAppWindows: PreviewWindowCaptureExclusion.includesAppWindowsInCaptures,
            cleanDesktop: false,
            overlayWindowIDs: overlays
        )
        for panel in panels {
            guard let view = panel.contentView as? RecordingAreaSelectionView, let screen = panel.screen,
                  let displayID = ActiveDisplayResolver.displayID(for: screen),
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }
            let filter = filters.makeFilter(for: display)
            let scale = max(1, CGFloat(filter.pointPixelScale))
            let configuration = SCStreamConfiguration()
            configuration.width = Int((filter.contentRect.width * scale).rounded())
            configuration.height = Int((filter.contentRect.height * scale).rounded())
            configuration.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
                  !Task.isCancelled else { continue }
            view.frozenImage = image

            let origin = CGDisplayBounds(displayID).origin
            let localWindows = windows.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
            let size = filter.contentRect.size
            let candidates = await Task.detached(priority: .userInitiated) {
                let boxes = SmartAreaBitmap(image).map {
                    SmartAreaDetector.boxes(in: $0, minSide: Int(SmartAreaCandidates.minimumSide * scale))
                } ?? []
                return SmartAreaCandidates(pixelBoxes: boxes, scale: scale, windows: localWindows, displaySize: size)
            }.value
            guard !Task.isCancelled else { return }
            view.candidates = candidates
        }
    }

    /// Escape cancels. For the screenshot picker the views also hear the
    /// modifiers, Space and the arrows, whichever panel has the keyboard.
    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.finish(rect: nil)
                return nil
            }
            let handled = self.views.map { $0.handle(event) }.contains(true)
            return handled ? nil : event
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

private final class RecordingAreaSelectionPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

private final class RecordingAreaSelectionView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    /// The display as it was when the picker opened: what the loupe magnifies.
    var frozenImage: CGImage? { didSet { needsDisplay = true } }
    /// The boxes Shift snaps to, once they've been found.
    var candidates: SmartAreaCandidates? { didSet { needsDisplay = true } }

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private let pixelScale: CGSize
    /// The Area screenshot's picker: Shift snaps, Option magnifies, Space moves the area.
    private let isScreenshot: Bool
    /// How far above the display's bottom edge the line about Shift and
    /// Option sits; nil once it has been shown often enough.
    private let hintInset: CGFloat?
    private var didPushSelectionCursor = false

    /// Where the pointer is, while it's on this display.
    private var pointer: CGPoint?
    /// Modifiers still down from the shortcut that opened the picker: they
    /// count only once they've been released and pressed again.
    private var heldSinceOpen: NSEvent.ModifierFlags
    /// How many boxes outward from the smallest one under the pointer.
    private var snapDepth = 0
    private var smallestSnap: CGRect?
    private var scrollRemainder: CGFloat = 0
    /// The box under a Shift-press, taken when the button comes up.
    private var pressedSnap: CGRect?
    private var isSpaceDown = false

    override var acceptsFirstResponder: Bool {
        true
    }

    init(frame frameRect: NSRect, pixelScale: CGSize, isScreenshot: Bool, hintInset: CGFloat?) {
        self.pixelScale = pixelScale
        self.isScreenshot = isScreenshot
        self.hintInset = hintInset
        heldSinceOpen = NSEvent.modifierFlags
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        endSelectionCursorSession()
    }

    private var selectionCursor: NSCursor {
        isScreenshot ? .crosshair : .annotationPlus
    }

    private var modifiers: NSEvent.ModifierFlags {
        NSEvent.modifierFlags.subtracting(heldSinceOpen)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        if let selectionRect {
            drawHole(selectionRect, color: .white)
            if isScreenshot, let currentPoint {
                drawBadge(sizeLabel(for: selectionRect)) { self.badgeOrigin(besidePointer: currentPoint, size: $0) }
            } else {
                drawBadge(sizeLabel(for: selectionRect)) { self.badgeOrigin(for: selectionRect, size: $0) }
            }
        } else if let snapRect = pressedSnap ?? snapRect {
            drawHole(snapRect, color: .controlAccentColor)
            drawBadge(sizeLabel(for: snapRect)) { self.badgeOrigin(for: snapRect, size: $0) }
        }

        let showsLoupe = isScreenshot && modifiers.contains(.option) && pointer != nil && frozenImage != nil
        if showsLoupe, let pointer, let frozenImage {
            drawLoupe(of: frozenImage, at: pointer)
        }

        // Only while nothing else is drawn, and not under the pointer: it
        // never meets the size label, the loupe or an area being placed.
        if let hintInset, selectionRect == nil, pressedSnap == nil, snapRect == nil, !showsLoupe {
            drawBadge("Hold Shift to snap to a box  ·  Hold Option to zoom in") { size in
                let origin = CGPoint(x: self.bounds.midX - size.width / 2, y: hintInset)
                let reach = CGRect(origin: origin, size: size).insetBy(dx: -48, dy: -48)
                return self.pointer.map(reach.contains) == true ? nil : origin
            }
        }
    }

    private func drawHole(_ rect: CGRect, color: NSColor) {
        NSColor.clear.setFill()
        rect.fill(using: .clear)

        color.withAlphaComponent(0.96).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: isScreenshot ? 0 : 4, yRadius: isScreenshot ? 0 : 4)
        border.lineWidth = 2
        border.stroke()
    }

    private func sizeLabel(for rect: CGRect) -> String {
        let pixelWidth = Int((rect.width * pixelScale.width).rounded())
        let pixelHeight = Int((rect.height * pixelScale.height).rounded())
        return "\(pixelWidth) x \(pixelHeight)"
    }

    /// `origin` places the badge given its size, or returns nil to leave it out.
    private func drawBadge(_ label: String, at origin: (CGSize) -> CGPoint?) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let attributedLabel = NSAttributedString(string: label, attributes: attributes)
        let textSize = attributedLabel.size()
        let padding = CGSize(width: 10, height: 6)
        let badgeSize = CGSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        guard let badgeOrigin = origin(badgeSize) else { return }
        let badgeRect = CGRect(origin: badgeOrigin, size: badgeSize)

        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 7, yRadius: 7).fill()

        attributedLabel.draw(
            at: CGPoint(
                x: badgeRect.minX + padding.width,
                y: badgeRect.minY + padding.height
            )
        )
    }

    private func badgeOrigin(for rect: CGRect, size: CGSize) -> CGPoint {
        let preferred = CGPoint(x: rect.minX, y: rect.minY - size.height - 8)
        if bounds.contains(CGRect(origin: preferred, size: size)) {
            return preferred
        }

        let fallbackY = min(rect.maxY + 8, bounds.maxY - size.height - 8)
        return CGPoint(
            x: min(max(rect.minX, bounds.minX + 8), bounds.maxX - size.width - 8),
            y: max(fallbackY, bounds.minY + 8)
        )
    }

    /// Below and right of the pointer, as the system crosshair shows it; on
    /// the other side where the display ends.
    private func badgeOrigin(besidePointer point: CGPoint, size: CGSize) -> CGPoint {
        let gap: CGFloat = 14
        let x = point.x + gap + size.width <= bounds.maxX ? point.x + gap : point.x - gap - size.width
        let y = point.y - gap - size.height >= bounds.minY ? point.y - gap - size.height : point.y + gap
        return CGPoint(x: x, y: y)
    }

    /// The frozen frame's pixels around the pointer, each drawn as a square,
    /// with lines between them and a crosshair where an edge would land.
    private func drawLoupe(of image: CGImage, at point: CGPoint) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let loupe = SmartAreaLoupe(pointer: point, viewSize: bounds.size, scale: pixelScale.width,
                                   imageSize: CGSize(width: image.width, height: image.height))
        let frame = loupe.frame
        context.saveGState()
        context.addPath(CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil))
        context.clip()
        context.setFillColor(NSColor.black.cgColor)
        context.fill(frame)
        if let pixels = image.cropping(to: loupe.source) {
            context.interpolationQuality = .none
            context.draw(pixels, in: loupe.destination)
        }
        /// A line across the loupe at `x` and one at `y`.
        func cross(x: CGFloat, y: CGFloat, color: NSColor, width: CGFloat) {
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.strokeLineSegments(between: [
                CGPoint(x: x, y: frame.minY), CGPoint(x: x, y: frame.maxY),
                CGPoint(x: frame.minX, y: y), CGPoint(x: frame.maxX, y: y),
            ])
        }
        for step in 1..<SmartAreaLoupe.pixels {
            let offset = CGFloat(step) * SmartAreaLoupe.cell
            cross(x: frame.minX + offset, y: frame.minY + offset, color: .black.withAlphaComponent(0.18), width: 0.5)
        }
        // White over black, so the crosshair shows on any pixels.
        cross(x: loupe.crosshair.x, y: loupe.crosshair.y, color: .black.withAlphaComponent(0.55), width: 2)
        cross(x: loupe.crosshair.x, y: loupe.crosshair.y, color: .white, width: 1)
        context.restoreGState()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        border.lineWidth = 1.5
        border.stroke()
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: selectionCursor)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
        if window != nil {
            beginSelectionCursorSession()
        } else {
            endSelectionCursorSession()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        beginSelectionCursorSession()
    }

    func beginSelectionCursorSession() {
        if didPushSelectionCursor {
            selectionCursor.set()
        } else {
            selectionCursor.push()
            didPushSelectionCursor = true
        }
    }

    func endSelectionCursorSession() {
        guard didPushSelectionCursor else { return }

        NSCursor.pop()
        didPushSelectionCursor = false
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard isScreenshot else { return }
        // The panels on other displays aren't key, and still follow the pointer.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        movePointer(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        movePointer(to: point)
        if let snapRect {
            pressedSnap = snapRect
        } else {
            startPoint = point
            currentPoint = point
        }
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        beginSelectionCursorSession()
        return true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointer = point
        // Space held: the whole area follows the pointer, as with the system crosshair.
        if isScreenshot, isSpaceDown, let start = startPoint, let last = currentPoint {
            startPoint = CGPoint(x: start.x + point.x - last.x, y: start.y + point.y - last.y)
        }
        currentPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let pressedSnap {
            onSelect?(pressedSnap)
            return
        }
        currentPoint = convert(event.locationInWindow, from: nil)
        let minimum: CGFloat = isScreenshot ? 4 : 16
        guard let rect = selectionRect, rect.width >= minimum, rect.height >= minimum else {
            // A stray click leaves the screenshot picker open; Escape closes it.
            guard isScreenshot else {
                onCancel?()
                return
            }
            startPoint = nil
            currentPoint = nil
            needsDisplay = true
            return
        }

        onSelect?(isScreenshot ? rect.intersection(bounds) : rect)
    }

    override func scrollWheel(with event: NSEvent) {
        guard snapRect != nil else { return }
        // Shift turns a mouse wheel's scroll sideways.
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta != 0 else { return }
        if event.hasPreciseScrollingDeltas {
            scrollRemainder += delta
            let steps = Int(scrollRemainder / 24)
            scrollRemainder -= CGFloat(steps) * 24
            stepSnap(by: steps)
        } else {
            stepSnap(by: delta > 0 ? 1 : -1)
        }
    }

    private func movePointer(to point: CGPoint) {
        pointer = point
        // Also here: a release the key monitor never saw still ends the hold.
        heldSinceOpen.formIntersection(NSEvent.modifierFlags)
        // Escape, Space and the arrows come to the display the pointer is on,
        // also after a permission prompt or another display's panel took the keyboard.
        if isScreenshot, let window, !window.isKeyWindow { window.makeKey() }
        let smallest = snapStack.first
        if smallest != smallestSnap {
            smallestSnap = smallest
            snapDepth = 0
            scrollRemainder = 0
        }
        needsDisplay = true
    }

    // MARK: - Keys

    /// Modifiers, Space and the arrows, from the presenter's monitor. True
    /// when the event was this picker's to use.
    func handle(_ event: NSEvent) -> Bool {
        guard isScreenshot else { return false }
        switch event.type {
        case .flagsChanged:
            heldSinceOpen.formIntersection(event.modifierFlags)
            if let pointer { movePointer(to: pointer) }
            needsDisplay = true
            return false
        case .keyDown, .keyUp:
            switch event.keyCode {
            case 49:
                isSpaceDown = event.type == .keyDown
                return true
            case 126, 124:
                guard event.type == .keyDown, snapRect != nil else { return false }
                stepSnap(by: 1)
                return true
            case 125, 123:
                guard event.type == .keyDown, snapRect != nil else { return false }
                stepSnap(by: -1)
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    // MARK: - Snapping

    /// The boxes under the pointer in the display's top-left points, smallest first.
    private var snapStack: [CGRect] {
        guard isScreenshot, startPoint == nil, modifiers.contains(.shift), let pointer, let candidates else { return [] }
        return candidates.stack(at: CGPoint(x: pointer.x, y: bounds.height - pointer.y))
    }

    /// The box Shift highlights, in the view's coordinates.
    private var snapRect: CGRect? {
        let stack = snapStack
        guard !stack.isEmpty else { return nil }
        let box = stack[min(snapDepth, stack.count - 1)]
        return CGRect(x: box.minX, y: bounds.height - box.maxY, width: box.width, height: box.height)
    }

    private func stepSnap(by steps: Int) {
        snapDepth = max(0, min(snapDepth + steps, snapStack.count - 1))
        needsDisplay = true
    }

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else { return nil }

        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(startPoint.x - currentPoint.x),
            height: abs(startPoint.y - currentPoint.y)
        )
    }
}
