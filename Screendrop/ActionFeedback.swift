//
//  ActionFeedback.swift
//  Screendrop
//
//  A brief sign that an action worked when nothing on screen shows it, such
//  as a copy. Every such button shares this state and look: an icon turns
//  into a green checkmark, a text label reads its message, and the Library's
//  status bar shows its menu and keyboard actions' messages.
//

import SwiftUI

/// Shows `message` for a moment after each `show`, and tells VoiceOver. Showing again
/// restarts the moment.
@Observable
final class ActionFeedback {
    /// Long enough to see a checkmark, short enough to click again.
    static let iconDuration: Duration = .seconds(1.5)
    /// Words take longer to read, as the Capture Text toast allows.
    static let textDuration: Duration = .seconds(2.5)

    private(set) var message: String?
    var isShowing: Bool { message != nil }

    @ObservationIgnored private let duration: Duration
    @ObservationIgnored private let announce: (String) -> Void
    @ObservationIgnored private let sleep: (Duration) async -> Void
    @ObservationIgnored private var shows = 0

    init(duration: Duration = ActionFeedback.iconDuration,
         announce: @escaping (String) -> Void = { AccessibilityNotification.Announcement($0).post() },
         sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.duration = duration
        self.announce = announce
        self.sleep = sleep
    }

    func show(_ message: String = "Copied") {
        shows += 1
        let current = shows
        self.message = message
        announce(message)
        Task {
            await sleep(duration)
            if shows == current { self.message = nil }
        }
    }

    static func linksCopied(_ count: Int) -> String {
        count == 1 ? "Link Copied" : "\(count) Links Copied"
    }
}

extension View {
    /// While `feedback` shows, help and VoiceOver read its message instead of `label` (and
    /// `help`, when the tooltip says more), and the swapped symbol or text changes with a
    /// replace effect, or a cross-fade under Reduce Motion.
    /// A shared button style can pass nil for its buttons that have nothing to confirm.
    func actionFeedback(_ feedback: ActionFeedback?, label: String, help: String? = nil) -> some View {
        modifier(ActionFeedbackStyle(feedback: feedback, label: label, help: help))
    }
}

private struct ActionFeedbackStyle: ViewModifier {
    let feedback: ActionFeedback?
    let label: String
    let help: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            .animation(.easeOut(duration: 0.15), value: feedback?.isShowing)
            .help(feedback?.message ?? help ?? label)
            .accessibilityLabel(feedback?.message ?? label)
    }
}
