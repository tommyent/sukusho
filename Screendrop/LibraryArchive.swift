/// Only the existing Saved mark determines the page a capture belongs to.
nonisolated enum LibraryArchive {
    static func includes(isSaved: Bool, inSavedPage: Bool) -> Bool {
        isSaved == inSavedPage
    }
}
