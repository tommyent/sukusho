/// Where a Save comes from, which decides whether it waits for a busy Library (Astra M3).
nonisolated enum LibrarySaveRequest: Sendable {
    /// The user's Save or Remove from Saved, from a menu or the inspector: ignored while another Library operation
    /// runs, as every other command is.
    case command
    /// A share finishing, perhaps long after it was started: it records what already happened, so it applies
    /// whatever the Library is busy with, instead of being dropped.
    case completion

    func applies(whileBusy isBusy: Bool) -> Bool {
        self == .completion || !isBusy
    }
}
