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

/// Window decoration only. The capture and movie renderers use their own document backgrounds.
struct AnnotationEditorWorkspaceBackground: View {
    var destination: BackgroundDestination = .editors
    @CurrentTheme private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let choice = WindowBackgroundStore.shared.choice(for: destination, theme: theme)
        let style = WorkspaceBackground.shown(choice.style, reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased)
        let ground = theme.ground.workspace.color
        ZStack {
            Rectangle().fill(ground)
            switch style {
            case .dots: WorkspaceDots()
            case .plain:
                if choice.style == .plain, let rgb = choice.solidRGB, !reduceTransparency && contrast != .increased {
                    Rectangle().fill(ThemeColor.rgb(rgb).color)
                }
            case .wallpaper:
                WindowPicture(choice: choice, destination: destination)
            }
        }
    }
}

private struct WindowPicture: View {
    let choice: BackgroundChoice
    let destination: BackgroundDestination
    private var picked: String { choice.picture }
    @Environment(\.colorScheme) private var colorScheme
    @CurrentTheme private var theme
    @State private var host = WeakWindow()
    @State private var refresh = 0
    @State private var picture: GlassPicture.Resolved?

    private func refreshIfOwn(_ note: Notification) {
        if let window = host.window, note.object as? NSWindow === window { refresh += 1 }
    }

    var body: some View {
        let ground = theme.ground.workspace.color
        ZStack {
            Rectangle().fill(ground)
            if let picture {
                let effects = choice.pictureEffects(for: destination, theme: theme)
                WorkspaceWallpaper(url: picture.url, version: picture.version, blur: effects.blur,
                                   dimming: ground.opacity(effects.dim), dotsWhenUnreadable: false)
            }
        }
        // A detach reports nil; keep the live window, as a swapped accessor's late nil would leave the backdrop windowless.
        .onWindowChange { if let window = $0 { host.window = window }; refresh += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification), perform: refreshIfOwn)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification), perform: refreshIfOwn)
        .task(id: "\(picked)#\(colorScheme == .dark)#\(refresh)") {
            // Until the window is on a screen, which screen's picture to show isn't known (the main screen is the
            // one with keyboard focus, perhaps another display's). Only the default needs it: a picked picture never
            // waits for a screen, or the pick would be dropped until the window next changed or became key.
            let screen = host.window?.screen
            guard screen != nil || !picked.isEmpty else { return }
            let desktop = screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            let resolved = await GlassPicture.resolve(picked: picked, desktop: desktop, dark: colorScheme == .dark)
            if !Task.isCancelled, resolved != picture { picture = resolved }
        }
    }
}

extension EnvironmentValues {
    @Entry var backgroundDestination = BackgroundDestination.app
    /// Library text over a picture or custom color needs a backing.
    @Entry var overGlassPicture = false
}

extension View {
    /// The cards' frost behind Library text over the Glass picture, or regular material over other custom backgrounds.
    func glassFrostBacking<S: Shape>(in shape: S) -> some View { modifier(GlassFrostBacking(shape: shape)) }
}

private struct GlassFrostBacking<S: Shape>: ViewModifier {
    let shape: S
    @DrawnGlass private var glass
    @CurrentTheme private var theme
    @Environment(\.overGlassPicture) private var needsBacking

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
        } else if needsBacking {
            content.background(.regularMaterial, in: shape)
        } else {
            content
        }
    }
}

extension View {
    /// Glass: apply consistent floating window chrome across every window that has a sidebar or inspector — transparent
    /// titlebar on macOS 27+, lifted Liquid Glass pill under the window buttons, and floating glass side panes via
    /// `LibraryFloatingSidebar`. Classic, Chip, Reduce Transparency and Increase Contrast restore the native layout.
    func glassWindowChrome(
        window: NSWindow?,
        hasSidebar: Bool,
        sidebarVisible: Bool,
        inspectorVisible: Bool,
        metrics: Binding<GlassWindowButtonMetrics>
    ) -> some View {
        modifier(GlassWindowChromeModifier(
            window: window,
            hasSidebar: hasSidebar,
            sidebarVisible: sidebarVisible,
            inspectorVisible: inspectorVisible,
            metrics: metrics
        ))
    }

    /// Glass: place the collapse-sidebar glass circle with shadow inside a floating left sidebar's top-trailing corner.
    func glassSidebarCollapseOverlay(
        enabled: Bool,
        metrics: GlassWindowButtonMetrics,
        action: @escaping () -> Void
    ) -> some View {
        overlay(alignment: .topTrailing) {
            if enabled {
                GlassPaneToggleButton(
                    title: "Hide Sidebar",
                    symbol: "sidebar.left",
                    diameter: metrics.diameter,
                    action: action
                )
                .padding(.top, metrics.topInsideFloatingPane)
                .padding(.trailing, metrics.paneTrailingInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .ignoresSafeArea(.container, edges: .top)
            }
        }
    }

    /// Glass: place the collapse-inspector glass circle with shadow inside the floating trailing inspector's top-right
    /// corner (and keep it in the same spot when collapsed so it stays reachable).
    func glassInspectorToggleOverlay(
        enabled: Bool,
        isPresented: Binding<Bool>,
        metrics: GlassWindowButtonMetrics,
        isDisabled: Bool = false,
        hasKeyboardShortcut: Bool = false,
        onToggle: (() -> Void)? = nil
    ) -> some View {
        overlay(alignment: .topTrailing) {
            if enabled {
                let button = GlassPaneToggleButton(
                    title: isPresented.wrappedValue ? "Hide Inspector" : "Show Inspector",
                    symbol: "sidebar.right",
                    diameter: metrics.diameter
                ) {
                    onToggle?()
                    isPresented.wrappedValue.toggle()
                }
                .disabled(isDisabled)
                Group {
                    if hasKeyboardShortcut {
                        button.keyboardShortcut("i", modifiers: [.command, .option])
                    } else {
                        button
                    }
                }
                .padding(.top, metrics.top)
                .padding(.trailing, LibraryFloatingSidebar.outerInset + metrics.paneTrailingInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .ignoresSafeArea(.container, edges: .top)
            }
        }
    }

    /// Glass: keep an empty toolbar inside `.inspector` so AppKit preserves the toolbar tracking separator at the
    /// floating inspector's leading edge and main toolbar actions stay clear of the pane.
    func glassInspectorToolbar(enabled: Bool) -> some View {
        modifier(GlassInspectorToolbarModifier(enabled: enabled))
    }
}

/// Neutral monochrome sidebar row with a translucent selection and hover pill, shared by Library and Settings across
/// all themes so sidebars never fall back to solid system-blue icons or highlights. Tag it inside a
/// `List(selection:)`: the list keeps native clicks, arrow keys, type-select and VoiceOver selection, and this row
/// turns off AppKit's accent pill (`NeutralListSelection`) and draws its own.
struct FloatingSidebarRow<Icon: View, Trailing: View>: View {
    let title: String
    let isSelected: Bool
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let trailing: () -> Trailing

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private var dark: Bool { colorScheme == .dark }

    private var ink: Color {
        isSelected ? .primary : AppTheme.glassTitleInk(dark: dark).color
    }

    private var pillFill: Color {
        if isSelected {
            return dark ? .white.opacity(0.14) : .black.opacity(0.09)
        }
        if isHovering {
            return dark ? .white.opacity(0.06) : .black.opacity(0.04)
        }
        return .clear
    }

    var body: some View {
        HStack(spacing: 6) {
            icon()
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .frame(width: 16, alignment: .center)
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
            trailing()
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
        .background(NeutralListSelection())
        .onHover { isHovering = $0 }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(pillFill)
                .padding(.horizontal, 8)
        )
        .listRowInsets(EdgeInsets(top: 1, leading: 2, bottom: 1, trailing: 2))
    }
}

/// Turns off the accent selection pill of the AppKit table behind the `List` this sits in, keeping its selection:
/// `FloatingSidebarRow` draws a neutral pill instead.
/// ponytail: relies on SwiftUI's macOS List being an NSTableView (true through 27); if that changes, the system
/// pill shows again under the neutral one, and keyboard selection still works.
private struct NeutralListSelection: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.neutralize() }

    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            neutralize()
        }

        func neutralize() {
            var view = superview
            while let current = view, !(current is NSTableView) { view = current.superview }
            if let table = view as? NSTableView, table.selectionHighlightStyle != .none {
                table.selectionHighlightStyle = .none
            }
        }
    }
}

extension FloatingSidebarRow where Icon == Image, Trailing == EmptyView {
    init(title: String, systemImage: String, isSelected: Bool) {
        self.init(title: title, isSelected: isSelected) {
            Image(systemName: systemImage)
        } trailing: {
            EmptyView()
        }
    }
}

extension FloatingSidebarRow where Icon == Image {
    init(
        title: String,
        systemImage: String,
        isSelected: Bool,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.init(title: title, isSelected: isSelected) {
            Image(systemName: systemImage)
        } trailing: {
            trailing()
        }
    }
}

/// Circular Liquid Glass sidebar/inspector toggle button matching the window-button pill's glass, height and shadow.
struct GlassPaneToggleButton: View {
    let title: String
    let symbol: String
    let diameter: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: max(12, diameter * 0.46), weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: diameter, height: diameter)
                .background {
                    // The window-button pill's lift (`applyLiftShadow`), drawn in SwiftUI and only outside the circle,
                    // so no AppKit host has to stop clipping for it and the glass isn't darkened from below.
                    Circle()
                        .fill(.black)
                        .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
                        .mask {
                            Rectangle().padding(-16)
                                .overlay { Circle().fill(.black).blendMode(.destinationOut) }
                                .compositingGroup()
                        }
                        .allowsHitTesting(false)
                }
                .background { CapsuleGlass().allowsHitTesting(false) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

private struct GlassWindowChromeModifier: ViewModifier {
    let window: NSWindow?
    let hasSidebar: Bool
    let sidebarVisible: Bool
    let inspectorVisible: Bool
    @Binding var metrics: GlassWindowButtonMetrics

    @FloatingGlassChrome private var floatingChrome
    @Environment(\.colorScheme) private var colorScheme
    @State private var titlebarBeforeGlass: (transparent: Bool, separator: NSTitlebarSeparatorStyle)?
    @State private var trackedWindowID: ObjectIdentifier?

    private var windowID: ObjectIdentifier? { window.map(ObjectIdentifier.init) }

    func body(content: Content) -> some View {
        content
            .onChange(of: windowID) { _, newID in
                if newID != trackedWindowID {
                    trackedWindowID = newID
                    titlebarBeforeGlass = nil
                }
            }
            .task(id: "\(floatingChrome)#\(windowID?.hashValue ?? 0)") {
                if #available(macOS 27, *), let window {
                    if floatingChrome {
                        if titlebarBeforeGlass == nil {
                            titlebarBeforeGlass = (window.titlebarAppearsTransparent, window.titlebarSeparatorStyle)
                        }
                        window.titlebarAppearsTransparent = true
                        window.titlebarSeparatorStyle = .none
                    } else if let previous = titlebarBeforeGlass {
                        window.titlebarAppearsTransparent = previous.transparent
                        window.titlebarSeparatorStyle = previous.separator
                        titlebarBeforeGlass = nil
                    }
                }
                for _ in 0..<10 {
                    let done = LibraryWindowButtonCapsule.update(window, shown: floatingChrome) { measured in
                        if measured != metrics { metrics = measured }
                    }
                    if done { break }
                    try? await Task.sleep(for: .milliseconds(200))
                    if Task.isCancelled { break }
                }
            }
            .task(id: "\(floatingChrome)#\(colorScheme)#\(sidebarVisible)#\(inspectorVisible)#\(windowID?.hashValue ?? 0)") {
                for _ in 0..<10 {
                    let done = LibraryFloatingSidebar.update(
                        window,
                        floating: floatingChrome,
                        hasSidebar: hasSidebar,
                        inspectorVisible: inspectorVisible
                    )
                    if done { break }
                    try? await Task.sleep(for: .milliseconds(200))
                    if Task.isCancelled { break }
                }
            }
    }
}

private struct GlassInspectorToolbarModifier: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.toolbar {
                ToolbarSpacer(.flexible)
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
    /// Glass's `GlassPicture.version(of:)`: a file replaced at the same path is drawn again.
    var version = ""
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
            .task(id: "\(url.path)#\(version)#\(Int(pixels.width))x\(Int(pixels.height))#\(blurred)") {
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
        // The file reads (its size did), so a nil decode is passing, such as the shared cache emptied mid-decode;
        // keep the last good image rather than latching blank, since nothing retries until the url or size changes.
        image = loaded ?? image
        failed = image == nil
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

    @Environment(\.backgroundDestination) private var destination

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.overGlassPicture) private var overGlassPicture
    @CurrentTheme private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased || (!overGlassPicture && !WindowBackgroundStore.shared.choice(for: destination, theme: theme).needsTextBacking) {
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
                    let plate = RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    Group {
                        if overGlassPicture {
                            Color.clear.glassFrostBacking(in: plate)
                        } else {
                            plate.fill(WorkspaceChrome.background)
                        }
                    }
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
