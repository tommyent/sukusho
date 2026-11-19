//
//  ScreendropPreferences.swift
//  Screendrop
//
//  Created by Codex on 26/04/26.
//

import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

enum ScreendropPreferences {
    static let autoSaveKey = "autoSaveScreenshots"
    static let saveButtonUsesFolderKey = "saveButtonUsesConfiguredFolder"
    static let autoCopyKey = "autoCopyScreenshotsToClipboard"
    static let autoCompressKey = "autoCompressScreenshots"
    static let copyTIFFKey = "copyScreenshotsAsTIFF"
    static let exportFormatKey = "exportFormat"
    static let compressionQualityKey = "compressionQuality"
    static let videoExportDirectoryPathKey = "videoExportDirectoryPath"
    static let exportDirectoryPathKey = "exportDirectoryPath"
    static let fullscreenHotkeyKey = "captureHotkey.fullscreen"
    static let windowHotkeyKey = "captureHotkey.window"
    static let areaHotkeyKey = "captureHotkey.area"
    static let textCaptureHotkeyKey = "captureHotkey.textCapture"
    static let scrollingCaptureHotkeyKey = "captureHotkey.scrollingCapture"
    static let libraryHotkeyKey = "captureHotkey.library"
    static let clipboardHistoryHotkeyKey = "captureHotkey.clipboardHistory"
    static let screenRecordingHotkeyKey = "captureHotkey.screenRecording"
    static let playSoundsKey = "playSounds"
    static let showMenuBarIconKey = "showMenuBarIcon"
    static let includeAppWindowsInCapturesKey = "includeAppWindowsInCaptures"
    static let captureWindowShadowKey = "captureWindowShadow"
    /// Capture Text keeps the screen's line breaks instead of joining wrapped lines into paragraphs. Off by default.
    static let captureTextKeepsLineBreaksKey = "captureTextKeepsLineBreaks"
    static let captureDelaySecondsKey = "captureDelaySeconds"
    /// Hidden: `defaults write <bundle id> areaCaptureUsesSystemPicker -bool YES`
    /// brings back the system crosshair for the Area screenshot and Capture Text.
    static let areaCaptureUsesSystemPickerKey = "areaCaptureUsesSystemPicker"
    static let areaPickerHintsShownKey = "areaPickerHintsShown"
    static let previewPositionKey = "previewPosition"
    static let previewAutoCloseSecondsKey = "previewAutoCloseSeconds"
    static let previewCloseAfterDraggingKey = "previewCloseAfterDragging"
    static let overlayCardLayoutKey = "overlayCardLayout"
    static let lowResolutionEditorPreviewKey = "lowResolutionEditorPreview"
    static let trimFullscreenMenuBarKey = "trimFullscreenMenuBar"
    static let recordingCameraDeviceIDKey = "recordingCameraDeviceID"
    static let recordingMicrophoneDeviceIDKey = "recordingMicrophoneDeviceID"
    static let recordingSystemAudioKey = "recordingSystemAudio"
    static let recordingCleanDesktopKey = "recordingCleanDesktop"
    static let recordingBugReportKey = "recordingBugReport"
    /// Bug report turned on Include Sukusho windows, so turning Bug report off turns it back off.
    static let recordingBugReportAddedAppWindowsKey = "recordingBugReportAddedAppWindows"
    static let recordingAppLogsKey = "recordingAppLogs"
    static let recordingStartDelaySecondsKey = "recordingStartDelaySeconds"
    static let recordingTeleprompterEnabledKey = "recordingTeleprompterEnabled"
    static let recordingTeleprompterScriptKey = "recordingTeleprompterScript"
    static let recordingTeleprompterLineCountKey = "recordingTeleprompterLineCount"
    static let revealExportInFinderKey = "revealExportInFinder"
    static let libraryReadsTextKey = "libraryReadsText"
    static let libraryUsesIntelligenceKey = "libraryUsesIntelligence"
    static let libraryInsightsIncludeExistingKey = "libraryInsightsIncludeExisting"
    private static let libraryInsightsSinceKey = "libraryInsightsSince"
    static let clipboardHistoryEnabledKey = "clipboardHistoryEnabled"
    static let clipboardRetentionDaysKey = "clipboardRetentionDays"
    static let clipboardMaxStorageMBKey = "clipboardMaxStorageMB"
    static let clipboardIgnoredAppsKey = "clipboardIgnoredApps"
    private static let clipboardDeviceIDKey = "clipboardDeviceID"
    /// Hidden: `defaults write <bundle id> ClipboardTrace -bool YES` logs each
    /// copy's types, source and sizes, never its contents, to the unified log.
    static let clipboardTraceKey = "ClipboardTrace"

    private static let defaultCompressionQuality = 0.8

    /// Clipboard history is off until the user turns it on.
    static var clipboardHistoryEnabled: Bool {
        UserDefaults.standard.bool(forKey: clipboardHistoryEnabledKey)
    }

    /// Nil keeps everything. Option A (owner, 2026-11-16): copies age out only through this setting, off by
    /// default; saved copies never do.
    static var clipboardRetention: TimeInterval? {
        let days = UserDefaults.standard.object(forKey: clipboardRetentionDaysKey) == nil
            ? 0 : UserDefaults.standard.integer(forKey: clipboardRetentionDaysKey)
        return days > 0 ? TimeInterval(days) * 86_400 : nil
    }

    /// shortcut: 2 GB is a provisional default the owner hasn't confirmed yet.
    static var clipboardMaxStorageBytes: Int64 {
        let megabytes = UserDefaults.standard.object(forKey: clipboardMaxStorageMBKey) == nil
            ? 2048 : UserDefaults.standard.integer(forKey: clipboardMaxStorageMBKey)
        return Int64(max(megabytes, 1)) * 1024 * 1024
    }

    /// Bundle IDs whose copies are never kept; edited in Settings › Clipboard.
    static var clipboardIgnoredApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: clipboardIgnoredAppsKey) ?? ClipboardCapturePolicy.defaultIgnoredApps }
        set { UserDefaults.standard.set(newValue, forKey: clipboardIgnoredAppsKey) }
    }

    /// Which Mac a clipboard entry came from, for sync later. Made once, kept.
    static var clipboardDeviceID: String {
        if let id = UserDefaults.standard.string(forKey: clipboardDeviceIDKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: clipboardDeviceIDKey)
        return id
    }

    static var autoSave: Bool {
        UserDefaults.standard.bool(forKey: autoSaveKey)
    }

    static var saveButtonUsesConfiguredFolder: Bool {
        if UserDefaults.standard.object(forKey: saveButtonUsesFolderKey) == nil {
            return autoSave
        }
        return UserDefaults.standard.bool(forKey: saveButtonUsesFolderKey)
    }
    
    static var autoCopy: Bool {
        UserDefaults.standard.bool(forKey: autoCopyKey)
    }
    
    static var autoCompress: Bool {
        UserDefaults.standard.bool(forKey: autoCompressKey)
    }

    static var copyTIFF: Bool {
        UserDefaults.standard.bool(forKey: copyTIFFKey)
    }

    static var exportFormat: ScreenshotExportFormat {
        if let rawValue = UserDefaults.standard.string(forKey: exportFormatKey),
           let format = ScreenshotExportFormat(rawValue: rawValue) {
            return format
        }

        return autoCompress ? .jpeg : .png
    }
    
    static var compressionQuality: Double {
        let value = UserDefaults.standard.object(forKey: compressionQualityKey) as? Double ?? defaultCompressionQuality
        return min(max(value, 0.1), 1)
    }
    
    static var exportDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: exportDirectoryPathKey),
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        
        return defaultExportDirectory
    }
    
    /// Where recordings and everything exported from them (movies, GIFs, audio) are saved: the Save folder the user
    /// chose, else ~/Movies/Sukusho, as images go to ~/Pictures/Sukusho (owner, 2026-11-17).
    static var videoExportDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: videoExportDirectoryPathKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let path = UserDefaults.standard.string(forKey: exportDirectoryPathKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultVideoExportDirectory
    }

    static var defaultVideoExportDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        return (movies ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies"))
            .appendingPathComponent(ScreendropStorage.directoryName, isDirectory: true)
    }

    static var defaultExportDirectory: URL {
        let picturesDirectory = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        return (picturesDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures"))
            .appendingPathComponent(ScreendropStorage.directoryName, isDirectory: true)
    }

    /// Unique ID of the camera recorded alongside the screen. Empty = camera off.
    static var recordingCameraDeviceID: String {
        get { UserDefaults.standard.string(forKey: recordingCameraDeviceIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: recordingCameraDeviceIDKey) }
    }

    /// Unique ID of the microphone captured during recordings. Empty = mic off.
    static var recordingMicrophoneDeviceID: String {
        get { UserDefaults.standard.string(forKey: recordingMicrophoneDeviceIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: recordingMicrophoneDeviceIDKey) }
    }

    /// Whether recordings include system audio. Defaults to off.
    static var recordingSystemAudio: Bool {
        get { UserDefaults.standard.bool(forKey: recordingSystemAudioKey) }
        set { UserDefaults.standard.set(newValue, forKey: recordingSystemAudioKey) }
    }

    /// Hides desktop distractions in recorded pixels only. Defaults to on.
    static var recordingCleanDesktop: Bool {
        UserDefaults.standard.object(forKey: recordingCleanDesktopKey) as? Bool ?? true
    }

    /// Records the take as a bug report for a coding agent: Stop writes its
    /// Agent Prompt instead of opening Studio. Defaults to off.
    static var recordingBugReport: Bool {
        UserDefaults.standard.bool(forKey: recordingBugReportKey)
    }

    /// A Bug report take also reads the recorded app's log. Off by default, and
    /// cleared after each take, since logs can hold personal data.
    static var recordingAppLogs: Bool {
        UserDefaults.standard.bool(forKey: recordingAppLogsKey)
    }

    /// Countdown delay (in seconds) before a recording starts. 0 means off.
    static var recordingStartDelaySeconds: Int {
        max(0, UserDefaults.standard.integer(forKey: recordingStartDelaySecondsKey))
    }

    /// Whether the notch teleprompter appears during recordings. Defaults to off.
    static var recordingTeleprompterEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: recordingTeleprompterEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: recordingTeleprompterEnabledKey) }
    }

    /// The script read from the teleprompter. Empty means nothing to show.
    static var recordingTeleprompterScript: String {
        get { UserDefaults.standard.string(forKey: recordingTeleprompterScriptKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: recordingTeleprompterScriptKey) }
    }

    static let teleprompterLineCountRange = 2...5

    /// How many script lines the teleprompter shows at once.
    static var recordingTeleprompterLineCount: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: recordingTeleprompterLineCountKey)
            guard stored != 0 else { return 3 }
            return min(max(stored, teleprompterLineCountRange.lowerBound), teleprompterLineCountRange.upperBound)
        }
        set { UserDefaults.standard.set(newValue, forKey: recordingTeleprompterLineCountKey) }
    }

    /// Whether to play the shutter sound after a screenshot. Defaults to on.
    static var playSounds: Bool {
        if UserDefaults.standard.object(forKey: playSoundsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: playSoundsKey)
    }

    /// Whether Screendrop's own windows and floating controls are visible in
    /// screenshots and screen recordings. Defaults to off for capture privacy.
    static var includeAppWindowsInCaptures: Bool {
        UserDefaults.standard.bool(forKey: includeAppWindowsInCapturesKey)
    }

    /// Whether captured windows include their drop shadow. Defaults to off
    /// (tighter, shadow-free crops).
    static var captureTextKeepsLineBreaks: Bool {
        UserDefaults.standard.bool(forKey: captureTextKeepsLineBreaksKey)
    }

    static var captureWindowShadow: Bool {
        UserDefaults.standard.bool(forKey: captureWindowShadowKey)
    }

    /// The Area screenshot and Capture Text use `screencapture -s` instead of
    /// Sukusho's own picker: no snapping and no loupe, but the system's own crosshair.
    static var areaCaptureUsesSystemPicker: Bool {
        UserDefaults.standard.bool(forKey: areaCaptureUsesSystemPickerKey)
    }

    /// Whether the picker opening now shows its line about Shift and Option:
    /// the first three times it opens, counted here, and never again.
    static func takeAreaPickerHint() -> Bool {
        let shown = UserDefaults.standard.integer(forKey: areaPickerHintsShownKey)
        guard shown < 3 else { return false }
        UserDefaults.standard.set(shown + 1, forKey: areaPickerHintsShownKey)
        return true
    }

    /// Countdown delay (in seconds) before a capture is taken. 0 means off.
    static var captureDelaySeconds: Int {
        max(0, UserDefaults.standard.integer(forKey: captureDelaySecondsKey))
    }

    /// Seconds before the preview overlay auto-dismisses. 0 means never.
    /// 10 s unless set (Fable #2: cards stayed five minutes and piled up the edge). Hovering, dragging and opening a
    /// card keep it; a user's own choice, Never (0) included, stands.
    static let previewAutoCloseDefault = 10
    static var previewAutoCloseSeconds: Int {
        guard UserDefaults.standard.object(forKey: previewAutoCloseSecondsKey) != nil else { return previewAutoCloseDefault }
        return max(0, UserDefaults.standard.integer(forKey: previewAutoCloseSecondsKey))
    }

    /// Whether dragging a preview card out dismisses it. Defaults to on.
    static var previewCloseAfterDragging: Bool {
        if UserDefaults.standard.object(forKey: previewCloseAfterDraggingKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: previewCloseAfterDraggingKey)
    }

    /// Whether the annotation editor displays a downscaled preview of the
    /// screenshot to reduce memory usage. This only affects the on-screen
    /// editing preview - exported images are always rendered at full
    /// resolution. Defaults to on.
    static var lowResolutionEditorPreview: Bool {
        if UserDefaults.standard.object(forKey: lowResolutionEditorPreviewKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: lowResolutionEditorPreviewKey)
    }
    
    /// Whether the Library reads the words in captures so search finds them.
    /// Defaults to on; off stops reading but keeps what was read.
    static var libraryReadsText: Bool {
        UserDefaults.standard.object(forKey: libraryReadsTextKey) as? Bool ?? true
    }

    /// Whether Apple Intelligence titles captures and suggests tags, where
    /// the model is available. Defaults to on.
    static var libraryUsesIntelligence: Bool {
        UserDefaults.standard.object(forKey: libraryUsesIntelligenceKey) as? Bool ?? true
    }

    /// Whether captures from before `libraryInsightsSince` get titles and
    /// suggestions too. Off until the user asks, since there can be many.
    static var libraryInsightsIncludeExisting: Bool {
        UserDefaults.standard.bool(forKey: libraryInsightsIncludeExistingKey)
    }

    /// Captures taken from this moment on are titled automatically. Fixed
    /// the first time it's read, when the model first runs.
    static var libraryInsightsSince: Date {
        let stored = UserDefaults.standard.double(forKey: libraryInsightsSinceKey)
        if stored > 0 { return Date(timeIntervalSinceReferenceDate: stored) }
        let now = Date()
        UserDefaults.standard.set(now.timeIntervalSinceReferenceDate, forKey: libraryInsightsSinceKey)
        return now
    }

    /// Whether a finished Studio export selects the file in Finder. An export
    /// is a deliberate "hand me the file" action, so this defaults to on.
    static var revealExportInFinder: Bool {
        if UserDefaults.standard.object(forKey: revealExportInFinderKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: revealExportInFinderKey)
    }

    /// Whether fullscreen captures on notched displays trim the empty black
    /// menu-bar strip at the top. The strip is only removed when it's solid
    /// black (menu bar hidden); a revealed menu bar is preserved. Defaults to on.
    static var trimFullscreenMenuBar: Bool {
        if UserDefaults.standard.object(forKey: trimFullscreenMenuBarKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: trimFullscreenMenuBarKey)
    }
}

enum PreviewOverlayPosition: String, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: "Bottom left"
        case .right: "Bottom right"
        }
    }
}

enum ScreenshotExportFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg
    case heic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png:
            "PNG"
        case .jpeg:
            "JPEG"
        case .heic:
            "HEIC"
        }
    }

    var fileExtension: String {
        switch self {
        case .png:
            "png"
        case .jpeg:
            "jpg"
        case .heic:
            "heic"
        }
    }

    var contentType: UTType {
        switch self {
        case .png:
            .png
        case .jpeg:
            .jpeg
        case .heic:
            .heic
        }
    }

    var usesLossyQuality: Bool {
        self != .png
    }
}

enum ScreenshotFileActions {
    @discardableResult
    static func copyPNGToClipboard(from url: URL, turn: OptimizedImageCopy.Turn? = nil) async throws -> Bool {
        try await copyImageToClipboard(from: url, dataType: .png, turn: turn)
    }

    /// The image at `url` copied as it is (Copy Original, or with optimizing off). It takes its turn before it
    /// reads the file, as the optimized copy does: false, with nothing written, when something newer was copied
    /// meanwhile, here or in another app, a repeat of the clipboard's image included (Astra, round 4). `turn` is
    /// the one the route took when it was asked to copy, if it did (`OptimizedImageCopy.takeTurn`).
    @discardableResult
    static func copyImageToClipboard(from url: URL, dataType: NSPasteboard.PasteboardType,
                                     to pasteboard: NSPasteboard = .general, turn: OptimizedImageCopy.Turn? = nil) async throws -> Bool {
        let (outcome, _) = try await OptimizedImageCopy.shared.copyNow(to: pasteboard, turn: turn, first: {
            .init(item: try await ScreenshotClipboardImage.item(from: url, dataType: dataType, includeTIFF: ScreendropPreferences.copyTIFF),
                  key: UUID())
        }, smaller: { nil })
        return outcome == .written
    }
    
    private static var reservedSaveURLs: Set<URL> = []

    @discardableResult
    static func saveToDefaultLocation(from url: URL) throws -> URL {
        let destinationURL = try prepareDefaultSaveURL(for: url, reserving: true)
        defer { releaseReservedSaveURL(destinationURL) }
        try save(from: url, to: destinationURL)
        return destinationURL
    }

    static func prepareDefaultSaveURL(for url: URL, reserving: Bool = false) throws -> URL {
        let destinationDirectory = ScreendropPreferences.exportDirectory
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let destination = ScreenshotFileNaming.uniqueURL(
            for: exportFileName(for: url),
            in: destinationDirectory,
            reserved: reservedSaveURLs
        )
        if reserving {
            reservedSaveURLs.insert(destination.standardizedFileURL)
        }
        return destination
    }

    static func releaseReservedSaveURL(_ url: URL) {
        reservedSaveURLs.remove(url.standardizedFileURL)
    }

    static func save(from sourceURL: URL, to destinationURL: URL) throws {
        let format = ScreendropPreferences.exportFormat
        try save(
            from: sourceURL,
            to: destinationURL,
            isPNG: format == .png,
            contentTypeIdentifier: format.contentType.identifier,
            compressionQuality: ScreendropPreferences.compressionQuality
        )
    }

    nonisolated static func save(
        from sourceURL: URL,
        to destinationURL: URL,
        isPNG: Bool,
        contentTypeIdentifier: String,
        compressionQuality: Double
    ) throws {
        let stagingURL = try stagingURL(from: sourceURL, to: destinationURL)
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        if isPNG {
            try FileManager.default.copyItem(at: sourceURL, to: stagingURL)
        } else {
            try exportImage(from: sourceURL, to: stagingURL, contentTypeIdentifier: contentTypeIdentifier, compressionQuality: compressionQuality)
        }
        try installExport(from: stagingURL, at: destinationURL)
    }
    /// Updates an already-associated export without changing its file format.
    /// The replacement is staged beside the destination and atomically swapped
    /// in only after encoding succeeds, so the last good export is never deleted
    /// first. Pixel dimensions are preserved; PNG-to-PNG updates copy bytes.
    static func replaceExistingExport(from sourceURL: URL, at destinationURL: URL) throws {
        guard let destinationType = exportContentType(for: destinationURL) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let stagingURL = try stagingURL(from: sourceURL, to: destinationURL)
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        if destinationType == .png, actualImageContentType(at: sourceURL) == .png {
            try FileManager.default.copyItem(at: sourceURL, to: stagingURL)
        } else {
            try exportImage(from: sourceURL, to: stagingURL, contentType: destinationType)
        }

        try installExport(from: stagingURL, at: destinationURL)
    }

    /// Shared by image, annotated-image and video saves. Keep the original source
    /// and destination intact until a complete sibling file is ready to install.
    nonisolated static func stagingURL(from sourceURL: URL, to destinationURL: URL) throws -> URL {
        let source = ((try? URL(resolvingAliasFileAt: sourceURL, options: [.withoutUI, .withoutMounting])) ?? sourceURL)
            .resolvingSymlinksInPath().standardizedFileURL
        let destination = ((try? URL(resolvingAliasFileAt: destinationURL, options: [.withoutUI, .withoutMounting])) ?? destinationURL)
            .resolvingSymlinksInPath().standardizedFileURL
        let sameFile: Bool
        if let sourceID = try? source.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
           let destinationID = try? destination.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier {
            sameFile = sourceID.isEqual(destinationID)
        } else {
            sameFile = false
        }
        guard source != destination, !sameFile else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [
                NSLocalizedDescriptionKey: "Choose a different destination to keep the original capture."
            ])
        }
        return destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(SukushoFileNames.prefix)-\(UUID().uuidString)")
            .appendingPathExtension(destinationURL.pathExtension)
    }

    nonisolated static func installExport(from stagingURL: URL, at destinationURL: URL, replacingExisting: Bool = true) throws {
        let result = replacingExisting
            ? rename(stagingURL.path, destinationURL.path)
            : renamex_np(stagingURL.path, destinationURL.path, UInt32(RENAME_EXCL))
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    
    static func exportFileName(for sourceURL: URL) -> String {
        return sourceURL
            .deletingPathExtension()
            .appendingPathExtension(ScreendropPreferences.exportFormat.fileExtension)
            .lastPathComponent
    }
    
    static var exportContentType: UTType {
        ScreendropPreferences.exportFormat.contentType
    }
    
    private static func exportImage(from sourceURL: URL, to destinationURL: URL, contentType: UTType) throws {
        try exportImage(
            from: sourceURL,
            to: destinationURL,
            contentTypeIdentifier: contentType.identifier,
            compressionQuality: ScreendropPreferences.compressionQuality
        )
    }

    nonisolated private static func exportImage(
        from sourceURL: URL,
        to destinationURL: URL,
        contentTypeIdentifier: String,
        compressionQuality: Double
    ) throws {
        guard let source = CGImageSourceCreateWithURL(
            sourceURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            contentTypeIdentifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let options: [CFString: Any] = contentTypeIdentifier == "public.png" ? [:] : [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]

        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
    private static func exportContentType(for url: URL) -> UTType? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .png) { return .png }
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .heic) { return .heic }
        return nil
    }

    private static func actualImageContentType(at url: URL) -> UTType? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), let identifier = CGImageSourceGetType(source) else {
            return nil
        }

        guard let type = UTType(identifier as String) else { return nil }
        if type.conforms(to: .png) { return .png }
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .heic) { return .heic }
        return type
    }
}
