import AppKit

/// Before a Bug report take's log goes into its Agent Prompt: what was captured, and the choice.
@MainActor
enum RecordingAppLogsReview {
    /// True when the user includes the log.
    static func confirm(_ logs: RecordingAppLogs) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add \(logs.appName)'s log to the bug report?"
        alert.informativeText = logs.countsLine
            + " Logs can hold personal data, such as names, file paths or what you typed. They stay on this Mac unless you share the bug report."
        alert.addButton(withTitle: "Include Log")
        alert.addButton(withTitle: "Leave Out")
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = CGRect(x: 0, y: 0, width: 560, height: 220)
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            // In the VM the alert opened partway down the log, then with the first line half hidden;
            // whole layout, a top inset and a scroll once it shows open it on the header.
            text.layoutManager?.allowsNonContiguousLayout = false
            text.textContainerInset = NSSize(width: 2, height: 10)
            text.string = logs.text(timeline: nil)
        }
        alert.accessoryView = scroll
        RunLoop.main.perform(inModes: [.modalPanel]) {
            (scroll.documentView as? NSTextView)?.scrollToBeginningOfDocument(nil)
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Reads the take's log after Stop and keeps it in the package if the user includes it.
    /// An empty log (nothing logged, or unreadable) is kept without asking, so the prompt can say so.
    static func collect(for session: RecordingSession) async {
        guard let span = session.loadCaptureManifest()?.appLogSpan else { return }
        let logs = await RecordingAppLogs.collect(span)
        guard logs.entries.isEmpty || confirm(logs) else { return }
        do { try logs.write(toPackage: session.directoryURL) }
        catch { NSLog("[Screendrop] Could not save the take's app log: %@", error.localizedDescription) }
    }
}
