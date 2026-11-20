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

    var body: some View {
        Form {
            Section("Appearance") {
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
                themePicker("Light theme", detail: "How Sukusho looks while it's light.", dark: false, selection: $lightTheme)
                themePicker("Dark theme", detail: "How Sukusho looks while it's dark.", dark: true, selection: $darkTheme)
            }

            if [lightTheme, darkTheme].contains(where: { $0.hasPrefix("glass") }) {
                Section("Glass") { GlassPictureSettings() }
            }

            Section("Workspace") {
                SettingsControlLabel(
                    "Workspace background",
                    detail: "Behind the Library, the image editor and Studio; with a Glass theme, the Library shows its picture instead. Captures, exports and uploads never include it."
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

    private func choose(_ url: URL) {
        store.addRecentWallpaper(url)
        wallpaperPath = url.standardizedFileURL.path
        addError = nil
    }

    private func addWallpaper() {
        let panel = NSOpenPanel()
        panel.title = "Add Wallpaper"
        panel.prompt = "Add"
        panel.allowedContentTypes = AnnotationWallpaperStore.supportedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            choose(try store.importWallpaper(from: url))
        } catch {
            addError = "Couldn't add the wallpaper: \(error.localizedDescription)"
        }
    }
}

/// Glass's picture: the default (the desktop picture, or Sukusho's own while macOS would ask first), the wallpapers
/// the workspace keeps, and Add…, which copies the picked file into Sukusho's folder so it stays when the original moves.
private struct GlassPictureSettings: View {
    @AppStorage(GlassPicture.pathKey) private var path = ""
    @Environment(\.colorScheme) private var colorScheme
    @State private var addError: String?

    private let store = AnnotationWallpaperStore.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: DS.Space.s), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SettingsControlLabel(
                "Picture",
                detail: "Behind Glass's frosted panes. By default your desktop picture, or Sukusho's own when macOS would ask before Sukusho reads yours."
            )
            LazyVGrid(columns: columns, spacing: DS.Space.s) {
                let fallback = GlassPicture.desktopPicture() == nil
                InspectorTile(title: fallback ? "Sukusho's" : "Desktop", aspectRatio: 1.35, isSelected: path.isEmpty) {
                    path = ""
                } content: {
                    AnnotationCustomWallpaperPreview(wallpaper: AnnotationCustomWallpaper(url: GlassPicture.url(picked: "", dark: colorScheme == .dark)),
                                                     maxPixelSize: 320)
                }
                .accessibilityLabel(fallback ? "Sukusho's picture" : "Desktop picture")
                ForEach(store.recentWallpapers) { wallpaper in
                    InspectorTile(title: wallpaper.title, aspectRatio: 1.35,
                                  isSelected: wallpaper.url.standardizedFileURL.path == path) {
                        path = wallpaper.url.standardizedFileURL.path
                    } content: {
                        AnnotationCustomWallpaperPreview(wallpaper: wallpaper, maxPixelSize: 320)
                    }
                    .accessibilityLabel(store.accessibilityTitle(for: wallpaper))
                }
                AnnotationAddWallpaperTile(action: add)
                    .help("Add a picture")
                    .accessibilityLabel("Add Picture…")
            }
            if let message = addError ?? missingMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The picked file is gone: Glass shows the default meanwhile.
    private var missingMessage: String? {
        path.isEmpty || FileManager.default.fileExists(atPath: path) ? nil
            : "The chosen picture is gone, so Glass shows the default. Choose another."
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.title = "Add Glass Picture"
        panel.prompt = "Add"
        panel.allowedContentTypes = AnnotationWallpaperStore.supportedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            path = try store.importWallpaper(from: url).standardizedFileURL.path
            addError = nil
        } catch {
            addError = "Couldn't add the picture: \(error.localizedDescription)"
        }
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
