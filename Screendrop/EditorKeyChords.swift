//
//  EditorKeyChords.swift
//  Screendrop
//

import AppKit

/// The editor's key chords that need exact modifiers, apart from the event monitor so they can be
/// tested.
nonisolated enum EditorKeyChords {
    /// ⌘S, and nothing more: ⌃⌘S is View › Show Sidebar, ⇧⌘S Save As (Astra E3).
    static func isSave(_ flags: NSEvent.ModifierFlags, characters: String?) -> Bool {
        flags.contains(.command)
            && flags.intersection([.shift, .option, .control]).isEmpty
            && characters?.lowercased() == "s"
    }
}
