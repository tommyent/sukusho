//
//  CloudUploadOptions.swift
//  Screendrop
//
//  The title, link expiry and comment choices offered right before a
//  manual cloud upload. Auto-upload (after-capture, no user interaction)
//  skips this entirely: the default expiry from Settings › Cloud, and the
//  remembered comment toggles.
//

import AppKit
import SwiftUI

struct CloudUploadOptions: Sendable {
    var title: String
    var socialEnabled: Bool
    var expiry = CloudExpiry.never
    var allowAnonymousComments = true
    /// Nil: anyone with the link can open it.
    var password: String? = nil
    /// Sealed before upload; the key goes in the link (CloudShareSeal).
    var encrypted = false
    /// The note Draft message wrote, as the owner left it. Never uploaded: it's copied above
    /// the link once the upload finishes, or handed to the agent that asked for the share.
    var message: String? = nil

    /// `nil` title means "let the worker fall back to the filename (or,
    /// for recordings, the auto-generated 'Screen Recording - …' title)".
    var trimmedTitleOrNil: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What a share that skips Share Options gets: the Settings expiry and the remembered
    /// comment choices, with no title, password or encryption.
    static var savedDefaults: CloudUploadOptions {
        CloudUploadOptions(title: "", socialEnabled: CloudUploadPreferences.lastSocialEnabled,
                           expiry: CloudUploadPreferences.defaultExpiry,
                           allowAnonymousComments: CloudUploadPreferences.lastAnonymousComments)
    }
}

/// Remembers the last-chosen "allow comments & likes" toggle across
/// uploads (including background auto-uploads, which never show the
/// popover) so the common case doesn't require re-deciding every time.
enum CloudUploadPreferences {
    private static let socialEnabledKey = "cloudUploadDefaultSocialEnabled"

    static var lastSocialEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: socialEnabledKey) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: socialEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: socialEnabledKey) }
    }

    private static let anonymousCommentsKey = "cloudUploadDefaultAnonymousComments"

    static let defaultExpiryKey = "cloudUploadDefaultExpiry"

    /// Settings › Cloud › Default link expiry. Share Options starts with it,
    /// and uploads that skip Share Options use it.
    static var defaultExpiry: CloudExpiry {
        CloudExpiry(rawValue: UserDefaults.standard.integer(forKey: defaultExpiryKey)) ?? .never
    }

    /// On unless turned off, as the Worker's own default.
    static var lastAnonymousComments: Bool {
        get { UserDefaults.standard.object(forKey: anonymousCommentsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: anonymousCommentsKey) }
    }
}

/// Small popover form shown from an upload/share button: a title field
/// (prefilled with a suggested default, editable), when the link expires,
/// an optional password, and whether comments + likes are on and open to
/// anonymous visitors.
/// Confirming remembers the comment toggles as the defaults for next
/// time; the expiry starts at the Settings default every time, and a
/// change here applies to this share only.
struct CloudUploadOptionsPopover: View {
    let suggestedTitle: String
    /// Off for several files at once: one title can't name them all.
    var showsTitle = true
    /// Why this share can't be encrypted; nil when it can.
    var encryptionUnavailable: String? = nil
    /// An agent's choices to start from (AgentAccess); they don't become the remembered defaults.
    var initial: CloudUploadOptions? = nil
    var focusesPassword = false
    var confirmTitle = "Upload"
    var cancelTitle = "Cancel"
    /// Cancel outside a sheet or popover, where `dismiss` does nothing: the shake shelf, an agent's approval panel.
    var onCancel: (() -> Void)? = nil
    /// Offers Draft message for one recording or capture; nil hides it.
    var messageSource: ShareMessageSource? = nil
    let onConfirm: (CloudUploadOptions) -> Void

    @State private var title: String
    /// Nil until Draft message has written one.
    @State private var message: String?
    @State private var isDrafting = false
    @State private var messageNote: String?
    @State private var socialEnabled = CloudUploadPreferences.lastSocialEnabled
    @State private var expiry = CloudUploadPreferences.defaultExpiry
    @State private var allowAnonymousComments = CloudUploadPreferences.lastAnonymousComments
    /// Never remembered: each protected link gets its own.
    @State private var password = ""
    /// Off every time, like the password.
    @State private var encrypted = false
    @FocusState private var passwordFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(suggestedTitle: String = "", showsTitle: Bool = true, encryptionUnavailable: String? = nil,
         initial: CloudUploadOptions? = nil, focusesPassword: Bool = false, confirmTitle: String = "Upload",
         cancelTitle: String = "Cancel", onCancel: (() -> Void)? = nil, messageSource: ShareMessageSource? = nil,
         onConfirm: @escaping (CloudUploadOptions) -> Void) {
        self.suggestedTitle = suggestedTitle
        self.showsTitle = showsTitle
        self.encryptionUnavailable = encryptionUnavailable
        self.initial = initial
        self.focusesPassword = focusesPassword
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.onCancel = onCancel
        self.messageSource = messageSource
        self.onConfirm = onConfirm
        _title = State(initialValue: initial?.title ?? suggestedTitle)
        if let initial {
            _socialEnabled = State(initialValue: initial.socialEnabled)
            _expiry = State(initialValue: initial.expiry)
            _allowAnonymousComments = State(initialValue: initial.allowAnonymousComments)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share Options")
                .font(.headline)

            if showsTitle {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Title")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Title", text: $title, prompt: Text("Untitled"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1)
                }
            }

            if let messageSource, showsTitle {
                messageControls(messageSource)
            }

            HStack {
                Text("Link expires")
                Spacer()
                Picker("Link expires", selection: $expiry) {
                    ForEach(CloudExpiry.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            HStack {
                Text("Password")
                Spacer()
                SecureField("Password", text: $password, prompt: Text("Optional"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .focused($passwordFocused)
            }
            .help("Visitors need it to open the link. Up to 128 characters.")
            .onAppear { if focusesPassword { passwordFocused = true } }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("End-to-end encryption")
                    Spacer()
                    Toggle("End-to-end encryption", isOn: $encrypted)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .disabled(encryptionUnavailable != nil)
                .foregroundStyle(encryptionUnavailable == nil ? .primary : .secondary)
                .help("The file is encrypted on this Mac before it's uploaded; the key travels only in the link.")
                Text(encryptionUnavailable ?? "Only people with the full link can open the file. Not even the server can.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Allow comments & likes")
                Spacer()
                Toggle("Allow comments & likes", isOn: $socialEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }

            HStack {
                Text("Allow anonymous comments")
                Spacer()
                Toggle("Allow anonymous comments", isOn: $allowAnonymousComments)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .disabled(!socialEnabled)
            .foregroundStyle(socialEnabled ? .primary : .secondary)
            .help("Visitors can comment without signing in")

            HStack {
                Spacer()
                Button(cancelTitle) {
                    onCancel?()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(confirmTitle) {
                    if initial == nil {
                        CloudUploadPreferences.lastSocialEnabled = socialEnabled
                        CloudUploadPreferences.lastAnonymousComments = allowAnonymousComments
                    }
                    let drafted = message?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let options = CloudUploadOptions(title: title, socialEnabled: socialEnabled, expiry: expiry,
                                                     allowAnonymousComments: allowAnonymousComments,
                                                     password: password.isEmpty ? nil : password,
                                                     encrypted: encrypted && encryptionUnavailable == nil,
                                                     message: drafted?.isEmpty == false ? drafted : nil)
                    // Confirm first: the Files sheet's dismissal clears the files it would upload.
                    onConfirm(options)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!password.isEmpty && !CloudUploadList.isValidPassword(password))
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    /// Draft message: Apple Intelligence writes the note to send with the link, from the title,
    /// summary and chapters. Upload copies it above the link; an agent's share hands it to the agent.
    @ViewBuilder
    private func messageControls(_ source: ShareMessageSource) -> some View {
        let unavailable = OnDeviceText.unavailableReason()
        let destination = initial == nil ? "Copied above the link when the upload finishes." : "Goes to the agent with the link."
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Message")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if isDrafting {
                    ProgressView().controlSize(.small)
                } else {
                    Button(message == nil ? "Draft Message" : "Draft Again", systemImage: "sparkles") {
                        draftMessage(source)
                    }
                    .controlSize(.small)
                    .disabled(unavailable != nil)
                    .help("Apple Intelligence drafts a short note to go with the link, on this Mac. It isn't uploaded.")
                }
            }
            if let message {
                TextField("Message", text: Binding(get: { message }, set: { self.message = $0 }), axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...10)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = unavailable ?? messageNote ?? (message == nil ? nil : destination) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func draftMessage(_ source: ShareMessageSource) {
        guard !isDrafting, OnDeviceText.unavailableReason() == nil else { return }
        isDrafting = true
        messageNote = nil
        let title = title
        Task {
            do {
                let text = try await RecordingTextIntelligence.message(title: title, source: source, model: SystemTextModel())
                if text.isEmpty { messageNote = "Apple Intelligence wrote nothing; try again." } else { message = text }
            } catch {
                messageNote = OnDeviceText.message(for: error)
            }
            isDrafting = false
        }
    }
}

/// Settings › Cloud: how long new share links last unless Share Options
/// says otherwise.
struct CloudShareDefaultsSection: View {
    @AppStorage(CloudUploadPreferences.defaultExpiryKey) private var expiry = CloudExpiry.never
    @AppStorage(ShakeToUpload.enabledKey) private var shakeToUpload = false

    var body: some View {
        Section {
            Picker("Default link expiry", selection: $expiry) {
                ForEach(CloudExpiry.allCases) { Text($0.title).tag($0) }
            }
            Toggle(isOn: $shakeToUpload) {
                Text("Shake while dragging files to upload")
                Text("Shake the pointer while you drag files from Finder or the Desktop, then drop them on the shelf that appears. Hold Option as you drop to skip Share Options.")
            }
            .onChange(of: shakeToUpload) { ShakeToUpload.shared.update() }
        } header: {
            Text("Sharing")
        } footer: {
            Text("New links expire after this, including quick and automatic uploads. Share Options starts with it, and a change there applies to that share only.")
        }
    }
}

/// Wraps any trigger content in a button that opens `CloudUploadOptionsPopover`
/// before firing `onUpload`. Drop-in replacement for a plain
/// `Button(action: onUpload) { ... }` at a manual upload/share call site.
struct CloudUploadButton<Label: View>: View {
    let suggestedTitle: String
    var encryptionUnavailable: String? = nil
    var messageSource: ShareMessageSource? = nil
    let onUpload: (CloudUploadOptions) -> Void
    @ViewBuilder let label: () -> Label

    @State private var showingOptions = false

    var body: some View {
        Button {
            showingOptions = true
        } label: {
            label()
        }
        .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
            CloudUploadOptionsPopover(suggestedTitle: suggestedTitle, encryptionUnavailable: encryptionUnavailable,
                                      messageSource: messageSource, onConfirm: onUpload)
        }
    }
}
