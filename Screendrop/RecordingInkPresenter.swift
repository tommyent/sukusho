//
//  RecordingInkPresenter.swift
//  Screendrop
//
//  The live pen during a take: a transparent panel over the recorded area.
//  The capture filter leaves it out, so screen.mov stays clean and Studio and
//  export replay the strokes from input.json. With the pen off the panel is
//  click-through; with it on, drags draw instead of reaching the app below.
//

import AppKit
import Carbon.HIToolbox

@Observable
@MainActor
final class RecordingInkPresenter {
    static let shared = RecordingInkPresenter()

    /// The marker's width on screen, in points.
    static let lineWidth: CGFloat = 6

    enum Tool { case pen, oval, markers }
    private(set) var tool = Tool.pen
    @ObservationIgnored private var history = RecordingInkHistory()
    @ObservationIgnored private var bugReport = false

    func togglePen() { select(.pen) }

    func select(_ next: Tool) {
        if isPenOn && tool == next { setPen(false); return }
        endStroke(at: ProcessInfo.processInfo.systemUptime, point: nil)
        tool = next
        setPen(true, fromBar: true)
    }

    private(set) var isPenOn = false

    /// Every stroke of the take, including faded and undone ones: the
    /// replay shows what the live pen showed.
    @ObservationIgnored private(set) var strokes: [RecordingInkCapture] = []
    @ObservationIgnored private var currentStroke: Int?
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var inkView: RecordingInkView?
    /// The panel's top-left in Quartz global space, where strokes are kept.
    @ObservationIgnored private var quartzOrigin: CGPoint = .zero
    @ObservationIgnored private var holdTimer: Timer?
    @ObservationIgnored private var fadeTimer: Timer?
    @ObservationIgnored private var fadingStrokes: [Int] = []
    @ObservationIgnored private var onPenChange: ((Bool, Bool) -> Void)?
    @ObservationIgnored private var penHotKeyIDs: [UInt32] = []

    private init() {}

    var windowID: CGWindowID? {
        panel.map { CGWindowID($0.windowNumber) }
    }

    /// Puts the click-through panel up before the capture filter is built,
    /// so the filter can leave it out. `frame` is in AppKit screen space.
    func prepare(covering frame: CGRect, bugReport: Bool, onPenChange: @escaping (Bool, Bool) -> Void) {
        hide()
        self.bugReport = bugReport
        let panel = RecordingInkPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        // Just under the recording bar and the camera bubble, so both stay
        // usable while the pen is on.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let view = RecordingInkView(frame: CGRect(origin: .zero, size: frame.size))
        panel.contentView = view

        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        quartzOrigin = CGPoint(x: frame.minX, y: mainDisplayHeight - frame.maxY)
        self.panel = panel
        inkView = view
        self.onPenChange = onPenChange
        panel.orderFrontRegardless()
    }

    func setPen(_ isOn: Bool, fromBar: Bool = false) {
        guard isOn != isPenOn, !isOn || panel != nil else { return }
        if !isOn { endStroke(at: ProcessInfo.processInfo.systemUptime, point: nil) }
        isPenOn = isOn
        panel?.ignoresMouseEvents = !isOn
        inkView?.needsDisplay = true
        setPenKeys(isOn)
        onPenChange?(isOn, fromBar)
    }

    /// Esc and ⌘Z belong to the pen only while it is on; the rest of the
    /// time they reach the app being recorded.
    private func setPenKeys(_ isOn: Bool) {
        penHotKeyIDs.forEach(HotkeyManager.shared.unregisterTemporaryHotKey)
        penHotKeyIDs = []
        guard isOn else { return }
        penHotKeyIDs = [
            HotkeyManager.shared.registerTemporaryHotKey(HotkeyShortcut(modifiers: [], keyCode: Int(kVK_Escape))) {
                RecordingInkPresenter.shared.setPen(false)
            },
            HotkeyManager.shared.registerTemporaryHotKey(HotkeyShortcut(modifiers: [.command], keyCode: Int(kVK_ANSI_Z))) {
                RecordingInkPresenter.shared.undoLastStroke()
            }
        ].compactMap { $0 }
    }

    /// Undo takes the last stroke still showing off at once.
    func undoLastStroke() {
        guard currentStroke == nil else { return }
        history.undo(&strokes, at: ProcessInfo.processInfo.systemUptime)
        inkView?.needsDisplay = true
    }

    func clearMarks() {
        endStroke(at: ProcessInfo.processInfo.systemUptime, point: nil)
        let now = ProcessInfo.processInfo.systemUptime
        guard strokes.contains(where: { $0.visible(at: now) }) else { return }
        history.clear(&strokes, at: now)
        setPen(true, fromBar: true)
        inkView?.needsDisplay = true
    }

    /// Takes the panel down and forgets the take's strokes; read `strokes`
    /// first.
    func hide() {
        setPen(false)
        holdTimer?.invalidate()
        fadeTimer?.invalidate()
        holdTimer = nil
        fadeTimer = nil
        panel?.orderOut(nil)
        panel = nil
        inkView = nil
        strokes = []
        history = RecordingInkHistory()
        tool = .pen
        fadingStrokes = []
        currentStroke = nil
        onPenChange = nil
    }

    // MARK: Strokes

    fileprivate func beginStroke(at uptime: TimeInterval, point: CGPoint) {
        endStroke(at: uptime, point: nil)
        // A stroke drawn before the hold ends keeps the group on screen.
        let number = history.added(at: strokes.count, marker: tool == .markers)
        if number == nil { holdTimer?.invalidate() }
        strokes.append(RecordingInkCapture(
            samples: [.init(uptime: uptime, point: quartz(point))],
            widthInPoints: Self.lineWidth, markerNumber: number
        ))
        if number != nil {
            inkView?.needsDisplay = true
            return
        }
        currentStroke = strokes.count - 1
        redraw(strokes[strokes.count - 1].samples[...])
    }

    fileprivate func continueStroke(at uptime: TimeInterval, point: CGPoint) {
        guard let index = currentStroke else { return }
        let point = quartz(point)
        if let last = strokes[index].samples.last?.point, hypot(point.x - last.x, point.y - last.y) < 0.5 { return }
        strokes[index].samples.append(.init(uptime: uptime, point: point))
        redraw(strokes[index].samples.suffix(7))
    }

    fileprivate func endStroke(at uptime: TimeInterval, point: CGPoint?) {
        guard let index = currentStroke else { return }
        if let point { strokes[index].samples.append(.init(uptime: uptime, point: quartz(point))) }
        currentStroke = nil
        if tool == .oval && RecordingInkPath.fitsOval(strokes[index].samples.map(\.point)) {
            strokes[index].fittedOval = true
            redraw(strokes[index].samples[...])
        }
        guard !bugReport else { return }
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: RecordingInkTimeline.holdDuration, repeats: false) { _ in
            Task { @MainActor in RecordingInkPresenter.shared.fadeGroup() }
        }
        redraw(strokes[index].samples.suffix(7))
    }

    private func fadeGroup() {
        guard currentStroke == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        fadingStrokes = strokes.indices.filter { strokes[$0].hideUptime == nil && !RecordingInkHistory.persists(marker: strokes[$0].markerNumber != nil, bugReport: bugReport) }
        for index in fadingStrokes {
            strokes[index].hideUptime = now
        }
        let end = now + RecordingInkTimeline.fadeDuration
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in RecordingInkPresenter.shared.fadeTick(endingAt: end) }
        }
    }

    private func fadeTick(endingAt end: TimeInterval) {
        // A tick queued before hide() can land after it emptied the strokes.
        for index in fadingStrokes where strokes.indices.contains(index) { redraw(strokes[index].samples[...]) }
        guard ProcessInfo.processInfo.systemUptime > end else { return }
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    /// Repaints only around these samples (a midpoint curve stays inside
    /// its points), not the whole display on every drag.
    private func redraw(_ samples: ArraySlice<RecordingInkCapture.Sample>) {
        guard let inkView, !samples.isEmpty else { return }
        let xs = samples.map(\.point.x), ys = samples.map(\.point.y)
        let pad = Self.lineWidth / 2 + 2
        inkView.setNeedsDisplay(CGRect(
            x: xs.min()! - quartzOrigin.x - pad, y: ys.min()! - quartzOrigin.y - pad,
            width: xs.max()! - xs.min()! + pad * 2, height: ys.max()! - ys.min()! + pad * 2
        ))
    }

    /// Flipped view point to Quartz global.
    private func quartz(_ point: CGPoint) -> CGPoint {
        CGPoint(x: quartzOrigin.x + point.x, y: quartzOrigin.y + point.y)
    }

    fileprivate func drawStrokes(in context: CGContext) {
        let now = ProcessInfo.processInfo.systemUptime
        for stroke in strokes {
            let opacity = RecordingInkTimeline.opacity(hideTime: stroke.hideUptime, fadesOut: stroke.fadesOut, at: now)
            guard stroke.visible(at: now) else { continue }
            let points = stroke.samples.map { CGPoint(x: $0.point.x - quartzOrigin.x, y: $0.point.y - quartzOrigin.y) }
            RecordingInkPath.draw(points, oval: stroke.fittedOval == true, marker: stroke.markerNumber, color: .marker, opacity: opacity,
                                  width: stroke.widthInPoints, bounds: inkView?.bounds ?? .zero, in: context)
        }
    }
}

/// Never key or main, so the app being recorded keeps the keyboard.
private final class RecordingInkPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RecordingInkView: NSView {
    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        RecordingInkPresenter.shared.beginStroke(at: event.timestamp, point: location(of: event))
    }

    override func mouseDragged(with event: NSEvent) {
        RecordingInkPresenter.shared.continueStroke(at: event.timestamp, point: location(of: event))
    }

    override func mouseUp(with event: NSEvent) {
        RecordingInkPresenter.shared.endStroke(at: event.timestamp, point: location(of: event))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let presenter = RecordingInkPresenter.shared
        if presenter.isPenOn {
            // Nearly clear, not clear: clicks over fully clear pixels may
            // pass through to the app below.
            NSColor(white: 0, alpha: 0.005).setFill()
            dirtyRect.fill()
            // The pen-on frame; the panel is never captured, so neither is it.
            context.setStrokeColor(RecordingInkColor.marker.cgColor(opacity: 0.9))
            context.setLineWidth(3)
            context.stroke(bounds.insetBy(dx: 1.5, dy: 1.5))
        }
        presenter.drawStrokes(in: context)
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }
}
