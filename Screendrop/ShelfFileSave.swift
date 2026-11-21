//
//  ShelfFileSave.swift
//  Screendrop
//
//  How the shake shelf's Save writes an optimized file next to the file it came
//  from, or in its place. A file on the shelf can be changed in another app
//  before Save is pressed, so a result is written only while its source is
//  still the file the optimizer read, and an original leaves its place only
//  once its replacement is safely on the same volume.
//

import Foundation

nonisolated enum ShelfFileSave {
    enum KeptOriginal: Equatable, Sendable {
        /// The new file is in place, but moving the original (or its retained backup) to Trash failed.
        case trashFailed(URL)
        /// A cross-format Replace saved the new file, then found the original had changed before Trash and left it alone.
        case sourceChanged(URL)
    }

    enum Outcome: Equatable, Sendable {
        case saved(URL, keptOriginal: KeptOriginal? = nil)
        /// The source isn't the file that was optimized any more; nothing was written or moved.
        case changed
        /// `recoveryURL`: if Foundation relocated the original (`NSFileOriginalItemLocationKey`) before
        /// failing, carry that URL structurally so the user can recover it in Finder.
        case failed(String, recoveryURL: URL? = nil)
    }

    struct Summary: Equatable, Sendable {
        let title: String
        let detail: String
        let isFailure: Bool
        let saved: [URL]
        /// Structured locations of originals or retained backups the user may need to recover; presented in a
        /// persistent alert with Reveal in Finder rather than a transient toast.
        let recoveryURLs: [URL]
    }

    typealias ReplaceItem = (_ original: URL, _ replacement: URL, _ backupName: String) throws -> URL?

    private static func defaultReplaceItem(_ original: URL, _ replacement: URL, _ backupName: String) throws -> URL? {
        try FileManager.default.replaceItemAt(original, withItemAt: replacement, backupItemName: backupName,
                                              options: [.withoutDeletingBackupItem])
    }

    /// Extracts `NSFileOriginalItemLocationKey` from an error thrown by `FileManager.replaceItemAt`, walking
    /// underlying errors if needed.
    static func relocatedOriginal(from error: Error) -> URL? {
        var current: NSError? = error as NSError
        while let nsError = current {
            if let url = nsError.userInfo[NSFileOriginalItemLocationKey] as? URL { return url }
            if let path = nsError.userInfo[NSFileOriginalItemLocationKey] as? String { return URL(fileURLWithPath: path) }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    /// Writes `result` beside `original` ("name optimized.png", or "name.webp" for another format), in
    /// `destinationFolder` when one was chosen, or with `replacing` in `original`'s place. `identity` is
    /// the contents the result was made from (`ImageOptimizationResult.source`), and `outputIdentity` is
    /// the encoder's verified output (`ImageOptimizationResult.output`): the original must still hold
    /// `identity` and the staged copy must match `outputIdentity` before the source is touched. `retire`
    /// takes the original out of the way and says where it went: the Trash, outside tests.
    static func save(_ result: URL, of original: URL, identity: FileIdentity?,
                     outputIdentity: FileIdentity?, replacing: Bool,
                     in destinationFolder: URL? = nil,
                     beforeInstall: (URL) throws -> Void = { _ in },
                     beforeRetire: (URL) throws -> Void = { _ in },
                     replaceItem: ReplaceItem = defaultReplaceItem,
                     retire: (URL) throws -> URL = moveToTrash) -> Outcome {
        guard let identity, identity == FileIdentity(original) else { return .changed }
        guard let outputIdentity else { return .failed("The optimized file couldn't be verified.") }
        let files = FileManager.default
        let folder = replacing ? original.deletingLastPathComponent() : (destinationFolder ?? original.deletingLastPathComponent())
        let base = original.deletingPathExtension().lastPathComponent
        let sameFormat = result.pathExtension.lowercased() == original.pathExtension.lowercased()

        // The whole new file first, on the destination's own volume: after this, putting it in place is a rename.
        let staging = folder.appendingPathComponent(".sukusho-save-\(UUID().uuidString)", isDirectory: true)
        let staged = staging.appendingPathComponent(result.lastPathComponent)
        defer { try? files.removeItem(at: staging) }
        do {
            try files.createDirectory(at: staging, withIntermediateDirectories: false)
            try files.copyItem(at: result, to: staged)
            guard let written = FileIdentity(staged), written == outputIdentity else {
                return .failed("The file couldn't be written completely.")
            }

            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinatorError: NSError?
            var coordinatedOutcome: Outcome?

            if replacing {
                let options: NSFileCoordinator.WritingOptions = sameFormat ? .forReplacing : .forDeleting
                coordinator.coordinate(writingItemAt: original, options: options, error: &coordinatorError) { coordinatedOriginal in
                    // Check the source fingerprint inside the coordinated write accessor so check and mutation stay together.
                    guard identity == FileIdentity(coordinatedOriginal) else {
                        coordinatedOutcome = .changed
                        return
                    }
                    let targetFolder = coordinatedOriginal.deletingLastPathComponent()
                    let targetBase = coordinatedOriginal.deletingPathExtension().lastPathComponent
                    do {
                        if sameFormat {
                            let backupName = Self.backupFileName(extension: coordinatedOriginal.pathExtension)
                            let backup = targetFolder.appendingPathComponent(backupName)
                            // Install atomically with a retained backup so the original never leaves its folder before
                            // the replacement is in place; only then move the backup to the Trash.
                            do {
                                _ = try replaceItem(coordinatedOriginal, staged, backupName)
                            } catch {
                                coordinatedOutcome = .failed(error.localizedDescription,
                                                             recoveryURL: relocatedOriginal(from: error))
                                return
                            }
                            do {
                                _ = try retire(backup)
                                coordinatedOutcome = .saved(coordinatedOriginal)
                            } catch {
                                coordinatedOutcome = .saved(coordinatedOriginal, keptOriginal: .trashFailed(backup))
                            }
                            return
                        }

                        let name = "\(targetBase).\(result.pathExtension)"
                        let destination = try installUniquely(from: staged, named: name, in: targetFolder, beforeInstall: beforeInstall)
                        try beforeRetire(destination)
                        // Re-check before Trash: if the source changed meanwhile, leave the newer original alone
                        // and keep the newly saved output as a separate file.
                        guard identity == FileIdentity(coordinatedOriginal) else {
                            coordinatedOutcome = .saved(destination, keptOriginal: .sourceChanged(coordinatedOriginal))
                            return
                        }
                        do {
                            _ = try retire(coordinatedOriginal)
                            coordinatedOutcome = .saved(destination)
                        } catch {
                            coordinatedOutcome = .saved(destination, keptOriginal: .trashFailed(coordinatedOriginal))
                        }
                    } catch {
                        coordinatedOutcome = .failed(error.localizedDescription)
                    }
                }
            } else {
                coordinator.coordinate(readingItemAt: original, options: .withoutChanges, error: &coordinatorError) { coordinatedOriginal in
                    guard identity == FileIdentity(coordinatedOriginal) else {
                        coordinatedOutcome = .changed
                        return
                    }
                    let name = (!sameFormat ? base : "\(base) optimized") + "." + result.pathExtension
                    do {
                        let destination = try installUniquely(from: staged, named: name, in: folder, beforeInstall: beforeInstall)
                        coordinatedOutcome = .saved(destination)
                    } catch {
                        coordinatedOutcome = .failed(error.localizedDescription)
                    }
                }
            }

            if let coordinatorError { return .failed(coordinatorError.localizedDescription) }
            return coordinatedOutcome ?? .failed("The file couldn't be coordinated.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Builds the user-facing summary for a batch of Save/Replace outcomes, preserving structured recovery
    /// URLs from both failed Trash moves and `NSFileOriginalItemLocationKey` errors across the batch.
    static func summary(of outcomes: [Outcome], replacing: Bool, folder: URL? = nil) -> Summary {
        var saved: [URL] = []
        var changed = 0
        var recoveryURLs: [URL] = []
        var seenRecovery: Set<String> = []
        var failures: [String] = []

        func addRecovery(_ url: URL) {
            let key = url.standardizedFileURL.path
            if seenRecovery.insert(key).inserted { recoveryURLs.append(url) }
        }

        for outcome in outcomes {
            switch outcome {
            case .saved(let file, let keptOriginal):
                saved.append(file)
                switch keptOriginal {
                case .trashFailed(let url): addRecovery(url)
                case .sourceChanged: changed += 1
                case nil: break
                }
            case .changed: changed += 1
            case .failed(let reason, let recoveryURL):
                if !failures.contains(reason) { failures.append(reason) }
                if let recoveryURL { addRecovery(recoveryURL) }
            }
        }
        var notes: [String] = []
        if !recoveryURLs.isEmpty {
            let heading = recoveryURLs.count == 1 ? "Original kept at:" : "Originals kept at:"
            notes.append(([heading] + recoveryURLs.map(\.path)).joined(separator: "\n"))
        }
        if changed > 0 {
            notes.append(changed == 1
                ? "1 file changed since it was optimized and was left alone."
                : "\(changed) files changed since they were optimized and were left alone.")
        }
        if !failures.isEmpty {
            return Summary(title: "Couldn’t Save",
                           detail: ([failures[0]] + notes).joined(separator: "\n\n"),
                           isFailure: true, saved: saved, recoveryURLs: recoveryURLs)
        }
        if saved.isEmpty {
            return Summary(title: "Nothing to Save",
                           detail: notes.first ?? "No file came out smaller.",
                           isFailure: false, saved: [], recoveryURLs: recoveryURLs)
        }
        let destination = replacing ? "The originals are in the Trash."
            : folder.map { "In \($0.lastPathComponent)" } ?? "Beside the originals"
        return Summary(title: saved.count == 1 ? "Saved" : "\(saved.count) Files Saved",
                       detail: notes.isEmpty ? destination : notes.joined(separator: "\n\n"),
                       isFailure: false, saved: saved, recoveryURLs: recoveryURLs)
    }

    /// Short, fixed-prefix + full-UUID backup name independent of the original stem length so 240+ byte
    /// filenames never exceed the 255-byte filesystem component limit during `replaceItemAt`.
    static func backupFileName(extension ext: String) -> String {
        let stem = "sukusho-original-\(UUID().uuidString)"
        guard !ext.isEmpty, ext.utf8.count <= 32 else { return stem }
        return "\(stem).\(ext)"
    }

    static func moveToTrash(_ url: URL) throws -> URL {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return (trashed as URL?) ?? url
    }

    /// Installs `staged` in `folder` as "name.webp", "name 2.webp", … using exclusive rename so a late
    /// collision picks the next free name instead of failing or overwriting.
    private static func installUniquely(from staged: URL, named name: String, in folder: URL,
                                        beforeInstall: (URL) throws -> Void) throws -> URL {
        let first = folder.appendingPathComponent(name)
        let base = first.deletingPathExtension().lastPathComponent
        let ext = first.pathExtension
        func candidate(_ number: Int) -> URL {
            guard number > 1 else { return first }
            let numbered = folder.appendingPathComponent("\(base) \(number)")
            return ext.isEmpty ? numbered : numbered.appendingPathExtension(ext)
        }
        for number in 1...10_000 {
            let destination = candidate(number)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            try beforeInstall(destination)
            do {
                try ScreenshotFileActions.installExport(from: staged, at: destination, replacingExisting: false)
                return destination
            } catch let error as POSIXError where error.code == .EEXIST {
                continue
            }
        }
        let fallback = folder.appendingPathComponent("\(base) \(UUID().uuidString)")
        let destination = ext.isEmpty ? fallback : fallback.appendingPathExtension(ext)
        try ScreenshotFileActions.installExport(from: staged, at: destination, replacingExisting: false)
        return destination
    }
}
