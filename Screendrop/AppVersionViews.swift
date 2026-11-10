//
//  AppVersionViews.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// Copies `AppVersion.reportString`, with the checkmark the app's other copy buttons show.
struct AppVersionCopyButton: View {
    @State private var copied = ActionFeedback()

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(AppVersion.reportString, forType: .string)
            copied.show()
        } label: {
            Image(systemName: copied.isShowing ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied.isShowing ? Color.green : .secondary)
                // The checkmark is narrower; the row mustn't shift under it.
                .frame(width: 16, height: 16)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .actionFeedback(copied, label: "Copy Version", help: "Copy the version for a bug report")
    }
}

/// The app's icon, name and version with its copy button: the top of Settings › About, and
/// the whole of the About window.
struct AboutHeader: View {
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 6) {
                Text("Sukusho")
                    .font(.largeTitle.bold())

                HStack(spacing: 6) {
                    Text(AppVersion.displayString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    AppVersionCopyButton()
                }

                Text("A native screenshot and recording tool for macOS.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The app menu's About Sukusho: the standard panel can't hold a copy button, so this small
/// window stands in for it.
@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: AboutWindowController?
    private var didEnterActivationPolicy = false

    static func show() {
        if shared == nil { shared = AboutWindowController() }
        shared?.showWindow(nil)
    }

    private init() {
        let hosting = NSHostingController(rootView: AboutHeader().padding(.horizontal, 28).padding(.vertical, 24).fixedSize())
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "About Sukusho"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        PreviewWindowCaptureExclusion.shared.register(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        // As Settings does: the app shows in the Dock while one of its windows is open.
        if !didEnterActivationPolicy {
            AppActivationPolicy.enter()
            didEnterActivationPolicy = true
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        super.showWindow(sender)
    }

    func windowWillClose(_ notification: Notification) {
        if didEnterActivationPolicy {
            AppActivationPolicy.leave()
            didEnterActivationPolicy = false
        }
        Self.shared = nil
    }
}
