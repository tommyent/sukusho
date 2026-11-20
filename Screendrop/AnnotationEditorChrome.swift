//
//  AnnotationEditorChrome.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct AnnotationZoomControl: View {
    @Bindable var model: AnnotationEditorModel

    var body: some View {
        Menu {
            // The image and AppKit annotation layer must receive the same
            // camera immediately; implicit SwiftUI-only animation splits them.
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!model.canZoomIn)
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!model.canZoomOut)

            Divider()

            Button("Fit Canvas") { model.fitCanvas() }
                .keyboardShortcut("1", modifiers: .command)

            Divider()

            Button("50%") { model.setZoomPercent(50) }
            Button("100%") { model.setZoomPercent(100) }
                .keyboardShortcut("0", modifiers: .command)
            Button("200%") { model.setZoomPercent(200) }
        } label: {
            Text("\(model.zoomPercent)%")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 38)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Capsule())
                .glassEffect(.regular.interactive())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // On 27.0.1 the label's glass doesn't show inside the menu, so the
        // readout would sit bare on a photo.
        .workspaceTextPlate(capsule: true)
        .help("Zoom")
    }
}

/// Live pixel dimensions of the current crop selection, shown in the bottom
/// trailing corner of the canvas while cropping. Styled to match the zoom
/// control capsule on the opposite side.
struct CropResolutionBadge: View {
    let size: CGSize

    var body: some View {
        VStack(spacing: 1) {
            Text(verbatim: "\(Int(size.width)) × \(Int(size.height)) px")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
            Text("Press Return to crop")
                .font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .fixedSize()
        .glassEffect()
        .help("Crop size")
    }
}

/// A small badge shown beside the zoom control when the editing preview is
/// downscaled to save memory. Collapsed it's just an "i" button; tapping it
/// expands an explanation that the reduction is preview-only and points users
/// to Settings to disable it.
struct LowResolutionPreviewNotice: View {
    @State private var isExpanded = false

    private let diameter: CGFloat = 28

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: diameter, height: diameter)

                if isExpanded {
                    Text("Low-res preview to save memory - exports stay full quality")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.trailing, 12)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .frame(height: diameter)
            .fixedSize()
            .glassEffect()
        }
        .buttonStyle(.plain)
        .help("Why is this preview low resolution?")
    }
}

/// The one flat colour of the windows' chrome, shared by the editor and the Library: the toolbar,
/// the left sidebar and the right inspector, from the theme (Classic: white in light mode, the window
/// background in dark).
enum WorkspaceChrome {
    static var background: Color { Color(nsColor: nsBackground) }
    static var nsBackground: NSColor { NSColor(name: nil, dynamicProvider: color) }

    /// Nonisolated: AppKit can resolve colours off the main thread.
    nonisolated private static func color(for appearance: NSAppearance) -> NSColor {
        AppTheme.current(for: appearance).chrome.background.nsColor
    }
}

/// The ground behind the Library's browser, the editor's canvas and Studio's
/// canvas: Dots, Plain or a wallpaper, from Settings › Appearance › Workspace, on the theme's ground.
struct AnnotationEditorWorkspaceBackground: View {
    @AppStorage(WorkspaceBackground.styleKey) private var style = WorkspaceBackground.Style.dots
    @AppStorage(WorkspaceBackground.wallpaperPathKey) private var wallpaperPath = ""
    @AppStorage(WorkspaceBackground.dimKey) private var dim = WorkspaceBackground.defaultDim
    @AppStorage(WorkspaceBackground.blurKey) private var blurs = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @CurrentTheme private var theme

    var body: some View {
        // Classic's is a flat, fully desaturated gray rather than a system
        // material - vibrancy materials pick up a bluish cast from the accent
        // color and whatever's behind the window, which reads as tinted
        // rather than neutral.
        let ground = theme.ground.workspace.color
        ZStack {
            Rectangle().fill(ground)

            switch WorkspaceBackground.shown(style, reduceTransparency: reduceTransparency,
                                             increaseContrast: contrast == .increased) {
            case .dots:
                WorkspaceDots()
            case .plain:
                EmptyView()
            case .wallpaper:
                if wallpaperPath.isEmpty {
                    WorkspaceDots()
                } else {
                    WorkspaceWallpaper(
                        url: URL(fileURLWithPath: wallpaperPath),
                        blur: blurs ? WorkspaceBackground.blurRadius : 0,
                        dimming: ground.opacity(WorkspaceBackground.dimOpacity(dim, dark: colorScheme == .dark))
                    )
                }
            }
        }
    }
}

/// Glass's picture (`AppTheme.Ground.backdrop`) under a whole window: the Library, its popup and Settings, never the
/// editor or Studio, which keep the Workspace setting. Callers draw it only while it's drawn (`DrawnGlass`). The
/// picture is resolved off the main thread (`GlassPicture.resolve`) for the window's own screen, and again when the
/// window changes screen or Sukusho comes to the front, since the desktop picture may have changed meanwhile.
struct GlassBackdrop: View {
    let backdrop: AppTheme.Backdrop
    @AppStorage(GlassPicture.pathKey) private var picked = ""
    @Environment(\.colorScheme) private var colorScheme
    @CurrentTheme private var theme
    @State private var host = WeakWindow()
    @State private var refresh = 0
    @State private var url: URL?

    private func refreshIfOwn(_ note: Notification) {
        if let window = host.window, note.object as? NSWindow === window { refresh += 1 }
    }

    var body: some View {
        let ground = theme.ground.workspace.color
        ZStack {
            Rectangle().fill(ground)
            if let url {
                WorkspaceWallpaper(url: url, blur: backdrop.blur, dimming: ground.opacity(backdrop.dim),
                                   dotsWhenUnreadable: false)
            }
        }
        .onWindowChange { host.window = $0; refresh += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification), perform: refreshIfOwn)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification), perform: refreshIfOwn)
        .task(id: "\(picked)#\(colorScheme == .dark)#\(refresh)") {
            // Until the window is on a screen, which screen's picture to show isn't known (the main screen is the
            // one with keyboard focus, perhaps another display's).
            guard let screen = host.window?.screen else { return }
            let desktop = NSWorkspace.shared.desktopImageURL(for: screen)
            let resolved = await GlassPicture.resolve(picked: picked, desktop: desktop, dark: colorScheme == .dark)
            if !Task.isCancelled, resolved != url { url = resolved }
        }
    }
}

extension EnvironmentValues {
    /// Set while Glass's picture is drawn under the window: text there takes frost or a plate, never the bare picture.
    @Entry var overGlassPicture = false
}

extension View {
    /// The cards' frost (material and tint) behind text in the Library that would otherwise sit straight on Glass's
    /// picture, such as the status bar or a clipboard row. It reads `DrawnGlass`, not the environment, so it works in
    /// the collection's cells, which AppKit hosts apart. Other themes, and Reduce Transparency or Increase Contrast,
    /// change nothing.
    func glassFrostBacking<S: Shape>(in shape: S) -> some View { modifier(GlassFrostBacking(shape: shape)) }
}

private struct GlassFrostBacking<S: Shape>: ViewModifier {
    let shape: S
    @DrawnGlass private var glass
    @CurrentTheme private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if glass != nil, let frost = theme.card.recipe.frost {
            content.background {
                ZStack {
                    shape.fill(frost.material.material)
                    shape.fill(frost.tint.color)
                }
                .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

/// The chosen photo at the window's pixel size, decoded and cached by the
/// wallpaper thumbnails' cache. Dots stand in while it can't be read, such
/// as after the file was deleted.
private struct WorkspaceWallpaper: View {
    let url: URL
    /// In points; 0 draws the photo sharp.
    let blur: CGFloat
    let dimming: Color
    /// The editor's Workspace shows Dots for a file it can't read; Glass, which has already fallen back
    /// (`GlassPicture.resolve`), shows its plain ground.
    var dotsWhenUnreadable = true
    private var blurred: Bool { blur > 0 }

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var failed = false
    @State private var cacheLease: BoundedCGImageCache.Lease?

    var body: some View {
        GeometryReader { proxy in
            let pixels = WorkspaceBackground.bucketed(CGSize(width: proxy.size.width * displayScale,
                                                             height: proxy.size.height * displayScale))
            Group {
                if failed {
                    if dotsWhenUnreadable { WorkspaceDots() }
                } else if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .blur(radius: blur, opaque: true)
                        .overlay(dimming)
                } else {
                    Color.clear
                }
            }
            .task(id: "\(url.path)#\(Int(pixels.width))x\(Int(pixels.height))#\(blurred)") {
                await load(bounds: pixels)
            }
        }
        .onAppear { cacheLease = AnnotationWallpaperPreviewCache.beginUse() }
        .onDisappear {
            cacheLease = nil
            image = nil
        }
    }

    /// Keeps the last image up until the next one is ready, so a resize
    /// never flashes the grey.
    private func load(bounds: CGSize) async {
        if cacheLease == nil { cacheLease = AnnotationWallpaperPreviewCache.beginUse() }
        let url = url
        let size = await Task.detached(priority: .utility) { WorkspaceBackground.pixelSize(of: url) }.value
        guard !Task.isCancelled else { return }
        guard let size else {
            image = nil
            failed = true
            return
        }
        let decodeSize = WorkspaceBackground.decodeSize(image: size, bounds: bounds, blurred: blurred)
        let loaded = await AnnotationWallpaperPreviewCache.shared.image(for: url, maxPixelSize: CGFloat(decodeSize))
        guard !Task.isCancelled else { return }
        image = loaded
        failed = loaded == nil
    }
}

extension View {
    /// A chrome-coloured backing under text drawn straight on the workspace,
    /// shown only while a wallpaper may be behind it, as the Library's cards
    /// have under their titles. With Dots or Plain nothing changes. `capsule`
    /// fits a small padded label, such as the editor's zoom readout.
    func workspaceTextPlate(capsule: Bool = false) -> some View { modifier(WorkspaceTextPlate(capsule: capsule)) }
}

private struct WorkspaceTextPlate: ViewModifier {
    let capsule: Bool

    @AppStorage(WorkspaceBackground.styleKey) private var style = WorkspaceBackground.Style.dots
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.overGlassPicture) private var overGlassPicture

    @ViewBuilder
    func body(content: Content) -> some View {
        if !overGlassPicture && WorkspaceBackground.shown(style, reduceTransparency: reduceTransparency,
                                                           increaseContrast: contrast == .increased) != .wallpaper {
            content
        } else if capsule {
            content.background(WorkspaceChrome.background, in: Capsule())
        } else {
            // Drawn past the text without padding or fixedSize, so the page's
            // layout stays as it is. A padded, fixedSize plate crashed AppKit
            // (an update-constraints loop) when a search emptied the Library
            // on 27.0.1; the size change is the inferred cause.
            content
                .frame(maxWidth: 520)
                .background {
                    RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                        .fill(WorkspaceChrome.background)
                        .padding(-DS.Space.xl)
                }
        }
    }
}

/// Today's 18 pt dot grid, the default.
private struct WorkspaceDots: View {
    private let dotSpacing: CGFloat = 18
    private let dotRadius: CGFloat = 1.15

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let offset = dotSpacing / 2

            stride(from: offset, through: size.width, by: dotSpacing).forEach { x in
                stride(from: offset, through: size.height, by: dotSpacing).forEach { y in
                    path.addEllipse(in: CGRect(
                        x: x - dotRadius,
                        y: y - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    ))
                }
            }

            context.fill(path, with: .color(Color.secondary.opacity(0.14)))
        }
        .allowsHitTesting(false)
    }
}
