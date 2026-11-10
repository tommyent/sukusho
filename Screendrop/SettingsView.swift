//
//  SettingsView.swift
//  Screendrop
//

import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case screenshots
    case video
    case overlay
    case library
    case cloud
    case agents
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .library: "Library"
        case .screenshots: "Screenshots"
        case .video: "Screen Recordings"
        case .overlay: "Overlay"
        case .cloud: "Cloud"
        case .agents: "Agents"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .library: "square.grid.2x2"
        case .screenshots: "photo.on.rectangle.angled"
        case .video: "video"
        case .overlay: "square.on.square"
        case .cloud: "cloud"
        case .agents: "terminal"
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
    /// The sidebar's 200 points plus the widest pane: General needs 476 (measured on macOS
    /// 27.0.1 and 27.3 as the window's 660 minus the squeezed sidebar's 184), with room to spare.
    static let minimumWidth: CGFloat = 720
    @State private var navigation = SettingsNavigation.shared
    @State private var navigationHistory: [SettingsTab] = [.general]
    @State private var historyIndex = 0
    @State private var isHistoryNavigation = false

    private var activeTab: SettingsTab {
        navigation.selectedTab ?? .general
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            // The window's minimum width (`minimumWidth`) leaves this column its 200 points
            // beside the widest pane. Below that, General's rows squeezed the column to 184
            // and the 200-point sidebar hung over both edges, losing its left inset.
            SettingsSidebarView(selectedTab: $navigation.selectedTab)
                .frame(width: 200)
                .navigationSplitViewColumnWidth(
                    min: 200,
                    ideal: 200,
                    max: 200
                )
                .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetailView(tab: activeTab)
        }
        .navigationTitle("Settings")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: SettingsView.minimumWidth, minHeight: 540)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
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
            Text(AppVersion.displayString.replacingOccurrences(of: "Version ", with: ""))
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fontDesign(.monospaced)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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

    var body: some View {
        Group {
            switch tab {
            case .general:
                GeneralSettingsPane()
            case .shortcuts:
                ShortcutsSettingsPane()
            case .library:
                LibrarySettingsPane()
            case .screenshots:
                ScreenshotsSettingsPane()
            case .video:
                VideoSettingsPane()
            case .overlay:
                OverlaySettingsPane()
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
