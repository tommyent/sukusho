//
//  SettingsView.swift
//  Screendrop
//

import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case shortcuts
    case screenshots
    case video
    case overlay
    case optimize
    case library
    case clipboard
    case cloud
    case agents
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .shortcuts: "Shortcuts"
        case .library: "Library"
        case .clipboard: "Clipboard"
        case .screenshots: "Screenshots"
        case .video: "Screen Recordings"
        case .overlay: "Overlay"
        case .optimize: "Optimize"
        case .cloud: "Cloud"
        case .agents: "Apps & Agents"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .shortcuts: "keyboard"
        case .library: "square.grid.2x2"
        case .clipboard: "doc.on.clipboard"
        case .screenshots: "photo.on.rectangle.angled"
        case .video: "video"
        case .overlay: "square.on.square"
        case .optimize: "arrow.down.right.and.arrow.up.left"
        case .cloud: "cloud"
        case .agents: "app.connected.to.app.below.fill"
        case .about: "info.circle"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()

    var selectedTab: SettingsTab? = .general

    private init() {}
}

// MARK: - Main Settings View

struct SettingsView: View {
    /// The sidebar's 200 points plus the widest pane: General needed 476 (measured on macOS
    /// 27.0.1 and 27.3 as the window's 660 minus the squeezed sidebar's 184) while it held what
    /// is now Appearance, with room to spare.
    static let minimumWidth: CGFloat = 720
    @State private var navigation = SettingsNavigation.shared
    @State private var navigationHistory: [SettingsTab] = [.general]
    @State private var historyIndex = 0
    @State private var isHistoryNavigation = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @DrawnGlass private var glass
    @State private var settingsWindow: NSWindow?
    @State private var glassMetrics = GlassWindowButtonMetrics.fallback

    private var activeTab: SettingsTab {
        navigation.selectedTab ?? .general
    }

    private var isSidebarCollapsed: Bool {
        glass != nil && columnVisibility == .detailOnly
    }

    var body: some View {
        NavigationSplitView(columnVisibility: glass != nil ? $columnVisibility : .constant(.all)) {
            // The window's minimum width (`minimumWidth`) leaves this column its 200 points
            // beside the widest pane. Keep the sidebar flexible inside the column so Glass's
            // floating inset pane (`LibraryFloatingSidebar`) never clips a fixed-width list.
            SettingsSidebarView(selectedTab: $navigation.selectedTab)
                .frame(minWidth: glass != nil ? 192 : 200, idealWidth: 200, maxWidth: 200)
                .navigationSplitViewColumnWidth(
                    min: 200,
                    ideal: 200,
                    max: 200
                )
                .glassSidebarCollapseOverlay(enabled: glass != nil, metrics: glassMetrics) {
                    withAnimation { columnVisibility = .detailOnly }
                }
                .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetailView(tab: activeTab)
        }
        .navigationTitle("Settings")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: SettingsView.minimumWidth, minHeight: 540)
        .onWindowChange { settingsWindow = $0 }
        .onChange(of: glass == nil) { _, off in
            if off { columnVisibility = .all }
        }
        .glassWindowChrome(
            window: settingsWindow,
            hasSidebar: true,
            sidebarVisible: !isSidebarCollapsed,
            inspectorVisible: false,
            metrics: $glassMetrics
        )
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if isSidebarCollapsed {
                    GlassPaneToggleButton(
                        title: "Show Sidebar",
                        symbol: "sidebar.left",
                        diameter: glassMetrics.diameter
                    ) {
                        withAnimation { columnVisibility = .all }
                    }
                }
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canGoBack)
                .help("Go Back")
                .accessibilityLabel("Go Back")

                Button {
                    goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canGoForward)
                .help("Go Forward")
                .accessibilityLabel("Go Forward")
            }
            // Bare icons, as in the Library and the editor: no glass capsule.
            .sharedBackgroundVisibility(.hidden)
        }
        .onAppear {
            navigationHistory = [activeTab]
            historyIndex = 0
        }
        .onChange(of: navigation.selectedTab) { _, _ in
            recordNavigation()
        }
    }

    // MARK: - Navigation History

    private var canGoBack: Bool {
        historyIndex > 0
    }

    private var canGoForward: Bool {
        historyIndex < navigationHistory.count - 1
    }

    private func goBack() {
        guard canGoBack else { return }
        isHistoryNavigation = true
        historyIndex -= 1
        navigation.selectedTab = navigationHistory[historyIndex]
        DispatchQueue.main.async { isHistoryNavigation = false }
    }

    private func goForward() {
        guard canGoForward else { return }
        isHistoryNavigation = true
        historyIndex += 1
        navigation.selectedTab = navigationHistory[historyIndex]
        DispatchQueue.main.async { isHistoryNavigation = false }
    }

    private func recordNavigation() {
        guard !isHistoryNavigation else { return }
        guard let tab = navigation.selectedTab else { return }
        if navigationHistory[historyIndex] == tab { return }
        if historyIndex < navigationHistory.count - 1 {
            navigationHistory = Array(navigationHistory.prefix(historyIndex + 1))
        }
        navigationHistory.append(tab)
        historyIndex = navigationHistory.count - 1
    }
}

// MARK: - Sidebar

private struct SettingsSidebarView: View {
    @Binding var selectedTab: SettingsTab?

    var body: some View {
        List(selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsSidebarRow(tab: tab)
                    .tag(tab)
            }
        }
        .listStyle(.sidebar)
        // Pinned to the bottom of the sidebar, below however many panes there are.
        .safeAreaInset(edge: .bottom, spacing: 0) { SettingsSidebarFooter() }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .navigationTitle("Settings")
    }
}

private struct SettingsSidebarRow: View {
    let tab: SettingsTab

    var body: some View {
        Label {
            Text(tab.title)
        } icon: {
            Image(systemName: tab.systemImage)
        }
        .foregroundStyle(.primary)
    }
}

private struct SettingsSidebarFooter: View {
    var body: some View {
        HStack(spacing: 6) {
            // Without the word "Version": the build number is long and the sidebar narrow.
            Text(AppVersion.displayString.replacingOccurrences(of: "Version ", with: "")
                .replacingOccurrences(of: " (", with: "\n("))
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fontDesign(.monospaced)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            AppVersionCopyButton()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Detail

private struct SettingsDetailView: View {
    let tab: SettingsTab
    @DrawnGlass private var glass
    @CurrentTheme private var theme

    var body: some View {
        Group {
            switch tab {
            case .general:
                GeneralSettingsPane()
            case .appearance:
                AppearanceSettingsPane()
            case .shortcuts:
                ShortcutsSettingsPane()
            case .library:
                LibrarySettingsPane()
            case .clipboard:
                ClipboardSettingsPane()
            case .screenshots:
                ScreenshotsSettingsPane()
            case .video:
                VideoSettingsPane()
            case .overlay:
                OverlaySettingsPane()
            case .optimize:
                OptimizeSettingsPane()
            case .cloud:
                CloudSettingsPane()
            case .agents:
                AgentsSettingsPane()
            case .about:
                SettingsAboutPane()
            }
        }
        .navigationTitle(tab.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Glass: the panes on the cards' frost, title bar too, so no form text meets the bare picture (a black one
        // made Light's rows black on black); the picture shows through it and, mirrored by macOS, under the sidebar.
        .background {
            if glass != nil, let frost = theme.card.recipe.frost {
                ZStack {
                    Rectangle().fill(frost.material.material)
                    Rectangle().fill(frost.tint.color)
                }
                .ignoresSafeArea()
            }
        }
        .background {
            if let glass { GlassBackdrop(backdrop: glass).backgroundExtensionEffect().ignoresSafeArea() }
        }
        .toolbarBackgroundVisibility(glass != nil ? .hidden : .automatic, for: .windowToolbar)
    }
}

// MARK: - Helpers

/// The same label rhythm across settings panes, with descriptions allowed to
/// wrap at the window's minimum width instead of being vertically truncated.
struct SettingsControlLabel: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// macOS reads the name and hint from the control itself.
    func control<Content: View>(@ViewBuilder _ content: (Self) -> Content) -> some View {
        content(self)
            .accessibilityLabel(title)
            .accessibilityHint(detail)
    }
}

extension URL {
    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
