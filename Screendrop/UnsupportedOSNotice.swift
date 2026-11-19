//
//  UnsupportedOSNotice.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// Below the tested macOS, once per macOS version until dismissed, in a modeless `LaunchNoticePanel`.
enum UnsupportedOSNotice {
    private(set) static var panel: LaunchNoticePanel?
    static let dismissedKey = "unsupportedOSNotice.dismissedForVersion"
    #if DEBUG
    /// A Debug build pretends to run on this version, so the notice can be seen on macOS 27:
    /// `defaults write <bundle id> unsupportedOSNotice.previewVersion 26.5.0`.
    static let previewKey = "unsupportedOSNotice.previewVersion"
    #endif

    static func showIfNeeded(defaults: UserDefaults = .standard) {
        let version = runningVersion(defaults: defaults)
        guard AppVersion.showsUnsupportedNotice(on: version, dismissedFor: defaults.string(forKey: dismissedKey)) else {
            return
        }
        guard panel == nil else { return }
        let window = LaunchNoticePanel(title: "Unsupported macOS version", content: Notice(version: version, defaults: defaults) {
            UnsupportedOSNotice.panel?.close()
        })
        window.onClose = { UnsupportedOSNotice.panel = nil }
        panel = window
        window.orderFront(nil)
    }

    private struct Notice: View {
        let version: OperatingSystemVersion
        let defaults: UserDefaults
        let close: () -> Void
        @State private var suppress = false

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sukusho has been tested on macOS \(AppVersion.testedMacOS.map(AppVersion.macOSString).formatted(.list(type: .and))).")
                    .font(.headline)
                Text("You’re running macOS \(AppVersion.macOSString(version)). Some features may be unavailable.")
                Toggle("Don’t show again for macOS \(version.majorVersion)", isOn: $suppress)
                    .toggleStyle(.checkbox)
                    .onChange(of: suppress) { _, checked in
                        if checked { defaults.set(String(version.majorVersion), forKey: UnsupportedOSNotice.dismissedKey) }
                        else { defaults.removeObject(forKey: UnsupportedOSNotice.dismissedKey) }
                    }
                HStack {
                    Spacer()
                    Button("OK", action: close).keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 330, alignment: .leading)
            .padding(20)
            .fixedSize()
        }
    }

    private static func runningVersion(defaults: UserDefaults) -> OperatingSystemVersion {
        #if DEBUG
        if let preview = defaults.string(forKey: previewKey) {
            let parts = preview.split(separator: ".").compactMap { Int($0) }
            if let major = parts.first {
                return OperatingSystemVersion(majorVersion: major, minorVersion: parts.count > 1 ? parts[1] : 0,
                                              patchVersion: parts.count > 2 ? parts[2] : 0)
            }
        }
        #endif
        return ProcessInfo.processInfo.operatingSystemVersion
    }
}
