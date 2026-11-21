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
    @Bindable private var backgrounds = WindowBackgroundStore.shared
    @State private var destination = BackgroundDestination.app
    @State private var editingNight = false
    @CurrentTheme private var theme
    @Environment(\.overGlassPicture) private var overGlassPicture

    var body: some View {
        Form {
            Section("Theme") {
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
                            detail: "System follows macOS."
                        )
                    }
                    .onChange(of: mode) { AppAppearance.apply() }
                } else {
                    SettingsControlLabel(
                        "Mode",
                        detail: "System follows macOS."
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
                themePicker("Light theme", dark: false, selection: $lightTheme)
                themePicker("Dark theme", dark: true, selection: $darkTheme)
            }

            Section("Background") {
                Picker("Applies to", selection: $destination) {
                    ForEach(BackgroundDestination.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(destination == .app ? "Library, Settings, and other app windows." : "Image editor and Studio.")
                    .font(.caption).foregroundStyle(.secondary)
                let choices = Binding(
                    get: { backgrounds.preferences.backgrounds(for: destination, theme: theme) },
                    set: { backgrounds.preferences[destination] = $0 }
                )
                Toggle("Use a different background at night", isOn: choices.usesNight)
                .accessibilityLabel("Use a different background at night")
                if choices.wrappedValue.usesNight {
                    Picker("Edit background", selection: $editingNight) {
                        Text("Day").tag(false)
                        Text("Night").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                let night = choices.wrappedValue.usesNight && editingNight
                let choice = night ? choices.night : choices.day
                Picker("Style", selection: choice.style) {
                    ForEach([WorkspaceBackground.Style.wallpaper, .plain, .grid]) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if choice.wrappedValue.style == .wallpaper {
                    WorkspaceWallpaperSettings(choice: choice, destination: destination, identity: destination.rawValue + (night ? "Night" : "Day"))
                        .id(destination.rawValue + (night ? "Night" : "Day"))
                } else if choice.wrappedValue.style == .plain {
                    ColorPicker("Color", selection: Binding(
                        get: { choice.wrappedValue.solidRGB.map { ThemeColor.rgb($0).color } ?? theme.ground.workspace.color },
                        set: { choice.wrappedValue.solidRGB = ThemeColor.hex($0) }
                    ), supportsOpacity: false)
                    .accessibilityLabel("Background color")
                    Button("Use Theme Color") { choice.wrappedValue.solidRGB = nil }
                        .disabled(choice.wrappedValue.solidRGB == nil)
                }
            }
            if backgrounds.preferences.app.usesNight || backgrounds.preferences.editors.usesNight {
                Section("Schedule") {
                    timePicker("Day begins", minute: $backgrounds.preferences.dayStart, other: backgrounds.preferences.nightStart)
                    timePicker("Night begins", minute: $backgrounds.preferences.nightStart, other: backgrounds.preferences.dayStart)
                }
            }
        }
        .onAppear { editingNight = backgrounds.isNight }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }

    private func timePicker(_ title: String, minute: Binding<Int>, other: Int) -> some View {
        DatePicker(title, selection: Binding(get: {
            Calendar.current.date(bySettingHour: minute.wrappedValue / 60, minute: minute.wrappedValue % 60, second: 0, of: .now) ?? .now
        }, set: { date in
            let value = Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
            if value != other { minute.wrappedValue = value }
        }), displayedComponents: .hourAndMinute)
        .accessibilityLabel(title)
    }

    /// A slot's menu: the themes of its appearance. A saved choice Sukusho doesn't have shows as the Classic it draws.
    private func themePicker(_ title: String, dark: Bool, selection: Binding<String>) -> some View {
        Picker(title, selection: Binding(get: { AppTheme.named(selection.wrappedValue, dark: dark).id },
                                         set: { selection.wrappedValue = $0 })) {
            ForEach(AppTheme.builtIns.filter { $0.isDark == dark }) { Text($0.name).tag($0.id) }
        }
        .accessibilityLabel(title)
    }
}

/// The Wallpaper choice's rows: the wallpapers the screenshot background
/// picker keeps, Add… and Unsplash, then Dim and Blur.
private struct WorkspaceWallpaperSettings: View {
    @Binding var choice: BackgroundChoice
    let destination: BackgroundDestination
    let identity: String
    @CurrentTheme private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var defaultPicture: URL?
    @State private var host = WeakWindow()
    @State private var screenChanges = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var addError: String?
    private var picks: LatestPick { .for(identity) }

    private let store = AnnotationWallpaperStore.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: DS.Space.s), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            LazyVGrid(columns: columns, spacing: DS.Space.s) {
                InspectorTile(title: "Default picture", aspectRatio: 1.35, isSelected: choice.picture.isEmpty) {
                    choose(nil)
                } content: {
                    AnnotationCustomWallpaperPreview(wallpaper: AnnotationCustomWallpaper(
                        url: defaultPicture ?? GlassPicture.ownPicture(dark: colorScheme == .dark)
                    ), maxPixelSize: 320)
                }
                ForEach(store.recentWallpapers) { wallpaper in
                    InspectorTile(title: wallpaper.title, aspectRatio: 1.35, isSelected: isChosen(wallpaper)) {
                        choose(wallpaper.url, importing: store.importWallpaper)
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
            UnsplashWallpaperSearchView(search: UnsplashWallpaperSearch.shared) { choose($0, importing: store.importWallpaper) }
        }

        .onWindowChange { window in
            if let window, host.window !== window { host.window = window; screenChanges += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { note in
            if let window = host.window, note.object as? NSWindow === window { screenChanges += 1 }
        }
        .task(id: "\(colorScheme == .dark)#\(screenChanges)") {
            let desktop = host.window?.screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            let resolved = await GlassPicture.resolve(picked: "", desktop: desktop, dark: colorScheme == .dark)
            if !Task.isCancelled { defaultPicture = resolved.url }
        }

        let dim = Binding(get: { choice.dimSetting(for: destination, theme: theme) }, set: { value in
            choice.usesGlassDimDefault = false
            choice.dim = value
        })
        LabeledContent {
            HStack(spacing: DS.Space.l) {
                Slider(value: dim, in: WorkspaceBackground.dimRange, step: 0.05)
                    .frame(width: 180)
                    .accessibilityLabel("Dim")
                    .accessibilityValue(dim.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                Text(dim.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        } label: {
            Text("Dim")
        }

        Toggle("Blur picture", isOn: $choice.blur)
            .accessibilityLabel("Blur picture")
            .toggleStyle(.switch)

        if reduceTransparency || contrast == .increased {
            Text("Reduce Transparency or Increase Contrast is on in Accessibility settings, so the workspaces use the plain gray.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The renderer falls back to the default picture if an import disappeared.
    private var missingMessage: String? {
        if choice.picture.isEmpty { return nil }
        guard !FileManager.default.fileExists(atPath: choice.picture) else { return nil }
        return "The chosen wallpaper is gone, so the default picture is shown. Choose another."
    }

    private func isChosen(_ wallpaper: AnnotationCustomWallpaper) -> Bool {
        wallpaper.url.standardizedFileURL.path == choice.picture
    }

    /// A tile or a found picture at once, an added one once it's copied in (`importing`); the latest pick wins.
    private func choose(_ url: URL?, importing: @escaping (URL) async throws -> URL = { $0 }) {
        Task {
            await picks.choose(url, importing: importing, apply: { path in
                if !path.isEmpty { store.addRecentWallpaper(URL(fileURLWithPath: path)) }
                choice.picture = path
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
