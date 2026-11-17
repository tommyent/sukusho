//
//  ClipboardEditCopies.swift
//  Screendrop
//

import Foundation

/// The copies of clipboard images opened in the editor, one folder per clip. A copy lives as long as an editor has it
/// open: closing that editor, or its first save moving it to the new capture, deletes it, and so do Delete, Delete
/// History and the retention sweep for every copy no editor has open (Astra R5-2, 2026-11-17: they stayed in the
/// temporary folder after their clips were deleted).
nonisolated struct ClipboardEditCopies {
    let folder: URL

    /// A fresh copy of `image` named `name`, unless an editor has this clip's copy open: then that one, so two
    /// editors of one clip share it. A leftover is replaced, since the clip may hold a newer version by now.
    func copy(of image: URL, named name: String, entryID: String, inUse: (URL) -> Bool) -> URL? {
        let entryFolder = folder.appendingPathComponent(entryID, isDirectory: true)
        let copy = entryFolder.appendingPathComponent(name)
        if inUse(entryFolder), FileManager.default.fileExists(atPath: copy.path) { return copy }
        do {
            try? FileManager.default.removeItem(at: entryFolder)
            try FileManager.default.createDirectory(at: entryFolder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: image, to: copy)
            return copy
        } catch {
            return nil
        }
    }

    /// Deletes every clip's copy that `inUse` doesn't claim.
    func clear(inUse: (URL) -> Bool) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where !inUse(entry) {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
