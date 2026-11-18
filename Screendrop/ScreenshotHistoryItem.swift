import Foundation

struct ScreenshotHistoryItem: Identifiable, Codable, Equatable, SavedMarkRow {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var fileName: String
    var pixelWidth: Int
    var pixelHeight: Int
    var kind: PreviewMediaKind
    var duration: Double?
    var cloudURL: String?
    var cloudRedactions: [RecordingRedaction]?
    /// Whether this screenshot has an editable annotation sidecar document.
    var hasEdits: Bool
    /// Absolute path to the non-destructive recording package, when this video
    /// belongs to the new Studio workflow. Older video items remain bare files.
    var recordingSessionPath: String?
    /// A Library title, kept separate from the file name and editable sidecars.
    var displayName: String?
    /// Library tags. Screendrop's own, not Finder tags.
    var tags: [String] = []
    /// The app and window it was taken from. Nil for older rows, and when
    /// no window could be named. Stays on this Mac.
    var source: CaptureSource?
    /// When it was saved (★) to Library › Saved, by the Move to Saved command. Kept in
    /// `CaptureSavedMarks`' file, not in history.json, which older builds rewrite without it; read from a row only to
    /// move it there.
    var librarySavedAt: Date?

    /// Every key but `librarySavedAt`, so history.json no longer carries it.
    enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, fileName, pixelWidth, pixelHeight, kind, duration, cloudURL, cloudRedactions,
             hasEdits, recordingSessionPath, displayName, tags, source
    }

    private enum LegacyKeys: String, CodingKey { case librarySavedAt }

    var isVideo: Bool { kind == .video }

    // Backward-compatible decoding: existing history.json entries have no
    // `kind` or `duration` fields, so they default to .image / nil.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        fileName = try container.decode(String.self, forKey: .fileName)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        kind = try container.decodeIfPresent(PreviewMediaKind.self, forKey: .kind) ?? .image
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        cloudURL = try container.decodeIfPresent(String.self, forKey: .cloudURL)
        cloudRedactions = try container.decodeIfPresent([RecordingRedaction].self, forKey: .cloudRedactions)
        hasEdits = try container.decodeIfPresent(Bool.self, forKey: .hasEdits) ?? false
        // Rows imported from Screendrop point at its folder; use this app's copy.
        recordingSessionPath = try container.decodeIfPresent(String.self, forKey: .recordingSessionPath)
            .map(ScreendropStorage.remapLegacyPath)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        source = try container.decodeIfPresent(CaptureSource.self, forKey: .source)
        librarySavedAt = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Date.self, forKey: .librarySavedAt)
    }

    init(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        fileName: String,
        pixelWidth: Int,
        pixelHeight: Int,
        kind: PreviewMediaKind = .image,
        duration: Double? = nil,
        cloudURL: String? = nil,
        hasEdits: Bool = false,
        recordingSessionPath: String? = nil,
        displayName: String? = nil,
        source: CaptureSource? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.fileName = fileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.kind = kind
        self.duration = duration
        self.cloudURL = cloudURL
        self.hasEdits = hasEdits
        self.recordingSessionPath = recordingSessionPath
        self.displayName = displayName
        self.source = source
    }

    mutating func rename(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = trimmed.isEmpty ? nil : trimmed
        updatedAt = .now
    }

    mutating func setTag(_ tag: String, applied: Bool) {
        tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        if applied { tags.append(tag) }
    }

    mutating func setLibraryCloudURL(_ url: String?) {
        if cloudURL != url { cloudRedactions = nil }
        cloudURL = url
        updatedAt = .now
    }

    mutating func recordCloudUpload(url: String, redactions: [RecordingRedaction]?) {
        cloudURL = url
        cloudRedactions = redactions
        updatedAt = .now
    }
}
