//
//  ShakeToUpload.swift
//  Screendrop
//
//  Settings › Cloud › Shake while dragging files to upload. While files are
//  dragged from another app, such as Finder or the Desktop, a shake of the
//  pointer brings up a small shelf under it. Dropping the files there shares
//  them as the Library's Files page does: Share Options first, unless the drop
//  lands on Upload Now or Option is held, and the links are copied.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
@Observable
final class ShakeToUpload {
    static let shared = ShakeToUpload()
    static let enabledKey = "shakeToUploadEnabled"

    enum Tile: CaseIterable {
        case share, upload, gallery

        var title: String {
            switch self {
            case .share: "Share…"
            case .upload: "Upload Now"
            case .gallery: "Gallery…"
            }
        }

        var symbol: String {
            switch self {
            case .share: "square.and.arrow.up"
            case .upload: "icloud.and.arrow.up"
            case .gallery: "square.grid.2x2"
            }
        }

        var spokenTitle: String {
            switch self {
            case .share: "Share with Share Options"
            case .upload: "Upload now with your saved Share Options"
            case .gallery: "Share as one gallery"
            }
        }
    }

    /// The tile a drag is over, for its highlight.
    private(set) var targeted: Tile?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var detector = ShakeDetector()
    /// The drag pasteboard's count when the button went down: only a drag begun since then is this press's.
    @ObservationIgnored private var dragCountAtPress = 0
    /// Whether this press drags files; nil until a drag begins.
    @ObservationIgnored private var pressDragsFiles: Bool?
    @ObservationIgnored private var panel: NSPanel?
    /// The shelf, before a drop; Share Options take its place after one.
    @ObservationIgnored private var showsShelf = false
    @ObservationIgnored private var dragEndTimer: Timer?
    @ObservationIgnored private var releasedAt: Date?

    private init() {}

    /// Watches drags while the setting is on; call at launch and when it changes.
    func update() {
        let isOn = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if isOn, monitor == nil {
            // Copies of other apps' mouse events; macOS asks no permission for these.
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { event in
                let isPress = event.type == .leftMouseDown
                // A global event has no window, so this is in screen coordinates.
                let x = event.locationInWindow.x
                let time = event.timestamp
                MainActor.assumeIsolated { ShakeToUpload.shared.pointer(isPress: isPress, x: x, time: time) }
            }
            CloudLibraryModel.shared.checkWorkerVersion()
        } else if !isOn, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            dismiss()
        }
    }

    private func pointer(isPress: Bool, x: CGFloat, time: TimeInterval) {
        let pasteboard = NSPasteboard(name: .drag)
        if isPress {
            dragCountAtPress = pasteboard.changeCount
            pressDragsFiles = nil
            detector.reset()
            return
        }
        guard panel == nil else { return }
        // A drag writes the drag pasteboard as it begins; until then this is a plain drag, or not yet one.
        if pressDragsFiles == nil, pasteboard.changeCount != dragCountAtPress {
            pressDragsFiles = pasteboard.types?.contains(.fileURL) == true
        }
        guard pressDragsFiles == true, detector.add(x: x, time: time) else { return }
        showShelf()
    }

    // MARK: - Shelf

    private func showShelf() {
        guard CloudUploader.shared.isConfigured else { return }
        guard CloudLibraryModel.shared.fileUploads == nil else {
            CaptureTextFeedbackPresenter.shared.showDone("Still Uploading", detail: "Shake again once the upload finishes.",
                                                         symbol: "icloud.and.arrow.up", displayID: Self.display)
            return
        }
        let files = NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !files.isEmpty else { return }
        let tiles = Tile.allCases.filter {
            $0 != .gallery || ShakeShelfFiles.canShareGallery(files, workerSupportsGalleries: CloudLibraryModel.shared.supportsGalleries)
        }
        let view = ShakeShelfView(tiles: tiles, files: files)
        let size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 2000, height: 2000))
        // The first tile, Share…, opens under the pointer, so a drop right where the shake ended asks first.
        let pointer = Self.pointer
        let tileCenter = CGPoint(x: ShakeShelfView.margin + ShakeShelfView.inset + ShakeShelfView.tileSize.width / 2,
                                 y: ShakeShelfView.margin + ShakeShelfView.inset + ShakeShelfView.tileSize.height / 2)
        let frame = Self.onScreen(CGRect(x: pointer.x - tileCenter.x, y: pointer.y - (size.height - tileCenter.y),
                                         width: size.width, height: size.height), near: pointer)
        let panel = ShakeShelfPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        PreviewWindowCaptureExclusion.shared.register(window: panel)
        install(view, in: panel)
        panel.orderFrontRegardless()
        self.panel = panel
        showsShelf = true

        // Often enough to catch a tap of Esc.
        let timer = Timer(timeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated { ShakeToUpload.shared.checkDragEnded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragEndTimer = timer
        // The panel never takes focus while the drag goes on, so VoiceOver wouldn't read it otherwise.
        AccessibilityNotification.Announcement("Sukusho shelf for \(files.count == 1 ? "1 file" : "\(files.count) files"). Drop on: "
            + tiles.map(\.spokenTitle).joined(separator: ", ")).post()
    }

    /// Esc, or the drag ended somewhere else: a drop on the shelf comes just after the release, so it waits a moment for one.
    private func checkDragEnded() {
        guard showsShelf, let panel else { return }
        // Read, not taken, so Esc still cancels the drag as it always does. Needs no permission (seen in the test VM),
        // where a hot key would keep the drag going and a release would then drop the files wherever the pointer is.
        if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape)) { return dismiss() }
        guard NSEvent.pressedMouseButtons & 1 == 0 else {
            releasedAt = nil
            return
        }
        let released = releasedAt ?? .now
        releasedAt = released
        let wait: TimeInterval = panel.frame.contains(Self.pointer) ? 2 : 0.3
        if Date.now.timeIntervalSince(released) > wait { dismiss() }
    }

    func setTargeted(_ tile: Tile, _ isTargeted: Bool) {
        if isTargeted { targeted = tile } else if targeted == tile { targeted = nil }
    }

    func drop(_ urls: [URL], on tile: Tile) {
        guard showsShelf else { return }
        let files = CloudLibraryModel.regularFiles(urls)
        // As the Files page says it; the files go on without the folders.
        if files.count < urls.count {
            CaptureTextFeedbackPresenter.shared.showDone("Folders Can’t Be Shared", detail: "Drop the files inside them instead.",
                                                         symbol: "folder", displayID: Self.display)
        }
        guard !files.isEmpty else { return dismiss() }
        let gallery = tile == .gallery
        if tile == .upload || NSEvent.modifierFlags.contains(.option) {
            start(files, gallery: gallery, options: .savedDefaults)
        } else {
            showOptions(files, gallery: gallery)
        }
    }

    private func showOptions(_ files: [URL], gallery: Bool) {
        guard let panel else { return }
        stopWatchingDrag()
        showsShelf = false
        let view = ShakeShelfOptions(files: files, gallery: gallery)
        let size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 2000, height: 2000))
        let top = CGPoint(x: panel.frame.midX, y: panel.frame.maxY)
        install(view, in: panel)
        panel.setFrame(Self.onScreen(CGRect(x: top.x - size.width / 2, y: top.y - size.height, width: size.width, height: size.height),
                                     near: top), display: true)
        // Key without activating Sukusho, so the title and password fields take typing.
        panel.makeKey()
    }

    func start(_ files: [URL], gallery: Bool, options: CloudUploadOptions) {
        dismiss()
        let cloud = CloudLibraryModel.shared
        let toast = CaptureTextFeedbackPresenter.shared
        let display = Self.display
        guard CloudUploader.shared.isConfigured, cloud.fileUploads == nil else { return }
        if gallery {
            toast.showWorking("Sharing \(files.count) images…", detail: "As one gallery", displayID: display)
            cloud.shareGallery(files, options: options) { link in
                guard link != nil else { return Self.showFailure() }
                toast.showDone(ActionFeedback.linksCopied(1), detail: "A gallery of \(files.count) images", displayID: display)
            }
        } else {
            let one = files.count == 1 ? files[0].lastPathComponent : nil
            toast.showWorking(one == nil ? "Uploading \(files.count) files…" : "Uploading file…",
                              detail: one ?? "One link each", displayID: display)
            cloud.uploadFiles(files, options: options) { copied, failed in
                guard copied > 0 else { return Self.showFailure() }
                toast.showDone(ActionFeedback.linksCopied(copied), detail: one ?? "One link each, ready to paste", displayID: display)
                if failed { CaptureLibraryModel.shared.show() }
            }
        }
    }

    func dismiss() {
        stopWatchingDrag()
        panel?.orderOut(nil)
        panel = nil
        showsShelf = false
        targeted = nil
        detector.reset()
    }

    private func stopWatchingDrag() {
        dragEndTimer?.invalidate()
        dragEndTimer = nil
        releasedAt = nil
    }

    private func install(_ view: some View, in panel: NSPanel) {
        let host = NSHostingView(rootView: view)
        // The panel sets the size and the hosting view follows, as the capture bars do.
        host.sizingOptions = []
        panel.contentView = host
    }

    /// The Library's alert says what failed; a cancel from the Files page's Stop says nothing.
    private static func showFailure() {
        CaptureTextFeedbackPresenter.shared.dismissWorking()
        if CaptureLibraryModel.shared.errorMessage != nil { CaptureLibraryModel.shared.show() }
    }

    private static var display: CGDirectDisplayID? { ActiveDisplayResolver.activeDisplayID(preferPointer: true) }

    /// The pointer in window coordinates, from Quartz's top-left position. `NSEvent.mouseLocation` can
    /// disagree with the screens' frames: in the macOS 27.0.1 test VM it said y 539 while the only
    /// screen's frame ran from y -1021 to 0, and the shelf landed at the top of the screen.
    private static var pointer: CGPoint {
        guard let location = CGEvent(source: nil)?.location, let primary = NSScreen.screens.first else { return NSEvent.mouseLocation }
        return CGPoint(x: location.x, y: primary.frame.maxY - location.y)
    }

    private static func onScreen(_ frame: CGRect, near point: CGPoint) -> CGRect {
        guard let bounds = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame else { return frame }
        var frame = frame
        frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        return frame
    }
}

private final class ShakeShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// One glass panel of drop tiles, with what's being dragged below them.
private struct ShakeShelfView: View {
    static let tileSize = CGSize(width: 88, height: 72)
    static let inset = DS.Space.ml
    /// Room around the glass for its shadow.
    static let margin = DS.Space.l

    let tiles: [ShakeToUpload.Tile]
    let files: [URL]
    @State private var shelf = ShakeToUpload.shared
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                ForEach(tiles, id: \.self) { tile($0) }
            }
            Text(caption)
                .font(DS.TypeScale.label)
                .foregroundStyle(Palette.secondaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: CGFloat(tiles.count) * Self.tileSize.width)
                .accessibilityHidden(true)
        }
        .padding(Self.inset)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .scaleEffect(appeared || reduceMotion ? 1 : 0.85)
        .opacity(appeared ? 1 : 0)
        .padding(Self.margin)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.35)) { appeared = true }
        }
    }

    private var caption: String {
        let what = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        return "\(what) · ⌥ skips options"
    }

    private func tile(_ tile: ShakeToUpload.Tile) -> some View {
        let isTargeted = shelf.targeted == tile
        return VStack(spacing: DS.Space.s) {
            Image(systemName: tile.symbol)
                .font(.system(size: 20, weight: .medium))
            Text(tile.title)
                .font(DS.TypeScale.labelSemibold)
                .lineLimit(1)
        }
        .foregroundStyle(isTargeted ? Palette.onAccent : Palette.label)
        .frame(width: Self.tileSize.width, height: Self.tileSize.height)
        // Concentric with the panel's corners.
        .background(isTargeted ? Palette.accent : Palette.selectedFill,
                    in: RoundedRectangle(cornerRadius: DS.Radius.panel - Self.inset, style: .continuous))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            shelf.drop(urls, on: tile)
            return true
        } isTargeted: {
            shelf.setTargeted(tile, $0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.spokenTitle)
        .accessibilityHint("Drop the dragged files here")
    }
}

/// Share Options after a drop on Share… or Gallery…, in the shelf's place.
private struct ShakeShelfOptions: View {
    let files: [URL]
    let gallery: Bool

    var body: some View {
        CloudUploadOptionsPopover(
            suggestedTitle: gallery ? "\(files.count) images" : "",
            // One title can't name several files; a gallery's names the gallery.
            showsTitle: gallery || files.count == 1,
            encryptionUnavailable: gallery ? "Galleries can’t be end-to-end encrypted yet." : CloudShareSeal.unavailableReason(fileURLs: files),
            onCancel: { ShakeToUpload.shared.dismiss() }
        ) { options in
            ShakeToUpload.shared.start(files, gallery: gallery, options: options)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .padding(ShakeShelfView.margin)
    }
}
