//
//  EditorSaveIdentity.swift
//  Screendrop
//

import Foundation

/// Which file an editor reads and writes after a save. A file from outside History (a clipboard image's copy) becomes
/// a History capture on its first saved edit, and from then on the editor works on that capture: its sidecar, base and
/// original. Keeping the outside path made "remove every shape and save" find no saved document and leave the capture
/// annotated (Astra R5-1, 2026-11-17).
nonisolated enum EditorSaveIdentity {
    static func afterSave(editing current: URL, savedTo result: URL, isHistory: (URL) -> Bool) -> URL {
        !isHistory(current) && isHistory(result) ? result : current
    }
}
