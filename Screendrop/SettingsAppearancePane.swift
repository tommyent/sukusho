//
//  SettingsAppearancePane.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// Settings › Appearance: whether Sukusho's windows are light or dark, the theme each draws, and the workspace
/// behind captures.
struct AppearanceSettingsPane: View {
    @AppStorage(AppAppearance.key) private var mode = AppAppearance.automatic
    @AppStorage(AppTheme.lightKey) private var lightTheme = AppTheme.classicLight.id
    @AppStorage(AppTheme.darkKey) private var darkTheme = AppTheme.classicDark.id
    @AppStorage(WorkspaceBackground.styleKey) private var workspaceStyle = WorkspaceBackground.Style.dots
    @Environment(\.overGlassPicture) private var overGlassPicture

    var body: some View {
        Form {
            Section("Appearance") {
                if overGlassPicture {
                    LabeledContent {
                        InspectorSegmented(
                            options: AppAppearance.allCases,
                            isSelected: { $0 == mode },
                            onTap: { mode = $0 },
                            label: { Text($0.title).font(.system(size: 12, weight: .medium)) },
                            height: 26,
                            equalWidths: false
                        )
                        .fixedSize()
                    } label: {
                        SettingsControlLabel(
                            "Mode",
                            detail: "Light or dark for Sukusho's windows. System follows macOS."
                        )
                    }
                    .onChange(of: mode) { AppAppearance.apply() }
                } else {
                    SettingsControlLabel(
                        "Mode",
                        detail: "Light or dark for Sukusho's windows. System follows macOS."
                    ).control { label in
                        Picker(selection: $mode) {
                            ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                        } label: {
                            label
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    .onChange(of: mode) { AppAppearance.apply() }
                }
                themePicker("Light theme", detail: "How Sukusho looks while it's light.", dark: false, selection: $lightTheme)
                themePicker("Dark theme", detail: "How Sukusho looks while it's dark.", dark: true, selection: $darkTheme)
            }

            if [lightTheme, darkTheme].contains(where: { $0.hasPrefix("glass") }) {
                Section("Glass") { GlassPictureSettings() }
            }

            Section("Workspace") {
                SettingsControlLabel(
                    "Workspace background",
                    detail: "Behind Classic and Chip Library windows, the image editor and Studio; with a Glass theme, the Glass section controls the Library background instead. Captures, exports and uploads never include it."
                ).control { label in
                    Picker(selection: $workspaceStyle) {
                        ForEach(WorkspaceBackground.Style.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    } label: {
                        label
                    }
                }
                if workspaceStyle == .wallpaper {
                    WorkspaceWallpaperSettings()
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }

    /// A slot's menu: the themes of its appearance. A saved choice Sukusho doesn't have shows as the Classic it draws.
    private func themePicker(_ title: String, detail: String, dark: Bool, selection: Binding<String>) -> some View {
        SettingsControlLabel(title, detail: detail).control { label in
            Picker(selection: Binding(get: { AppTheme.named(selection.wrappedValue, dark: dark).id },
                                      set: { selection.wrappedValue = $0 })) {
                ForEach(AppTheme.builtIns.filter { $0.isDark == dark }) { Text($0.name).tag($0.id) }
            } label: {
                label
            }
        }
    }
}

/// The Wallpaper choice's rows: the wallpapers the screenshot background
/// picker keeps, Add… and Unsplash, then Dim and Blur.
private struct WorkspaceWallpaperSettings: View {
    @AppStorage(WorkspaceBackground.wallpaperPathKey) private var wallpaperPath = ""
    @AppStorage(WorkspaceBackground.dimKey) private var dim = WorkspaceBackground.defaultDim
    @AppStorage(WorkspaceBackground.blurKey) private var blurs = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var addError: String?
    private let picks = LatestPick.for(WorkspaceBackground.wallpaperPathKey)

    private let store = AnnotationWallpaperStore.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: DS.Space.s), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            LazyVGrid(columns: columns, spacing: DS.Space.s) {
                ForEach(store.recentWallpapers) { wallpaper in
                    InspectorTile(title: wallpaper.title, aspectRatio: 1.35, isSelected: isChosen(wallpaper)) {
                        choose(wallpaper.url)
                    } content: {
                        AnnotationCustomWallpaperPreview(wallpaper: wallpaper, maxPixelSize: 320)
                    }
                    .accessibilityLabel(store.accessibilityTitle(for: wallpaper))
                }
                AnnotationAddWallpaperTile(action: addWallpaper)
                    .help("Add a wallpaper")
                    .accessibilityLabel("Add Wallpaper…")
            }
            if let message = addError ?? missingMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            UnsplashWallpaperSearchView(search: UnsplashWallpaperSearch.shared) { choose($0) }
        }

        LabeledContent {
            HStack(spacing: DS.Space.l) {
                Slider(value: $dim, in: WorkspaceBackground.dimRange, step: 0.05)
                    .frame(width: 180)
                    .accessibilityLabel("Dim")
                    .accessibilityValue(dim.formatted(.percent.precision(.fractionLength(0))))
                Text(dim, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        } label: {
            SettingsControlLabel("Dim", detail: "Fades the wallpaper into the workspace gray so cards and canvases stand out, half as much again in dark mode.")
        }

        SettingsControlLabel(
            "Blur",
            detail: "Softens the wallpaper so a busy photo sits back."
        ).control { label in
            Toggle(isOn: $blurs) { label }
        }
        .toggleStyle(.switch)

        if reduceTransparency || contrast == .increased {
            Text("Reduce Transparency or Increase Contrast is on in Accessibility settings, so the workspaces use the plain gray.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Nothing chosen yet, or the chosen file is gone: the workspaces show Dots meanwhile.
    private var missingMessage: String? {
        if wallpaperPath.isEmpty { return "Choose a wallpaper. Until then the workspaces show dots." }
        guard !FileManager.default.fileExists(atPath: wallpaperPath) else { return nil }
        return "The chosen wallpaper is gone, so the workspaces show dots. Choose another."
    }

    private func isChosen(_ wallpaper: AnnotationCustomWallpaper) -> Bool {
        wallpaper.url.standardizedFileURL.path == wallpaperPath
    }

    /// A tile or a found picture at once, an added one once it's copied in (`importing`); the latest pick wins.
    private func choose(_ url: URL, importing: @escaping (URL) async throws -> URL = { $0 }) {
        Task {
            await picks.choose(url, importing: importing, apply: { path in
                store.addRecentWallpaper(URL(fileURLWithPath: path))
                wallpaperPath = path
                addError = nil
            }, failed: { addError = "Couldn't add the wallpaper: \($0.localizedDescription)" })
        }
    }

    private func addWallpaper() {
        let panel = NSOpenPanel()
        panel.title = "Add Wallpaper"
        panel.prompt = "Add"
        panel.allowedContentTypes = AnnotationWallpaperStore.supportedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choose(url, importing: store.importWallpaper)
    }
}

/// Glass's picture: the default (the desktop picture, or Sukusho's own while macOS would ask first), the wallpapers
/// the workspace keeps, and Add…. Every choice, a recent tile too, goes through `importWallpaper`, which copies a file
/// from outside Sukusho's folder in, so the choice stays when the original moves. What's shown is resolved off the
/// main thread, as the windows resolve it (`GlassPicture.resolve`).
private struct GlassPictureSettings: View {
    @AppStorage(GlassPicture.solidBackgroundKey) private var solidBackground = false
    @AppStorage(GlassPicture.pathKey) private var path = ""
    @Environment(\.colorScheme) private var colorScheme
    @State private var addError: String?
    /// The default for this window's screen, and what Glass shows for the current choice.
    @State private var resolved: (fallback: URL, shown: URL)?
    @State private var host = WeakWindow()
    @State private var windowChanges = 0
    private let picks = LatestPick.for(GlassPicture.pathKey)

    private let store = AnnotationWallpaperStore.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: DS.Space.s), count: 6)

    var body: some View {
        let dark = colorScheme == .dark
        SettingsControlLabel(
            "Solid background",
            detail: "Use a solid background instead of a blurred picture behind Glass windows."
        ).control { label in
            Toggle(isOn: $solidBackground) { label }
        }
        .toggleStyle(.switch)

        if !solidBackground {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                SettingsControlLabel(
                    "Picture",
                    detail: "Behind Glass's frosted panes. By default your desktop picture, or Sukusho's own when macOS would ask before Sukusho reads yours."
                )
                LazyVGrid(columns: columns, spacing: DS.Space.s) {
                    let own = resolved.map { $0.fallback == GlassPicture.ownPicture(dark: dark) } ?? true
                    InspectorTile(title: own ? "Sukusho's" : "Desktop", aspectRatio: 1.35, isSelected: path.isEmpty) {
                        choose(nil)
                    } content: {
                        if let resolved {
                            AnnotationCustomWallpaperPreview(wallpaper: AnnotationCustomWallpaper(url: resolved.fallback), maxPixelSize: 320)
                        }
                    }
                    .accessibilityLabel(own ? "Sukusho's picture" : "Desktop picture")
                    ForEach(store.recentWallpapers) { wallpaper in
                        InspectorTile(title: wallpaper.title, aspectRatio: 1.35,
                                      isSelected: wallpaper.url.standardizedFileURL.path == path) {
                            choose(wallpaper.url)
                        } content: {
                            AnnotationCustomWallpaperPreview(wallpaper: wallpaper, maxPixelSize: 320)
                        }
                        .accessibilityLabel(store.accessibilityTitle(for: wallpaper))
                    }
                    AnnotationAddWallpaperTile(action: add)
                        .help("Add a picture")
                        .accessibilityLabel("Add Picture…")
                }
                if let message = addError ?? unreadableMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .onWindowChange { host.window = $0; windowChanges += 1 }
            // As the backdrop does (`GlassBackdrop`): another screen, or Sukusho back in front, may mean another picture.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification), perform: refreshIfOwn)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification), perform: refreshIfOwn)
            .task(id: "\(path)#\(dark)#\(windowChanges)") {
                let desktop = host.window?.screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
                let fallback = await GlassPicture.resolve(picked: "", desktop: desktop, dark: dark).url
                let shown = path.isEmpty ? fallback : await GlassPicture.resolve(picked: path, desktop: desktop, dark: dark).url
                if !Task.isCancelled { resolved = (fallback, shown) }
            }
        }
    }

    /// The picked file is gone or doesn't decode: Glass shows the default meanwhile.
    private var unreadableMessage: String? {
        guard !path.isEmpty, let resolved, resolved.shown.path != path else { return nil }
        return "The chosen picture can't be read, so Glass shows the default. Choose another."
    }

    private func refreshIfOwn(_ note: Notification) {
        if let window = host.window, note.object as? NSWindow === window { windowChanges += 1 }
    }

    /// Copied into Sukusho's folder first unless it's already there (`importWallpaper` keeps those as they are);
    /// nil is the default. The latest pick wins, so a slow copy can't undo a newer choice.
    private func choose(_ url: URL?) {
        Task {
            await picks.choose(url, importing: store.importWallpaper, apply: { path = $0; addError = nil },
                               failed: { addError = "Couldn't use the picture: \($0.localizedDescription)" })
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.title = "Add Glass Picture"
        panel.prompt = "Add"
        panel.allowedContentTypes = AnnotationWallpaperStore.supportedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choose(url)
    }
}

/// Settings › Appearance › Mode: Sukusho's windows follow macOS, or stay light or dark.
enum AppAppearance: String, CaseIterable, Identifiable {
    case automatic, light, dark

    static let key = "appAppearance"

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Sets the saved choice on every window, at launch and when it changes.
    static func apply() {
        let choice = UserDefaults.standard.string(forKey: key).flatMap(Self.init) ?? .automatic
        NSApp.appearance = switch choice {
        case .automatic: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
