//
//  ScreenshotFileNaming.swift
//  Screendrop
//

import Foundation

/// Names for captures where the user sees them, in the user's pattern:
/// `screenshot_2026-10-09_055530.png` and `recording_2026-10-09_055530.mov`.
/// A same-second clash becomes `_2`, `_3` and so on; an existing file is
/// never overwritten. Files already saved keep their names, and internal
/// packages and fallbacks (`Sukusho_<uuid>` and so on) keep theirs.
enum ScreenshotFileNaming {
    static func fileName(date: Date = Date(), extension pathExtension: String = "png") -> String {
        "screenshot_\(timestamp(date)).\(pathExtension)"
    }

    static func recordingFileName(date: Date, extension pathExtension: String) -> String {
        "recording_\(timestamp(date)).\(pathExtension)"
    }

    /// `fileName` in `directory`, or the first free of `name_2`, `name_3`…
    static func uniqueURL(for fileName: String, in directory: URL, fileManager: FileManager = .default) -> URL {
        let first = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: first.path) else { return first }

        let baseName = first.deletingPathExtension().lastPathComponent
        let pathExtension = first.pathExtension
        func named(_ suffix: String) -> URL {
            let name = baseName + "_" + suffix
            return directory.appendingPathComponent(pathExtension.isEmpty ? name : "\(name).\(pathExtension)")
        }
        for index in 2...10_000 {
            let candidate = named(String(index))
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return named(UUID().uuidString)
    }

    static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    /// Fixed, whatever the user's locale and calendar: a Buddhist or 12-hour
    /// setting must not change a file name. Local wall-clock time.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }()
}

/// The names and extensions Sukusho gives the files it makes, and those of
/// Screendrop, the app it was forked from, which it still reads. Files
/// already on disk keep their names.
nonisolated enum SukushoFileNames {
    /// Starts the name of every package and working file: `Sukusho_…`.
    static let prefix = "Sukusho"
    static let legacyPrefix = "Screendrop"

    static let recordingExtension = "sukushorec"
    static let legacyRecordingExtension = "screendroprec"
    static let editDocumentExtension = "sukusho"
    static let legacyEditDocumentExtension = "screendrop"
    static let presetExtension = "sukushopreset"
    static let legacyPresetExtension = "screendroppreset"

    static func isRecordingExtension(_ pathExtension: String) -> Bool {
        pathExtension == recordingExtension || pathExtension == legacyRecordingExtension
    }

    /// A new recording package's name without its extension:
    /// `Sukusho_2026-11-10-14-03-22_9A5457`.
    static func recordingName(date: Date = Date(), id: String = String(UUID().uuidString.prefix(6))) -> String {
        "\(prefix)_\(recordingDateFormatter().string(from: date))_\(id)"
    }

    /// When a package named by `recordingName`, under either prefix, was recorded.
    static func recordingDate(inName name: String) -> Date? {
        let parts = name.split(separator: "_")
        guard parts.count >= 2, parts[0] == prefix || parts[0] == legacyPrefix else { return nil }
        return recordingDateFormatter().date(from: String(parts[1]))
    }

    /// A screenshot's editable sidecar: `<image>.sukusho`, or the
    /// `<image>.screendrop` an older capture already has, which stays in use.
    static func editDocumentURL(for displayURL: URL) -> URL {
        let current = displayURL.appendingPathExtension(editDocumentExtension)
        let legacy = displayURL.appendingPathExtension(legacyEditDocumentExtension)
        let files = FileManager.default
        return !files.fileExists(atPath: current.path) && files.fileExists(atPath: legacy.path) ? legacy : current
    }

    private static func recordingDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}
