//
//  RecordingStudioModel.swift
//  Screendrop
//
//  View-model for the recording studio: loads a recording session (screen
//  movie + optional camera movie + pointer-capture sidecar), owns the style
//  settings and zoom cues, and keeps the screen and camera players in
//  sync. Layout math lives in RecordingStudioLayout so the live preview and
//  the exporter compose frames identically.
//

import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Observation
import Translation
import UniformTypeIdentifiers

enum RecordingTranscriptionState: Equatable {
    case idle
    case transcribing
    case failed(String)

    var isTranscribing: Bool {
        self == .transcribing
    }
}

enum RecordingStudioExportState: Equatable {
    case idle
    case exporting(progress: Double)
    case finished(URL)
    case failed(String)

    var isExporting: Bool {
        if case .exporting = self { return true }
        return false
    }
}

/// Share-to-cloud pipeline: render the current edits, upload, copy link.
enum RecordingStudioShareState: Equatable {
    case idle
    case rendering(progress: Double)
    case uploading
    case finished(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .rendering, .uploading: true
        default: false
        }
    }
}

enum RecordingOverlayImportMode: Equatable, Sendable {
    /// Copies the source `.sukushorec`'s raw `screen.mov` directly (no double-framing).
    case raw
    /// Renders the source `.sukushorec` with its zooms, camera, and overlays baked in.
    case finished
}

struct PendingRecordingOverlayImport: Identifiable, Equatable {
    let id = UUID()
    let urls: [URL]
    let editorTime: TimeInterval
    let recordingNames: [String]
    let canImportFinished: Bool
}

@MainActor
@Observable
final class RecordingStudioModel {
    let sessionURL: URL
    private(set) var session: RecordingSession?
    private(set) var manifest: CaptureManifest?
    private(set) var pointerCapture = PointerCaptureFile()
    private(set) var recordedPressTimes: [TimeInterval] = []
    private(set) var sourceDuration: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var videoSize = CGSize(width: 1920, height: 1080)
    private(set) var hasCameraVideo = false
    private(set) var hasRecordedAudio = false
    private(set) var cameraOffset: TimeInterval = 0
    private(set) var isLoaded = false
    private(set) var loadError: String?

    let screenPlayer = AVPlayer()
    let cameraPlayer = AVPlayer()
    /// Single recycled player for the `.videoOverlay` lane. Loads only near an
    /// active overlay span and clears outside spans to keep memory bounded.
    let videoOverlayPlayer = AVPlayer()

    var style = RecordingStudioStyle(background: RecordingStudioDefaults.background) {
        didSet {
            if isLoaded, oldValue.background != style.background {
                RecordingStudioDefaults.background = style.background
            }
            scheduleProjectSave()
        }
    }
    /// The style preset currently applied, so the Studio's preset bar can
    /// show its name and detect whether the user has since edited away from
    /// it. Not persisted in the project file: reapplied by content match.
    var appliedStylePresetID: RecordingStudioStylePreset.ID?
    var zoomEnabled = true {
        didSet {
            scheduleProjectSave()
            rebuildPreviewReframe()
        }
    }
    var exportSettings = VideoCompressionSettings() {
        didSet { scheduleProjectSave() }
    }
    /// Studio-side input feedback: both are reconstructed from the sidecar,
    /// so they can be toggled after the fact without touching the footage.
    var showsClickEffects = true {
        didSet { scheduleProjectSave() }
    }
    var showsKeystrokes = true {
        didSet { scheduleProjectSave() }
    }
    /// Pen strokes drawn during the take, also reconstructed from the sidecar.
    var showsInk = true {
        didSet { scheduleProjectSave() }
    }
    private(set) var hiddenInkStrokeIDs: Set<UUID> = []
    private(set) var inkTimeline = RecordingInkTimeline(strokes: [])
    var selectedInkStrokeID: UUID?
    var keystrokePlacement: RecordingKeystrokePlacement = .bottomCenter {
        didSet { scheduleProjectSave() }
    }
    var showsSubtitles = true {
        didSet { scheduleProjectSave() }
    }
    var subtitleStyle = SubtitleBarStyle() {
        didSet { scheduleProjectSave() }
    }
    /// Output aspect for Export/Share. Anything but `.original` crops the
    /// render with a virtual camera that follows the pointer and zooms;
    /// the Studio preview shows the same crop live.
    var exportAspect: ExportAspectPreset = .original {
        didSet {
            scheduleProjectSave()
            rebuildPreviewReframe()
            rebuildMultiSourceFramingIfNeeded()
        }
    }
    /// Fill crops with the follow camera; Fit shows the whole recording
    /// framed on the background.
    var exportAspectMode: ExportAspectContentMode = .fill {
        didSet {
            scheduleProjectSave()
            rebuildPreviewReframe()
            rebuildMultiSourceFramingIfNeeded()
        }
    }
    /// Non-destructive crop of the screen-video source. The Studio background,
    /// camera bubble and captions remain in canvas space around the reshaped
    /// video card.
    var videoCropRect = CropRectEditor.unit {
        didSet {
            scheduleProjectSave()
            rebuildMultiSourceFramingIfNeeded()
        }
    }
    private(set) var isCroppingVideo = false
    var workingVideoCropRect = CropRectEditor.unit
    var videoCropAspect: CropAspectRatio = .freeform
    private(set) var redactions: [RecordingRedaction] = []
    var selectedRedactionID: UUID?
    private(set) var isSelectingRedaction = false
    private(set) var isPreparingRedactionPreview = false
    private(set) var cutRedactionPreviewError: String?
    /// Transient error from a temporary redacted source-asset trim preview.
    /// Kept separate from `cutRedactionPreviewError` so releasing the trim
    /// restores the valid redacted cut cleanly without leaving the canvas blocked.
    private(set) var trimSourcePreviewError: String?
    var redactionPreviewError: String? {
        trimSourcePreviewError ?? cutRedactionPreviewError
    }
    private(set) var redactionEditError: String?
    var isEditingSourceRegion: Bool { isCroppingVideo || isSelectingRedaction }
    private var playerItemTask: Task<Void, Never>?
    private let redactionPreview = RecordingRedactionPreviewSource()
    private var redactionRefreshTask: Task<Void, Never>?
    private var redactionFailureObserver: NSObjectProtocol?
    private var redactionStatusObserver: NSKeyValueObservation?
    private let pendingRedactionEdit = StudioPendingEdit<[RecordingRedaction]>()
    private(set) var textOverlays: [RecordingTextOverlay] = []
    var selectedTextID: UUID?
    private let pendingTextEdit = StudioPendingEdit<[RecordingTextOverlay]>()
    private(set) var imageOverlays: [RecordingImageOverlay] = []
    var selectedImageID: UUID?
    let overlayImages = RecordingOverlayImageStore()
    private(set) var overlayImageRevision = 0
    var mediaImportError: String?
    private let pendingImageEdit = StudioPendingEdit<[RecordingImageOverlay]>()
    private var mediaLoadTask: Task<Void, Never>?
    private(set) var videoOverlays: [RecordingVideoOverlay] = []
    var selectedVideoOverlayID: UUID?
    private(set) var missingVideoOverlayFiles: Set<String> = []
    private let pendingVideoOverlayEdit = StudioPendingEdit<[RecordingVideoOverlay]>()
    private var videoOverlaySeek = StudioCameraSeekCoordinator()
    private var loadedVideoOverlayFileName: String?
    private var loadedVideoOverlayID: UUID?
    private var videoOverlayImportTask: Task<Void, Never>?
    private var videoOverlayImportID: UUID?
    private(set) var videoOverlayRenderProgress: Double?
    private(set) var pendingRecordingOverlayImport: PendingRecordingOverlayImport?
    /// The preview's copy of the reframe camera, kept current with every
    /// edit that would change the exported crop.
    private(set) var previewReframe: ReframeTrack?
    private var reframeFocusTimeline: PointerTimeline?
    private var reframeFocusResolved = false
    private(set) var chapters: [RecordingChapter] = []
    private(set) var chapterError: String?
    /// The on-device model behind Summarize and Name Chapters.
    @ObservationIgnored var textModel: any OnDeviceTextModel = SystemTextModel()
    private(set) var summary: String?
    private(set) var summaryNote: String?
    private(set) var isSummarizing = false
    private(set) var isNamingChapters = false
    private(set) var captionTracks: [RecordingCaptionTrack] = []
    private(set) var translationNote: String?
    /// The language being translated now; the view's translation task runs it.
    private(set) var translationConfiguration: TranslationSession.Configuration?
    @ObservationIgnored private var translationQueue: [Locale.Language] = []
    /// The chapter whose name is being typed, and the undo step its first save made.
    @ObservationIgnored private var renameUndoMark: (id: UUID, revision: Int)?

    private(set) var subtitleCues: [RecordingSubtitleCue] = []
    private(set) var subtitleTimeline = SubtitleTimeline.empty {
        didSet { refreshPlayheadMarks() }
    }
    /// Word-level timing behind the cues; empty for projects transcribed
    /// before transcript editing shipped (cues only).
    private(set) var transcriptWords: [RecordingTranscriptWord] = [] {
        didSet { refreshFillerWords() }
    }
    /// The transcript's language as read from its words, for its filler list.
    private(set) var transcriptLanguage: String?
    private(set) var fillerWordIndices: Set<Int> = []
    /// Also cut words that are often filler ("like", "you know"); off by default.
    var includesDiscourseFillers = UserDefaults.standard.bool(forKey: RecordingStudioModel.discourseFillersKey) {
        didSet {
            UserDefaults.standard.set(includesDiscourseFillers, forKey: Self.discourseFillersKey)
            refreshFillerWords()
        }
    }
    /// The transcript shows the filler words struck through, as a cut would.
    var previewsFillerWords = false
    /// Shorten Pauses: pauses longer than this…
    var pauseThreshold = UserDefaults.standard.object(forKey: RecordingStudioModel.pauseThresholdKey) as? Double
        ?? PausePlanner.defaultThreshold {
        didSet { UserDefaults.standard.set(pauseThreshold, forKey: Self.pauseThresholdKey) }
    }
    /// …keep this much.
    var pauseBeat = UserDefaults.standard.object(forKey: RecordingStudioModel.pauseBeatKey) as? Double
        ?? PausePlanner.defaultBeat {
        didSet { UserDefaults.standard.set(pauseBeat, forKey: Self.pauseBeatKey) }
    }
    /// Whether each quiet pause's frames stay still, by its source range in ms.
    private(set) var pauseScreenStill: [[Int]: Bool] = [:]
    static let discourseFillersKey = "studio.cleanup.discourseFillers"
    static let pauseThresholdKey = "studio.cleanup.pauseThreshold"
    static let pauseBeatKey = "studio.cleanup.pauseBeat"
    /// Word-timing lookup for karaoke captions; rebuilt with the cues.
    private(set) var karaokeTimeline = KaraokeTimeline.empty
    /// Word under the playhead, updated only on word boundaries so the
    /// transcript view isn't invalidated on every 20 ms playback tick.
    private(set) var activeTranscriptWordIndex: Int?
    var transcriptionState = RecordingTranscriptionState.idle
    private(set) var zoomCues: [ZoomCue] = []
    private(set) var viewportTimeline = ViewportTimeline.identity
    private(set) var pointerTimeline = PointerTimeline.empty
    private(set) var keystrokeTimeline = KeystrokeCaptionTimeline.empty
    var selectedCueID: UUID?
    private(set) var clipTimeline = RecordingClipTimeline(segments: []) {
        didSet {
            if clipTimeline != oldValue {
                rebuildCaptionTimelines()
                refreshPlayheadMarks()
            }
        }
    }
    var selectedClipID: UUID?
    /// A stretch of the edited video marked with I and O (or ⇧-drag on the
    /// ruler) for ripple deletion.
    var rangeSelection: ClosedRange<TimeInterval>?
    /// Moments flagged with M, stored on the source clock so they stay
    /// attached to their footage across cuts.
    private(set) var markers: [RecordingMarker] = []
    /// Sound under the video, on audio lanes on the edited video's clock.
    /// Linked clips are cut with the video above them; the rest keep their
    /// place (`StudioAudioConform`).
    private(set) var audioClips: [RecordingAudioClip] = []
    /// Linked audio ranges temporarily hidden by trimming a video clip inward,
    /// kept so dragging the trim back out restores them.
    private var hiddenLinkedAudio: [StudioAudioConform.HiddenLinkedRange] = []
    /// Currently soloed audio lane for live monitoring, kept separate from
    /// each clip's stored `isMuted` flag and tracked in Undo/Redo.
    private(set) var soloAudioLane: Int?
    /// The audio clip the inspector shows: the last one clicked.
    var selectedAudioClipID: UUID? {
        didSet {
            if let selectedAudioClipID {
                if !selectedAudioClipIDs.contains(selectedAudioClipID) {
                    selectedAudioClipIDs = [selectedAudioClipID]
                }
            } else {
                selectedAudioClipIDs = []
            }
        }
    }
    /// Every selected audio clip; ⇧- or ⌘-click adds to it. Move, delete,
    /// mute and link act on all of them.
    private(set) var selectedAudioClipIDs: Set<UUID> = []
    /// Waveform outlines of the audio files, by file name, and of the
    /// recording's own audio and the soundtrack replacing it under
    /// `recordingPeaksKey` and `soundtrackPeaksKey`.
    private(set) var audioPeaks: [String: RecordingAudioWaveform] = [:]
    private var audioPeakTasks: [String: Task<Void, Never>] = [:]
    /// File names of audio clips whose files are missing or unreadable.
    private(set) var missingAudioClipFiles: Set<String> = []
    static let recordingPeaksKey = "\u{1}recording"
    static let soundtrackPeaksKey = "\u{1}soundtrack"
    /// A block is being dragged on the timeline. The preview stays on the
    /// playhead meanwhile instead of chasing the pointer, and audio lanes
    /// keep a spare row to drag into.
    var isDraggingTimelineBlock = false {
        didSet {
            if isDraggingTimelineBlock, !oldValue { laneCountAtDragStart = usedAudioLaneCount }
        }
    }
    private var laneCountAtDragStart = 1
    /// A video clip's edge is being dragged; the preview shows the frame at
    /// that edge rather than skimming.
    var isTrimmingClip = false
    /// Whether trim drags snap to the playhead, markers, clicks, and audio edges.
    var snapsEdits = (UserDefaults.standard.object(forKey: RecordingStudioModel.snapsEditsKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(snapsEdits, forKey: Self.snapsEditsKey)
        }
    }
    static let snapsEditsKey = "StudioTimelineSnapping"
    /// Storyboard tiles for the clip lane, sampled on demand at whatever
    /// density the lane's current zoom needs.
    let timelineThumbnails = RecordingTimelineThumbnailStore()

    private(set) var isPlaying = false
    /// Playback speed and direction for J/K/L shuttling; 1 plays normally.
    private(set) var shuttleRate: Float = 1
    /// One frame of the recording, for approximate frame-step fallback.
    private(set) var frameDuration: TimeInterval = StudioPlayback.defaultFrameDuration
    private var canUseSampleCursors = false
    private var cameraSeek = StudioCameraSeekCoordinator()
    private var lastCameraSegmentID: UUID?
    /// A short word shown over the picture when a key does something that is
    /// otherwise hard to see ("2×", "◀ 1×").
    private(set) var notice: StudioNotice?
    private var noticeTask: Task<Void, Never>?
    var currentTime: TimeInterval = 0 {
        didSet {
            if currentTime != oldValue { refreshPlayheadMarks() }
        }
    }
    /// The clip and the subtitle under the playhead. Stored, and assigned
    /// only when the playhead crosses into another one, so views that read
    /// them are not redrawn on every 20 ms playback tick the way a read of
    /// `currentTime` would redraw them.
    private(set) var playheadClipID: UUID?
    private(set) var activeSubtitleCueID: UUID?
    /// Live scrub-preview time while the pointer hovers the trim strip
    /// without committing to a new playhead position, matching Final
    /// Cut/iMovie skimming. `nil` shows the real playhead again.
    var hoverPreviewTime: TimeInterval? {
        didSet {
            guard isLoaded, duration > 0, !isPlaying, activeTrimSourcePreviewTime == nil else { return }
            movePlayers(to: hoverPreviewTime ?? currentTime)
        }
    }
    /// Non-nil while a trim drag temporarily displays the unedited source
    /// asset (for footage being restored outside the current cut). Observed so
    /// editor-clock canvas overlays stay hidden while raw source frames show.
    private(set) var activeTrimSourcePreviewTime: TimeInterval?
    /// Single gate and ready cut item shared by cut rebuilds and temporary
    /// source-asset trim previews.
    @ObservationIgnored private var playerItemGate = StudioPlayerItemGate()
    @ObservationIgnored private var readyCutPlayerItem: AVPlayerItem?
    @ObservationIgnored private var compositionTimeMap: StudioCompositionTimeMap?
    var exportState: RecordingStudioExportState = .idle
    /// The running export is the Bug Report's (its Agent Prompt), so its button shows the progress.
    private(set) var isExportingAgentPrompt = false
    /// The Bug Report button says the prompt was copied for a moment after a success.
    private(set) var showsAgentPromptSaved = false
    /// The How-To Guide is being written; its button shows it's busy.
    private(set) var isExportingGuide = false
    var audioExportState: RecordingStudioExportState = .idle
    var shareState: RecordingStudioShareState = .idle
    private(set) var isDeletingSharedLink = false
    private(set) var sharedVideoError: String?
    /// Work that closing the window or quitting would cancel.
    var hasRunningWork: Bool {
        isRestoringDocument || exportTask != nil || shareTask != nil || backgroundMusicTask != nil || videoImportTask != nil || isIsolatingVoice || exportState.isExporting || audioExportState.isExporting || shareState.isBusy || isDeletingSharedLink || videoOverlayRenderProgress != nil
    }

    /// Pending choice when adding one or more Sukusho `.sukushorec` recordings
    /// into the sequence: raw `screen.mov` (default) or rendered finished movie.
    struct PendingRecordingImport: Identifiable, Equatable {
        let id = UUID()
        let urls: [URL]
        let insertionIndex: Int
        let recordingNames: [String]
        let canImportFinished: Bool
    }

    var pendingRecordingImport: PendingRecordingImport?
    /// Live render progress (0...1) while rendering a Sukusho recording's
    /// finished movie before importing it into the sequence.
    private(set) var videoImportProgress: Double?
    private(set) var videoImportTitle: String?
    private var videoImportTask: Task<Void, Never>?
    var isImportingVideoClip: Bool { videoImportTask != nil }
    /// Resolved metadata and video tracks for imported in-sequence clips, keyed
    /// by their filename inside `session.mediaDirectoryURL`.
    private var importedVideoSources: [String: StudioVideoSource] = [:]
    /// File names of imported video clips whose files are missing or unreadable.
    private(set) var missingVideoClipFiles: Set<String> = []
    private var screenNaturalSize = CGSize(width: 1920, height: 1080)
    private var screenPreferredTransform: CGAffineTransform = .identity
    /// Upload identity while sharing, so the UI can read the uploader's
    /// live progress and the history card mirrors the state.
    private(set) var shareItemID: UUID?

    /// Gain shared by playback and video/audio export; 1 preserves the source.
    var audioVolume: CGFloat = 1 {
        didSet {
            updatePlaybackVolume()
            scheduleProjectSave()
        }
    }

    /// Everything that should be heard right now, for the composer.
    private var audioPlan: StudioAudioPlan {
        StudioAudioPlan(
            timeline: clipTimeline,
            sync: replacementAudio == nil ? nil : replacementAudioSync,
            clips: audioClips,
            volume: Double(audioVolume),
            soloLane: soloAudioLane,
            videoOverlays: videoOverlays
        )
    }

    /// Resolved audio sources with Sukusho's voice-isolated microphone swapped
    /// in whenever voice isolation is active, so any original recording audio
    /// (including detached recording clips or revealed footage) uses it.
    private var activeAudioSources: StudioAudioSources {
        if voiceIsolationEnabled,
           let isolated = isolatedMicrophone,
           let micID = microphoneTrackID,
           let swapped = audioSources.replacingMicrophone(
               trackID: micID,
               with: StudioAudioSources.Track(track: isolated.track, range: isolated.range, asset: isolated.asset)
           ) {
            return swapped
        }
        return audioSources
    }

    private func updatePlaybackVolume() {
        guard let item = screenPlayer.currentItem else { return }
        let base = StudioAudioComposer.mix(for: playbackAudioLayout, plan: audioPlan)
        item.audioMix = RecordingBackgroundMusicMixer.combinedMix(
            base: base,
            musicTrackID: playbackMusicTrackID,
            settings: backgroundMusicSettings,
            speech: microphoneMusicAnalysis?.speech ?? [],
            timeline: clipTimeline
        )
    }

    /// Format the audio-only export writes.
    var audioExportFormat: RecordingAudioFormat = .m4a {
        didSet { scheduleProjectSave() }
    }
    /// Mixes background music and audio lanes into the audio-only export.
    /// Off by default so the cleanup round trip exports only the speech track
    /// and never doubles the music bed or lanes when re-imported.
    var audioExportIncludesClips = false
    /// The soundtrack standing in for the recording's own audio, resolved
    /// so both playback and export can use it without reloading tracks.
    private(set) var replacementAudio: RecordingReplacementAudio?
    /// How that soundtrack lines up with the recording. It is what lets a
    /// cut of the video cut the soundtrack in the same place.
    private(set) var replacementAudioSync: RecordingAudioSync?
    /// Keep the document's selection even if its file cannot be loaded.
    private var replacementAudioReference: StudioReplacementReference?
    /// Session-scoped external URLs for detached replacement clips in standalone
    /// movies (which have no project folder to copy into).
    private var externalPinnedReplacementURLs: [String: URL] = [:]
    /// Every soundtrack and audio file this editor has used since it opened.
    private var undoReferencedFiles = Set<String>()
    private var soundtrackOffsetSnapshot: TimeInterval?
    private var soundtrackOffsetTask: Task<Void, Never>?
    var hasReplacementAudio: Bool {
        replacementAudio != nil || replacementAudioReference != nil
    }
    /// Why the last import was rejected, shown next to the Replace control.
    private(set) var replacementAudioError: String?

    private(set) var backgroundMusic: RecordingReplacementAudio?
    private(set) var backgroundMusicSettings: RecordingBackgroundMusic?
    private(set) var backgroundMusicError: String?
    private var backgroundMusicTask: Task<Void, Never>?
    private var musicSliderBaseline: RecordingBackgroundMusic?
    private var playbackMusicTrackID: CMPersistentTrackID?
    private var microphoneMusicAnalysis: RecordingMusicAnalysis?
    private(set) var musicWaveform: [Float] = []
#if DEBUG
    @ObservationIgnored var musicAnalysisOverride: ((URL, CMPersistentTrackID) async -> RecordingMusicAnalysis?)?
#endif

    private func availableMusicAnalysis(url: URL, trackID: CMPersistentTrackID) async throws -> RecordingMusicAnalysis? {
#if DEBUG
        if let musicAnalysisOverride {
            let result = await musicAnalysisOverride(url, trackID)
            try Task.checkCancellation()
            return result
        }
#endif
        return try await RecordingMusicAnalysisCache.shared.availableAnalysis(url: url, trackID: trackID)
    }
    var hasBackgroundMusic: Bool { backgroundMusicSettings != nil }

    var musicStartOffset: CGFloat {
        get { CGFloat(backgroundMusicSettings?.startOffset ?? 0) }
        set { changeBackgroundMusic { $0.startOffset = RecordingBackgroundMusic.startOffset(Double(newValue), duration: backgroundMusic?.duration ?? 0) } }
    }
    var musicVolume: CGFloat {
        get { CGFloat(backgroundMusicSettings?.volume ?? 0.25) }
        set { changeBackgroundMusic { $0.volume = Double(newValue.isFinite ? min(1, max(0, newValue)) : 0.25) } }
    }
    var musicLoops: Bool {
        get { backgroundMusicSettings?.loop ?? true }
        set { changeBackgroundMusic { $0.loop = newValue } }
    }
    var musicDucks: Bool {
        get { backgroundMusicSettings?.duck ?? true }
        set { changeBackgroundMusic { $0.duck = newValue } }
    }
    var musicDuckAmount: RecordingBackgroundMusic.DuckAmount {
        get { backgroundMusicSettings?.duckAmount ?? .medium }
        set { changeBackgroundMusic { $0.duckAmount = newValue } }
    }

    func setMusicSliderEditing(_ editing: Bool) {
        if editing {
            guard !isRestoringDocument, musicSliderBaseline == nil else { return }
            musicSliderBaseline = backgroundMusicSettings
        } else if let previous = musicSliderBaseline {
            musicSliderBaseline = nil
            if previous != backgroundMusicSettings { registerBackgroundMusicUndo(previous) }
        }
    }

    private func registerBackgroundMusicUndo(_ previous: RecordingBackgroundMusic?) {
        registerUndo("Background Music") { $0.restoreBackgroundMusicSelection(previous) }
    }

    private func restoreBackgroundMusicSelection(_ settings: RecordingBackgroundMusic?) {
        guard !isRestoringDocument, settings != backgroundMusicSettings else { return }
        registerBackgroundMusicUndo(backgroundMusicSettings)
        let restoreID = beginDocumentRestore()
        backgroundMusicSettings = settings
        documentRestoreTask = Task {
            await resolveBackgroundMusic()
            if !Task.isCancelled, !isTornDown {
                do { try rebuildScreenPlayerItem(preserving: currentTime) }
                catch { backgroundMusicError = "Could not restore music: \(error.localizedDescription)" }
            }
            finishDocumentRestore(restoreID)
            scheduleProjectSave()
        }
    }

    private func changeBackgroundMusic(_ change: (inout RecordingBackgroundMusic) -> Void) {
        guard !isRestoringDocument, var settings = backgroundMusicSettings else { return }
        change(&settings)
        guard settings != backgroundMusicSettings else { return }
        if musicSliderBaseline == nil { registerBackgroundMusicUndo(backgroundMusicSettings) }
        let rebuild = settings.startOffset != backgroundMusicSettings?.startOffset || settings.loop != backgroundMusicSettings?.loop
        backgroundMusicSettings = settings
        if rebuild {
            let resume = isPlaying
            pause()
            applyReplacementAudioToPlayback()
            if resume { play() }
        } else {
            updatePlaybackVolume()
            scheduleProjectSave()
        }
    }

    /// The picker deletes its download on return; copy synchronously before resolving audio.
    func setBackgroundMusic(fileURL: URL, displayName: String, credit: String?, startOffset: TimeInterval) {
        guard isLoaded, !isRestoringDocument, let session else { return }
        setMusicSliderEditing(false)
        pause()
        backgroundMusicTask?.cancel()
        backgroundMusicTask = nil
        backgroundMusicError = nil
        let destination = session.directoryURL
            .appendingPathComponent("\(RecordingBackgroundMusic.baseName).\(UUID().uuidString)")
            .appendingPathExtension(fileURL.pathExtension.isEmpty ? "m4a" : fileURL.pathExtension)
        do { try FileManager.default.copyItem(at: fileURL, to: destination) }
        catch {
            try? FileManager.default.removeItem(at: destination)
            backgroundMusicError = "Could not import music: \(error.localizedDescription)"
            return
        }
        backgroundMusicTask = Task { [weak self] in
            var adopted = false
            defer { if !adopted { try? FileManager.default.removeItem(at: destination) } }
            let resolved = await RecordingReplacementAudio.load(url: destination, displayName: displayName)
            guard let self, !self.isTornDown, !Task.isCancelled else { return }
            guard let resolved else {
                self.backgroundMusicTask = nil
                self.backgroundMusicError = "That file has no readable audio track."
                return
            }
            do {
                let waveform = try await self.availableMusicAnalysis(url: destination, trackID: resolved.track.trackID)?.waveform ?? []
                let micAnalysis: RecordingMusicAnalysis?
                if let id = self.microphoneTrackID, self.microphoneMusicAnalysis == nil {
                    micAnalysis = try await self.availableMusicAnalysis(url: self.screenURL, trackID: id) ?? RecordingMusicAnalysis(levels: [])
                } else { micAnalysis = self.microphoneMusicAnalysis }
                try Task.checkCancellation()
                guard !self.isTornDown else { return }
                self.musicWaveform = waveform
                self.microphoneMusicAnalysis = micAnalysis
            } catch {
                guard !Task.isCancelled, !self.isTornDown else { return }
                self.backgroundMusicTask = nil
                self.backgroundMusicError = "Could not prepare music: \(error.localizedDescription)"
                return
            }
            self.backgroundMusicTask = nil
            var settings = self.backgroundMusicSettings ?? RecordingBackgroundMusic(fileName: destination.lastPathComponent, displayName: displayName)
            settings.fileName = destination.lastPathComponent
            settings.displayName = displayName
            settings.credit = credit
            settings.startOffset = RecordingBackgroundMusic.startOffset(startOffset, duration: resolved.duration)
            // A drag held across adoption folds into the import's step, then continues from the new song.
            self.registerBackgroundMusicUndo(self.musicSliderBaseline ?? self.backgroundMusicSettings)
            self.backgroundMusic = resolved
            self.backgroundMusicSettings = settings
            if self.musicSliderBaseline != nil { self.musicSliderBaseline = settings }
            adopted = true
            self.applyReplacementAudioToPlayback()
        }
    }

    func removeBackgroundMusic() {
        guard !isRestoringDocument else { return }
        setMusicSliderEditing(false)
        if backgroundMusicSettings != nil { registerBackgroundMusicUndo(backgroundMusicSettings) }
        backgroundMusicTask?.cancel()
        backgroundMusicTask = nil
        pause()
        backgroundMusic = nil
        backgroundMusicSettings = nil
        musicWaveform = []
        backgroundMusicError = nil
        applyReplacementAudioToPlayback()
    }

    private func resolveBackgroundMusic() async {
        backgroundMusic = nil
        backgroundMusicError = nil
        guard let settings = backgroundMusicSettings, let session else { return }
        let resolved = await RecordingReplacementAudio.load(url: session.directoryURL.appendingPathComponent(settings.fileName), displayName: settings.displayName)
        guard !Task.isCancelled, !isTornDown, backgroundMusicSettings == settings else { return }
        guard let resolved else {
            backgroundMusicError = "The background music file is missing or unreadable. Add it again or remove it."
            return
        }
        do {
            let analysis = try await availableMusicAnalysis(url: resolved.url, trackID: resolved.track.trackID)
            if let id = microphoneTrackID, microphoneMusicAnalysis == nil {
                microphoneMusicAnalysis = try await availableMusicAnalysis(url: screenURL, trackID: id) ?? RecordingMusicAnalysis(levels: [])
            }
            guard !Task.isCancelled, !isTornDown, backgroundMusicSettings == settings else { return }
            var normalized = settings
            normalized.startOffset = RecordingBackgroundMusic.startOffset(settings.startOffset, duration: resolved.duration)
            backgroundMusicSettings = normalized
            musicWaveform = analysis?.waveform ?? []
            backgroundMusic = resolved
        } catch {
            guard !Task.isCancelled, !isTornDown else { return }
            backgroundMusicError = "Could not prepare music: \(error.localizedDescription)"
        }
    }

    private var voiceIsolationEnabled = false
    private var isolatedMicrophone: RecordingReplacementAudio?
    private var microphoneTrackID: CMPersistentTrackID?
    private var voiceIsolationTask: Task<Void, Never>?
    private var voiceIsolationRequestID = UUID()
    private(set) var voiceIsolationProgress: Double?
    private(set) var voiceIsolationError: String?
    var canIsolateVoice: Bool { session != nil && microphoneTrackID != nil }
    var isIsolatingVoice: Bool { voiceIsolationProgress != nil || voiceIsolationTask != nil }
    var isolateVoice: Bool {
        get { voiceIsolationEnabled }
        set {
            guard !isReadOnlyNewerFormat, newValue != voiceIsolationEnabled, !newValue || canIsolateVoice else { return }
            pause()
            cancelVoiceIsolation()
            voiceIsolationError = nil
            voiceIsolationEnabled = newValue
            if newValue {
                voiceIsolationProgress = 0
                let requestID = voiceIsolationRequestID
                voiceIsolationTask = Task { [weak self] in
                    guard let self, !Task.isCancelled, !self.isTornDown,
                          self.voiceIsolationRequestID == requestID else { return }
                    await self.resolveVoiceIsolation()
                    guard self.voiceIsolationRequestID == requestID, !self.isTornDown else { return }
                    self.voiceIsolationTask = nil
                    self.applyVoiceIsolationToPlayback()
                }
            } else {
                applyVoiceIsolationToPlayback()
            }
        }
    }

    private func applyVoiceIsolationToPlayback() {
        do {
            try rebuildScreenPlayerItem(preserving: currentTime)
        } catch {
            voiceIsolationEnabled = false
            voiceIsolationError = "Voice isolation failed. The original microphone audio is still in use. \(error.localizedDescription)"
            try? rebuildScreenPlayerItem(preserving: currentTime)
        }
        scheduleProjectSave()
    }

    private func cancelVoiceIsolation() {
        voiceIsolationTask?.cancel()
        voiceIsolationTask = nil
        voiceIsolationRequestID = UUID()
        voiceIsolationProgress = nil
    }

    private func resolveVoiceIsolation() async {
        guard voiceIsolationEnabled, let session else { return }
        let requestID = voiceIsolationRequestID
        if isReadOnlyNewerFormat {
            // Read-only newer projects must never write into the package: load
            // an existing valid cache file only and leave missing caches absent.
            guard let existingURL = RecordingPackageMedia.resolvePackageFile(
                named: RecordingVoiceIsolation.fileName,
                in: session.directoryURL
            ) else {
                isolatedMicrophone = nil
                voiceIsolationProgress = nil
                return
            }
            let loaded = await RecordingReplacementAudio.load(url: existingURL, displayName: "Isolated voice")
            guard !Task.isCancelled, voiceIsolationRequestID == requestID, !isTornDown else { return }
            isolatedMicrophone = loaded
            voiceIsolationProgress = nil
            return
        }
        voiceIsolationProgress = 0
        do {
            guard let microphoneTrackID else { throw RecordingVoiceIsolation.IsolationError.missingMicrophone }
            let url = session.directoryURL.appendingPathComponent(RecordingVoiceIsolation.fileName)
            try await RecordingVoiceIsolation.render(sourceURL: screenURL,
                microphoneTrackID: microphoneTrackID, destinationURL: url) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.voiceIsolationRequestID == requestID,
                          self.voiceIsolationProgress != nil else { return }
                    self.voiceIsolationProgress = progress
                }
            }
            let loaded = await RecordingReplacementAudio.load(url: url, displayName: "Isolated voice")
            try Task.checkCancellation()
            guard voiceIsolationRequestID == requestID, !isTornDown else { return }
            guard let loaded else { throw RecordingVoiceIsolation.IsolationError.invalidAudio }
            isolatedMicrophone = loaded
            voiceIsolationProgress = nil
        } catch {
            guard voiceIsolationRequestID == requestID, !isTornDown else { return }
            voiceIsolationEnabled = false
            voiceIsolationProgress = nil
            voiceIsolationError = "Voice isolation failed. The original microphone audio is still in use. \(error.localizedDescription)"
        }
    }

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var exportTask: Task<Void, Never>?
    private var audioExportTask: Task<Void, Never>?
    private var replacementAudioTask: Task<Void, Never>?
    /// The screen movie's video track, kept from load so the player item
    /// can be rebuilt synchronously when an imported soundtrack means the
    /// composition has to be assembled track by track.
    private var screenVideoTrack: AVAssetTrack?
    private var shareTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var projectSaveTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    /// The project as this window opened it, for Revert To › Last Opened.
    private var openedDocument: RecordingEditDocument?
    private var openedOnDraft = false
    /// Opened on the last save because the draft couldn't be read. Until it's discarded, nothing
    /// saves over it, and export and upload stay off: the draft may hold redactions this lacks.
    private(set) var hasUnreadableDraft = false
    /// Opened a project saved by a newer format version; strictly read-only so
    /// neither `edit.json`, the draft, snapshots, nor media are ever modified.
    private(set) var isReadOnlyNewerFormat = false
    /// Highest unsupported format version seen in `edit.json` or `edit.draft.json`.
    private var newerFormatVersion: Int?
    /// True when the active newer-format edit could not be decoded and validated,
    /// so playback, posters, and the filmstrip stay withheld rather than showing
    /// the unredacted master.
    private(set) var withholdsNewerFormatPreview = false
    private var sessionOpenedAt = Date()
    private var keptOpeningSession = false
    private(set) var sessionSnapshots: [CaptureSessionSnapshot] = []
    var previousSessionSnapshots: [CaptureSessionSnapshot] {
        sessionSnapshots.filter { $0.openedAt != sessionOpenedAt }
    }
    private var openedStylePresetID: RecordingStudioStylePreset.ID?
    /// Revert To › Last Opened is off until something changes.
    private(set) var hasEditsSinceOpening = false
    private var screenAsset: AVURLAsset?
    private var isTornDown = false
    private var isLoading = false
    private var wallpaperCacheLease: BoundedCGImageCache.Lease?
    private let editUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    private(set) var undoRevision = 0
    private var zoomEditSnapshot: [ZoomCue]?
    private var viewportRebuildTask: Task<Void, Never>?
    private var audioEditSnapshot: [RecordingAudioClip]?
    private var audioCoalesceTask: Task<Void, Never>?
    private var clipSoundSnapshot: RecordingClipTimeline?
    private var clipSoundCoalesceTask: Task<Void, Never>?
    private var audioPlaybackRebuildTask: Task<Void, Never>?
    /// Every audio track the project plays, resolved once so the player
    /// item can be rebuilt synchronously.
    private var audioSources = StudioAudioSources()
    /// Where the playback composition put each sound, for the mix.
    private var playbackAudioLayout = StudioAudioLayout()
    /// What the playback composition was built for; a plan that places
    /// sound differently needs a new one.
    private var playbackAudioPlacement: StudioAudioPlan?
    /// The document as of the last save. Everything the user does after
    /// that lives in memory and in the draft until the next save.
    private var lastSavedDocument: RecordingEditDocument?
    /// Set while a stored document is being applied to the model, so the
    /// resulting property writes don't register as user edits.
    private var isApplyingDocument = false
    private var documentRestoreID: UUID?
    private var documentRestoreTask: Task<Void, Never>?
    var isRestoringDocument: Bool { documentRestoreID != nil }

    private func beginDocumentRestore() -> UUID {
        let id = UUID()
        documentRestoreID = id
        musicSliderBaseline = nil
        pause()
        return id
    }

    private func finishDocumentRestore(_ id: UUID) {
        guard documentRestoreID == id else { return }
        documentRestoreID = nil
        documentRestoreTask = nil
    }
    /// Whether the editor holds edits that have not been committed to
    /// `edit.json`. Stored rather than derived: the title bar reads it on
    /// every body evaluation, and rebuilding the whole document to compare
    /// it there would cost real time while dragging.
    private(set) var hasUnsavedChanges = false
    /// Whether the last save in this window worked; nil before the first.
    private(set) var lastSaveSucceeded: Bool?

    /// The window subtitle's status, as in the image editor: nothing on
    /// open, then Edited, Saved (until the next edit) or Not Saved (until a
    /// save works). A save is one small file write, so there's no Saving….
    var saveStatus: String {
        guard hasUnsavedChanges else { return lastSaveSucceeded == true ? "Saved" : "" }
        return lastSaveSucceeded == false ? "Not Saved" : "Edited"
    }

    /// Accepts either a recording session folder or a bare video file (so
    /// history items and old recordings still open, just without events).
    init(url: URL) {
        sessionURL = url
        if RecordingSession.isSessionDirectory(url) {
            session = RecordingSession(directoryURL: url)
        } else {
            session = nil
        }
    }

    var screenURL: URL {
        session?.screenURL ?? sessionURL
    }

    /// False for a bare movie opened from disk: there is no project package
    /// behind it, so there is nothing to save into.
    var isProject: Bool { session != nil }

    /// What the window title, share sheet, and Projects browser call this
    /// project. A bare movie falls back to its file name.
    var projectDisplayName: String {
        _ = nameRevision
        return session?.displayName ?? sessionURL.deletingPathExtension().lastPathComponent
    }

    /// The name given in the Library or the title bar, if any.
    var customName: String? {
        _ = nameRevision
        return session?.customName
    }

    /// Apple Intelligence's title for the recording, as its Library card shows it.
    var modelTitle: String? {
        session.flatMap { CaptureLibraryIndex.shared.visibleInsight("recording:" + $0.directoryURL.standardizedFileURL.path)?.title }
    }

    /// An unnamed project's name, as the Library and the image editor show
    /// it: when it was recorded. Until load reads the manifest, that comes
    /// from the `Sukusho_<timestamp>_<id>` folder name; a bare movie
    /// keeps its file name.
    var defaultName: String {
        let name = sessionURL.deletingPathExtension().lastPathComponent
        guard let date = manifest?.createdAt ?? SukushoFileNames.recordingDate(inName: name) else { return name }
        return CaptureLibraryItem.dateTitle(date)
    }

    /// The names above are read from disk; a rename here bumps this so the
    /// title shows the new one at once.
    private var nameRevision = 0

    /// Renames the project as the Library does; an empty name restores the
    /// default one.
    func rename(to name: String) {
        guard !isReadOnlyNewerFormat, let session else { return }
        RecordingProjectStore.shared.rename(session, to: name)
        nameRevision += 1
    }

    func load() async {
        guard !isLoaded, !isLoading, !isTornDown, !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        wallpaperCacheLease = AnnotationBackgroundRenderer.beginWallpaperUse()

        if let session {
            let metadata = session.loadProjectMetadata()
            chapters = metadata?.chapters ?? []
            summary = metadata?.summary
            captionTracks = metadata?.captionTracks ?? []
            manifest = session.loadCaptureManifest()
            pointerCapture = session.loadPointerCapture() ?? PointerCaptureFile()
        }

        let asset = AVURLAsset(url: screenURL)
        screenAsset = asset
        do {
            let (durationTime, tracks) = try await asset.load(.duration, .tracks)
            guard !isTornDown, !Task.isCancelled else { return }
            sourceDuration = durationTime.seconds
            duration = sourceDuration
            if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
                screenVideoTrack = videoTrack
                let (naturalSize, preferredTransform, frameRate, providesSampleCursors) = try await videoTrack.load(
                    .naturalSize,
                    .preferredTransform,
                    .nominalFrameRate,
                    .canProvideSampleCursors
                )
                guard !isTornDown, !Task.isCancelled else { return }
                frameDuration = StudioPlayback.frameDuration(nominalFrameRate: frameRate)
                canUseSampleCursors = providesSampleCursors
                screenPreferredTransform = preferredTransform
                if naturalSize.width > 0, naturalSize.height > 0 {
                    screenNaturalSize = naturalSize
                    let oriented = RecordingCompositionBuilder.displaySize(
                        naturalSize: naturalSize,
                        preferredTransform: preferredTransform
                    )
                    if oriented.width > 0, oriented.height > 0 {
                        videoSize = oriented
                    }
                }
            }
            let recordingAudio = await StudioAudioSources.Track.loadAll(of: asset)
            guard !isTornDown, !Task.isCancelled else { return }
            audioSources.recording = recordingAudio
            hasRecordedAudio = !audioSources.recording.isEmpty
            microphoneTrackID = RecordingVoiceIsolation.microphoneTrack(in: tracks,
                includesMicrophone: manifest?.includesMicrophone == true,
                includesSystemAudio: manifest?.includesSystemAudio == true)?.trackID
            if hasRecordedAudio {
                loadPeaks(for: Self.recordingPeaksKey, url: screenURL)
            }
        } catch {
            guard !isTornDown, !Task.isCancelled else { return }
            loadError = "Could not open the recording: \(error.localizedDescription)"
            return
        }

        if session != nil {
            let pointScale = max(manifest?.pixelScale ?? 1, 1)
            let stream = PointerStreamSanitizer.sanitize(
                pointerCapture,
                options: PointerSanitizeOptions(
                    recordingSizeInPoints: CGSize(
                        width: videoSize.width / CGFloat(pointScale),
                        height: videoSize.height / CGFloat(pointScale)
                    )
                )
            )
            pointerCapture = stream.sanitizedCapture
            recordedPressTimes = pointerCapture.presses
                .filter { $0.phase == .down }
                .map(\.time)
            keystrokeTimeline = KeystrokeCaptionTimeline(events: pointerCapture.keystrokes)
            inkTimeline = RecordingInkTimeline(strokes: pointerCapture.ink)
        }

        if let session, session.hasCamera {
            hasCameraVideo = true
            cameraOffset = manifest?.cameraLeadIn ?? 0
            cameraPlayer.replaceCurrentItem(with: AVPlayerItem(url: session.cameraURL))
            cameraPlayer.actionAtItemEnd = .pause
            cameraPlayer.isMuted = true
        } else {
            style.camera.isVisible = false
        }

        let draftVersion = session.flatMap { RecordingPackageMedia.readFormatVersion(at: $0.draftDocumentURL) }
        let savedVersion = session.flatMap { RecordingPackageMedia.readFormatVersion(at: $0.editDocumentURL) }
        if let detectedNewer = [draftVersion, savedVersion]
            .compactMap({ $0 })
            .filter({ $0 > RecordingEditDocument.currentFormatVersion })
            .max() {
            isReadOnlyNewerFormat = true
            newerFormatVersion = detectedNewer
        }

        lastSavedDocument = session?.loadEditDocument()?.withoutRevision
        // Recover a draft that is newer than the last save.
        func read(ignoringDraft: Bool) throws -> RecordingEditDocument? {
            let document = try session?.editDocumentForRendering(ignoringDraft: ignoringDraft)
            for region in document?.redactions ?? [] { try region.validate(sourceDuration: sourceDuration) }
            return document
        }
        let document: RecordingEditDocument?
        if isReadOnlyNewerFormat {
            // Newer-format documents may carry unknown enum cases or schema
            // additions that this build cannot decode. Open read-only without
            // classifying a newer draft as corrupt or enabling Discard; if the
            // effective edit cannot be decoded and validated, withhold playback,
            // posters, and the filmstrip instead of showing the unredacted master.
            do {
                document = try read(ignoringDraft: false)
            } catch {
                document = nil
                withholdsNewerFormatPreview = true
                cutRedactionPreviewError = RecordingEditDocument.newerFormatNotice
                cameraPlayer.replaceCurrentItem(with: nil)
                style.camera.isVisible = false
            }
            hasUnreadableDraft = false
        } else {
            do {
                do { document = try read(ignoringDraft: false) }
                catch where FileManager.default.fileExists(atPath: session?.draftDocumentURL.path ?? "") {
                    // An unreadable draft: open on the last save and leave the draft alone until Discard.
                    document = try read(ignoringDraft: true)
                    hasUnreadableDraft = true
                }
            } catch {
                loadError = "Could not read the recording edits: \(error.localizedDescription)"
                return
            }
        }
        // Sessions recorded before the toggle moved into Studio stored the
        // choice in the manifest; honor it as the default.
        showsClickEffects = manifest?.pressEffectsEnabled ?? true
        // A brand new recording has no project yet, so it also starts from
        // the remembered export choice.
        exportSettings = RecordingExportPreferences.lastSettings
        if let document {
            if document.isUnsupportedFutureVersion || lastSavedDocument?.isUnsupportedFutureVersion == true {
                isReadOnlyNewerFormat = true
                newerFormatVersion = max(
                    newerFormatVersion ?? 0,
                    max(document.formatVersion, lastSavedDocument?.formatVersion ?? 0)
                )
            }
            applyDocumentSettings(document)
        } else if session == nil {
            // Legacy bare movies use the same editor, but open visually
            // unchanged until the user explicitly adds styling.
            style = RecordingStudioStyle(
                background: .none,
                padding: 0,
                cornerRadius: 0,
                shadow: 0,
                camera: RecordingCameraBubbleSettings(isVisible: false)
            )
            zoomEnabled = false
        } else if !isReadOnlyNewerFormat {
            zoomCues = ZoomCueSynthesizer.cues(from: pointerCapture, duration: sourceDuration)
            if let defaultPreset = RecordingStudioStylePresetStore.shared.activePreset {
                style = defaultPreset.value
                appliedStylePresetID = defaultPreset.id
            }
        }

        if let storedClips = document?.clips, !storedClips.isEmpty {
            clipTimeline = RecordingClipTimeline(segments: storedClips)
                .normalized(to: sourceDuration)
        } else {
            clipTimeline = .legacyTrim(
                start: document?.trimStart,
                end: document?.trimEnd,
                sourceDuration: sourceDuration
            )
        }
        duration = clipTimeline.duration
        // Nothing is selected until the user picks a clip; an unsplit
        // recording would otherwise open wrapped in selection chrome.
        selectedClipID = nil

        // Resolve the imported soundtrack before the first player item is
        // built, so the editor opens already playing what it will export.
        if let session, let fileName = document?.replacementAudioFileName {
            let reference = StudioReplacementReference(
                fileName: fileName,
                displayName: document?.replacementAudioDisplayName
            )
            let url = session.directoryURL.appendingPathComponent(fileName)
            let loadedAudio: RecordingReplacementAudio?
            if FileManager.default.fileExists(atPath: url.path) {
                loadedAudio = await RecordingReplacementAudio.load(
                    url: url,
                    displayName: reference.label
                )
                guard !isTornDown, !Task.isCancelled else { return }
            } else {
                loadedAudio = nil
            }
            adoptReplacementAudio(
                loadedAudio,
                reference: loadedAudio == nil ? reference : nil,
                sync: document?.replacementAudioSync
            )
        }
        videoOverlayPlayer.isMuted = true
        videoOverlayPlayer.actionAtItemEnd = .pause
        audioClips = StudioAudioConform.resolvingLanes(audioClips.map { $0.sanitized() })
        videoOverlays = StudioVideoOverlayLane.normalized(videoOverlays)
        await resolveImportedVideoSources()
        await resolveAudioClipSources()
        await resolveVideoOverlaySources()
        guard !isTornDown, !Task.isCancelled else { return }

        if withholdsNewerFormatPreview {
            replaceScreenPlayerItem(nil, observeRedactionFailure: false)
            cameraPlayer.replaceCurrentItem(with: nil)
            videoOverlayPlayer.replaceCurrentItem(with: nil)
            stylePoster = nil
            isLoaded = true
        } else {
            await resolveBackgroundMusic()
            guard !isTornDown, !Task.isCancelled else { return }
            await resolveVoiceIsolation()
            guard !isTornDown, !Task.isCancelled else { return }
            do {
                try rebuildScreenPlayerItem(preserving: 0)
            } catch {
                loadError = "Could not prepare the recording timeline: \(error.localizedDescription)"
                return
            }
            rebuildPointerTimeline()
            rebuildViewportTimeline()
            installObservers()
            isLoaded = true
            rebuildPreviewReframe()
            loadTimelineThumbnails()
            syncImportedThumbnails()
            loadStylePoster()
            loadOverlayMedia()
        }

        if let session {
            openedOnDraft = session.hasUnsavedDraft
            if isReadOnlyNewerFormat {
                hasUnsavedChanges = false
                lastSavedDocument = currentDocument()
            } else if openedOnDraft {
                // Reopened on a draft that outlived its editor.
                hasUnsavedChanges = true
            } else {
                hasUnsavedChanges = false
                // Adopt the loaded document in its normalized in-memory form
                // as the baseline. Defaults filled in during load (an export
                // preset an older project never stored, clips normalized to
                // the real duration) would otherwise read as edits. A new
                // recording's defaults (the default style, zoom cues found
                // in its pointer track) are its baseline too, so opening one
                // saves nothing until it is edited.
                lastSavedDocument = currentDocument()
                if let document, document.isolateVoice != voiceIsolationEnabled {
                    lastSavedDocument?.isolateVoice = document.isolateVoice
                    hasUnsavedChanges = true
                    scheduleProjectSave()
                }
            }
            if !isReadOnlyNewerFormat {
                try? session.updateProjectMetadata { $0.lastOpenedAt = Date() }
            }
        } else {
            // A bare movie has nowhere to save its edits; this baseline only
            // tells the close prompt whether there are any to lose.
            lastSavedDocument = currentDocument()
        }
        openedDocument = currentDocument()
        sessionOpenedAt = Date()
        if let session {
            do { sessionSnapshots = try CaptureSessionSnapshots(directory: session.sessionSnapshotsURL).entries() }
            catch { FailureAlert.present(message: "Session snapshots could not be read", error: error) }
        }
        openedStylePresetID = appliedStylePresetID
        StudioProjectRegistry.shared.register(self)
    }

    /// Copies a stored project onto the model. Shared by the initial load and
    /// by discarding changes, so both routes can never drift apart.
    private func applyDocumentSettings(_ document: RecordingEditDocument) {
        isApplyingDocument = true
        defer { isApplyingDocument = false }

        pause()
        cancelVoiceIsolation()
        voiceIsolationEnabled = document.isolateVoice
        backgroundMusicTask?.cancel()
        backgroundMusicTask = nil
        backgroundMusicSettings = document.backgroundMusic
        voiceIsolationError = nil
        replacementAudioReference = document.replacementAudioFileName.map {
            StudioReplacementReference(fileName: $0, displayName: document.replacementAudioDisplayName)
        }
        replacementAudioSync = document.replacementAudioFileName == nil ? nil : document.replacementAudioSync
        if replacementAudio?.url.lastPathComponent != document.replacementAudioFileName {
            replacementAudio = nil
            audioSources.replacement = []
            audioPeaks[Self.soundtrackPeaksKey] = nil
            audioPeakTasks.removeValue(forKey: Self.soundtrackPeaksKey)?.cancel()
        }
        audioClips = (document.audioClips ?? []).map { $0.sanitized() }
        hiddenLinkedAudio = (document.hiddenLinkedAudio ?? []).map { entry in
            var copy = entry
            copy.clip = entry.clip.sanitized()
            return copy
        }
        soloAudioLane = nil
        if let selectedAudioClipID, !audioClips.contains(where: { $0.id == selectedAudioClipID }) {
            self.selectedAudioClipID = nil
        }
        selectedAudioClipIDs = selectedAudioClipIDs.filter { id in
            audioClips.contains(where: { $0.id == id })
        }
        style = document.style.value
        zoomEnabled = document.zoomEnabled
        zoomCues = studioNormalizedZoomCues(document.zoomCues, sourceDuration: sourceDuration)
        if let selectedCueID, !zoomCues.contains(where: { $0.id == selectedCueID }) {
            self.selectedCueID = nil
        }
        // A project that never chose its own settings inherits whatever
        // was picked last, so "export as MP4" sticks across recordings.
        exportSettings = document.exportSettings ?? RecordingExportPreferences.lastSettings
        if document.exportSettings == nil {
            // Old projects without export settings may inherit quality/codec
            // preferences, but keep their original cadence and blur policy.
            exportSettings.frameRate = nil
            exportSettings.motionBlurEnabled = nil
        }
        showsClickEffects = document.showsClickEffects ?? showsClickEffects
        showsKeystrokes = document.showsKeystrokes ?? true
        showsInk = document.showsInk ?? true
        hiddenInkStrokeIDs = Set(document.hiddenInkStrokeIDs ?? [])
        inkTimeline = RecordingInkTimeline(strokes: pointerCapture.ink, hiding: hiddenInkStrokeIDs)
        markers = (document.markers ?? [])
            .filter { $0.sourceTime.isFinite && $0.sourceTime >= 0 }
            .sorted { $0.sourceTime < $1.sourceTime }
        rangeSelection = nil
        isTrimmingClip = false
        keystrokePlacement = document.keystrokePlacement ?? .bottomCenter
        showsSubtitles = document.showsSubtitles ?? true
        subtitleCues = document.subtitleCues ?? []
        transcriptWords = document.subtitleWords ?? []
        rebuildCaptionTimelines()
        subtitleStyle = document.subtitleStyle
        exportAspect = document.exportAspectPreset
        exportAspectMode = document.exportAspectContentMode
        videoCropRect = document.normalizedVideoCropRect
        if isLoaded, redactions != document.redactions, !document.redactions.isEmpty {
            isPreparingRedactionPreview = true
            stylePoster = nil
            timelineThumbnails.cancel()
        }
        redactions = document.redactions
        if let selectedRedactionID, !redactions.contains(where: { $0.id == selectedRedactionID }) {
            self.selectedRedactionID = nil
        }
        redactionPreview.update(redactions: redactions, clipTimeline: clipTimeline)
        textOverlays = document.textOverlays ?? []
        if let selectedTextID, !textOverlays.contains(where: { $0.id == selectedTextID }) {
            self.selectedTextID = nil
        }
        imageOverlays = document.imageOverlays ?? []
        if let selectedImageID, !imageOverlays.contains(where: { $0.id == selectedImageID }) {
            self.selectedImageID = nil
        }
        videoOverlays = StudioVideoOverlayLane.normalized(document.videoOverlays ?? [])
        if let selectedVideoOverlayID, !videoOverlays.contains(where: { $0.id == selectedVideoOverlayID }) {
            self.selectedVideoOverlayID = nil
        }
        if isLoaded {
            loadOverlayMedia()
            Task { [weak self] in
                await self?.resolveVideoOverlaySources()
                guard let self, !self.isTornDown else { return }
                self.moveVideoOverlayPlayer(to: self.displayTime)
            }
        }
        audioExportFormat = document.audioExportFormatValue
        audioVolume = CGFloat(RecordingAudioGain.normalized(document.audioVolume ?? 1))
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        documentRestoreTask?.cancel()
        documentRestoreTask = nil
        documentRestoreID = nil
        // Persist only a fully loaded document, before releasing its data.
        if isLoaded { writeDraftNow() }
        isLoaded = false
        StudioProjectRegistry.shared.unregister(self)
        exportTask?.cancel()
        playerItemGate.invalidate()
        readyCutPlayerItem = nil
        activeTrimSourcePreviewTime = nil
        trimSourcePreviewError = nil
        cutRedactionPreviewError = nil
        playerItemTask?.cancel()
        playerItemTask = nil
        redactionRefreshTask?.cancel()
        redactionRefreshTask = nil
        pendingRedactionEdit.cancel()
        pendingTextEdit.cancel()
        pendingImageEdit.cancel()
        pendingVideoOverlayEdit.cancel()
        mediaLoadTask?.cancel()
        mediaLoadTask = nil
        videoOverlayImportTask?.cancel()
        videoOverlayImportTask = nil
        videoOverlayImportID = nil
        videoOverlayRenderProgress = nil
        pendingRecordingOverlayImport = nil
        overlayImages.removeAll()
        clearRedactionObservers()
        audioExportTask?.cancel()
        backgroundMusicTask?.cancel()
        backgroundMusicTask = nil
        videoImportTask?.cancel()
        videoImportTask = nil
        pendingRecordingImport = nil
        videoImportProgress = nil
        videoImportTitle = nil
        for source in importedVideoSources.values {
            source.asset.cancelLoading()
        }
        importedVideoSources.removeAll()
        missingVideoClipFiles.removeAll()
        replacementAudioTask?.cancel()
        cancelVoiceIsolation()
        cancelShare()
        transcriptionTask?.cancel()
        projectSaveTask?.cancel()
        autosaveTask?.cancel()
        autosaveTask = nil
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
        if let session, !StudioProjectRegistry.shared.hasLoadedEditor(for: sessionURL) { removeUnusedReplacementAudio(in: session) }
        exportTask = nil
        audioExportTask = nil
        replacementAudioTask = nil
        transcriptionTask = nil
        projectSaveTask = nil
        timelineThumbnails.releaseResources()
        stylePosterTask?.cancel()
        stylePosterTask = nil
        stylePoster = nil
        isPlaying = false
        screenPlayer.pause()
        cameraPlayer.pause()
        if let timeObserver {
            screenPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        screenPlayer.currentItem?.cancelPendingSeeks()
        cameraPlayer.currentItem?.cancelPendingSeeks()
        videoOverlayPlayer.currentItem?.cancelPendingSeeks()
        screenPlayer.replaceCurrentItem(with: nil)
        cameraPlayer.replaceCurrentItem(with: nil)
        clearVideoOverlayPlayer()
        videoOverlays.removeAll()
        selectedVideoOverlayID = nil
        missingVideoOverlayFiles.removeAll()
        screenAsset?.cancelLoading()
        screenAsset = nil
        screenVideoTrack = nil
        canUseSampleCursors = false
        cameraSeek.invalidate()
        lastCameraSegmentID = nil
        isolatedMicrophone = nil
        backgroundMusic = nil
        backgroundMusicSettings = nil
        microphoneTrackID = nil
        microphoneMusicAnalysis = nil
        musicWaveform = []
        playbackMusicTrackID = nil
        replacementAudio = nil
        replacementAudioSync = nil
        replacementAudioReference = nil
        externalPinnedReplacementURLs.removeAll()
        undoReferencedFiles.removeAll()
        soundtrackOffsetTask?.cancel()
        soundtrackOffsetTask = nil
        soundtrackOffsetSnapshot = nil
        audioEditSnapshot = nil
        audioCoalesceTask?.cancel()
        audioCoalesceTask = nil
        clipSoundSnapshot = nil
        clipSoundCoalesceTask?.cancel()
        clipSoundCoalesceTask = nil
        audioPlaybackRebuildTask?.cancel()
        audioPlaybackRebuildTask = nil
        audioSources = StudioAudioSources()
        playbackAudioLayout = StudioAudioLayout()
        playbackAudioPlacement = nil
        audioClips.removeAll()
        hiddenLinkedAudio.removeAll()
        soloAudioLane = nil
        selectedAudioClipID = nil
        selectedAudioClipIDs.removeAll()
        for task in audioPeakTasks.values { task.cancel() }
        audioPeakTasks.removeAll()
        audioPeaks.removeAll()
        missingAudioClipFiles.removeAll()
        editUndoManager.removeAllActions()
        zoomEditSnapshot = nil
        viewportRebuildTask?.cancel()
        viewportRebuildTask = nil
        isDraggingTimelineBlock = false
        endTrimSourcePreview(restoreItem: false)
        isTrimmingClip = false
        rangeSelection = nil
        markers.removeAll()
        lastSavedDocument = nil
        pointerCapture = PointerCaptureFile()
        pointerTimeline = .empty
        keystrokeTimeline = .empty
        inkTimeline = RecordingInkTimeline(strokes: [])
        viewportTimeline = .identity
        previewReframe = nil
        reframeFocusTimeline = nil
        recordedPressTimes.removeAll()
        zoomCues.removeAll()
        subtitleCues.removeAll()
        transcriptWords.removeAll()
        subtitleTimeline = .empty
        karaokeTimeline = .empty
        clipTimeline = RecordingClipTimeline(segments: [])
        compositionTimeMap = nil
        wallpaperCacheLease = nil
    }

    // MARK: - Style presets

    /// A fill shown on the canvas while the pointer rests on it in the
    /// picker. Never saved or exported; picking it writes `style`.
    var previewBackground: AnnotationBackgroundStyle?

    /// Shows or clears a hovered fill. Leaving one fill can arrive after
    /// entering the next, so only the fill being left is cleared.
    func previewBackground(_ background: AnnotationBackgroundStyle, isHovering: Bool) {
        if isHovering {
            previewBackground = background
        } else if previewBackground == background {
            previewBackground = nil
        }
    }

    func applyStylePreset(_ preset: RecordingStudioStylePreset) {
        style = preset.value
        appliedStylePresetID = preset.id
    }

    // MARK: - Playback

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard !isPlaying else { return }
        shuttleRate = 1
        startPlayback()
    }

    private func startPlayback() {
        if endTrimSourcePreview(restoreItem: true) {
            isTrimmingClip = false
            movePlayers(to: currentTime)
        }
        guard !isRestoringDocument, !isEditingSourceRegion, !isPreparingRedactionPreview, redactionPreviewError == nil else {
            shuttleRate = 1
            return
        }
        if hoverPreviewTime != nil {
            hoverPreviewTime = nil
        }
        guard clipTimeline.hasPlayableEditorDuration else {
            shuttleRate = 1
            return
        }
        if shuttleRate > 0, currentTime < 0 || currentTime >= duration - 0.05 {
            seek(to: 0)
        } else if shuttleRate < 0, currentTime <= 0.05 {
            seek(to: duration)
        }
        isPlaying = true
        screenPlayer.rate = shuttleRate
        syncCameraPlayback()
        syncVideoOverlayPlayback()
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        shuttleRate = 1
        cameraSeek.invalidate()
        lastCameraSegmentID = nil
        videoOverlaySeek.invalidate()
        screenPlayer.pause()
        cameraPlayer.pause()
        videoOverlayPlayer.pause()
        moveVideoOverlayPlayer(to: currentTime)
    }

    private static func playbackCapabilities(of item: AVPlayerItem?) -> StudioPlaybackCapabilities {
        guard let item else {
            return StudioPlaybackCapabilities(
                isReady: false,
                canPlayFastForward: false,
                canPlaySlowForward: false,
                canPlayReverse: false,
                canPlaySlowReverse: false,
                canPlayFastReverse: false
            )
        }
        return StudioPlaybackCapabilities(
            isReady: item.status == .readyToPlay,
            canPlayFastForward: item.canPlayFastForward,
            canPlaySlowForward: item.canPlaySlowForward,
            canPlayReverse: item.canPlayReverse,
            canPlaySlowReverse: item.canPlaySlowReverse,
            canPlayFastReverse: item.canPlayFastReverse
        )
    }

    /// J/K/L. Forward plays, and each further press doubles the speed up
    /// to 8×; backward does the same in reverse. Turning around starts
    /// again from normal speed. Respects the current item's readiness and
    /// playback capabilities before publishing or applying a rate.
    func shuttle(forward: Bool) {
        guard isLoaded, !isRestoringDocument, !isEditingSourceRegion, !isPreparingRedactionPreview, redactionPreviewError == nil else { return }
        let capabilities = Self.playbackCapabilities(of: screenPlayer.currentItem)
        let resolution = StudioPlayback.resolveShuttle(
            currentRate: shuttleRate,
            isPlaying: isPlaying,
            forward: forward,
            capabilities: capabilities
        )
        switch resolution {
        case .ignore:
            return
        case .seekStep(let delta, let noticeText):
            pause()
            seek(to: currentTime + delta)
            showNotice(noticeText)
        case .play(let nextRate):
            if isPlaying, shuttleRate * nextRate > 0 {
                if shuttleRate != nextRate {
                    shuttleRate = nextRate
                    screenPlayer.rate = shuttleRate
                    syncCameraPlayback()
                    syncVideoOverlayPlayback()
                }
            } else {
                if isPlaying {
                    screenPlayer.pause()
                    cameraPlayer.pause()
                    videoOverlayPlayer.pause()
                    isPlaying = false
                }
                shuttleRate = nextRate
                startPlayback()
            }
            if isPlaying {
                showNotice(Self.shuttleTitle(shuttleRate))
            }
        }
    }

    /// "2×", "◀ 1×".
    static func shuttleTitle(_ rate: Float) -> String {
        StudioPlayback.shuttleTitle(rate)
    }

    /// Moves the paused playhead by whole video frames on the edited timeline.
    /// Uses native `AVPlayerItem.step(byCount:)` when supported and synchronous,
    /// otherwise steps to the adjacent video sample via `AVSampleCursor` (or
    /// the clip-speed-scaled `frameDuration` fallback when sample timing is
    /// unavailable).
    func stepFrames(_ count: Int) {
        guard count != 0, isLoaded, !isRestoringDocument, !isEditingSourceRegion else { return }
        pause()
        if hoverPreviewTime != nil {
            hoverPreviewTime = nil
        }
        if let item = screenPlayer.currentItem,
           item.status == .readyToPlay,
           (count > 0 ? item.canStepForward : item.canStepBackward) {
            let before = item.currentTime().seconds
            item.step(byCount: count)
            let after = item.currentTime().seconds
            let moved = before.isFinite && after.isFinite
                && ((count > 0 && after > before + 1e-5) || (count < 0 && after < before - 1e-5))
            let atBoundary = after.isFinite
                && ((count > 0 && currentTime >= duration - 1e-4) || (count < 0 && currentTime <= 1e-4))
            if moved || atBoundary {
                let clamped = min(max(after, 0), max(duration, 0))
                currentTime = clamped
                updateActiveTranscriptWord()
                moveCameraPlayer(to: clamped)
                moveVideoOverlayPlayer(to: clamped)
                return
            }
        }
        let target = StudioPlayback.steppedEditorTime(
            from: currentTime,
            frames: count,
            timeline: clipTimeline,
            frameDuration: frameDuration,
            duration: duration,
            sampleNeighborhood: (canUseSampleCursors && isPrimaryRecording(at: currentTime)) ? { [weak self] sourceTime in
                self?.sampleNeighborhood(at: sourceTime)
            } : nil
        )
        seek(to: target)
    }

    private func sampleNeighborhood(at sourceTime: TimeInterval) -> StudioSampleNeighborhood? {
        guard let screenVideoTrack else { return nil }
        let query = CMTime(seconds: max(0, sourceTime), preferredTimescale: StudioPlayback.seekTimescale)
        guard let cursor = screenVideoTrack.makeSampleCursor(presentationTimeStamp: query) else {
            return nil
        }
        let epsilon: TimeInterval = 1e-5
        var current = cursor.presentationTimeStamp.seconds
        guard current.isFinite else { return nil }

        // Ensure cursor sits on the displayed sample (latest sample <= sourceTime + epsilon).
        if current > sourceTime + epsilon {
            var movedBack = false
            while cursor.stepInPresentationOrder(byCount: -1) == -1 {
                movedBack = true
                let candidate = cursor.presentationTimeStamp.seconds
                guard candidate.isFinite else { return nil }
                current = candidate
                if current <= sourceTime + epsilon { break }
            }
            if !movedBack || current > sourceTime + epsilon {
                // `sourceTime` precedes the track's first sample.
                return StudioSampleNeighborhood(displayed: nil, previous: nil, next: current)
            }
        } else {
            while cursor.stepInPresentationOrder(byCount: 1) == 1 {
                let candidate = cursor.presentationTimeStamp.seconds
                guard candidate.isFinite else { return nil }
                if candidate > sourceTime + epsilon {
                    _ = cursor.stepInPresentationOrder(byCount: -1)
                    break
                }
                current = candidate
            }
        }

        let displayed = current
        var next: TimeInterval?
        if cursor.stepInPresentationOrder(byCount: 1) == 1 {
            let candidate = cursor.presentationTimeStamp.seconds
            if candidate.isFinite, candidate > displayed + epsilon {
                next = candidate
            }
            _ = cursor.stepInPresentationOrder(byCount: -1)
        }
        var previous: TimeInterval?
        if cursor.stepInPresentationOrder(byCount: -1) == -1 {
            let candidate = cursor.presentationTimeStamp.seconds
            if candidate.isFinite, candidate < displayed - epsilon {
                previous = candidate
            }
        }
        return StudioSampleNeighborhood(displayed: displayed, previous: previous, next: next)
    }

    /// Shows a word over the picture for a moment.
    func showNotice(_ text: String) {
        notice = StudioNotice(text: text)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, 0), max(duration, 0))
        currentTime = clamped
        updateActiveTranscriptWord()
        movePlayers(to: clamped)
        if isPlaying {
            syncCameraPlayback()
            syncVideoOverlayPlayback()
        }
    }

    /// Moves both players to a source time without touching `currentTime`,
    /// so hover skimming can preview a frame and cleanly hand back to the
    /// real playhead position afterward.
    private func movePlayers(to time: TimeInterval) {
        let editorTime = min(max(time, 0), max(duration, 0))
        let target = CMTime(seconds: editorTime, preferredTimescale: StudioPlayback.seekTimescale)
        screenPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        moveCameraPlayer(to: editorTime)
        moveVideoOverlayPlayer(to: editorTime)
    }

    private func moveCameraPlayer(to editorTime: TimeInterval) {
        guard hasCameraVideo else { return }
        cameraSeek.invalidate()
        let location = clipTimeline.location(at: editorTime)
        lastCameraSegmentID = location?.segmentID
        guard let location, clipTimeline.segments[location.segmentIndex].isPrimaryRecording else {
            cameraPlayer.pause()
            return
        }
        let sourceTime = location.sourceTime
        if sourceTime >= cameraOffset {
            let cameraTime = CMTime(seconds: max(0, sourceTime - cameraOffset), preferredTimescale: StudioPlayback.seekTimescale)
            cameraPlayer.seek(to: cameraTime, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            cameraPlayer.pause()
            cameraPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Time the preview canvas should render right now.
    var displayTime: TimeInterval {
        if isPlaying {
            let time = screenPlayer.currentTime().seconds
            return time.isFinite ? time : currentTime
        }
        return hoverPreviewTime ?? currentTime
    }

    private func handlePlaybackBoundary(_ trigger: StudioPlaybackEndTrigger) -> Bool {
        var state = StudioPlaybackBoundaryState(
            isPlaying: isPlaying,
            shuttleRate: shuttleRate,
            currentTime: currentTime
        )
        guard let endpoint = StudioPlayback.resolvePlaybackEnd(
            state: &state,
            trigger: trigger,
            duration: duration
        ) else { return false }
        pause()
        seek(to: endpoint)
        return true
    }

    private func installObservers() {
        timeObserver = screenPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.02, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isPlaying {
                    let seconds = time.seconds
                    if self.handlePlaybackBoundary(.periodic(seconds: seconds)) {
                        return
                    }
                    self.currentTime = seconds
                    self.updateActiveTranscriptWord()
                    self.correctCameraDriftIfNeeded()
                    self.correctVideoOverlayDriftIfNeeded()
                }
            }
        }

        installEndObserver()
    }

    private func installEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: screenPlayer.currentItem,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let item = notification.object as? AVPlayerItem else { return }
                let isCurrentItem = item === self.screenPlayer.currentItem
                let itemTime = item.currentTime()
                let itemSeconds = itemTime.isNumeric ? itemTime.seconds : nil
                let reverseEnd = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime.seconds : 0
                let forwardEnd = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime.seconds : self.duration
                _ = self.handlePlaybackBoundary(
                    .itemDidPlayToEnd(
                        isCurrentItem: isCurrentItem,
                        itemSeconds: itemSeconds,
                        reverseEnd: reverseEnd,
                        forwardEnd: forwardEnd
                    )
                )
            }
        }
    }

    // MARK: - Clips

    private enum PendingOverlayKind { case text, image, videoOverlay, redaction }

    private var hasPendingOverlayEdit: Bool {
        pendingTextEdit.isDirty(current: textOverlays)
            || pendingImageEdit.isDirty(current: imageOverlays)
            || pendingVideoOverlayEdit.isDirty(current: videoOverlays)
            || pendingRedactionEdit.isDirty(current: redactions)
    }

    private func commitPendingOverlayEdits(excluding excluded: PendingOverlayKind? = nil) {
        if excluded != .text, pendingTextEdit.isActive {
            endTextEdit()
        }
        if excluded != .image, pendingImageEdit.isActive {
            endImageEdit()
        }
        if excluded != .videoOverlay, pendingVideoOverlayEdit.isActive {
            endVideoOverlayEdit()
        }
        if excluded != .redaction, pendingRedactionEdit.isActive {
            endRedactionEdit()
        }
    }

    var canUndo: Bool {
        _ = undoRevision
        return !isRestoringDocument
            && backgroundMusicTask == nil
            && (editUndoManager.canUndo
                || (musicSliderBaseline != nil && musicSliderBaseline != backgroundMusicSettings)
                || hasPendingOverlayEdit)
    }

    var canRedo: Bool {
        _ = undoRevision
        return !isRestoringDocument && backgroundMusicTask == nil && editUndoManager.canRedo
    }

    var selectedClip: RecordingClipSegment? {
        guard let selectedClipID else { return nil }
        return clipTimeline.segments.first { $0.id == selectedClipID }
    }

    var hasClipEdits: Bool {
        !clipTimeline.isUnedited(sourceDuration: sourceDuration)
    }

    var canDeleteSelectedClip: Bool {
        selectedClipID != nil && clipTimeline.segments.count > 1
    }

    private var activeTimelineSelection: StudioTimelineSelection? {
        if let selectedTextID { return .text(selectedTextID) }
        if let selectedImageID { return .image(selectedImageID) }
        if let selectedVideoOverlayID { return .videoOverlay(selectedVideoOverlayID) }
        if let selectedRedactionID { return .redaction(selectedRedactionID) }
        if let selectedAudioClipID { return .audioClip(selectedAudioClipID) }
        if let selectedCueID { return .zoomCue(selectedCueID) }
        if let selectedClipID { return .clip(selectedClipID) }
        return nil
    }

    var hasDeletableTimelineSelection: Bool {
        StudioEditing.deleteTarget(
            selection: activeTimelineSelection,
            canDeleteClip: canDeleteSelectedClip,
            hasRangeSelection: false
        ) != nil
    }

    var canDeleteSelection: Bool {
        StudioEditing.deleteTarget(
            selection: activeTimelineSelection,
            canDeleteClip: canDeleteSelectedClip,
            hasRangeSelection: rangeSelection != nil
        ) != nil
    }

    /// Shared Delete action used by both keyboard shortcuts (⌫/⌦) and the
    /// timeline toolbar trash button.
    func deleteSelection() {
        guard let target = StudioEditing.deleteTarget(
            selection: activeTimelineSelection,
            canDeleteClip: canDeleteSelectedClip,
            hasRangeSelection: rangeSelection != nil
        ) else { return }
        switch target {
        case .text(let id):
            removeText(id: id)
        case .image(let id):
            removeImage(id: id)
        case .videoOverlay(let id):
            removeVideoOverlay(id: id)
        case .redaction(let id):
            removeRedaction(id: id)
        case .audioClip(let id):
            removeAudioClip(id: id)
        case .zoomCue(let id):
            removeZoomCue(id: id)
        case .clip:
            deleteSelectedClip()
        case .range:
            deleteRange()
        }
    }

    var canMoveSelectedClipEarlier: Bool {
        guard let selectedClipID,
              let index = clipTimeline.segments.firstIndex(where: { $0.id == selectedClipID }) else {
            return false
        }
        return index > 0
    }

    var canMoveSelectedClipLater: Bool {
        guard let selectedClipID,
              let index = clipTimeline.segments.firstIndex(where: { $0.id == selectedClipID }) else {
            return false
        }
        return index + 1 < clipTimeline.segments.count
    }

    func moveSelectedClip(by offset: Int) {
        guard let selectedClipID,
              let index = clipTimeline.segments.firstIndex(where: { $0.id == selectedClipID }) else {
            return
        }
        moveClip(id: selectedClipID, to: index + offset)
    }

    // MARK: - Range, markers, snapping & navigation

    func toggleSnapping() {
        snapsEdits.toggle()
        showNotice(snapsEdits ? "Snapping On" : "Snapping Off")
    }

    /// Static editor times a trimmed video edge can catch on: markers, recorded
    /// clicks, and audio clip edges. The clip strip adds its own `playheadTime`
    /// during a drag so reading this never pulls the timeline dock into the
    /// 20 ms playback tick.
    var clipSnapPoints: [TimeInterval] {
        StudioEditing.clipSnapPoints(
            markers: markerEditorTimes.map(\.time),
            recordedClicks: visibleRecordedPressTimes,
            audioClipEdges: audioClips.flatMap { [$0.start, $0.end] },
            videoOverlayEdges: videoOverlays.flatMap { [$0.start, $0.end] }
        )
    }

    /// Every moment worth stopping at with ↑/↓: video cuts, markers, video
    /// overlay edges, and audio edges.
    var editPoints: [TimeInterval] {
        StudioEditing.editPoints(
            timeline: clipTimeline,
            markerTimes: markerEditorTimes.map(\.time),
            audioClipEdges: audioClips.flatMap { [$0.start, $0.end] },
            videoOverlayEdges: videoOverlays.flatMap { [$0.start, $0.end] },
            duration: duration
        )
    }

    /// Jumps the playhead to the previous or next cut or marker.
    func seekToEditPoint(forward: Bool) {
        guard isLoaded, !isRestoringDocument, !isEditingSourceRegion else { return }
        let target = StudioEditing.nextEditPoint(
            from: currentTime,
            in: editPoints,
            duration: duration,
            forward: forward
        )
        pause()
        seek(to: target)
    }

    /// I and O: mark where the ripple-delete range starts or ends.
    func markRange(_ edge: StudioRangeEdge) {
        guard isLoaded, !isRestoringDocument, !isEditingSourceRegion, duration > 0 else { return }
        clearTimelineSelection()
        rangeSelection = StudioEditing.markedRange(
            current: rangeSelection,
            edge: edge,
            at: currentTime,
            duration: duration
        )
    }

    func clearRange() {
        rangeSelection = nil
    }

    /// Ripple-deletes the marked editor range, closing up everything after it.
    func deleteRange() {
        guard isLoaded, !isRestoringDocument, !isEditingSourceRegion, let range = rangeSelection else { return }
        switch clipTimeline.removeEditorRange(range) {
        case .emptyRange:
            showNotice("Mark a range to delete")
        case .removesEntireVideo:
            showNotice("Can't remove the whole video")
        case .leavesShortClip:
            showNotice("Remaining clip would be too short")
        case .removed(let candidate):
            guard let committed = candidate.validatedForCommit(sourceDuration: sourceDuration) else {
                showNotice("Remaining clip would be too short")
                return
            }
            rangeSelection = nil
            applyClipTimeline(
                committed,
                selectedID: nil,
                selectsClip: false,
                playheadTime: range.lowerBound,
                actionName: "Delete Range"
            )
        }
    }

    /// Markers that still have surviving footage in the cut, in playback order.
    var markerEditorTimes: [(marker: RecordingMarker, time: TimeInterval)] {
        StudioEditing.markerEditorTimes(markers, in: clipTimeline)
    }

    /// M: drops a marker at the playhead, or removes an existing one there.
    func toggleMarker() {
        guard isLoaded, !isRestoringDocument, !isEditingSourceRegion else { return }
        let tolerance = max(frameDuration, StudioEditing.markerToggleToleranceMinimum)
        if let existing = markerEditorTimes.first(where: { abs($0.time - currentTime) <= tolerance }) {
            applyMarkers(markers.filter { $0.id != existing.marker.id }, actionName: "Remove Marker")
            showNotice("Marker Removed")
        } else {
            let anchor = StudioEditing.markerAnchor(at: currentTime, in: clipTimeline)
            let marker = RecordingMarker(
                sourceTime: anchor.sourceTime,
                mediaFileName: anchor.mediaFileName,
                clipOccurrenceID: anchor.clipOccurrenceID
            )
            applyMarkers(markers + [marker], actionName: "Add Marker")
            showNotice("Marker")
        }
    }

    func removeMarker(id: UUID) {
        applyMarkers(markers.filter { $0.id != id }, actionName: "Remove Marker")
    }

    private func applyMarkers(_ next: [RecordingMarker], actionName: String) {
        let sorted = next.sorted { $0.sourceTime < $1.sourceTime }
        guard sorted != markers else { return }
        let previous = markers
        registerUndo(actionName) { target in
            target.applyMarkers(previous, actionName: actionName)
        }
        markers = sorted
        scheduleProjectSave()
    }

    /// Puts a clip at another position in the clip list. Zoom and pointer
    /// timelines snap across cuts that jump backward in source time.
    func moveClip(id: UUID, to index: Int) {
        guard isLoaded, !isRestoringDocument, !isEditingSourceRegion,
              let next = clipTimeline.moving(segmentID: id, to: index) else {
            return
        }
        let playhead = next.editorRange(for: id)?.lowerBound ?? currentTime
        applyClipTimeline(
            next,
            selectedID: id,
            playheadTime: playhead,
            actionName: "Move Clip"
        )
    }

    /// Live trim preview for either a primary or imported clip.
    func previewClipTrim(clipID: UUID, sourceTime: TimeInterval?) {
        guard let sourceTime else {
            previewSourceTime(nil)
            return
        }
        guard isLoaded,
              let segment = clipTimeline.segments.first(where: { $0.id == clipID }) else { return }
        if segment.isPrimaryRecording {
            previewSourceTime(sourceTime)
            return
        }
        guard let editorRange = clipTimeline.editorRange(for: clipID) else { return }
        pause()
        isTrimmingClip = true
        if !playerItemGate.isShowingSourcePreview,
           sourceTime >= segment.sourceStart - 0.000_5,
           sourceTime <= segment.sourceEnd + 0.000_5 {
            let clamped = min(max(sourceTime, segment.sourceStart), segment.sourceEnd)
            hoverPreviewTime = editorRange.lowerBound + (clamped - segment.sourceStart) / max(segment.speed, 1)
            return
        }
        guard let fileName = segment.mediaFileName,
              let imported = importedVideoSources[fileName],
              playerItemGate.isCutReady,
              readyCutPlayerItem != nil else { return }
        let clampedSource = min(max(sourceTime, 0), imported.duration)
        activeTrimSourcePreviewTime = clampedSource
        hoverPreviewTime = clampedSource < segment.sourceStart ? editorRange.lowerBound : editorRange.upperBound
        if !playerItemGate.isShowingSourcePreview,
           playerItemGate.beginSourcePreview(isAsync: false) != nil {
            playerItemTask?.cancel()
            playerItemTask = nil
            let item = AVPlayerItem(asset: imported.asset)
            item.videoComposition = RecordingCompositionBuilder.makeSingleSourcePreviewComposition(
                source: imported,
                contentMode: segment.effectiveContentMode,
                renderSize: videoSize,
                targetRect: multiSourceTargetRect
            )
            replaceScreenPlayerItem(item, observeRedactionFailure: false)
        }
        let target = CMTime(seconds: clampedSource, preferredTimescale: StudioPlayback.seekTimescale)
        screenPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        if hasCameraVideo { cameraPlayer.pause() }
    }

    /// Shows the exact recording frame at the edge being trimmed; `nil` hands
    /// the preview back to the playhead. Extending an edge into previously cut
    /// footage temporarily previews the source asset (with source-clock
    /// redactions applied) once a ready cut item exists, and restores that cut
    /// item on release.
    func previewSourceTime(_ time: TimeInterval?) {
        guard let time else {
            let restored = endTrimSourcePreview(restoreItem: true)
            isTrimmingClip = false
            hoverPreviewTime = nil
            if restored, isLoaded, duration > 0, !isPlaying {
                movePlayers(to: currentTime)
            }
            return
        }
        guard isLoaded,
              let target = StudioEditing.trimPreviewTarget(
                  forSourceTime: time,
                  in: clipTimeline,
                  sourceDuration: sourceDuration,
                  usingSourceAsset: playerItemGate.isShowingSourcePreview,
                  hasReadyCutItem: playerItemGate.isCutReady && readyCutPlayerItem != nil
              ) else { return }
        pause()
        isTrimmingClip = true

        switch target {
        case .editedTime(let editor):
            hoverPreviewTime = editor
        case .sourceTime(let source):
            activeTrimSourcePreviewTime = source
            hoverPreviewTime = nearestEditorTime(forSourceTime: source) ?? currentTime
            beginTrimSourcePreviewIfNeeded()
            if playerItemTask == nil {
                seekSourcePreviewPlayers(to: source)
            }
        }
    }

    private func beginTrimSourcePreviewIfNeeded() {
        guard !playerItemGate.isShowingSourcePreview,
              let screenAsset,
              let generation = playerItemGate.beginSourcePreview(isAsync: !redactions.isEmpty) else {
            return
        }
        playerItemTask?.cancel()
        playerItemTask = nil
        let item = AVPlayerItem(asset: screenAsset)
        if redactions.isEmpty {
            replaceScreenPlayerItem(item, observeRedactionFailure: false)
            return
        }
        // Never expose an unmasked source frame while redactions build.
        trimSourcePreviewError = nil
        isPreparingRedactionPreview = true
        replaceScreenPlayerItem(nil, observeRedactionFailure: false)
        let regions = redactions
        playerItemTask = Task { [weak self] in
            do {
                item.videoComposition = try await RecordingRedactionFilter.composition(
                    asset: screenAsset,
                    redactions: regions,
                    timeline: nil
                )
                guard let self, !Task.isCancelled, !self.isTornDown,
                      self.playerItemGate.finishSourcePreview(generation: generation) else { return }
                self.playerItemTask = nil
                self.replaceScreenPlayerItem(item, observeRedactionFailure: true)
                self.isPreparingRedactionPreview = false
                if let source = self.activeTrimSourcePreviewTime {
                    self.seekSourcePreviewPlayers(to: source)
                }
            } catch {
                guard let self, !Task.isCancelled,
                      self.playerItemGate.finishSourcePreview(generation: generation) else { return }
                self.playerItemTask = nil
                self.isPreparingRedactionPreview = false
                self.trimSourcePreviewError = error.localizedDescription
            }
        }
    }

    @discardableResult
    private func endTrimSourcePreview(restoreItem: Bool) -> Bool {
        activeTrimSourcePreviewTime = nil
        trimSourcePreviewError = nil
        let shouldRestore = playerItemGate.endSourcePreview()
        guard shouldRestore else { return false }
        playerItemTask?.cancel()
        playerItemTask = nil
        guard restoreItem, let saved = readyCutPlayerItem else { return false }
        isPreparingRedactionPreview = false
        replaceScreenPlayerItem(saved, observeRedactionFailure: !redactions.isEmpty)
        if timeObserver != nil {
            installEndObserver()
        }
        return true
    }

    private func clearRedactionObservers() {
        if let redactionFailureObserver { NotificationCenter.default.removeObserver(redactionFailureObserver) }
        redactionFailureObserver = nil
        redactionStatusObserver = nil
    }

    /// Single owner for replacing `screenPlayer.currentItem` and wiring/clearing
    /// redaction failure observers so cut rebuilds and source previews cannot race.
    private func replaceScreenPlayerItem(_ item: AVPlayerItem?, observeRedactionFailure: Bool) {
        clearRedactionObservers()
        if let item, observeRedactionFailure {
            redactionFailureObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self, weak item] _ in
                MainActor.assumeIsolated {
                    guard let self, let item, self.screenPlayer.currentItem === item else { return }
                    self.coverFailedRedactionPreview()
                }
            }
            redactionStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.screenPlayer.currentItem === item else { return }
                    self.coverFailedRedactionPreview()
                }
            }
        }
        screenPlayer.replaceCurrentItem(with: item)
    }

    private func seekSourcePreviewPlayers(to sourceTime: TimeInterval) {
        let target = CMTime(seconds: max(0, sourceTime), preferredTimescale: StudioPlayback.seekTimescale)
        screenPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        guard hasCameraVideo else { return }
        cameraSeek.invalidate()
        if sourceTime >= cameraOffset {
            let cameraTime = CMTime(
                seconds: max(0, sourceTime - cameraOffset),
                preferredTimescale: StudioPlayback.seekTimescale
            )
            cameraPlayer.seek(to: cameraTime, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            cameraPlayer.pause()
            cameraPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func nearestEditorTime(forSourceTime sourceTime: TimeInterval) -> TimeInterval? {
        guard sourceTime.isFinite, !clipTimeline.segments.isEmpty else { return nil }
        var bestDistance = TimeInterval.greatestFiniteMagnitude
        var bestEditorTime: TimeInterval?
        var editorStart: TimeInterval = 0
        for segment in clipTimeline.segments {
            let editorEnd = editorStart + segment.editorDuration
            let startDistance = abs(sourceTime - segment.sourceStart)
            if startDistance < bestDistance {
                bestDistance = startDistance
                bestEditorTime = editorStart
            }
            let endDistance = abs(sourceTime - segment.sourceEnd)
            if endDistance < bestDistance {
                bestDistance = endDistance
                bestEditorTime = editorEnd
            }
            editorStart = editorEnd
        }
        return bestEditorTime
    }

    func selectClip(id: UUID) {
        guard clipTimeline.segments.contains(where: { $0.id == id }) else { return }
        clearTimelineSelection()
        selectedClipID = id
    }

    func selectZoomCue(id: UUID) {
        guard zoomCues.contains(where: { $0.id == id }) else { return }
        clearTimelineSelection()
        selectedCueID = id
    }

    /// Lets go of whatever is selected on the timeline, like clicking empty
    /// canvas.
    func clearTimelineSelection() {
        selectedCueID = nil
        selectedClipID = nil
        selectedAudioClipID = nil
        selectedTextID = nil
        selectedImageID = nil
        selectedVideoOverlayID = nil
        selectedRedactionID = nil
    }

    func undo() {
        guard !isRestoringDocument, backgroundMusicTask == nil else { return }
        setMusicSliderEditing(false)
        flushPendingAudioEdits()
        commitPendingOverlayEdits()
        guard editUndoManager.canUndo else { return }
        pause()
        editUndoManager.undo()
        undoRevision &+= 1
    }

    func redo() {
        guard !isRestoringDocument, backgroundMusicTask == nil else { return }
        setMusicSliderEditing(false)
        flushPendingAudioEdits()
        commitPendingOverlayEdits()
        guard editUndoManager.canRedo else { return }
        pause()
        editUndoManager.redo()
        undoRevision &+= 1
    }

    func splitClip(at editorTime: TimeInterval) {
        guard let result = clipTimeline.split(at: editorTime) else { return }
        applyClipTimeline(
            result.timeline,
            selectedID: result.selectedID,
            playheadTime: min(max(editorTime, 0), duration),
            actionName: "Split Clip"
        )
    }

    func deleteSelectedClip() {
        guard let selectedClipID,
              let deletedRange = clipTimeline.editorRange(for: selectedClipID),
              let next = clipTimeline.deleting(segmentID: selectedClipID) else {
            return
        }
        let seekTime = min(deletedRange.lowerBound, next.duration)
        let nextSelection = next.location(at: seekTime)?.segmentID
            ?? next.segments.last?.id
        applyClipTimeline(
            next,
            selectedID: nextSelection,
            playheadTime: seekTime,
            actionName: "Delete Clip"
        )
    }

    func trimClip(_ replacement: RecordingClipSegment) {
        guard let next = clipTimeline.replacingAndValidating(replacement, sourceDuration: sourceDuration),
              next != clipTimeline else { return }
        let editorTime = next.editorRange(for: replacement.id)?.lowerBound ?? currentTime
        applyClipTimeline(
            next,
            selectedID: replacement.id,
            playheadTime: min(currentTime, next.duration),
            actionName: "Trim Clip",
            hoverTime: editorTime
        )
    }

    func setClipSpeed(_ speed: Double, forClipID id: UUID) {
        guard let segment = clipTimeline.segments.first(where: { $0.id == id }) else { return }
        let clamped = min(max(speed, RecordingClipSegment.minimumSpeed), RecordingClipSegment.maximumSpeed)
        guard abs(segment.speed - clamped) > 0.000_001 else { return }
        var replacement = segment
        replacement.speed = clamped
        let next = clipTimeline.replacing(replacement)
        applyClipTimeline(
            next,
            selectedID: id,
            playheadTime: min(currentTime, next.duration),
            actionName: "Change Clip Speed"
        )
    }

    /// Switches an imported clip between Fit (letterboxed) and Fill (center-cropped).
    func setClipContentMode(_ mode: VideoClipContentMode, forClipID id: UUID) {
        guard var segment = clipTimeline.segments.first(where: { $0.id == id }),
              !segment.isPrimaryRecording,
              segment.effectiveContentMode != mode else { return }
        segment.contentMode = mode
        let previous = clipTimeline
        let next = clipTimeline.replacing(segment)
        applyClipFraming(next, previous: previous, actionName: "Change Clip Framing")
    }

    private func applyClipFraming(
        _ next: RecordingClipTimeline,
        previous: RecordingClipTimeline,
        actionName: String
    ) {
        guard next != clipTimeline else { return }
        registerUndo(actionName) { target in
            target.applyClipFraming(previous, previous: next, actionName: actionName)
        }
        clipTimeline = next
        do {
            try rebuildScreenPlayerItem(preserving: currentTime)
        } catch {
            loadError = "Could not update the recording timeline: \(error.localizedDescription)"
        }
        scheduleProjectSave()
    }

    /// Sets one clip's own audio level (0...2). Coalesces slider drags into
    /// one undo step and updates only the audio mix without rebuilding playback.
    func setClipVolume(_ volume: Double, forClipID id: UUID) {
        guard let segment = clipTimeline.segments.first(where: { $0.id == id }) else { return }
        let clamped = min(max(volume.isFinite ? volume : 1, RecordingClipSegment.volumeRange.lowerBound),
                          RecordingClipSegment.volumeRange.upperBound)
        guard abs(segment.volume - clamped) > 0.000_1 else { return }
        if clipSoundSnapshot == nil { clipSoundSnapshot = clipTimeline }
        var replacement = segment
        replacement.volume = clamped
        clipTimeline = clipTimeline.replacing(replacement)
        updatePlaybackVolume()
        scheduleProjectSave()
        clipSoundCoalesceTask?.cancel()
        clipSoundCoalesceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.endClipSoundEdit(actionName: "Change Clip Volume")
        }
    }

    private func endClipSoundEdit(actionName: String) {
        clipSoundCoalesceTask?.cancel()
        clipSoundCoalesceTask = nil
        guard let previous = clipSoundSnapshot else { return }
        clipSoundSnapshot = nil
        guard previous != clipTimeline else { return }
        let current = clipTimeline
        registerUndo(actionName) { target in
            target.restoreClipSound(previous, redoing: current, actionName: actionName)
        }
    }

    private func restoreClipSound(
        _ timeline: RecordingClipTimeline,
        redoing other: RecordingClipTimeline,
        actionName: String
    ) {
        registerUndo(actionName) { target in
            target.restoreClipSound(other, redoing: timeline, actionName: actionName)
        }
        clipTimeline = timeline
        updatePlaybackVolume()
        scheduleProjectSave()
    }

    func toggleClipMuted(id: UUID) {
        guard var segment = clipTimeline.segments.first(where: { $0.id == id }) else { return }
        flushPendingAudioEdits()
        segment.isMuted.toggle()
        let previous = clipTimeline
        let next = clipTimeline.replacing(segment)
        clipTimeline = next
        updatePlaybackVolume()
        scheduleProjectSave()
        let actionName = segment.isMuted ? "Mute Clip" : "Unmute Clip"
        registerUndo(actionName) { target in
            target.restoreClipSound(previous, redoing: next, actionName: actionName)
        }
        showNotice(segment.isMuted ? "Clip Muted" : "Clip Unmuted")
    }

    /// True when this clip carries its own audible source tracks (the primary
    /// recording's audio or soundtrack for primary clips; the imported file's
    /// own audio tracks for imported clips).
    func clipHasOwnAudio(_ segment: RecordingClipSegment) -> Bool {
        if segment.isPrimaryRecording {
            return hasRecordedAudio || replacementAudio != nil
        }
        guard let fileName = segment.mediaFileName else { return false }
        return !(audioSources.files[fileName]?.isEmpty ?? true)
    }

    /// True when the clip still plays its own sound, so there is something
    /// to detach.
    func canDetachAudio(fromClipID id: UUID) -> Bool {
        guard let segment = clipTimeline.segments.first(where: { $0.id == id }) else { return false }
        return !segment.isMuted && clipHasOwnAudio(segment)
    }

    /// Lifts a clip's own sound off its picture onto an audio lane, where
    /// it can be trimmed, moved, split and faded on its own. The new audio
    /// clip stays linked to the video, so later cuts still cut both; the
    /// clip's own sound is muted in its place.
    func detachAudio(fromClipID id: UUID) {
        guard canDetachAudio(fromClipID: id),
              let index = clipTimeline.segments.firstIndex(where: { $0.id == id }),
              let editorRange = clipTimeline.editorRange(for: id) else { return }
        flushPendingAudioEdits()
        var segment = clipTimeline.segments[index]
        let lane = (audioClips.map(\.lane).max() ?? -1) + 1
        let pinnedFileName = replacementAudio.map { pinnedReplacementKey(for: $0.url) } ?? ""
        let hasImportedAudio = !segment.isPrimaryRecording && clipHasOwnAudio(segment)

        guard let detached = StudioAudioComposer.detachedClips(
            for: segment,
            editorStart: editorRange.lowerBound,
            editorEnd: editorRange.upperBound,
            projectVolume: Double(audioVolume),
            sync: replacementAudio == nil ? nil : replacementAudioSync,
            replacementFileName: pinnedFileName.isEmpty ? nil : pinnedFileName,
            replacementDisplayName: replacementAudio?.displayName,
            replacementDuration: replacementAudio?.duration ?? 0,
            recordingDisplayName: "\(projectDisplayName) audio",
            sourceDuration: sourceDuration,
            hasRecording: hasRecordedAudio,
            hasImportedAudio: hasImportedAudio,
            lane: lane
        ) else { return }

        if let fileName = segment.mediaFileName {
            undoReferencedFiles.insert(fileName)
            if let directory = mediaDirectoryURL,
               let url = RecordingOverlayMedia.resolveRegularFile(named: fileName, in: directory) {
                loadPeaks(for: fileName, url: url)
            }
        }
        if let replacementAudio, !pinnedFileName.isEmpty,
           detached.contains(where: { $0.source == .replacement }) {
            if session == nil {
                externalPinnedReplacementURLs[pinnedFileName] = replacementAudio.url
            }
            audioSources.pinnedReplacements[pinnedFileName] = [
                StudioAudioSources.Track(track: replacementAudio.track, range: replacementAudio.range, asset: replacementAudio.asset)
            ]
            if let existingPeaks = audioPeaks[Self.soundtrackPeaksKey] {
                audioPeaks[pinnedFileName] = existingPeaks
            } else {
                loadPeaks(for: pinnedFileName, url: replacementAudio.url)
            }
            undoReferencedFiles.insert(pinnedFileName)
        }

        segment.isMuted = true
        clearTimelineSelection()
        applyClipTimeline(
            clipTimeline.replacing(segment),
            audio: audioClips + detached,
            selectedID: nil,
            selectsClip: false,
            playheadTime: currentTime,
            actionName: "Detach Audio"
        )
        selectedAudioClipID = detached.first?.id
    }

    func resetClips() {
        let full = RecordingClipTimeline.full(sourceDuration: sourceDuration)
        guard full != clipTimeline else { return }
        let keepSelection = selectedClipID != nil
        applyClipTimeline(
            full,
            selectedID: keepSelection ? full.segments.first?.id : nil,
            selectsClip: keepSelection,
            playheadTime: 0,
            actionName: "Reset Clips"
        )
    }

    /// Single choke point for every structural edit to `clipTimeline`.
    /// Updates clips, selection, motion timelines, playback, and undo together.
    /// Linked-audio conform hooks in here so audio follows every cut, trim,
    /// ripple delete, and reorder.
    private func applyClipTimeline(
        _ requestedTimeline: RecordingClipTimeline,
        audio requestedAudio: [RecordingAudioClip]? = nil,
        hidden requestedHidden: [StudioAudioConform.HiddenLinkedRange]? = nil,
        solo requestedSolo: Int?? = nil,
        videoOverlays requestedVideoOverlays: [RecordingVideoOverlay]? = nil,
        selectedID: UUID?,
        selectsClip: Bool = true,
        playheadTime: TimeInterval,
        actionName: String,
        hoverTime: TimeInterval? = nil
    ) {
        flushPendingAudioEdits()
        guard let next = requestedTimeline.validatedForCommit(sourceDuration: sourceDuration) else { return }
        let nextAudio: [RecordingAudioClip]
        let nextHidden: [StudioAudioConform.HiddenLinkedRange]
        if let requestedAudio {
            nextAudio = StudioAudioConform.resolvingLanes(requestedAudio)
            nextHidden = requestedHidden ?? hiddenLinkedAudio
        } else {
            let conformed = StudioAudioConform.conform(audioClips, hidden: hiddenLinkedAudio, from: clipTimeline, to: next)
            nextAudio = conformed.clips
            nextHidden = conformed.hidden
        }
        let nextVideoOverlays = requestedVideoOverlays.map {
            StudioVideoOverlayLane.normalized($0, timelineDuration: next.duration)
        } ?? StudioVideoOverlayLane.conform(videoOverlays, from: clipTimeline, to: next)
        let nextSolo = StudioAudioLaneSolo.reconcile(clips: nextAudio, soloLane: requestedSolo ?? soloAudioLane)
        guard next != clipTimeline || nextAudio != audioClips || nextHidden != hiddenLinkedAudio || nextSolo != soloAudioLane || nextVideoOverlays != videoOverlays else { return }

        let previousTimeline = clipTimeline
        let previousAudio = audioClips
        let previousHidden = hiddenLinkedAudio
        let previousSolo = soloAudioLane
        let previousVideoOverlays = videoOverlays
        let previousSelection = selectedClipID
        let hadSelection = selectedClipID != nil
        let previousTime = currentTime
        registerUndo(actionName) { target in
            target.applyClipTimeline(
                previousTimeline,
                audio: previousAudio,
                hidden: previousHidden,
                solo: .some(previousSolo),
                videoOverlays: previousVideoOverlays,
                selectedID: previousSelection,
                selectsClip: hadSelection,
                playheadTime: previousTime,
                actionName: actionName
            )
        }
        hiddenLinkedAudio = nextHidden
        soloAudioLane = nextSolo

        pause()
        endTrimSourcePreview(restoreItem: false)
        hoverPreviewTime = nil
        isTrimmingClip = false
        rangeSelection = nil
        clipTimeline = next
        audioClips = nextAudio
        videoOverlays = nextVideoOverlays
        duration = next.duration
        if let selectedVideoOverlayID, !nextVideoOverlays.contains(where: { $0.id == selectedVideoOverlayID }) {
            self.selectedVideoOverlayID = nil
        }
        if let selectedAudioClipID, !nextAudio.contains(where: { $0.id == selectedAudioClipID }) {
            self.selectedAudioClipID = nil
        }
        selectedAudioClipIDs = selectedAudioClipIDs.filter { id in
            nextAudio.contains(where: { $0.id == id })
        }
        let nextSelection = StudioEditing.selectionAfterClipEdit(
            current: activeTimelineSelection,
            nextTimeline: next,
            requestedClipID: selectedID,
            selectsClip: selectsClip,
            playheadTime: playheadTime
        )
        if case .clip(let nextClipID) = nextSelection {
            clearTimelineSelection()
            selectedClipID = nextClipID
        } else {
            selectedClipID = nil
        }
        // Both motion timelines integrate along editor time, so a cut, trim,
        // reorder, source change, or speed change invalidates them even when
        // their source data did not change. A change to a clip's sound alone leaves them be.
        if Self.motionShape(of: next) != Self.motionShape(of: previousTimeline) {
            rebuildPointerTimeline()
            rebuildViewportTimeline()
        }
        syncImportedThumbnails()

        do {
            try rebuildScreenPlayerItem(preserving: min(max(playheadTime, 0), duration))
            if let hoverTime {
                hoverPreviewTime = min(max(hoverTime, 0), duration)
            }
        } catch {
            loadError = "Could not update the recording timeline: \(error.localizedDescription)"
        }
        updateActiveTranscriptWord()
        scheduleProjectSave()
    }

    private struct ClipMotionSegment: Equatable {
        let mediaFileName: String?
        let sourceStart: TimeInterval
        let sourceEnd: TimeInterval
        let speed: Double
    }

    /// What the motion timelines depend on: each clip's source, range, and speed.
    private static func motionShape(of timeline: RecordingClipTimeline) -> [ClipMotionSegment] {
        timeline.segments.map {
            ClipMotionSegment(
                mediaFileName: $0.mediaFileName,
                sourceStart: $0.sourceStart,
                sourceEnd: $0.sourceEnd,
                speed: $0.speed
            )
        }
    }

    private var primaryVideoSource: StudioVideoSource? {
        guard let screenAsset, let screenVideoTrack else { return nil }
        return StudioVideoSource(
            asset: screenAsset,
            videoTrack: screenVideoTrack,
            naturalSize: screenNaturalSize,
            preferredTransform: screenPreferredTransform,
            duration: sourceDuration
        )
    }

    /// Visible sub-rect of `videoSize` framed inside the project's video card
    /// (equals full `videoSize` for `.original` uncropped and `.fit` aspect).
    private var multiSourceTargetRect: CGRect {
        let layout = RecordingStudioLayout.make(
            canvasSize: basePreviewCanvasSize,
            style: style,
            includeBubble: false,
            usesUniformPadding: exportAspect == .original,
            contentAspect: previewContentAspect,
            contentMode: previewContentMode,
            contentCropRect: videoCropRect
        )
        return RecordingCompositionBuilder.visibleCardRect(
            renderSize: videoSize,
            cardSize: layout.cardRect.size,
            contentFillSize: layout.contentFillSize
        )
    }

    private func rebuildMultiSourceFramingIfNeeded() {
        guard isLoaded, !isApplyingDocument, !isRestoringDocument, clipTimeline.hasImportedClips else { return }
        try? rebuildScreenPlayerItem(preserving: currentTime)
    }

    private func rebuildScreenPlayerItem(preserving editorTime: TimeInterval) throws {
        guard !withholdsNewerFormatPreview else {
            replaceScreenPlayerItem(nil, observeRedactionFailure: false)
            return
        }
        guard let screenAsset else { return }
        audioPlaybackRebuildTask?.cancel()
        audioPlaybackRebuildTask = nil
        playbackMusicTrackID = nil

        let usesMultiSource = clipTimeline.hasImportedClips
        let playbackAsset: AVAsset
        var multiSourceVideoComposition: AVVideoComposition?

        if usesMultiSource, let primarySource = primaryVideoSource {
            if !redactions.isEmpty {
                for region in redactions { try region.validate(sourceDuration: sourceDuration) }
            }
            redactionPreview.update(redactions: redactions, clipTimeline: clipTimeline, timeMap: nil)
            let (composition, videoComposition, builtTimeMap) = try RecordingCompositionBuilder.makeMultiSourceVideoComposition(
                primarySource: primarySource,
                importedSources: importedVideoSources,
                timeline: clipTimeline,
                renderSize: videoSize,
                targetRect: multiSourceTargetRect,
                redactionSource: redactions.isEmpty ? nil : redactionPreview
            )
            compositionTimeMap = builtTimeMap
            redactionPreview.update(redactions: redactions, clipTimeline: clipTimeline, timeMap: builtTimeMap)
            let plan = audioPlan
            playbackAudioLayout = StudioAudioComposer.add(plan, sources: activeAudioSources, to: composition)
            playbackAudioPlacement = plan.placement
            if let backgroundMusic, let settings = backgroundMusicSettings {
                playbackMusicTrackID = try RecordingBackgroundMusicMixer.addTrack(
                    to: composition,
                    music: backgroundMusic,
                    settings: settings,
                    timeline: clipTimeline
                )
            }
            playbackAsset = composition
            multiSourceVideoComposition = videoComposition
        } else if let screenVideoTrack {
            let (composition, builtTimeMap) = try RecordingCompositionBuilder.makeVideoCompositionWithTimeMap(
                videoTrack: screenVideoTrack,
                timeline: clipTimeline
            )
            compositionTimeMap = builtTimeMap
            let plan = audioPlan
            playbackAudioLayout = StudioAudioComposer.add(plan, sources: activeAudioSources, to: composition)
            playbackAudioPlacement = plan.placement
            if let backgroundMusic, let settings = backgroundMusicSettings {
                playbackMusicTrackID = try RecordingBackgroundMusicMixer.addTrack(
                    to: composition,
                    music: backgroundMusic,
                    settings: settings,
                    timeline: clipTimeline
                )
            }
            playbackAsset = composition
        } else {
            let composition = AVMutableComposition()
            let plan = audioPlan
            playbackAudioLayout = StudioAudioComposer.add(plan, sources: activeAudioSources, to: composition)
            playbackAudioPlacement = plan.placement
            if let backgroundMusic, let settings = backgroundMusicSettings {
                playbackMusicTrackID = try RecordingBackgroundMusicMixer.addTrack(
                    to: composition,
                    music: backgroundMusic,
                    settings: settings,
                    timeline: clipTimeline
                )
            }
            playbackAsset = composition.tracks.isEmpty ? screenAsset : composition
        }

        playerItemTask?.cancel()
        playerItemTask = nil
        redactionRefreshTask?.cancel()
        redactionRefreshTask = nil
        activeTrimSourcePreviewTime = nil
        trimSourcePreviewError = nil
        readyCutPlayerItem = nil
        cutRedactionPreviewError = nil
        redactionPreview.update(redactions: redactions, clipTimeline: clipTimeline, timeMap: compositionTimeMap)
        let needsAsyncSingleSourceRedactions = !usesMultiSource && !redactions.isEmpty
        let generation = playerItemGate.beginCutBuild(isAsync: needsAsyncSingleSourceRedactions)
        let item = AVPlayerItem(asset: playbackAsset)
        // Sped-up speech keeps its pitch, as it does in the export.
        item.audioTimePitchAlgorithm = .timeDomain
        if let multiSourceVideoComposition {
            item.videoComposition = multiSourceVideoComposition
            isPreparingRedactionPreview = false
            readyCutPlayerItem = item
            replaceScreenPlayerItem(item, observeRedactionFailure: !redactions.isEmpty)
        } else if redactions.isEmpty {
            isPreparingRedactionPreview = false
            readyCutPlayerItem = item
            replaceScreenPlayerItem(item, observeRedactionFailure: false)
        } else {
            // Never display the previous, potentially unmasked paused frame while rebuilding.
            isPreparingRedactionPreview = true
            replaceScreenPlayerItem(nil, observeRedactionFailure: false)
            let previewSource = redactionPreview
            playerItemTask = Task { [weak self] in
                do {
                    item.videoComposition = try await previewSource.composition(asset: playbackAsset)
                    guard let self, !Task.isCancelled, !self.isTornDown,
                          self.playerItemGate.finishCutBuild(generation: generation) else { return }
                    self.playerItemTask = nil
                    self.readyCutPlayerItem = item
                    self.replaceScreenPlayerItem(item, observeRedactionFailure: true)
                    self.updatePlaybackVolume()
                    self.movePlayers(to: self.displayTime)
                    self.installEndObserver()
                    self.isPreparingRedactionPreview = false
                } catch {
                    guard let self, !Task.isCancelled,
                          self.playerItemGate.generation == generation else { return }
                    self.playerItemTask = nil
                    self.cutRedactionPreviewError = error.localizedDescription
                    self.isPreparingRedactionPreview = false
                }
            }
        }
        updatePlaybackVolume()
        screenPlayer.actionAtItemEnd = .pause
        currentTime = min(max(editorTime, 0), duration)
        movePlayers(to: currentTime)
        if timeObserver != nil {
            installEndObserver()
        }
    }

    private func registerUndo(
        _ actionName: String,
        operation: @escaping @MainActor (RecordingStudioModel) -> Void
    ) {
        let openExplicitGroup = !editUndoManager.isUndoing && !editUndoManager.isRedoing
        if openExplicitGroup {
            commitPendingOverlayEdits()
            editUndoManager.beginUndoGrouping()
        }
        editUndoManager.registerUndo(withTarget: self) { target in
            operation(target)
        }
        editUndoManager.setActionName(actionName)
        if openExplicitGroup {
            editUndoManager.endUndoGrouping()
        }
        undoRevision &+= 1
    }

    private func coverFailedRedactionPreview() {
        pause()
        isPreparingRedactionPreview = false
        if playerItemGate.handleRuntimeItemFailure() {
            // A temporary source-preview item failed: keep the canvas covered
            // while the drag is active, but preserve `readyCutPlayerItem` and
            // `cutRedactionPreviewError` so releasing restores the valid cut.
            trimSourcePreviewError = RecordingRedactionError.filterFailed.localizedDescription
            replaceScreenPlayerItem(nil, observeRedactionFailure: false)
        } else {
            cutRedactionPreviewError = RecordingRedactionError.filterFailed.localizedDescription
            readyCutPlayerItem = nil
            activeTrimSourcePreviewTime = nil
            replaceScreenPlayerItem(nil, observeRedactionFailure: false)
        }
    }

    /// A small frame from early in the recording, for the Styles tiles.
    private(set) var stylePoster: CGImage?
    private var stylePosterTask: Task<Void, Never>?

    /// Once the recording has loaded, so the file is known to be readable.
    private func loadStylePoster() {
        stylePosterTask?.cancel()
        stylePosterTask = nil
        guard !withholdsNewerFormatPreview else {
            stylePoster = nil
            return
        }
        let url = screenURL
        let duration = sourceDuration
        let regions = redactions
        stylePoster = nil
        stylePosterTask = Task { [weak self] in
            let poster = await Self.posterFrame(url: url, duration: duration, redactions: regions)
            guard let self, !Task.isCancelled, !self.isTornDown else { return }
            self.stylePosterTask = nil
            if self.redactions == regions { self.stylePoster = poster }
        }
    }

    /// About a second in, past a blank first frame; the first frame if that
    /// fails.
    nonisolated private static func posterFrame(url: URL, duration: TimeInterval, redactions: [RecordingRedaction]) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        if !redactions.isEmpty {
            do { generator.videoComposition = try await RecordingRedactionFilter.composition(asset: generator.asset, redactions: redactions) }
            catch { return nil }
        }
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        let cancellation = ImageGenerationCancellation(generator: generator)
        return await withTaskCancellationHandler {
            for seconds in [min(1, duration / 2), 0] where seconds.isFinite {
                guard !Task.isCancelled else { return nil }
                if let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image {
                    return image
                }
            }
            return nil
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func loadTimelineThumbnails() {
        guard !withholdsNewerFormatPreview else { return }
        timelineThumbnails.prepare(url: screenURL, duration: sourceDuration, redactions: redactions)
    }

    /// Speed of whichever clip covers this editor time; 1 when nothing
    /// covers it (e.g. past the end of the timeline).
    private func speed(atEditorTime time: TimeInterval) -> Double {
        guard let location = clipTimeline.location(at: time) else { return 1 }
        return clipTimeline.segments[location.segmentIndex].speed
    }

    private func syncCameraPlayback() {
        guard hasCameraVideo else { return }
        let location = clipTimeline.location(at: currentTime)
        lastCameraSegmentID = location?.segmentID
        guard let location, clipTimeline.segments[location.segmentIndex].isPrimaryRecording else {
            cameraSeek.invalidate()
            cameraPlayer.pause()
            return
        }
        let sourceTime = location.sourceTime
        guard sourceTime >= cameraOffset else {
            cameraSeek.invalidate()
            cameraPlayer.pause()
            cameraPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        // The camera master is a separate, unedited recording - it has no
        // composition to bake speed into, so a sped-up clip must also play
        // the camera bubble at that rate or the two drift apart immediately.
        let initialRate = Float(speed(atEditorTime: currentTime)) * shuttleRate
        let cameraSeconds = max(0, sourceTime - cameraOffset)
        if !Self.playbackCapabilities(of: cameraPlayer.currentItem).supports(rate: initialRate),
           cameraPlayer.rate != 0 {
            cameraPlayer.pause()
        }
        if let dispatch = cameraSeek.requestSeek(to: cameraSeconds) {
            dispatchCameraSeek(generation: dispatch.generation, seconds: dispatch.target)
        }
    }

    private func dispatchCameraSeek(generation: Int, seconds: TimeInterval) {
        let cameraTime = CMTime(seconds: max(0, seconds), preferredTimescale: StudioPlayback.seekTimescale)
        cameraPlayer.seek(to: cameraTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.finishCameraSeek(generation: generation, finished: finished)
            }
        }
    }

    private func finishCameraSeek(generation: Int, finished: Bool) {
        guard hasCameraVideo, isPlaying else {
            cameraSeek.invalidate()
            return
        }
        switch cameraSeek.completeSeek(generation: generation, finished: finished) {
        case .ignore:
            return
        case .startCoalescedSeek(let nextGeneration, let nextTarget):
            let sourceTime = clipTimeline.sourceTime(at: currentTime)
            guard sourceTime >= cameraOffset else {
                cameraSeek.invalidate()
                cameraPlayer.pause()
                cameraPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                return
            }
            dispatchCameraSeek(generation: nextGeneration, seconds: nextTarget)
        case .applyPlaybackRate:
            let currentRate = Float(speed(atEditorTime: currentTime)) * shuttleRate
            if Self.playbackCapabilities(of: cameraPlayer.currentItem).supports(rate: currentRate) {
                cameraPlayer.rate = currentRate
            } else {
                cameraPlayer.pause()
            }
        }
    }

    private func correctCameraDriftIfNeeded() {
        guard hasCameraVideo, isPlaying else { return }
        let location = clipTimeline.location(at: currentTime)
        let segmentID = location?.segmentID
        guard let location, clipTimeline.segments[location.segmentIndex].isPrimaryRecording else {
            cameraSeek.invalidate()
            lastCameraSegmentID = segmentID
            if cameraPlayer.rate != 0 { cameraPlayer.pause() }
            return
        }
        let sourceTime = location.sourceTime
        guard sourceTime >= cameraOffset else {
            cameraSeek.invalidate()
            lastCameraSegmentID = segmentID
            cameraPlayer.pause()
            return
        }
        let targetRate = Float(speed(atEditorTime: currentTime)) * shuttleRate
        let expected = sourceTime - cameraOffset
        guard Self.playbackCapabilities(of: cameraPlayer.currentItem).supports(rate: targetRate) else {
            lastCameraSegmentID = segmentID
            if cameraPlayer.rate != 0 { cameraPlayer.pause() }
            if expected.isFinite, let dispatch = cameraSeek.requestSeek(to: max(0, expected)) {
                dispatchCameraSeek(generation: dispatch.generation, seconds: dispatch.target)
            }
            return
        }
        if cameraSeek.isSeeking {
            // Let the in-flight seek complete instead of cancelling it on every
            // observer tick; coalesce a follow-up target only if a cut was crossed.
            if segmentID != lastCameraSegmentID, expected.isFinite {
                lastCameraSegmentID = segmentID
                _ = cameraSeek.requestSeek(to: max(0, expected))
            }
            return
        }
        if cameraPlayer.rate == 0 {
            syncCameraPlayback()
            return
        }
        if abs(cameraPlayer.rate - targetRate) > 0.01 {
            cameraPlayer.rate = targetRate
        }
        let actual = cameraPlayer.currentTime().seconds
        if StudioPlayback.shouldResyncCamera(
            expected: expected,
            actual: actual,
            segmentID: segmentID,
            lastSegmentID: lastCameraSegmentID,
            shuttleRate: shuttleRate
        ) {
            syncCameraPlayback()
        }
    }

    // MARK: - Zoom cues

    private func replaceZoomCues(_ cues: [ZoomCue]) {
        let sorted = cues.sorted { $0.start < $1.start }
        guard sorted != zoomCues else { return }
        zoomCues = sorted
        if let selectedCueID, !sorted.contains(where: { $0.id == selectedCueID }) {
            self.selectedCueID = nil
        }
        if zoomEditSnapshot != nil {
            // A drag reports dozens of moves a second, and planning the
            // camera integrates the whole recording. The block follows the
            // pointer from `zoomCues`; the plan catches up when it rests.
            scheduleViewportRebuild()
        } else {
            rebuildViewportTimeline()
        }
        scheduleProjectSave()
    }

    private func applyZoomCues(_ cues: [ZoomCue], actionName: String) {
        let sorted = cues.sorted { $0.start < $1.start }
        guard sorted != zoomCues else { return }
        let previous = zoomCues
        registerUndo(actionName) { target in
            target.applyZoomCues(previous, actionName: actionName)
        }
        replaceZoomCues(sorted)
    }

    func beginZoomCueEdit() {
        if zoomEditSnapshot == nil {
            zoomEditSnapshot = zoomCues
        }
    }

    func endZoomCueEdit(actionName: String = "Edit Zoom") {
        guard let previous = zoomEditSnapshot else { return }
        zoomEditSnapshot = nil
        if viewportRebuildTask != nil {
            viewportRebuildTask?.cancel()
            viewportRebuildTask = nil
            rebuildViewportTimeline()
        }
        guard previous != zoomCues else { return }
        registerUndo(actionName) { target in
            target.applyZoomCues(previous, actionName: actionName)
        }
    }

    func resynthesizeZoomCues() {
        applyZoomCues(
            ZoomCueSynthesizer.cues(from: pointerCapture, duration: sourceDuration),
            actionName: "Reset Zooms"
        )
    }

    func addZoomCue(at time: TimeInterval) {
        guard isPrimaryRecording(at: time) else {
            showNotice("Zooms apply only to the main recording")
            return
        }
        let sourceTime = clipTimeline.sourceTime(at: time)
        let start = min(max(0, sourceTime), max(0, sourceDuration - 1))
        insertZoomCue(start: start, end: min(sourceDuration, start + 3))
    }

    /// Where a new cue can actually go. A request landing inside an existing
    /// zoom is pushed past it rather than dropped, and the span is trimmed to
    /// the next cue; nil when no gap from here on is long enough to use.
    private func freeSpan(
        from start: TimeInterval,
        preferredEnd: TimeInterval
    ) -> ClosedRange<TimeInterval>? {
        guard sourceDuration > 0 else { return nil }
        let length = max(preferredEnd - start, ZoomCue.minimumDuration)
        var lower = min(max(start, 0), sourceDuration)
        // Walks chains of touching cues, so "add at playhead" inside a run of
        // zooms lands in the first real gap after them.
        while let covering = zoomCues.first(where: { $0.start <= lower && $0.end > lower }) {
            lower = covering.end
        }
        let upper = zoomCues
            .filter { $0.start > lower }
            .map(\.start)
            .min() ?? sourceDuration
        guard upper - lower >= ZoomCue.minimumDuration else { return nil }
        return lower...min(lower + length, upper)
    }

    /// Adds a zoom over a range drawn on the zoom track, in editor time.
    /// The track has already fitted the range between the neighbouring
    /// blocks and grown it to `ZoomCue.minimumDuration`, and shown it that
    /// way, so this adds it as is: it neither moves nor stretches it.
    func addZoomCue(overEditorRange range: ClosedRange<TimeInterval>) {
        guard let span = studioDrawnSourceSpan(
            for: range,
            clipTimeline: clipTimeline,
            sourceDuration: sourceDuration,
            among: zoomCues.compactMap { $0.end > $0.start ? $0.start...$0.end : nil },
            minimum: ZoomCue.minimumDuration
        ) else { return }
        appendZoomCue(span)
    }

    private func insertZoomCue(start: TimeInterval, end: TimeInterval) {
        guard let span = freeSpan(from: start, preferredEnd: end) else { return }
        appendZoomCue(span)
    }

    private func appendZoomCue(_ span: ClosedRange<TimeInterval>) {
        let hasPointerTrack = !pointerCapture.travel.isEmpty || !pointerCapture.presses.isEmpty
        let editorTime = clipTimeline.editorTime(forSourceTime: span.lowerBound) ?? currentTime
        let target = pointerTimeline.location(at: editorTime) ?? CGPoint(x: 0.5, y: 0.5)
        let cue = ZoomCue(
            start: span.lowerBound,
            end: span.upperBound,
            zoom: 1.5,
            anchorMode: hasPointerTrack ? .pointerAnchor : .pinnedAnchor,
            pinnedPoint: target,
            boundsBias: hasPointerTrack ? 0.25 : 0
        )
        var cues = zoomCues
        cues.append(cue)
        applyZoomCues(cues, actionName: "Add Zoom")
        clearTimelineSelection()
        selectedCueID = cue.id
    }

    func removeZoomCue(id: UUID) {
        applyZoomCues(zoomCues.filter { $0.id != id }, actionName: "Remove Zoom")
        if selectedCueID == id {
            selectedCueID = nil
        }
    }

    /// Applies an edited cue, stopping either edge at the neighboring cues so
    /// blocks can be resized right up to each other but never through.
    func updateZoomCue(_ cue: ZoomCue) {
        guard let cues = studioPlaceUpdatedZoomCue(cue, in: zoomCues, sourceDuration: sourceDuration) else { return }
        replaceZoomCues(cues)
    }

    /// Trims one edge of a cue in source time while keeping the opposite edge
    /// fixed so a blocked trim never shifts the untouched edge.
    func trimZoomCue(
        id: UUID,
        edge: StudioBlockEdge,
        toSourceTime sourceTime: TimeInterval,
        base: ZoomCue? = nil
    ) {
        guard let cues = studioPlaceTrimmedZoomCue(
            id: id,
            edge: edge,
            proposedSourceTime: sourceTime,
            base: base,
            in: zoomCues,
            sourceDuration: sourceDuration
        ) else { return }
        replaceZoomCues(cues)
    }

    /// Slides a cue without changing its editor length. Preserves the positive
    /// source span calculated from the editor interval so short cues moved from
    /// a sped-up clip onto a normal-speed clip keep their visible length.
    func moveZoomCue(_ cue: ZoomCue) {
        guard let cues = studioPlaceMovedZoomCue(cue, in: zoomCues, sourceDuration: sourceDuration) else { return }
        replaceZoomCues(cues)
    }

    var selectedCue: ZoomCue? {
        zoomCues.first { $0.id == selectedCueID }
    }

    var visibleRecordedPressTimes: [TimeInterval] {
        recordedPressTimes.compactMap { clipTimeline.editorTime(forSourceEventTime: $0) }
    }

    /// All occupied zoom spans in editor time, including cues hidden inside a
    /// cut as zero-width barriers at the cut's editor time.
    var zoomOverlapSpans: [StudioLaneSpan] {
        studioOccupiedLaneSpans(cues: zoomCues, clipTimeline: clipTimeline)
    }

    /// One visual block per cue on the edited timeline. In recording order a
    /// cue's slices always touch; after reordering they may not, so the
    /// longest touching run stands for the block.
    var zoomTimelineBlocks: [RecordingZoomTimelineBlock] {
        zoomCues
            .filter { !$0.isImplicit }
            .compactMap { cue in
                guard let span = clipTimeline.editorSpan(overlapping: cue.start, sourceEnd: cue.end) else {
                    return nil
                }
                return RecordingZoomTimelineBlock(
                    cue: cue,
                    editorStart: span.lowerBound,
                    editorEnd: span.upperBound
                )
            }
    }

    func sourceTime(atEditorTime time: TimeInterval) -> TimeInterval {
        clipTimeline.sourceTime(at: time)
    }

    func editorTime(forSourceTime time: TimeInterval) -> TimeInterval? {
        clipTimeline.editorTime(forSourceTime: time)
    }

    private func rebuildPointerTimeline() {
        reframeFocusTimeline = nil
        reframeFocusResolved = false
        guard pointerIsSynthesized, sourceDuration > 0 else {
            pointerTimeline = .empty
            return
        }
        pointerTimeline = PointerTimeline.build(
            capture: pointerCapture,
            duration: sourceDuration,
            recordingSizeInPoints: recordingPointSize,
            fallbackArtwork: PointerArtworkCapture.defaultArtwork(),
            clipTimeline: clipTimeline
        )
    }

    private func scheduleViewportRebuild() {
        viewportRebuildTask?.cancel()
        viewportRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            self.viewportRebuildTask = nil
            self.rebuildViewportTimeline()
        }
    }

    private func rebuildViewportTimeline() {
        viewportRebuildTask?.cancel()
        viewportRebuildTask = nil
        guard sourceDuration > 0 else {
            viewportTimeline = .identity
            return
        }
        viewportTimeline = ViewportTimeline.build(
            cues: zoomCues,
            capture: pointerCapture,
            clipTimeline: clipTimeline
        )
        // The reframe camera derives from the viewport, so it follows
        // every rebuild (zoom edits, cuts, speed changes).
        rebuildPreviewReframe()
    }

    private func scheduleProjectSave() {
        guard isLoaded, !isApplyingDocument, !isRestoringDocument, !isReadOnlyNewerFormat else { return }
        hasUnsavedChanges = true
        hasEditsSinceOpening = true
        // The uploaded link no longer matches; bring Upload back.
        if case .finished = shareState { shareState = .idle }
        projectSaveTask?.cancel()
        projectSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.writeDraftNow()
        }
        scheduleAutosave()
    }

    /// Two seconds after the last change. Every keystroke and drag step is a
    /// change, so this waits out typing; a held mouse button (a drag or a
    /// scrub paused mid-way) puts it off again.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            if NSEvent.pressedMouseButtons != 0 {
                self.scheduleAutosave()
            } else {
                self.autosave()
            }
        }
    }

    /// A save nobody asked for, as in the image editor; a bare movie has
    /// nowhere to save. A failure shows Not Saved rather than an alert, and
    /// the draft keeps the edits.
    func autosave() {
        guard isProject, hasUnsavedChanges, !isReadOnlyNewerFormat else { return }
        saveProject(reportingFailure: false)
    }

    /// The edits a flattened render outside the editor should use. A
    /// recording never saved or edited has none, like the render made at
    /// Stop, so Agent Prompt reuses that render and closing Studio keeps it.
    var deliverableDocument: RecordingEditDocument? {
        hasUnsavedChanges || session?.hasSavedProject == true ? currentDocument() : nil
    }

    /// Every edit in the editor, as a storable document.
    func currentDocument() -> RecordingEditDocument {
        RecordingEditDocument(
            style: style,
            zoomEnabled: zoomEnabled,
            zoomCues: zoomCues.filter { !$0.isImplicit },
            clipTimeline: clipTimeline,
            exportSettings: exportSettings,
            showsClickEffects: showsClickEffects,
            showsKeystrokes: showsKeystrokes,
            keystrokePlacement: keystrokePlacement,
            showsSubtitles: showsSubtitles,
            subtitleCues: subtitleCues.isEmpty ? nil : subtitleCues,
            subtitleWords: transcriptWords.isEmpty ? nil : transcriptWords,
            subtitleStyle: subtitleStyle,
            exportAspect: exportAspect,
            exportAspectMode: exportAspectMode,
            videoCropRect: isVideoCropped ? videoCropRect : nil,
            replacementAudioFileName: replacementAudio?.url.lastPathComponent ?? replacementAudioReference?.fileName,
            replacementAudioDisplayName: replacementAudio?.displayName ?? replacementAudioReference?.displayName,
            replacementAudioSync: replacementAudio == nil && replacementAudioReference == nil ? nil : replacementAudioSync,
            audioClips: audioClips.isEmpty ? nil : audioClips,
            hiddenLinkedAudio: hiddenLinkedAudio.isEmpty ? nil : hiddenLinkedAudio,
            audioExportFormat: audioExportFormat,
            audioVolume: Double(audioVolume),
            isolateVoice: voiceIsolationEnabled && isolatedMicrophone != nil,
            backgroundMusic: backgroundMusicSettings,
            redactions: redactions,
            textOverlays: textOverlays.isEmpty ? nil : textOverlays,
            imageOverlays: imageOverlays.isEmpty ? nil : imageOverlays,
            videoOverlays: videoOverlays.isEmpty ? nil : videoOverlays,
            showsInk: showsInk ? nil : false,
            hiddenInkStrokeIDs: hiddenInkStrokeIDs.isEmpty
                ? nil : hiddenInkStrokeIDs.sorted { $0.uuidString < $1.uuidString },
            markers: markers.isEmpty ? nil : markers
        )
    }

    /// Persists the working copy. Cheap, debounced, and never touches the
    /// committed `edit.json`, so a crash or a failed save costs nothing.
    @discardableResult
    private func writeDraftNow() -> Bool {
        guard isLoaded, !isRestoringDocument, !hasUnreadableDraft, !isReadOnlyNewerFormat else { return false }
        do {
            try persistDraft()
            return true
        } catch {
            return false
        }
    }

    private func persistDraft() throws {
        let document = currentDocument()
        let changed = document != lastSavedDocument
        guard let session else {
            hasUnsavedChanges = changed
            return
        }
        do {
            if document != openedDocument {
                do { try keepOpeningSession() }
                catch where !openedOnDraft {
                    // A saved opening is still safe in edit.json.
                    lastSaveSucceeded = false
                }
            }
            if changed {
                try session.writeDraftDocument(document)
            } else {
                try session.removeDraftDocumentIfPresent()
            }
            hasUnsavedChanges = changed
            dropStaleRender(in: session)
        } catch {
            lastSaveSucceeded = false
            hasUnsavedChanges = true
            throw error
        }
    }

    /// A cached flatten that no longer matches the edits is worse than no
    /// cache: History previews it and Share would upload it. It is judged by
    /// the document a render would use (draft, else last save, else none),
    /// not the in-memory baseline: an unedited recording's baseline is a
    /// full default document, but the render made at Stop is stamped with none.
    private func dropStaleRender(in session: RecordingSession) {
        guard (try? RecordingPackageMedia.validateRenderInputs(in: session.directoryURL)) != nil else {
            return
        }
        guard session.existingFinalURL != nil else { return }
        do {
            if session.freshFinalURL(matching: try session.editDocumentForRendering()) != nil { return }
        } catch {
            // Unreadable edits can't vouch for any render.
        }
        session.removeFinalVideos()
    }

    /// Writes the working copy immediately, bypassing the debounce. Used on
    /// teardown and on quit so no edit is left only in memory.
    func flushDraft() {
        commitPendingOverlayEdits()
        projectSaveTask?.cancel()
        writeDraftNow()
    }

    func flushDraftForDelivery() throws {
        if isReadOnlyNewerFormat, let newerFormatVersion {
            throw RecordingPackageMedia.ValidationError.unsupportedFormatVersion(newerFormatVersion)
        }
        guard isLoaded, !isRestoringDocument, !hasUnreadableDraft, !isReadOnlyNewerFormat else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "Studio could not prepare the recording edits for delivery."])
        }
        try persistDraft()
    }

    /// ⌘S, a pause, leaving the window, closing and quitting. Commits the
    /// working copy to `edit.json` and clears the draft.
    @discardableResult
    func saveProject(reportingFailure: Bool = true) -> Bool {
        guard isLoaded, !isRestoringDocument, !hasUnreadableDraft, !isReadOnlyNewerFormat, let session else { return false }
        projectSaveTask?.cancel()
        autosaveTask?.cancel()
        let document = currentDocument()
        do {
            if document != openedDocument { try keepOpeningSession() }
            try session.writeEditDocument(document)
            try session.removeDraftDocumentIfPresent()
            lastSavedDocument = document
            hasUnsavedChanges = false
            try? session.updateProjectMetadata { $0.savedAt = Date() }
            dropStaleRender(in: session)
            RecordingProjectStore.shared.reload()
            lastSaveSucceeded = true
            return true
        } catch {
            lastSaveSucceeded = false
            // The draft still holds the edits.
            writeDraftNow()
            if reportingFailure {
                FailureAlert.present(message: "The recording project could not be saved", error: error,
                                     detail: "Your editor will stay open. Try saving again after resolving the problem.")
            }
            return false
        }
    }

    /// The bar's Discard: drops only the unreadable draft; edits made since opening become the new one.
    func discardUnreadableDraft() {
        guard hasUnreadableDraft, !isRestoringDocument, !isReadOnlyNewerFormat, let session else { return }
        session.removeDraftDocument()
        hasUnreadableDraft = false
        flushDraft()
    }

    /// Throws away everything since the last save and returns the editor to
    /// that state. Only offered for projects that have actually been saved.
    func discardChanges() async {
        guard isLoaded, !isRestoringDocument, !isReadOnlyNewerFormat, let session else { return }
        projectSaveTask?.cancel()
        replacementAudioTask?.cancel()
        replacementAudioTask = nil
        session.removeDraftDocument()
        hasUnreadableDraft = false
        guard let document = lastSavedDocument else { return }
        let restoreID = beginDocumentRestore()
        applyDocumentSettings(document)
        await applyDocumentTimeline(document)
        finishDocumentRestore(restoreID)
        // Rebuilding the timeline touches published state; let the normal
        // draft path settle the dirty flag rather than assuming it landed.
        flushDraft()
    }

    /// The parts of a stored project that need the timeline rebuilt around
    /// them: cuts, the imported soundtrack, and everything derived from both.
    private func applyDocumentTimeline(_ document: RecordingEditDocument, keepingUndo: Bool = false) async {
        guard !isTornDown, !Task.isCancelled, let session else { return }
        isApplyingDocument = true
        defer { isApplyingDocument = false }

        if let storedClips = document.clips, !storedClips.isEmpty {
            clipTimeline = RecordingClipTimeline(segments: storedClips)
                .normalized(to: sourceDuration)
        } else {
            clipTimeline = .legacyTrim(
                start: document.trimStart,
                end: document.trimEnd,
                sourceDuration: sourceDuration
            )
        }
        duration = clipTimeline.duration
        // Nothing is selected until the user picks a clip; an unsplit
        // recording would otherwise open wrapped in selection chrome.
        selectedClipID = nil

        if let fileName = document.replacementAudioFileName {
            let reference = StudioReplacementReference(
                fileName: fileName,
                displayName: document.replacementAudioDisplayName
            )
            let url = session.directoryURL.appendingPathComponent(fileName)
            if url != replacementAudio?.url {
                let loadedAudio: RecordingReplacementAudio?
                if FileManager.default.fileExists(atPath: url.path) {
                    loadedAudio = await RecordingReplacementAudio.load(
                        url: url,
                        displayName: reference.label
                    )
                    guard !isTornDown, !Task.isCancelled else { return }
                } else {
                    loadedAudio = nil
                }
                adoptReplacementAudio(
                    loadedAudio,
                    reference: loadedAudio == nil ? reference : nil,
                    sync: document.replacementAudioSync
                )
            } else if let replacementAudio {
                adoptReplacementAudio(replacementAudio, sync: document.replacementAudioSync)
            }
        } else {
            adoptReplacementAudio(nil, reference: nil, sync: nil)
        }
        videoOverlayPlayer.isMuted = true
        videoOverlayPlayer.actionAtItemEnd = .pause
        audioClips = StudioAudioConform.resolvingLanes(audioClips.map { $0.sanitized() })
        videoOverlays = StudioVideoOverlayLane.normalized(videoOverlays)
        await resolveImportedVideoSources()
        await resolveAudioClipSources()
        await resolveVideoOverlaySources()
        guard !isTornDown, !Task.isCancelled else { return }

        await resolveBackgroundMusic()
        await resolveVoiceIsolation()
        guard !isTornDown, !Task.isCancelled else { return }
        try? rebuildScreenPlayerItem(preserving: currentTime)
        loadTimelineThumbnails()
        syncImportedThumbnails()
        loadStylePoster()
        rebuildPointerTimeline()
        rebuildViewportTimeline()
        rebuildPreviewReframe()
        if !keepingUndo { editUndoManager.removeAllActions() }
        undoRevision += 1
    }

    private func keepOpeningSession() throws {
        guard !isReadOnlyNewerFormat, !keptOpeningSession, let session, let openedDocument,
              currentDocument() != openedDocument else { return }
        sessionSnapshots = try CaptureSessionSnapshots(directory: session.sessionSnapshotsURL).keep(
            document: CaptureSessionSnapshots.encode(openedDocument), openedAt: sessionOpenedAt
        )
        keptOpeningSession = true
    }

    static func decodeRestorableSnapshot(_ data: Data) throws -> RecordingEditDocument {
        if let version = RecordingPackageMedia.readFormatVersion(from: data),
           version > RecordingEditDocument.currentFormatVersion {
            throw RecordingPackageMedia.ValidationError.unsupportedFormatVersion(version)
        }
        let document = try CaptureManifest.decoder.decode(RecordingEditDocument.self, from: data)
        if document.isUnsupportedFutureVersion {
            throw RecordingPackageMedia.ValidationError.unsupportedFormatVersion(document.formatVersion)
        }
        return document
    }

    func revertToSession(_ snapshot: CaptureSessionSnapshot) {
        guard canRevert, let session else { return }
        do {
            let stored = try CaptureSessionSnapshots(directory: session.sessionSnapshotsURL).read(snapshot)
            let document = try Self.decodeRestorableSnapshot(stored.document)
            revert(to: document, stylePresetID: nil, actionName: "Revert to Session")
        } catch {
            FailureAlert.present(message: "The session could not be restored", error: error)
        }
    }

    // MARK: - Revert To

    /// A project, loaded, not cropping, and with no export or upload that
    /// is rendering the current edits.
    var canRevert: Bool {
        isLoaded && isProject && !isEditingSourceRegion && !hasRunningWork && !isReadOnlyNewerFormat
    }

    /// File › Revert To › Original: every edit back to what a new recording
    /// opens with. The recording itself was never changed.
    func revertToOriginal() {
        revert(
            to: freshDocument(),
            stylePresetID: RecordingStudioStylePresetStore.shared.activePreset?.id,
            actionName: "Revert to Original"
        )
    }

    /// File › Revert To › Last Opened: the project as this window opened it.
    func revertToLastOpened() {
        guard let openedDocument else { return }
        revert(to: openedDocument, stylePresetID: openedStylePresetID, actionName: "Revert to Last Opened")
    }

    /// What a new recording opens with (see `load`): the style for new
    /// recordings or the default one, zooms found in its pointer track, the
    /// whole clip, and no captions, crop or soundtrack.
    private func freshDocument() -> RecordingEditDocument {
        RecordingEditDocument(
            style: RecordingStudioStylePresetStore.shared.activePreset?.value
                ?? RecordingStudioStyle(background: RecordingStudioDefaults.background),
            zoomEnabled: true,
            zoomCues: ZoomCueSynthesizer.cues(from: pointerCapture, duration: sourceDuration),
            exportSettings: RecordingExportPreferences.lastSettings,
            showsClickEffects: manifest?.pressEffectsEnabled ?? true
        )
    }

    /// A whole document as one step Undo takes back (and Redo repeats),
    /// saved like any other edit.
    private func revert(
        to document: RecordingEditDocument,
        stylePresetID: RecordingStudioStylePreset.ID?,
        actionName: String
    ) {
        guard canRevert else { return }
        let previous = currentDocument()
        guard document != previous else { return }
        let previousStylePresetID = appliedStylePresetID
        registerUndo(actionName) { target in
            target.revert(to: previous, stylePresetID: previousStylePresetID, actionName: actionName)
        }
        let restoreID = beginDocumentRestore()
        selectedCueID = nil
        applyDocumentSettings(document)
        appliedStylePresetID = stylePresetID
        documentRestoreTask = Task {
            await applyDocumentTimeline(document, keepingUndo: true)
            finishDocumentRestore(restoreID)
            scheduleProjectSave()
        }
    }

    /// True when `time` falls inside a primary-recording clip (not an imported
    /// clip), following the active composition's quantized 600ths boundaries so
    /// preview overlays stay in lockstep with the player.
    func isPrimaryRecording(at time: TimeInterval) -> Bool {
        if let entry = compositionTimeMap?.entry(at: time) {
            return entry.isPrimaryRecording
        }
        return clipTimeline.isPrimaryRecording(at: time)
    }

    /// Viewport frame to render at a given time, honoring the zoom toggle.
    func viewportFrame(at time: TimeInterval) -> ViewportFrame {
        guard zoomEnabled, isPrimaryRecording(at: time) else { return .identity }
        return viewportTimeline.frame(at: time)
    }

    /// True when this session was captured without the OS cursor, so the
    /// preview and export draw the synthetic pointer.
    var pointerIsSynthesized: Bool {
        manifest?.pointerSynthesized == true
    }

    /// Smoothed normalized pointer location for the preview overlay; nil when
    /// the recording carries its cursor in the pixels or on imported clips.
    func pointerLocation(at time: TimeInterval) -> CGPoint? {
        guard pointerIsSynthesized, isPrimaryRecording(at: time) else { return nil }
        return pointerTimeline.location(at: time)
    }

    func pointerFrame(at time: TimeInterval) -> PointerFrame? {
        guard activeTrimSourcePreviewTime == nil, !style.hidesCursor, pointerIsSynthesized,
              isPrimaryRecording(at: time) else { return nil }
        return pointerTimeline.frame(at: time)
    }

    func artwork(id: String?) -> PointerArtwork? {
        pointerTimeline.artwork(id: id)
    }

    /// Legacy sessions may already contain baked-in press feedback; only
    /// sidecar-reconstructed sessions can re-render it on demand.
    var canShowPressEffects: Bool {
        pointerIsSynthesized && manifest?.pressEffectsBaked == false
    }

    var showsPressEffects: Bool {
        canShowPressEffects && showsClickEffects
    }

    var hasKeystrokes: Bool {
        !keystrokeTimeline.isEmpty
    }

    // MARK: - Drawings

    var hasInk: Bool {
        !pointerCapture.ink.isEmpty
    }

    /// The take's strokes still in the project, in drawing order.
    var inkStrokes: [RecordingInkStroke] {
        inkTimeline.strokes
    }

    /// Stable across deletes: the stroke's place among everything drawn.
    func inkStrokeNumber(_ id: UUID) -> Int {
        (pointerCapture.ink.firstIndex { $0.id == id } ?? 0) + 1
    }

    func inkFrames(at time: TimeInterval) -> [RecordingInkTimeline.Frame] {
        guard showsInk, activeTrimSourcePreviewTime == nil, isPrimaryRecording(at: time) else { return [] }
        return inkTimeline.frames(at: clipTimeline.sourceTime(at: time))
    }

    /// Lands where the stroke is fully drawn, or its start if that was cut.
    func jumpToInkStroke(_ stroke: RecordingInkStroke) {
        selectedInkStrokeID = stroke.id
        pause()
        let end = stroke.points.last.flatMap { editorTime(forSourceTime: $0.t) }
        if let time = end ?? editorTime(forSourceTime: stroke.startTime) { seek(to: time) }
    }

    func deleteInkStroke(_ id: UUID) {
        applyHiddenInk(hiddenInkStrokeIDs.union([id]))
        if selectedInkStrokeID == id { selectedInkStrokeID = nil }
    }

    private func applyHiddenInk(_ next: Set<UUID>) {
        guard next != hiddenInkStrokeIDs else { return }
        let previous = hiddenInkStrokeIDs
        hiddenInkStrokeIDs = next
        inkTimeline = RecordingInkTimeline(strokes: pointerCapture.ink, hiding: next)
        registerUndo("Delete Drawing") { $0.applyHiddenInk(previous) }
        scheduleProjectSave()
    }

    // MARK: - Transcription

    /// Only narrated sessions can be transcribed; the mic requirement means
    /// legacy bare movies and silent captures never show the section.
    var canTranscribe: Bool {
        manifest?.includesMicrophone == true
    }

    var hasSubtitles: Bool {
        !subtitleTimeline.isEmpty
    }

    /// Subtitle text to draw over the card right now; nil when hidden or
    /// nobody is speaking, or on imported clips.
    func subtitleText(at time: TimeInterval) -> String? {
        guard showsSubtitles, hasSubtitles, activeTrimSourcePreviewTime == nil,
              isPrimaryRecording(at: time) else { return nil }
        return subtitleTimeline.text(at: clipTimeline.sourceTime(at: time))
    }

    /// Karaoke word state for the bar at this editor time; nil when the
    /// style doesn't highlight words, no timings exist, or on imported clips.
    func subtitleKaraokeLine(at time: TimeInterval) -> KaraokeTimeline.Line? {
        guard showsSubtitles, subtitleStyle.highlightsSpokenWord,
              !karaokeTimeline.isEmpty, activeTrimSourcePreviewTime == nil,
              isPrimaryRecording(at: time) else {
            return nil
        }
        return karaokeTimeline.line(at: clipTimeline.sourceTime(at: time))
    }

    func transcribe() {
        guard !transcriptionState.isTranscribing, isLoaded else { return }
        transcriptionState = .transcribing
        let movieURL = screenURL
        transcriptionTask = Task { [weak self] in
            do {
                let transcript = try await RecordingTranscriptionService.transcribe(screenMovieURL: movieURL)
                guard !Task.isCancelled else { return }
                self?.applyTranscription(transcript)
            } catch {
                guard !Task.isCancelled else { return }
                self?.transcriptionState = .failed(error.localizedDescription)
            }
        }
    }

    private func rebuildCaptionTimelines() {
        guard !subtitleCues.isEmpty else {
            subtitleTimeline = .empty
            karaokeTimeline = .empty
            return
        }
        let captions = clipTimeline.segments.isEmpty
            ? RecordingTranscript(words: transcriptWords, cues: subtitleCues)
            : RecordingTranscript(words: transcriptWords, cues: subtitleCues).renderCaptions(in: clipTimeline)
        subtitleTimeline = SubtitleTimeline(cues: captions.cues)
        karaokeTimeline = KaraokeTimeline(cues: captions.cues, words: captions.words)
    }

    private func applyTranscription(_ transcript: RecordingTranscript) {
        subtitleCues = transcript.cues
        transcriptWords = transcript.words
        rebuildCaptionTimelines()
        showsSubtitles = true
        transcriptionState = .idle
        updateActiveTranscriptWord()
        scheduleProjectSave()
    }

    func removeTranscription() {
        subtitleCues = []
        subtitleTimeline = .empty
        transcriptWords = []
        karaokeTimeline = .empty
        activeTranscriptWordIndex = nil
        transcriptionState = .idle
        scheduleProjectSave()
    }

    func updateSubtitleText(id: UUID, text: String) {
        guard let index = subtitleCues.firstIndex(where: { $0.id == id }),
              subtitleCues[index].text != text else {
            return
        }
        subtitleCues[index].text = text
        rebuildCaptionTimelines()
        scheduleProjectSave()
    }

    /// Moves the paused playhead to a cue's first surviving frame; a cue
    /// whose audio was cut out entirely has no home on the edited timeline.
    func seekToSubtitle(_ cue: RecordingSubtitleCue) {
        let target = clipTimeline.editorTime(forSourceTime: cue.start)
            ?? clipTimeline.editorTime(forSourceTime: (cue.start + cue.end) / 2)
        guard let target else { return }
        pause()
        seek(to: target)
    }

    /// Cue under the playhead right now, for highlighting the list row.
    var activeSubtitleCue: RecordingSubtitleCue? {
        guard let activeSubtitleCueID else { return nil }
        return subtitleCues.first { $0.id == activeSubtitleCueID }
    }

    // MARK: - Chapters

    var visibleChapters: [RecordingChapter] {
        RecordingChapterPlanner.mapped(chapters, through: clipTimeline, cues: subtitleCues, words: transcriptWords)
    }

    func addChapterAtPlayhead() {
        guard isLoaded, duration > 0 else { return }
        let time = min(currentTime, max(0, duration - 0.001))
        guard !visibleChapters.contains(where: { abs($0.start - time) < 0.5 }),
              let location = clipTimeline.location(at: time) else { return }
        let segment = clipTimeline.segments[location.segmentIndex]
        var chapter = RecordingChapter(
            title: "Chapter \(chapters.count + 1)",
            start: location.sourceTime,
            autoTitle: segment.isPrimaryRecording,
            mediaFileName: segment.mediaFileName,
            clipOccurrenceID: segment.isPrimaryRecording ? nil : segment.effectiveOccurrenceID
        )
        if segment.isPrimaryRecording {
            chapter.title = RecordingChapterPlanner.mapped(
                chapters + [chapter], through: clipTimeline, cues: subtitleCues, words: transcriptWords
            ).first(where: { $0.id == chapter.id })?.title ?? chapter.title
        }
        applyChapters(chapters + [chapter], actionName: "Add Chapter")
    }

    func suggestChapters() {
        applyChapters(RecordingChapterPlanner.suggest(
            cues: subtitleCues, words: transcriptWords, timeline: clipTimeline, keeping: chapters
        ), actionName: "Suggest Chapters")
    }

    /// The name field saves as you type; saves of one chapter's name until
    /// editing ends share one undo step, so Undo takes back the whole rename.
    func renameChapter(id: UUID, title: String) {
        var next = chapters
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].title = String(title.prefix(200))
        next[index].autoTitle = false
        let continuing = renameUndoMark.map { $0.id == id && $0.revision == undoRevision } ?? false
        applyChapters(next, actionName: "Rename Chapter", registersUndo: !continuing)
        renameUndoMark = (id, undoRevision)
    }

    /// Editing a chapter's name ended; the next rename is its own undo step.
    func finishChapterRename() {
        renameUndoMark = nil
    }

    func removeChapter(id: UUID) {
        applyChapters(chapters.filter { $0.id != id }, actionName: "Remove Chapter")
    }

    /// A marker drag previews locally; its release saves once through the Chapters edit path.
    func moveChapter(id: UUID, to editorTime: TimeInterval) {
        guard isLoaded, !hasRunningWork,
              let time = RecordingChapterPlanner.clampedStart(id: id, proposed: editorTime,
                  chapters: visibleChapters, duration: duration),
              let location = clipTimeline.location(at: time),
              let index = chapters.firstIndex(where: { $0.id == id }) else { return }
        let segment = clipTimeline.segments[location.segmentIndex]
        var next = chapters
        next[index].start = location.sourceTime
        next[index].mediaFileName = segment.mediaFileName
        next[index].clipOccurrenceID = segment.isPrimaryRecording ? nil : segment.effectiveOccurrenceID
        applyChapters(next, actionName: "Move Chapter")
    }

    func jumpToChapter(_ chapter: RecordingChapter) {
        pause()
        seek(to: chapter.start)
    }

    private func applyChapters(_ next: [RecordingChapter], actionName: String, registersUndo: Bool = true) {
        guard !isReadOnlyNewerFormat, let session, next != chapters else { return }
        do {
            try session.updateProjectMetadata { $0.chapters = next }
            let previous = chapters
            if registersUndo { registerUndo(actionName) { $0.applyChapters(previous, actionName: actionName) } }
            chapters = next
            chapterError = nil
        } catch {
            chapterError = "Chapters could not be saved: \(error.localizedDescription)"
        }
    }

    var openingSentenceTitle: String {
        RecordingChapterPlanner.openingSentenceTitle(cues: subtitleCues, words: transcriptWords, through: clipTimeline)
    }

    // MARK: - Summary and chapter titles (Apple Intelligence)

    /// Why Summarize and Name Chapters can't run here, or nil when they can.
    var textModelUnavailableReason: String? { OnDeviceText.unavailableReason() }

    /// The narration as it survives the edits, a chapter's title before its first line.
    private var narrationLines: [String] {
        RecordingTextIntelligence.narrationLines(
            chapters: visibleChapters,
            cues: RecordingChapterPlanner.survivingCues(subtitleCues, words: transcriptWords, through: clipTimeline),
            editorTime: { [clipTimeline] in clipTimeline.editorTime(forSourceTime: $0) })
    }

    func summarize() {
        guard !isSummarizing, textModelUnavailableReason == nil else { return }
        let lines = narrationLines
        guard !lines.isEmpty else {
            summaryNote = "Transcribe the narration first; the summary is written from it."
            return
        }
        let source = session?.loadProjectMetadata()?.source
        let model = textModel
        isSummarizing = true
        summaryNote = nil
        Task { [weak self] in
            do {
                let text = try await RecordingTextIntelligence.summary(lines: lines, source: source, model: model)
                guard let self, !self.isTornDown else { return }
                self.isSummarizing = false
                if text.isEmpty { self.summaryNote = "Apple Intelligence wrote nothing for this narration." } else { self.setSummary(text) }
            } catch {
                self?.isSummarizing = false
                self?.summaryNote = OnDeviceText.message(for: error)
            }
        }
    }

    /// Saves the summary as edited; empty removes it.
    func setSummary(_ text: String?) {
        guard !isReadOnlyNewerFormat, let session else { return }
        let trimmed = CloudShareText.trimmedSummary(text)
        let next = trimmed.isEmpty ? nil : trimmed
        guard next != summary else { return }
        do {
            try session.updateProjectMetadata { $0.summary = next }
            summary = next
            summaryNote = nil
        } catch {
            summaryNote = "The summary could not be saved: \(error.localizedDescription)"
        }
    }

    /// Replaces the chapters' titles with the model's, as one undoable edit.
    func nameChapters() {
        guard !isNamingChapters, textModelUnavailableReason == nil else { return }
        let visible = visibleChapters
        let readable = RecordingChapterPlanner.survivingCues(subtitleCues, words: transcriptWords, through: clipTimeline)
        let texts = visible.indices.map { index in
            RecordingChapterPlanner.chapterText(readable, through: clipTimeline, start: visible[index].start,
                                                end: index + 1 < visible.count ? visible[index + 1].start : clipTimeline.duration)
        }
        guard texts.contains(where: { !$0.isEmpty }) else {
            chapterError = "Transcribe the narration first; chapters are named from it."
            return
        }
        let model = textModel
        isNamingChapters = true
        chapterError = nil
        Task { [weak self] in
            do {
                let titles = try await RecordingTextIntelligence.chapterTitles(texts, model: model)
                guard let self, !self.isTornDown else { return }
                self.isNamingChapters = false
                var named: [UUID: String] = [:]
                for (chapter, title) in zip(visible, titles) { if let title { named[chapter.id] = title } }
                // Edits made while the model wrote stay; only the titles change.
                self.applyChapters(RecordingChapterPlanner.named(self.chapters, titles: named), actionName: "Name Chapters")
            } catch {
                self?.isNamingChapters = false
                self?.chapterError = OnDeviceText.message(for: error)
            }
        }
    }

    // MARK: - Translated captions

    /// The language the captions are in, as read from their text.
    var captionSourceLanguage: Locale.Language? {
        RecordingCaptionTranslation.sourceLanguage(of: subtitleCues)
    }

    /// Translates the captions into each language in turn; the view's
    /// translation task runs each one, after the system's download prompt if it needs one.
    func translateCaptions(to languages: [Locale.Language]) {
        guard translationConfiguration == nil, hasSubtitles, !languages.isEmpty else { return }
        translationQueue = languages
        translationNote = nil
        startNextTranslation()
    }

    private func startNextTranslation() {
        guard !translationQueue.isEmpty else {
            translationConfiguration = nil
            return
        }
        translationConfiguration = TranslationSession.Configuration(source: captionSourceLanguage, target: translationQueue.removeFirst())
    }

    func translate(using session: TranslationSession) async {
        guard let target = translationConfiguration?.target else { return }
        let cues = subtitleCues
        let lang = RecordingCaptionTranslation.tag(target)
        do {
            let requests = cues.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString) }
            let responses = try await session.translations(from: requests)
            var translations: [String: String] = [:]
            for response in responses { if let id = response.clientIdentifier { translations[id] = response.targetText } }
            let track = RecordingCaptionTranslation.track(lang: lang, cues: cues, translations: translations)
            saveCaptionTracks(RecordingCaptionTranslation.merging(track, into: captionTracks))
        } catch is CancellationError {
            translationQueue = []
        } catch {
            translationNote = "\(RecordingCaptionTranslation.label(for: lang)) couldn’t be translated: \(error.localizedDescription)"
        }
        startNextTranslation()
    }

    var isTranslating: Bool { translationConfiguration != nil }

    func cancelTranslation() {
        translationQueue = []
        translationConfiguration = nil
    }

    func updateTranslatedCue(lang: String, id: UUID, text: String) {
        guard let track = captionTracks.firstIndex(where: { $0.lang == lang }),
              let cue = captionTracks[track].cues.firstIndex(where: { $0.id == id }),
              captionTracks[track].cues[cue].text != text else { return }
        var tracks = captionTracks
        tracks[track].cues[cue].text = text
        saveCaptionTracks(tracks)
    }

    func removeCaptionTrack(lang: String) {
        saveCaptionTracks(captionTracks.filter { $0.lang != lang })
    }

    private func saveCaptionTracks(_ tracks: [RecordingCaptionTrack]) {
        guard !isReadOnlyNewerFormat, let session else { return }
        do {
            try session.updateProjectMetadata { $0.captionTracks = tracks.isEmpty ? nil : tracks }
            captionTracks = tracks
        } catch {
            translationNote = "Translations could not be saved: \(error.localizedDescription)"
        }
    }

    // MARK: - Transcript editing

    /// Cues-only projects (transcribed before words were stored) can still
    /// show captions but need a fresh transcription to edit by text.
    var hasTranscriptWords: Bool {
        !transcriptWords.isEmpty
    }

    /// Whether this word's audio still exists on the edited timeline.
    func transcriptWordSurvives(_ index: Int) -> Bool {
        guard transcriptWords.indices.contains(index) else { return false }
        return clipTimeline.editorTime(forSourceTime: transcriptWords[index].midpoint) != nil
    }

    func isFillerWord(_ index: Int) -> Bool {
        fillerWordIndices.contains(index)
    }

    /// Fillers that would actually be cut - ones already removed don't count.
    var removableFillerWordIndices: [Int] {
        fillerWordIndices.sorted().filter { transcriptWordSurvives($0) }
    }

    var removableFillerWordCount: Int { removableFillerWordIndices.count }

    /// Filler words in the transcript's language, read once when the words
    /// or the discourse option change, not for every word chip drawn.
    private func refreshFillerWords() {
        transcriptLanguage = transcriptWords.isEmpty ? nil : TranscriptEditPlanner.language(of: transcriptWords)
        fillerWordIndices = Set(TranscriptEditPlanner.fillerIndices(
            in: transcriptWords, language: transcriptLanguage, includingDiscourse: includesDiscourseFillers))
    }

    /// Pauses over the threshold that are quiet and still, ready to shorten;
    /// how many stay because something happens on screen; and the ones whose
    /// frames haven't been compared yet.
    struct PauseSummary {
        var shortenable: [PausePlanner.Pause] = []
        var kept: [PausePlanner.Pause] = []
        var checking: [PausePlanner.Pause] = []
        var saved: TimeInterval { shortenable.reduce(0) { $0 + $1.saved } }
    }

    var pauseSummary: PauseSummary {
        let size = CGSize(width: videoSize.width / CGFloat(max(manifest?.pixelScale ?? 1, 1)),
                          height: videoSize.height / CGFloat(max(manifest?.pixelScale ?? 1, 1)))
        var summary = PauseSummary()
        for pause in PausePlanner.pauses(
            words: transcriptWords, timeline: clipTimeline, sourceDuration: sourceDuration,
            threshold: pauseThreshold, beat: pauseBeat, capture: pointerCapture, pointSize: size
        ) {
            switch (pause.activity, pauseScreenStill[Self.pauseKey(pause.gap)]) {
            case (nil, true?): summary.shortenable.append(pause)
            case (nil, nil): summary.checking.append(pause)
            default: summary.kept.append(pause)
            }
        }
        return summary
    }

    private static func pauseKey(_ gap: ClosedRange<TimeInterval>) -> [Int] {
        [Int((gap.lowerBound * 1000).rounded()), Int((gap.upperBound * 1000).rounded())]
    }

    /// Compares the frames of every quiet pause not yet checked. The source
    /// movie never changes, so a pause is checked once per Studio session.
    func checkPauseScreens() async {
        guard let asset = screenAsset else { return }
        while let pause = pauseSummary.checking.first, !Task.isCancelled {
            let still = await StudioPauseScreenCheck.isStill(asset: asset, gap: pause.gap)
            guard !Task.isCancelled, !isTornDown else { return }
            pauseScreenStill[Self.pauseKey(pause.gap)] = still
        }
    }

    /// Moves the paused playhead to a word's first surviving frame.
    func seekToTranscriptWord(at index: Int) {
        guard transcriptWords.indices.contains(index) else { return }
        let word = transcriptWords[index]
        let target = clipTimeline.editorTime(forSourceTime: word.start)
            ?? clipTimeline.editorTime(forSourceTime: word.midpoint)
        guard let target else { return }
        pause()
        seek(to: target)
    }

    /// Cuts the selected words' footage out of the video.
    func cutTranscriptWords(in range: ClosedRange<Int>) {
        guard let cut = TranscriptEditPlanner.cutRange(
            forWordsAt: range,
            in: transcriptWords,
            sourceDuration: sourceDuration
        ) else { return }
        cutSourceRanges([cut], actionName: range.count == 1 ? "Cut Word" : "Cut Words")
    }

    /// Cuts every surviving filler in one undoable step.
    func removeFillerWords() {
        cutSourceRanges(
            TranscriptEditPlanner.fillerCutRanges(at: removableFillerWordIndices, in: transcriptWords,
                                                  sourceDuration: sourceDuration),
            actionName: "Remove Filler Words"
        )
        previewsFillerWords = false
    }

    /// Shortens every quiet, still pause to the beat in one undoable step.
    func shortenPauses() {
        cutSourceRanges(pauseSummary.shortenable.map(\.cut), actionName: "Shorten Pauses")
    }

    /// The shared transcript-cut path: removes source ranges from the clip
    /// timeline and drops the cut words from any overlapping captions. Both
    /// registrations land in one undo group, so a single ⌘Z restores the
    /// footage and the caption text together.
    private func cutSourceRanges(_ ranges: [ClosedRange<TimeInterval>], actionName: String) {
        let merged = RecordingClipTimeline.mergedRanges(ranges)
        guard !merged.isEmpty,
              let next = clipTimeline.removingSourceRanges(merged)?.normalized(to: sourceDuration),
              next != clipTimeline else {
            return
        }

        let keptChapters = TranscriptEditPlanner.chapters(chapters, keptThrough: merged)
        if keptChapters != chapters {
            applyChapters(keptChapters, actionName: actionName)
        }

        let updatedCues = Self.rebuildingCueTexts(
            subtitleCues,
            words: transcriptWords,
            cutRanges: merged,
            surviving: next
        )
        if updatedCues != subtitleCues {
            applySubtitleCues(updatedCues, actionName: actionName)
        }

        // Park the playhead on the first splice so the result is audible
        // right where the cut happened.
        let playhead = next.editorTime(forSourceTime: merged[0].upperBound)
            ?? min(currentTime, next.duration)
        applyClipTimeline(
            next,
            selectedID: selectedClipID,
            selectsClip: selectedClipID != nil,
            playheadTime: playhead,
            actionName: actionName
        )
    }

    private func applySubtitleCues(_ cues: [RecordingSubtitleCue], actionName: String) {
        guard cues != subtitleCues else { return }
        let previous = subtitleCues
        registerUndo(actionName) { target in
            target.applySubtitleCues(previous, actionName: actionName)
        }
        subtitleCues = cues
        rebuildCaptionTimelines()
        scheduleProjectSave()
    }

    /// Rewrites the text of cues touched by a cut so captions stop showing
    /// words whose audio is gone. Only touched cues are rebuilt, so manual
    /// caption edits elsewhere survive. A word belongs to the last cue that
    /// starts at or before it.
    private static func rebuildingCueTexts(
        _ cues: [RecordingSubtitleCue],
        words: [RecordingTranscriptWord],
        cutRanges: [ClosedRange<TimeInterval>],
        surviving timeline: RecordingClipTimeline
    ) -> [RecordingSubtitleCue] {
        guard !words.isEmpty, !cues.isEmpty else { return cues }
        var result = cues
        let byStart = result.indices.sorted { result[$0].start < result[$1].start }

        for (position, index) in byStart.enumerated() {
            let cue = result[index]
            let overlapsCut = cutRanges.contains {
                $0.lowerBound < cue.end && $0.upperBound > cue.start
            }
            guard overlapsCut else { continue }

            let nextCueStart = position < byStart.count - 1
                ? result[byStart[position + 1]].start
                : .infinity
            result[index].text = words
                .filter { word in
                    word.start >= cue.start - 0.001
                        && word.start < nextCueStart - 0.001
                        && timeline.editorTime(forSourceTime: word.midpoint) != nil
                }
                .map(\.text)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private func refreshPlayheadMarks() {
        let location = clipTimeline.location(at: currentTime)
        let clipID = location?.segmentID
        if clipID != playheadClipID { playheadClipID = clipID }
        let isPrimary = location.map { clipTimeline.segments[$0.segmentIndex].isPrimaryRecording } ?? false
        let cueID = subtitleTimeline.isEmpty || !isPrimary
            ? nil
            : subtitleTimeline.cue(at: location?.sourceTime ?? 0)?.id
        if cueID != activeSubtitleCueID { activeSubtitleCueID = cueID }
    }

    /// Recomputes which word the playhead is on; assigns only on change so
    /// observation-driven views wake on word boundaries, not every tick.
    private func updateActiveTranscriptWord() {
        guard !transcriptWords.isEmpty, isPrimaryRecording(at: currentTime) else {
            if activeTranscriptWordIndex != nil {
                activeTranscriptWordIndex = nil
            }
            return
        }
        let index = Self.transcriptWordIndex(
            at: clipTimeline.sourceTime(at: currentTime),
            in: transcriptWords
        )
        if activeTranscriptWordIndex != index {
            activeTranscriptWordIndex = index
        }
    }

    /// Last word started at or before this source time, if the time is
    /// still within it (with a small bridge across inter-word gaps so the
    /// highlight doesn't flicker between words).
    private static func transcriptWordIndex(
        at sourceTime: TimeInterval,
        in words: [RecordingTranscriptWord]
    ) -> Int? {
        guard sourceTime.isFinite,
              let index = words.lastIndex(atOrBefore: sourceTime, by: \.start)
        else { return nil }
        return sourceTime <= words[index].end + 0.25 ? index : nil
    }

    /// Caption to draw over the card right now; nil when hidden, silent, or on imported clips.
    func keystrokeCaption(at time: TimeInterval) -> KeystrokeCaptionFrame? {
        guard showsKeystrokes, hasKeystrokes, activeTrimSourcePreviewTime == nil,
              isPrimaryRecording(at: time) else { return nil }
        return keystrokeTimeline.frame(at: clipTimeline.sourceTime(at: time))
    }

    private var recordingPointSize: CGSize {
        let scale = max(CGFloat(manifest?.pixelScale ?? 1), 1)
        return CGSize(width: videoSize.width / scale, height: videoSize.height / scale)
    }

    // MARK: - Overlay ranges

    private func sourceRange(
        startingAt editorTime: TimeInterval,
        length: TimeInterval,
        minimum: TimeInterval
    ) -> ClosedRange<TimeInterval>? {
        guard sourceDuration >= minimum else { return nil }
        return clipTimeline.insertionSourceRange(
            atEditorTime: min(max(editorTime, 0), duration),
            length: length,
            minimum: minimum
        )
    }

    private func sourceRange(
        fromEditorTime editorStart: TimeInterval,
        toEditorTime editorEnd: TimeInterval,
        minimum: TimeInterval
    ) -> ClosedRange<TimeInterval>? {
        guard sourceDuration >= minimum else { return nil }
        return clipTimeline.drawnSourceRange(
            fromEditorTime: min(max(editorStart, 0), duration),
            toEditorTime: min(max(editorEnd, 0), duration),
            minimum: minimum
        )
    }

    private func clampedSourceRange(start: TimeInterval, end: TimeInterval, minimum: TimeInterval) -> ClosedRange<TimeInterval> {
        let lower = min(max(0, start), max(0, sourceDuration - minimum))
        let upper = min(max(end, lower + minimum), sourceDuration)
        return lower...max(lower, upper)
    }

    // MARK: - Text overlays

    var selectedText: RecordingTextOverlay? {
        textOverlays.first { $0.id == selectedTextID }
    }

    var textTimelineBlocks: [RecordingOverlayTimelineBlock<RecordingTextOverlay>] {
        RecordingOverlayTimelineBlock.blocks(for: textOverlays, clipTimeline: clipTimeline) {
            ($0.start, $0.end)
        }
    }

    /// The texts showing at an editor time, bottom to top.
    func texts(atEditorTime time: TimeInterval) -> [RecordingTextOverlay] {
        guard activeTrimSourcePreviewTime == nil, !textOverlays.isEmpty,
              isPrimaryRecording(at: time) else { return [] }
        let sourceTime = clipTimeline.sourceTime(at: time)
        return textOverlays.filter { $0.isActive(atSourceTime: sourceTime) }
    }

    func selectText(id: UUID) {
        guard textOverlays.contains(where: { $0.id == id }) else { return }
        clearTimelineSelection()
        selectedTextID = id
    }

    /// Adds a text at the playhead, three seconds long.
    func addText(atEditorTime time: TimeInterval) {
        guard let range = sourceRange(startingAt: time, length: RecordingTextOverlay.defaultDuration,
                                      minimum: RecordingTextOverlay.minimumDuration) else { return }
        insertText(RecordingTextOverlay(start: range.lowerBound, end: range.upperBound))
    }

    /// Adds a text over a range dragged across the text track.
    func addText(fromEditorTime editorStart: TimeInterval, toEditorTime editorEnd: TimeInterval) {
        guard let range = sourceRange(fromEditorTime: editorStart, toEditorTime: editorEnd,
                                      minimum: RecordingTextOverlay.minimumDuration) else { return }
        insertText(RecordingTextOverlay(start: range.lowerBound, end: range.upperBound))
    }

    private func insertText(_ overlay: RecordingTextOverlay) {
        applyTexts(textOverlays + [overlay], actionName: "Add Text")
        selectText(id: overlay.id)
    }

    func removeText(id: UUID) {
        applyTexts(textOverlays.filter { $0.id != id }, actionName: "Remove Text")
        if selectedTextID == id { selectedTextID = nil }
    }

    func beginTextEdit() {
        commitPendingOverlayEdits(excluding: .text)
        if pendingTextEdit.isCoalescing { endTextEdit() }
        pendingTextEdit.begin(from: textOverlays)
    }

    func endTextEdit(actionName: String = "Edit Text") {
        guard let commit = pendingTextEdit.takeCommit(current: textOverlays, fallbackActionName: actionName) else {
            undoRevision &+= 1
            return
        }
        registerUndo(commit.actionName) { target in
            target.applyTexts(commit.previous, actionName: commit.actionName)
        }
    }

    func setText(_ overlay: RecordingTextOverlay) {
        guard let index = textOverlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        var texts = textOverlays
        var updated = overlay
        let range = clampedSourceRange(start: overlay.start, end: overlay.end, minimum: RecordingTextOverlay.minimumDuration)
        updated.start = range.lowerBound
        updated.end = range.upperBound
        updated.fontSize = min(max(updated.fontSize, RecordingTextOverlay.fontSizeRange.lowerBound),
                               RecordingTextOverlay.fontSizeRange.upperBound)
        updated.center = CGPoint(x: min(max(updated.center.x, 0), 1), y: min(max(updated.center.y, 0), 1))
        texts[index] = updated
        replaceTexts(texts)
        if pendingTextEdit.isActive { undoRevision &+= 1 }
    }

    func editText(_ overlay: RecordingTextOverlay, actionName: String) {
        commitPendingOverlayEdits(excluding: .text)
        if pendingTextEdit.isActive, !pendingTextEdit.actionName.isEmpty, pendingTextEdit.actionName != actionName {
            endTextEdit()
        }
        pendingTextEdit.begin(from: textOverlays, actionName: actionName)
        setText(overlay)
        pendingTextEdit.scheduleCommit(actionName: actionName) { [weak self] in
            self?.endTextEdit(actionName: actionName)
        }
    }

    private func replaceTexts(_ texts: [RecordingTextOverlay]) {
        textOverlays = texts
        scheduleProjectSave()
    }

    private func applyTexts(_ texts: [RecordingTextOverlay], actionName: String) {
        if !editUndoManager.isUndoing && !editUndoManager.isRedoing {
            commitPendingOverlayEdits()
        }
        guard texts != textOverlays else { return }
        let previous = textOverlays
        registerUndo(actionName) { target in
            target.applyTexts(previous, actionName: actionName)
        }
        replaceTexts(texts)
        if let selectedTextID, !texts.contains(where: { $0.id == selectedTextID }) {
            self.selectedTextID = nil
        }
    }

    // MARK: - Media & Image overlays

    /// Where imported images and audio are copied; nil for a bare movie,
    /// which has no project folder to keep them in.
    var mediaDirectoryURL: URL? {
        session?.mediaDirectoryURL
    }

    var canImportMedia: Bool { mediaDirectoryURL != nil && isLoaded && !isReadOnlyNewerFormat }

    /// Routes a timeline Finder drop across video clips, video overlays, and
    /// image/audio media while preserving any rejected-destination warning
    /// alongside valid sibling files in a mixed drop.
    func handleTimelineMediaDrop(
        urls: [URL],
        atEditorTime time: TimeInterval,
        audioLane: Int,
        insertionIndex: Int,
        targetLane: StudioMovieDropLane?
    ) {
        let videos = urls.filter { StudioVideoClipImport.canImport($0) || RecordingVideoOverlay.canImport($0) }
        let others = urls.filter { !StudioVideoClipImport.canImport($0) && !RecordingVideoOverlay.canImport($0) }
        var videoLaneError: String?
        if !videos.isEmpty {
            switch StudioMediaDropRouting.videoDestination(
                for: targetLane,
                canDropClip: canImportVideoClip,
                canDropOverlay: canImportMedia
            ) {
            case .clips:
                requestImportVideoClips(videos, insertionIndex: insertionIndex)
            case .videoOverlay:
                importVideoOverlays(videos, atEditorTime: time)
            default:
                videoLaneError = "Drop videos onto the Clips lane to insert in sequence, or onto the Video Overlay lane to add a PiP or cutaway."
            }
        }
        if !others.isEmpty {
            importMedia(others, atEditorTime: time, audioLane: audioLane, priorError: videoLaneError)
        } else if let videoLaneError {
            mediaImportError = videoLaneError
        }
    }

    /// Copies picked images and GIFs into the project's `media` folder and places
    /// them from `time`. Audio files target `audioLane` (the highlighted lane on
    /// a Finder drop, or lane 0 from the picker).
    func importMedia(
        _ urls: [URL],
        atEditorTime time: TimeInterval,
        audioLane: Int = 0,
        priorError: String? = nil
    ) {
        guard !isReadOnlyNewerFormat, let directory = mediaDirectoryURL else { return }
        mediaImportError = priorError
        let videoURLs = urls.filter { !RecordingOverlayImage.canImport($0) && RecordingVideoOverlay.canImport($0) }
        let otherURLs = urls.filter { RecordingOverlayImage.canImport($0) || !RecordingVideoOverlay.canImport($0) }
        if !videoURLs.isEmpty {
            importVideoOverlays(videoURLs, atEditorTime: time)
        }
        guard !otherURLs.isEmpty else { return }
        Task { [weak self] in
            var imageTime = time
            var audioTime = time
            var rejected: [String] = []
            for url in otherURLs {
                guard let self, !self.isTornDown else { return }
                if RecordingOverlayImage.canImport(url) {
                    if let placed = await self.importImage(url, into: directory, atEditorTime: imageTime) {
                        imageTime = placed
                    } else {
                        rejected.append(url.lastPathComponent)
                    }
                } else if let placed = await self.importAudioMedia(
                    url,
                    into: directory,
                    atEditorTime: audioTime,
                    preferredLane: audioLane
                ) {
                    audioTime = placed
                } else {
                    rejected.append(url.lastPathComponent)
                }
            }
            if !rejected.isEmpty {
                let otherError = "Couldn't add \(rejected.joined(separator: ", ")). Images, animated GIF/APNG/WebP/HEIC, video, and audio files can be added."
                self?.mediaImportError = [priorError, otherError].compactMap { $0 }.joined(separator: " ")
            }
        }
    }

    /// One file, awaited. False when the file isn't supported media.
    func importMediaFile(_ url: URL, atEditorTime time: TimeInterval, audioLane: Int = 0) async -> Bool {
        guard let directory = mediaDirectoryURL, !isTornDown else { return false }
        if RecordingOverlayImage.canImport(url) {
            return await importImage(url, into: directory, atEditorTime: time) != nil
        }
        if RecordingVideoOverlay.canImportVideoFile(url) {
            return await importVideoOverlayFile(url, displayName: url.deletingPathExtension().lastPathComponent, into: directory, atEditorTime: time) != nil
        }
        return await importAudioMedia(url, into: directory, atEditorTime: time, preferredLane: audioLane) != nil
    }

    /// Routes dropped or picked audio files into the project's audio lanes.
    func importAudioMedia(
        _ url: URL,
        into directory: URL,
        atEditorTime time: TimeInterval,
        preferredLane: Int = 0
    ) async -> TimeInterval? {
        guard RecordingAudioClip.canImport(url) else { return nil }
        return await importAudio(url, into: directory, atEditorTime: time, preferredLane: preferredLane)
    }

    func copyMediaIntoProject(_ url: URL, directory: URL) -> String? {
        RecordingOverlayMedia.copyRegularFile(from: url, into: directory)
    }

    /// Adds one image at an editor time. Returns where the next one goes.
    private func importImage(_ url: URL, into directory: URL, atEditorTime time: TimeInterval) async -> TimeInterval? {
        guard let fileName = copyMediaIntoProject(url, directory: directory),
              let storedURL = RecordingOverlayMedia.resolveRegularFile(named: fileName, in: directory) else { return nil }
        let store = overlayImages
        let decoded = await Task.detached(priority: .userInitiated) { store.image(at: storedURL) }.value
        guard let decoded, !isTornDown,
              let range = sourceRange(startingAt: time, length: RecordingImageOverlay.defaultDuration,
                                      minimum: RecordingImageOverlay.minimumDuration) else {
            try? FileManager.default.removeItem(at: storedURL)
            return nil
        }
        var overlay = RecordingImageOverlay(
            fileName: fileName,
            displayName: url.deletingPathExtension().lastPathComponent,
            start: range.lowerBound,
            end: range.upperBound
        )
        overlay.aspect = decoded.aspect
        overlay.isAnimated = decoded.isAnimated
        // At most 40% of the canvas wide and half of it tall.
        overlay.width = RecordingImageOverlay.initialWidth(aspect: decoded.aspect, canvasSize: basePreviewCanvasSize)
        overlayImageRevision &+= 1
        applyImages(imageOverlays + [overlay], actionName: "Add Image")
        selectImage(id: overlay.id)
        return clipTimeline.editorRuns(overlapping: range.lowerBound, sourceEnd: range.upperBound).first?.editorEnd
            ?? time + RecordingImageOverlay.defaultDuration
    }

    private func loadOverlayMedia() {
        mediaLoadTask?.cancel()
        guard let directory = mediaDirectoryURL, !imageOverlays.isEmpty else { return }
        let imageFiles = Set(imageOverlays.map(\.fileName))
        let store = overlayImages
        mediaLoadTask = Task { [weak self] in
            await Task.detached(priority: .userInitiated) {
                for name in imageFiles {
                    guard let resolved = RecordingOverlayMedia.resolveRegularFile(named: name, in: directory) else { continue }
                    _ = store.image(at: resolved)
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.overlayImageRevision &+= 1
        }
    }

    var selectedImage: RecordingImageOverlay? {
        imageOverlays.first { $0.id == selectedImageID }
    }

    var imageTimelineBlocks: [RecordingOverlayTimelineBlock<RecordingImageOverlay>] {
        RecordingOverlayTimelineBlock.blocks(for: imageOverlays, clipTimeline: clipTimeline) {
            ($0.start, $0.end)
        }
    }

    /// The images showing at an editor time, bottom to top.
    func images(atEditorTime time: TimeInterval) -> [RecordingImageOverlay] {
        guard activeTrimSourcePreviewTime == nil, !imageOverlays.isEmpty,
              isPrimaryRecording(at: time) else { return [] }
        let sourceTime = clipTimeline.sourceTime(at: time)
        return imageOverlays.filter { $0.isActive(atSourceTime: sourceTime) }
    }

    func overlayImageURL(for overlay: RecordingImageOverlay) -> URL? {
        mediaDirectoryURL.flatMap { RecordingOverlayMedia.resolveRegularFile(named: overlay.fileName, in: $0) }
    }

    func notifyOverlayFrameDecoded() {
        overlayImageRevision &+= 1
    }

    func selectImage(id: UUID) {
        guard imageOverlays.contains(where: { $0.id == id }) else { return }
        clearTimelineSelection()
        selectedImageID = id
    }

    func removeImage(id: UUID) {
        applyImages(imageOverlays.filter { $0.id != id }, actionName: "Remove Image")
        if selectedImageID == id { selectedImageID = nil }
    }

    func beginImageEdit() {
        commitPendingOverlayEdits(excluding: .image)
        if pendingImageEdit.isCoalescing { endImageEdit() }
        pendingImageEdit.begin(from: imageOverlays)
    }

    func endImageEdit(actionName: String = "Edit Image") {
        guard let commit = pendingImageEdit.takeCommit(current: imageOverlays, fallbackActionName: actionName) else {
            undoRevision &+= 1
            return
        }
        registerUndo(commit.actionName) { target in
            target.applyImages(commit.previous, actionName: commit.actionName)
        }
    }

    func setImage(_ overlay: RecordingImageOverlay) {
        guard let index = imageOverlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        var updated = overlay
        let range = clampedSourceRange(start: overlay.start, end: overlay.end, minimum: RecordingImageOverlay.minimumDuration)
        updated.start = range.lowerBound
        updated.end = range.upperBound
        updated.width = RecordingImageOverlay.sanitizedWidth(
            updated.width,
            fallback: RecordingImageOverlay.widthRange.lowerBound
        )
        updated.center = CGPoint(x: min(max(updated.center.x, 0), 1), y: min(max(updated.center.y, 0), 1))
        updated.opacity = min(max(updated.opacity, 0), 1)
        var all = imageOverlays
        all[index] = updated
        imageOverlays = all
        scheduleProjectSave()
        if pendingImageEdit.isActive { undoRevision &+= 1 }
    }

    func editImage(_ overlay: RecordingImageOverlay, actionName: String) {
        commitPendingOverlayEdits(excluding: .image)
        if pendingImageEdit.isActive, !pendingImageEdit.actionName.isEmpty, pendingImageEdit.actionName != actionName {
            endImageEdit()
        }
        pendingImageEdit.begin(from: imageOverlays, actionName: actionName)
        setImage(overlay)
        pendingImageEdit.scheduleCommit(actionName: actionName) { [weak self] in
            self?.endImageEdit(actionName: actionName)
        }
    }

    private func applyImages(_ all: [RecordingImageOverlay], actionName: String) {
        if !editUndoManager.isUndoing && !editUndoManager.isRedoing {
            commitPendingOverlayEdits()
        }
        guard all != imageOverlays else { return }
        let previous = imageOverlays
        registerUndo(actionName) { target in
            target.applyImages(previous, actionName: actionName)
        }
        imageOverlays = all
        scheduleProjectSave()
        if let selectedImageID, !all.contains(where: { $0.id == selectedImageID }) {
            self.selectedImageID = nil
        }
    }

    // MARK: - Video overlays

    var selectedVideoOverlay: RecordingVideoOverlay? {
        videoOverlays.first { $0.id == selectedVideoOverlayID }
    }

    var videoOverlayOverlapSpans: [StudioLaneSpan] {
        videoOverlays.map { StudioLaneSpan(id: $0.id, editorStart: $0.start, editorEnd: $0.end) }
    }

    func activeVideoOverlay(atEditorTime time: TimeInterval) -> RecordingVideoOverlay? {
        guard activeTrimSourcePreviewTime == nil, !videoOverlays.isEmpty else { return nil }
        return StudioVideoOverlayLane.activeOverlay(in: videoOverlays, atEditorTime: time)
    }

    func cutawayCoverage(atEditorTime time: TimeInterval) -> Double {
        guard activeTrimSourcePreviewTime == nil, !videoOverlays.isEmpty else { return 0 }
        return StudioVideoOverlayLane.cutawayCoverage(in: videoOverlays, atEditorTime: time)
    }

    func isVideoOverlayMissing(_ overlay: RecordingVideoOverlay) -> Bool {
        missingVideoOverlayFiles.contains(overlay.fileName)
    }

    func selectVideoOverlay(id: UUID) {
        guard videoOverlays.contains(where: { $0.id == id }) else { return }
        clearTimelineSelection()
        selectedVideoOverlayID = id
    }

    func removeVideoOverlay(id: UUID) {
        applyVideoOverlays(videoOverlays.filter { $0.id != id }, actionName: "Remove Video Overlay")
        if selectedVideoOverlayID == id { selectedVideoOverlayID = nil }
    }

    func beginVideoOverlayEdit() {
        commitPendingOverlayEdits(excluding: .videoOverlay)
        if pendingVideoOverlayEdit.isCoalescing { endVideoOverlayEdit() }
        pendingVideoOverlayEdit.begin(from: videoOverlays)
    }

    func endVideoOverlayEdit(actionName: String = "Edit Video Overlay") {
        guard let commit = pendingVideoOverlayEdit.takeCommit(current: videoOverlays, fallbackActionName: actionName) else {
            undoRevision &+= 1
            return
        }
        registerUndo(commit.actionName) { target in
            target.applyVideoOverlays(commit.previous, actionName: commit.actionName)
        }
    }

    func setVideoOverlay(_ overlay: RecordingVideoOverlay) {
        guard let index = videoOverlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        var all = videoOverlays
        all[index] = overlay.sanitized()
        let limit = duration > 0 ? duration : nil
        replaceVideoOverlays(StudioVideoOverlayLane.normalized(all, timelineDuration: limit))
        if pendingVideoOverlayEdit.isActive { undoRevision &+= 1 }
    }

    func editVideoOverlay(_ overlay: RecordingVideoOverlay, actionName: String) {
        commitPendingOverlayEdits(excluding: .videoOverlay)
        if pendingVideoOverlayEdit.isActive, !pendingVideoOverlayEdit.actionName.isEmpty, pendingVideoOverlayEdit.actionName != actionName {
            endVideoOverlayEdit()
        }
        pendingVideoOverlayEdit.begin(from: videoOverlays, actionName: actionName)
        setVideoOverlay(overlay)
        pendingVideoOverlayEdit.scheduleCommit(actionName: actionName) { [weak self] in
            self?.endVideoOverlayEdit(actionName: actionName)
        }
    }

    func setVideoOverlayPresentation(_ presentation: RecordingVideoOverlay.Presentation, id: UUID) {
        guard let overlay = videoOverlays.first(where: { $0.id == id }),
              overlay.presentation != presentation else { return }
        let updated = overlay.switchingPresentation(to: presentation)
        applyVideoOverlays(
            videoOverlays.map { $0.id == id ? updated : $0 },
            actionName: presentation == .cutaway ? "Switch to Cutaway" : "Switch to Picture-in-Picture"
        )
    }

    func setVideoOverlaySpeed(_ speed: Double, id: UUID) {
        guard let overlay = videoOverlays.first(where: { $0.id == id }) else { return }
        let limit = duration > 0 ? duration : nil
        let updated = StudioVideoOverlayLane.withSpeed(
            overlay,
            speed: speed,
            among: videoOverlays,
            timelineDuration: limit
        )
        applyVideoOverlays(
            videoOverlays.map { $0.id == id ? updated : $0 },
            actionName: "Change Video Overlay Speed"
        )
    }

    func setVideoOverlayLinked(_ linked: Bool, id: UUID) {
        guard var overlay = videoOverlays.first(where: { $0.id == id }),
              overlay.isLinked != linked else { return }
        overlay.isLinked = linked
        applyVideoOverlays(
            videoOverlays.map { $0.id == id ? overlay : $0 },
            actionName: linked ? "Link Video Overlay to Video" : "Unlink Video Overlay from Video"
        )
    }

    func toggleVideoOverlayMuted(id: UUID) {
        guard var overlay = videoOverlays.first(where: { $0.id == id }) else { return }
        overlay.isMuted.toggle()
        applyVideoOverlays(
            videoOverlays.map { $0.id == id ? overlay : $0 },
            actionName: overlay.isMuted ? "Mute Video Overlay" : "Unmute Video Overlay"
        )
        showNotice(overlay.isMuted ? "Muted" : "Unmuted")
    }

    private func replaceVideoOverlays(_ all: [RecordingVideoOverlay]) {
        videoOverlays = all
        scheduleProjectSave()
        if audioPlan.placement != playbackAudioPlacement {
            scheduleAudioPlaybackRebuild()
        } else {
            updatePlaybackVolume()
        }
        if isPlaying {
            syncVideoOverlayPlayback()
        } else {
            moveVideoOverlayPlayer(to: displayTime)
        }
    }

    private func applyVideoOverlays(_ requested: [RecordingVideoOverlay], actionName: String) {
        if !editUndoManager.isUndoing && !editUndoManager.isRedoing {
            commitPendingOverlayEdits()
        }
        let limit = duration > 0 ? duration : nil
        let all = StudioVideoOverlayLane.normalized(requested, timelineDuration: limit)
        guard all != videoOverlays else { return }
        let previous = videoOverlays
        registerUndo(actionName) { target in
            target.applyVideoOverlays(previous, actionName: actionName)
        }
        replaceVideoOverlays(all)
        if let selectedVideoOverlayID, !all.contains(where: { $0.id == selectedVideoOverlayID }) {
            self.selectedVideoOverlayID = nil
        }
    }

    /// Imports video files or Sukusho `.sukushorec` recordings onto the layered
    /// video overlay lane. Refuses importing the currently open recording into
    /// itself, validates `.sukushorec` packages before offering Raw vs Finished,
    /// and never reads `project.json` from unvalidated or rejected packages.
    func importVideoOverlays(_ urls: [URL], atEditorTime time: TimeInterval) {
        guard mediaDirectoryURL != nil, isLoaded, !urls.isEmpty else { return }
        mediaImportError = nil

        var accepted: [URL] = []
        var rejectedSelf = false
        var rejectedPackages: [String] = []
        var recordingNames: [String] = []
        var allFinishedValid = true
        for url in urls {
            if RecordingSession.isSessionDirectory(url) {
                if RecordingVideoOverlayMedia.isSelfRecording(url, openSessionURL: sessionURL) {
                    rejectedSelf = true
                    continue
                }
                let fallbackName = url.deletingPathExtension().lastPathComponent
                guard (try? RecordingSessionRenderer.validateRawImport(in: url)) != nil else {
                    rejectedPackages.append(fallbackName)
                    continue
                }
                let finishedValid = (try? RecordingPackageMedia.validateRenderInputs(in: url)) != nil
                if !finishedValid {
                    allFinishedValid = false
                }
                let safeDisplayName: String
                if finishedValid
                    || (try? RecordingPackageMedia.resolveOptionalPackageFile(
                        named: RecordingSession.projectMetadataFileName,
                        in: url
                    )) != nil {
                    safeDisplayName = RecordingSession(directoryURL: url).displayName
                } else {
                    safeDisplayName = fallbackName
                }
                recordingNames.append(safeDisplayName)
            }
            accepted.append(url)
        }

        if accepted.isEmpty {
            if !rejectedPackages.isEmpty {
                mediaImportError = "Couldn't add \(rejectedPackages.joined(separator: ", ")). Check that the recording package and its media files are readable."
            } else if rejectedSelf {
                mediaImportError = RecordingVideoOverlayMedia.selfImportErrorMessage
            }
            return
        }

        if rejectedSelf {
            mediaImportError = RecordingVideoOverlayMedia.selfImportErrorMessage
        } else if !rejectedPackages.isEmpty {
            mediaImportError = "Couldn't add \(rejectedPackages.joined(separator: ", ")). Check that the recording package and its media files are readable."
        }

        if !recordingNames.isEmpty {
            pendingRecordingOverlayImport = PendingRecordingOverlayImport(
                urls: accepted,
                editorTime: time,
                recordingNames: recordingNames,
                canImportFinished: allFinishedValid
            )
            return
        }
        runVideoOverlayImport(
            urls: accepted,
            atEditorTime: time,
            recordingMode: .raw,
            initialError: mediaImportError
        )
    }

    func resolvePendingRecordingImport(mode: RecordingOverlayImportMode) {
        guard let pending = pendingRecordingOverlayImport else { return }
        pendingRecordingOverlayImport = nil
        runVideoOverlayImport(
            urls: pending.urls,
            atEditorTime: pending.editorTime,
            recordingMode: mode,
            initialError: mediaImportError
        )
    }

    func cancelPendingRecordingImport() {
        pendingRecordingOverlayImport = nil
        pendingRecordingImport = nil
    }

    func cancelVideoOverlayRender() {
        videoOverlayImportTask?.cancel()
        videoOverlayImportTask = nil
        videoOverlayImportID = nil
        videoOverlayRenderProgress = nil
    }

    private func runVideoOverlayImport(
        urls: [URL],
        atEditorTime time: TimeInterval,
        recordingMode: RecordingOverlayImportMode,
        initialError: String? = nil
    ) {
        guard let directory = mediaDirectoryURL else { return }
        let importID = UUID()
        videoOverlayImportTask?.cancel()
        videoOverlayImportID = importID
        videoOverlayRenderProgress = nil
        videoOverlayImportTask = Task { [weak self] in
            defer {
                if self?.videoOverlayImportID == importID {
                    self?.videoOverlayRenderProgress = nil
                    self?.videoOverlayImportTask = nil
                    self?.videoOverlayImportID = nil
                }
            }
            var cursor = time
            var rejected: [String] = []
            var sawSelfImport = false
            for url in urls {
                guard let self, !self.isTornDown, !Task.isCancelled,
                      self.videoOverlayImportID == importID else { return }
                let sourceURL: URL
                let displayName: String
                var temporaryRawRenderURL: URL?
                if RecordingSession.isSessionDirectory(url) {
                    if RecordingVideoOverlayMedia.isSelfRecording(url, openSessionURL: self.sessionURL) {
                        sawSelfImport = true
                        continue
                    }
                    let fallbackName = url.deletingPathExtension().lastPathComponent
                    let sourceSession = RecordingSession(directoryURL: url)
                    switch recordingMode {
                    case .raw:
                        let safeName: String
                        if (try? RecordingPackageMedia.resolveOptionalPackageFile(
                            named: RecordingSession.projectMetadataFileName,
                            in: url
                        )) != nil {
                            safeName = sourceSession.displayName
                        } else {
                            safeName = fallbackName
                        }
                        do {
                            let prepared = try await RecordingSessionRenderer.prepareRawImport(for: url) { [weak self] progress in
                                Task { @MainActor [weak self] in
                                    if self?.videoOverlayImportID == importID {
                                        self?.videoOverlayRenderProgress = progress
                                    }
                                }
                            }
                            if self.videoOverlayImportID == importID {
                                self.videoOverlayRenderProgress = nil
                            }
                            displayName = safeName
                            sourceURL = prepared.url
                            if prepared.isTemporary {
                                temporaryRawRenderURL = prepared.url
                            }
                        } catch is CancellationError {
                            return
                        } catch RecordingStudioExporter.ExportError.cancelled {
                            return
                        } catch {
                            if self.videoOverlayImportID == importID {
                                self.videoOverlayRenderProgress = nil
                            }
                            rejected.append(fallbackName)
                            continue
                        }
                    case .finished:
                        guard (try? RecordingPackageMedia.validateRenderInputs(in: url)) != nil else {
                            rejected.append(fallbackName)
                            continue
                        }
                        displayName = sourceSession.displayName
                        self.videoOverlayRenderProgress = 0
                        do {
                            sourceURL = try await RecordingSessionRenderer.ensureDeliverable(for: sourceSession) { [weak self] progress in
                                Task { @MainActor [weak self] in
                                    if self?.videoOverlayImportID == importID, self?.videoOverlayRenderProgress != nil {
                                        self?.videoOverlayRenderProgress = progress
                                    }
                                }
                            }
                            if self.videoOverlayImportID == importID {
                                self.videoOverlayRenderProgress = nil
                            }
                        } catch is CancellationError {
                            return
                        } catch RecordingStudioExporter.ExportError.cancelled {
                            return
                        } catch {
                            if self.videoOverlayImportID == importID {
                                self.videoOverlayRenderProgress = nil
                            }
                            rejected.append(displayName)
                            continue
                        }
                    }
                } else if RecordingVideoOverlay.canImportVideoFile(url) {
                    sourceURL = url
                    displayName = url.deletingPathExtension().lastPathComponent
                } else {
                    rejected.append(url.lastPathComponent)
                    continue
                }
                defer {
                    if let temporaryRawRenderURL {
                        try? FileManager.default.removeItem(at: temporaryRawRenderURL)
                    }
                }
                guard !self.isTornDown, !Task.isCancelled, self.videoOverlayImportID == importID else { return }
                if let placedEnd = await self.importVideoOverlayFile(
                    sourceURL,
                    displayName: displayName,
                    into: directory,
                    atEditorTime: cursor,
                    importID: importID
                ) {
                    cursor = placedEnd
                } else {
                    rejected.append(displayName)
                }
            }
            guard let self, !self.isTornDown, !Task.isCancelled,
                  self.videoOverlayImportID == importID else { return }
            if !rejected.isEmpty {
                self.mediaImportError = "Couldn't add \(rejected.joined(separator: ", ")). Check that the file is a readable video and there is open space on the video overlay lane."
            } else if sawSelfImport {
                self.mediaImportError = RecordingVideoOverlayMedia.selfImportErrorMessage
            } else if let initialError {
                self.mediaImportError = initialError
            }
        }
    }

    private func importVideoOverlayFile(
        _ url: URL,
        displayName: String,
        into directory: URL,
        atEditorTime time: TimeInterval,
        importID: UUID? = nil
    ) async -> TimeInterval? {
        guard let fileName = copyMediaIntoProject(url, directory: directory),
              let storedURL = RecordingOverlayMedia.resolveRegularFile(named: fileName, in: directory) else {
            return nil
        }
        var adopted = false
        defer {
            if !adopted {
                try? FileManager.default.removeItem(at: storedURL)
            }
        }
        guard let probe = await RecordingVideoOverlayMedia.probe(url: storedURL),
              !isTornDown, !Task.isCancelled,
              importID == nil || videoOverlayImportID == importID else {
            return nil
        }
        var loadedTracks: [StudioAudioSources.Track] = []
        if probe.hasAudio, audioSources.files[fileName] == nil {
            loadedTracks = await StudioAudioSources.Track.loadAll(of: AVURLAsset(url: storedURL))
            guard !isTornDown, !Task.isCancelled,
                  importID == nil || videoOverlayImportID == importID else {
                return nil
            }
        }
        // Recheck placement after the final await so it always reflects the
        // live lane occupancy and timeline duration.
        var candidate = RecordingVideoOverlay(
            fileName: fileName,
            displayName: displayName,
            start: time,
            fileDuration: probe.duration,
            presentation: .pip
        )
        candidate.aspect = probe.aspect
        candidate.hasAudio = probe.hasAudio
        candidate.width = RecordingVideoOverlay.initialWidth(aspect: probe.aspect, canvasSize: basePreviewCanvasSize)
        candidate.center = RecordingVideoOverlay.initialCenter(cameraVisible: hasCameraVideo && style.camera.isVisible)
        guard let placed = StudioVideoOverlayLane.place(
            candidate,
            at: time,
            timelineDuration: duration,
            among: videoOverlays
        ) else {
            return nil
        }
        if !loadedTracks.isEmpty {
            audioSources.files[fileName] = loadedTracks
        }
        missingVideoOverlayFiles.remove(fileName)
        undoReferencedFiles.insert(fileName)
        adopted = true
        applyVideoOverlays(videoOverlays + [placed], actionName: "Add Video Overlay")
        selectVideoOverlay(id: placed.id)
        return placed.end
    }

    private func resolveVideoOverlaySources() async {
        missingVideoOverlayFiles.removeAll()
        guard !videoOverlays.isEmpty else { return }
        guard let directory = mediaDirectoryURL else {
            missingVideoOverlayFiles.formUnion(videoOverlays.map(\.fileName))
            return
        }
        for name in Set(videoOverlays.map(\.fileName)) {
            guard let url = RecordingOverlayMedia.resolveRegularFile(named: name, in: directory) else {
                missingVideoOverlayFiles.insert(name)
                continue
            }
            undoReferencedFiles.insert(name)
            if audioSources.files[name] == nil {
                let tracks = await StudioAudioSources.Track.loadAll(of: AVURLAsset(url: url))
                guard !Task.isCancelled, !isTornDown else { return }
                if !tracks.isEmpty {
                    audioSources.files[name] = tracks
                }
            }
        }
    }

    // MARK: Recycled video overlay player sync

    private func clearVideoOverlayPlayer() {
        guard videoOverlayPlayer.currentItem != nil
            || loadedVideoOverlayFileName != nil
            || loadedVideoOverlayID != nil
            || videoOverlaySeek.isSeeking
            || videoOverlaySeek.pendingTarget != nil
            || videoOverlayPlayer.rate != 0 else { return }
        videoOverlaySeek.invalidate()
        videoOverlayPlayer.pause()
        if videoOverlayPlayer.currentItem != nil {
            videoOverlayPlayer.replaceCurrentItem(with: nil)
        }
        loadedVideoOverlayFileName = nil
        loadedVideoOverlayID = nil
    }

    private func ensureVideoOverlayItemLoaded(for overlay: RecordingVideoOverlay) -> Bool {
        if loadedVideoOverlayFileName == overlay.fileName, videoOverlayPlayer.currentItem != nil {
            return true
        }
        guard let directory = mediaDirectoryURL,
              let url = RecordingOverlayMedia.resolveRegularFile(named: overlay.fileName, in: directory) else {
            clearVideoOverlayPlayer()
            return false
        }
        let item = AVPlayerItem(url: url)
        videoOverlayPlayer.replaceCurrentItem(with: item)
        videoOverlayPlayer.isMuted = true
        videoOverlayPlayer.actionAtItemEnd = .pause
        loadedVideoOverlayFileName = overlay.fileName
        loadedVideoOverlayID = overlay.id
        return true
    }

    private func moveVideoOverlayPlayer(to editorTime: TimeInterval) {
        let plan = StudioVideoOverlayPlaybackPlan.resolve(
            at: editorTime,
            isPlaying: false,
            shuttleRate: shuttleRate,
            overlays: videoOverlays
        )
        switch plan {
        case .clear:
            clearVideoOverlayPlayer()
        case .preload(let overlay, let mediaTime), .active(let overlay, let mediaTime, _):
            videoOverlaySeek.invalidate()
            guard ensureVideoOverlayItemLoaded(for: overlay) else { return }
            loadedVideoOverlayID = overlay.id
            videoOverlayPlayer.pause()
            let target = CMTime(seconds: max(0, mediaTime), preferredTimescale: StudioPlayback.seekTimescale)
            videoOverlayPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func syncVideoOverlayPlayback() {
        let plan = StudioVideoOverlayPlaybackPlan.resolve(
            at: currentTime,
            isPlaying: isPlaying,
            shuttleRate: shuttleRate,
            overlays: videoOverlays
        )
        switch plan {
        case .clear:
            clearVideoOverlayPlayer()
        case .preload(let overlay, let mediaTime):
            let switchedOverlay = loadedVideoOverlayID != overlay.id
            guard ensureVideoOverlayItemLoaded(for: overlay) else { return }
            loadedVideoOverlayID = overlay.id
            videoOverlayPlayer.pause()
            if switchedOverlay || abs(videoOverlayPlayer.currentTime().seconds - mediaTime) > 0.05 {
                videoOverlaySeek.invalidate()
                let target = CMTime(seconds: max(0, mediaTime), preferredTimescale: StudioPlayback.seekTimescale)
                videoOverlayPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        case .active(let overlay, let mediaTime, let targetRate):
            guard ensureVideoOverlayItemLoaded(for: overlay) else { return }
            loadedVideoOverlayID = overlay.id
            let rate = targetRate ?? Float(overlay.speed) * shuttleRate
            if !Self.playbackCapabilities(of: videoOverlayPlayer.currentItem).supports(rate: rate),
               videoOverlayPlayer.rate != 0 {
                videoOverlayPlayer.pause()
            }
            if let dispatch = videoOverlaySeek.requestSeek(to: max(0, mediaTime)) {
                dispatchVideoOverlaySeek(generation: dispatch.generation, seconds: dispatch.target)
            }
        }
    }

    private func dispatchVideoOverlaySeek(generation: Int, seconds: TimeInterval) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: StudioPlayback.seekTimescale)
        videoOverlayPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.finishVideoOverlaySeek(generation: generation, finished: finished)
            }
        }
    }

    private func finishVideoOverlaySeek(generation: Int, finished: Bool) {
        guard isPlaying else {
            videoOverlaySeek.invalidate()
            return
        }
        switch videoOverlaySeek.completeSeek(generation: generation, finished: finished) {
        case .ignore:
            return
        case .startCoalescedSeek(let nextGeneration, let nextTarget):
            dispatchVideoOverlaySeek(generation: nextGeneration, seconds: nextTarget)
        case .applyPlaybackRate:
            guard let active = StudioVideoOverlayLane.activeOverlay(in: videoOverlays, atEditorTime: currentTime),
                  active.id == loadedVideoOverlayID else {
                videoOverlayPlayer.pause()
                return
            }
            let rate = Float(active.speed) * shuttleRate
            if Self.playbackCapabilities(of: videoOverlayPlayer.currentItem).supports(rate: rate) {
                videoOverlayPlayer.rate = rate
            } else {
                videoOverlayPlayer.pause()
            }
        }
    }

    private func correctVideoOverlayDriftIfNeeded() {
        guard isPlaying else { return }
        if videoOverlays.isEmpty {
            clearVideoOverlayPlayer()
            return
        }
        let plan = StudioVideoOverlayPlaybackPlan.resolve(
            at: currentTime,
            isPlaying: true,
            shuttleRate: shuttleRate,
            overlays: videoOverlays
        )
        switch plan {
        case .clear:
            clearVideoOverlayPlayer()
        case .preload:
            syncVideoOverlayPlayback()
        case .active(let overlay, let expected, let rate):
            let previousID = loadedVideoOverlayID
            guard ensureVideoOverlayItemLoaded(for: overlay) else { return }
            let targetRate = rate ?? Float(overlay.speed) * shuttleRate
            guard Self.playbackCapabilities(of: videoOverlayPlayer.currentItem).supports(rate: targetRate) else {
                loadedVideoOverlayID = overlay.id
                if videoOverlayPlayer.rate != 0 { videoOverlayPlayer.pause() }
                if expected.isFinite, let dispatch = videoOverlaySeek.requestSeek(to: max(0, expected)) {
                    dispatchVideoOverlaySeek(generation: dispatch.generation, seconds: dispatch.target)
                }
                return
            }
            if videoOverlaySeek.isSeeking {
                if overlay.id != previousID, expected.isFinite {
                    loadedVideoOverlayID = overlay.id
                    _ = videoOverlaySeek.requestSeek(to: max(0, expected))
                }
                return
            }
            if videoOverlayPlayer.rate == 0 || overlay.id != previousID {
                syncVideoOverlayPlayback()
                return
            }
            if abs(videoOverlayPlayer.rate - targetRate) > 0.01 {
                videoOverlayPlayer.rate = targetRate
            }
            let actual = videoOverlayPlayer.currentTime().seconds
            if StudioPlayback.shouldResyncCamera(
                expected: expected,
                actual: actual,
                segmentID: overlay.id,
                lastSegmentID: previousID,
                shuttleRate: shuttleRate
            ) {
                syncVideoOverlayPlayback()
            }
        }
    }

    // MARK: - Redactions & Video crop

    var selectedRedaction: RecordingRedaction? {
        redactions.first { $0.id == selectedRedactionID }
    }

    var redactionTimelineBlocks: [RecordingOverlayTimelineBlock<RecordingRedaction>] {
        RecordingOverlayTimelineBlock.blocks(for: redactions, clipTimeline: clipTimeline) {
            ($0.start, $0.end)
        }
    }

    /// The redactions showing at an editor time.
    func redactions(atEditorTime time: TimeInterval) -> [RecordingRedaction] {
        guard activeTrimSourcePreviewTime == nil, !redactions.isEmpty,
              isPrimaryRecording(at: time) else { return [] }
        let sourceTime = clipTimeline.sourceTime(at: time)
        return redactions.filter { $0.start <= sourceTime && sourceTime < $0.end }
    }

    func selectRedaction(id: UUID) {
        guard redactions.contains(where: { $0.id == id }) else { return }
        clearTimelineSelection()
        selectedRedactionID = id
    }

    func beginRedaction() {
        guard isLoaded, !hasRunningWork else { return }
        pause()
        cancelVideoCrop()
        clearTimelineSelection()
        hoverPreviewTime = nil
        workingVideoCropRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        videoCropAspect = .freeform
        isSelectingRedaction = true
    }

    func cancelRedaction() { isSelectingRedaction = false }

    func addRedaction() {
        guard isSelectingRedaction,
              let range = clipTimeline.redactionCoverageSourceRange(
                atEditorTime: min(max(currentTime, 0), duration),
                sourceDuration: sourceDuration,
                minimum: RecordingRedaction.minimumDuration
              ) else { return }
        let region = RecordingRedaction(start: range.lowerBound, end: range.upperBound, rect: workingVideoCropRect)
        applyRedactions(redactions + [region], actionName: "Add Redaction")
        selectRedaction(id: region.id)
        isSelectingRedaction = false
    }

    /// Adds a pixelate or blur block at the playhead, three seconds long,
    /// centered on the recorded picture; drag its handles on the canvas to place it.
    func addRedaction(atEditorTime time: TimeInterval, mode: RecordingRedaction.Mode = .pixelate) {
        guard isLoaded, !hasRunningWork,
              let range = sourceRange(startingAt: time, length: RecordingRedaction.defaultDuration,
                                      minimum: RecordingRedaction.minimumDuration) else { return }
        let region = RecordingRedaction(
            start: range.lowerBound,
            end: range.upperBound,
            rect: RecordingRedaction.defaultRect,
            mode: mode
        )
        applyRedactions(redactions + [region], actionName: mode == .blur ? "Add Blur" : "Add Pixelate")
        selectRedaction(id: region.id)
    }

    func updateRedaction(_ region: RecordingRedaction, actionName: String = "Video Redaction") {
        applyRedactions(redactions.map { $0.id == region.id ? region : $0 }, actionName: actionName)
    }

    func removeRedaction(_ id: UUID) {
        applyRedactions(redactions.filter { $0.id != id }, actionName: "Remove Redaction")
        if selectedRedactionID == id { selectedRedactionID = nil }
    }

    func removeRedaction(id: UUID) {
        removeRedaction(id)
    }

    func beginRedactionEdit() {
        commitPendingOverlayEdits(excluding: .redaction)
        if pendingRedactionEdit.isCoalescing { endRedactionEdit() }
        pendingRedactionEdit.begin(from: redactions)
    }

    func endRedactionEdit(actionName: String = "Edit Redaction") {
        guard let commit = pendingRedactionEdit.takeCommit(current: redactions, fallbackActionName: actionName) else {
            undoRevision &+= 1
            return
        }
        let previous = commit.previous
        do { for region in redactions { try region.validate(sourceDuration: sourceDuration) } }
        catch {
            redactions = previous
            redactionPreview.update(redactions: previous, clipTimeline: clipTimeline)
            redactionEditError = error.localizedDescription
            scheduleRedactionRefresh()
            return
        }
        guard writeDraftNow() else {
            redactions = previous
            redactionPreview.update(redactions: previous, clipTimeline: clipTimeline)
            FailureAlert.present(message: "The video redaction could not be saved",
                                 error: CocoaError(.fileWriteUnknown),
                                 detail: "The change was not applied. Resolve the project storage problem and try again.")
            scheduleRedactionRefresh()
            return
        }
        registerUndo(commit.actionName) { $0.applyRedactions(previous, actionName: commit.actionName) }
        scheduleProjectSave()
        QuickLookPreviewPresenter.dismiss()
        if let session { ScreenshotPreviewStack.shared.dismissRecordingSession(session.directoryURL) }
        RecordingProjectStore.shared.reload()
        loadTimelineThumbnails()
        loadStylePoster()
    }

    /// Applies an edited region during a continuous canvas or timeline drag,
    /// keeping it validated and inside the recording and picture.
    func setRedaction(_ redaction: RecordingRedaction) {
        guard let index = redactions.firstIndex(where: { $0.id == redaction.id }) else { return }
        redactionEditError = nil
        var updated = redaction
        let range = clampedSourceRange(start: redaction.start, end: redaction.end, minimum: RecordingRedaction.minimumDuration)
        updated.start = range.lowerBound
        updated.end = range.upperBound
        updated.rect = RecordingRedaction.clamped(redaction.rect)
        updated.strength = min(max(updated.strength, 0), 1)
        do { try updated.validate(sourceDuration: sourceDuration) }
        catch { redactionEditError = error.localizedDescription; return }
        var all = redactions
        all[index] = updated
        let wasEmpty = redactions.isEmpty
        redactions = all
        redactionPreview.update(redactions: all, clipTimeline: clipTimeline)
        if wasEmpty {
            do { try rebuildScreenPlayerItem(preserving: currentTime) }
            catch { cutRedactionPreviewError = error.localizedDescription }
        } else {
            scheduleRedactionRefresh()
        }
        scheduleProjectSave()
        if pendingRedactionEdit.isActive { undoRevision &+= 1 }
    }

    func editRedaction(_ redaction: RecordingRedaction, actionName: String) {
        commitPendingOverlayEdits(excluding: .redaction)
        if pendingRedactionEdit.isActive, !pendingRedactionEdit.actionName.isEmpty, pendingRedactionEdit.actionName != actionName {
            endRedactionEdit()
        }
        pendingRedactionEdit.begin(from: redactions, actionName: actionName)
        setRedaction(redaction)
        pendingRedactionEdit.scheduleCommit(actionName: actionName) { [weak self] in
            self?.endRedactionEdit(actionName: actionName)
        }
    }

    /// Refreshes the paused player frame when a redaction is moved, resized,
    /// or adjusted without tearing down the player item.
    private func scheduleRedactionRefresh() {
        guard !isPlaying, redactionRefreshTask == nil else { return }
        redactionRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, !Task.isCancelled else { return }
            self.redactionRefreshTask = nil
            guard !self.isPlaying, !self.isTornDown,
                  self.activeTrimSourcePreviewTime == nil,
                  let item = self.screenPlayer.currentItem else { return }
            if self.clipTimeline.hasImportedClips {
                if let primarySource = self.primaryVideoSource {
                    do {
                        let (_, videoComposition, builtTimeMap) = try RecordingCompositionBuilder.makeMultiSourceVideoComposition(
                            primarySource: primarySource,
                            importedSources: self.importedVideoSources,
                            timeline: self.clipTimeline,
                            renderSize: self.videoSize,
                            targetRect: self.multiSourceTargetRect,
                            redactionSource: self.redactions.isEmpty ? nil : self.redactionPreview
                        )
                        self.compositionTimeMap = builtTimeMap
                        self.redactionPreview.update(
                            redactions: self.redactions,
                            clipTimeline: self.clipTimeline,
                            timeMap: builtTimeMap
                        )
                        item.videoComposition = videoComposition
                    } catch {
                        self.cutRedactionPreviewError = error.localizedDescription
                        return
                    }
                }
            } else if !self.redactions.isEmpty {
                do {
                    item.videoComposition = try await self.redactionPreview.composition(asset: item.asset)
                } catch {
                    self.cutRedactionPreviewError = error.localizedDescription
                    return
                }
            } else {
                item.videoComposition = nil
            }
            self.movePlayers(to: self.displayTime)
        }
    }

    private func applyRedactions(_ next: [RecordingRedaction], actionName: String = "Video Redaction") {
        if !editUndoManager.isUndoing && !editUndoManager.isRedoing {
            commitPendingOverlayEdits()
        }
        redactionEditError = nil
        guard next != redactions else { return }
        do { for region in next { try region.validate(sourceDuration: sourceDuration) } }
        catch { redactionEditError = error.localizedDescription; return }
        let previous = redactions
        pause()
        redactions = next
        redactionPreview.update(redactions: next, clipTimeline: clipTimeline)
        guard writeDraftNow() else {
            redactions = previous
            redactionPreview.update(redactions: previous, clipTimeline: clipTimeline)
            FailureAlert.present(message: "The video redaction could not be saved",
                                 error: CocoaError(.fileWriteUnknown),
                                 detail: "The change was not applied. Resolve the project storage problem and try again.")
            return
        }
        registerUndo(actionName) { $0.applyRedactions(previous, actionName: actionName) }
        if let selectedRedactionID, !next.contains(where: { $0.id == selectedRedactionID }) {
            self.selectedRedactionID = nil
        }
        scheduleProjectSave()
        QuickLookPreviewPresenter.dismiss()
        if let session { ScreenshotPreviewStack.shared.dismissRecordingSession(session.directoryURL) }
        RecordingProjectStore.shared.reload()
        do { try rebuildScreenPlayerItem(preserving: currentTime) }
        catch { cutRedactionPreviewError = error.localizedDescription }
        loadTimelineThumbnails()
        loadStylePoster()
    }

    var isVideoCropped: Bool {
        RecordingVideoCropGeometry.isCropped(videoCropRect)
    }

    var videoCropPixelSize: CGSize {
        let crop = isCroppingVideo ? workingVideoCropRect : videoCropRect
        return CGSize(
            width: (videoSize.width * crop.width).rounded(),
            height: (videoSize.height * crop.height).rounded()
        )
    }

    func beginVideoCrop() {
        guard !isCroppingVideo, videoSize.width > 0, videoSize.height > 0 else {
            return
        }
        pause()
        cancelRedaction()
        workingVideoCropRect = videoCropRect
        videoCropAspect = .freeform
        isCroppingVideo = true
    }

    func cancelVideoCrop() {
        guard isCroppingVideo else { return }
        workingVideoCropRect = videoCropRect
        videoCropAspect = .freeform
        isCroppingVideo = false
    }

    func resetVideoCrop() {
        guard isCroppingVideo else { return }
        if let ratio = videoCropAspect.normalizedRatio(imageSize: videoSize) {
            workingVideoCropRect = CropRectEditor.applyAspect(
                to: CropRectEditor.unit,
                aspect: ratio
            )
        } else {
            workingVideoCropRect = CropRectEditor.unit
        }
    }

    func setVideoCropAspect(_ aspect: CropAspectRatio) {
        videoCropAspect = aspect
        guard isCroppingVideo,
              let ratio = aspect.normalizedRatio(imageSize: videoSize) else {
            return
        }
        workingVideoCropRect = CropRectEditor.applyAspect(
            to: workingVideoCropRect,
            aspect: ratio
        )
    }

    func moveVideoCrop(from start: CGRect, byNormalized delta: CGSize) {
        guard isEditingSourceRegion else { return }
        workingVideoCropRect = CropRectEditor.move(start, by: delta)
    }

    func updateVideoCrop(handle: CropHandle, toNormalized point: CGPoint) {
        guard isEditingSourceRegion else { return }
        let aspect = handle.isCorner
            ? videoCropAspect.normalizedRatio(imageSize: videoSize)
            : nil
        workingVideoCropRect = CropRectEditor.resize(
            workingVideoCropRect,
            handle: handle,
            to: point,
            aspect: aspect,
            minWidth: min(1, 24 / max(videoSize.width, 1)),
            minHeight: min(1, 24 / max(videoSize.height, 1)),
            fromCenter: isVideoCropCenterResizeModifierPressed
        )
    }

    func applyVideoCrop() {
        guard isCroppingVideo else { return }
        let next = RecordingVideoCropGeometry.normalized(workingVideoCropRect)
        isCroppingVideo = false
        videoCropAspect = .freeform
        workingVideoCropRect = next
        applyVideoCrop(next, actionName: "Crop Video")
    }

    private func applyVideoCrop(_ requested: CGRect, actionName: String) {
        let next = RecordingVideoCropGeometry.normalized(requested)
        guard next != videoCropRect else { return }
        let previous = videoCropRect
        registerUndo(actionName) { target in
            target.applyVideoCrop(previous, actionName: actionName)
        }
        videoCropRect = next
    }

    private var isVideoCropCenterResizeModifierPressed: Bool {
        let flags = NSEvent.modifierFlags
        return flags.contains(.option) || (flags.contains(.command) && flags.contains(.shift))
    }

    func isCameraVisible(at time: TimeInterval) -> Bool {
        // No time gate on primary segments: before cameraOffset the player is
        // parked on the camera's first frame, which beats the bubble popping in
        // late. On imported clips the primary webcam bubble stays hidden.
        hasCameraVideo && style.camera.isVisible && isPrimaryRecording(at: time)
    }

    // MARK: - Export

    private func replacementAudioURLForExport(includeAudio: Bool) throws -> URL? {
        let usesUnpinnedReplacementClip = audioClips.contains { $0.source == .replacement && $0.fileName.isEmpty }
        guard includeAudio, RecordingAudioGain.normalized(Double(audioVolume)) > 0 || usesUnpinnedReplacementClip else {
            return nil
        }
        let url = replacementAudio?.url ?? replacementAudioReference.flatMap {
            session?.directoryURL.appendingPathComponent($0.fileName)
        }
        if let url, !FileManager.default.fileExists(atPath: url.path) {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "The project's replacement soundtrack is missing. Open the recording in Studio, then reset to recorded audio or import the soundtrack again."
            ])
        }
        return url
    }

    private func backgroundMusicConfiguration(includeAudio: Bool) -> RecordingBackgroundMusicMixer.Configuration? {
        guard includeAudio, let settings = backgroundMusicSettings, let session else { return nil }
        return .init(url: session.directoryURL.appendingPathComponent(settings.fileName), settings: settings)
    }

    func makeExportConfiguration(settings: VideoCompressionSettings? = nil) throws -> RecordingStudioExporter.Configuration {
        if isReadOnlyNewerFormat {
            throw RecordingPackageMedia.ValidationError.unsupportedFormatVersion(
                newerFormatVersion ?? (RecordingEditDocument.currentFormatVersion + 1)
            )
        }
        let settings = settings ?? exportSettings
        let audioReplacementURL = try replacementAudioURLForExport(includeAudio: !settings.removeAudio)
        let reframe = makeReframeTrack()
        let captions = RecordingTranscript(words: transcriptWords, cues: subtitleCues).renderCaptions(in: clipTimeline)
        let fitContentAspect: CGFloat? =
            (exportAspect == .original || exportAspectMode == .fit) && videoSize.height > 0
                ? videoSize.width / videoSize.height
                : nil
        return RecordingStudioExporter.Configuration(
            screenURL: screenURL,
            cameraURL: hasCameraVideo && style.camera.isVisible ? session?.cameraURL : nil,
            cameraOffset: cameraOffset,
            style: style,
            viewportTimeline: zoomEnabled ? viewportTimeline : .identity,
            pointerTimeline: pointerIsSynthesized ? pointerTimeline : nil,
            showsPressEffects: showsPressEffects,
            keystrokeTimeline: showsKeystrokes && hasKeystrokes ? keystrokeTimeline : nil,
            keystrokePlacement: keystrokePlacement,
            subtitleTimeline: showsSubtitles && !captions.cues.isEmpty ? SubtitleTimeline(cues: captions.cues) : nil,
            subtitleStyle: subtitleStyle,
            karaokeTimeline: showsSubtitles && !captions.cues.isEmpty && !captions.words.isEmpty
                ? KaraokeTimeline(cues: captions.cues, words: captions.words)
                : nil,
            canvasSize: basePreviewCanvasSize,
            videoCropRect: videoCropRect,
            clipTimeline: clipTimeline,
            exportSettings: settings,
            audioReplacementURL: audioReplacementURL,
            audioReplacementSync: audioReplacementURL == nil ? nil : replacementAudioSync,
            audioVolume: Double(audioVolume),
            isolatedMicrophoneURL: voiceIsolationEnabled ? isolatedMicrophone?.url : nil,
            microphoneTrackID: microphoneTrackID,
            backgroundMusic: backgroundMusicConfiguration(includeAudio: !settings.removeAudio && !settings.effectiveExportsGIF),
            audioClips: audioClips,
            mediaDirectory: mediaDirectoryURL,
            externalReplacementURLs: externalPinnedReplacementURLs,
            reframe: reframe,
            fitContentAspect: fitContentAspect,
            usesUniformPadding: exportAspect == .original,
            redactions: redactions,
            textOverlays: textOverlays,
            imageOverlays: imageOverlays,
            videoOverlays: videoOverlays,
            ink: showsInk && !inkTimeline.isEmpty ? inkTimeline : nil
        )
    }

    /// The crop-and-follow camera for non-original aspect exports. Focus
    /// comes from the recorded pointer whenever the session captured one,
    /// whether or not the cursor is drawn synthetically.
    private func makeReframeTrack() -> ReframeTrack? {
        guard exportAspect != .original, exportAspectMode == .fill else { return nil }
        let focusTimeline = reframeFocusPointer()
        let effectiveViewport = zoomEnabled ? viewportTimeline : .identity
        return ReframeTrack.build(
            preset: exportAspect,
            sourceSize: videoSize,
            viewportTimeline: effectiveViewport,
            duration: duration
        ) { editorTime in
            focusTimeline?.location(at: editorTime)
        }
    }

    /// The focus source is immutable per session, so it resolves once.
    private func reframeFocusPointer() -> PointerTimeline? {
        if reframeFocusResolved { return reframeFocusTimeline }
        reframeFocusResolved = true
        if pointerIsSynthesized {
            reframeFocusTimeline = pointerTimeline
        } else if !pointerCapture.travel.isEmpty || !pointerCapture.presses.isEmpty {
            reframeFocusTimeline = PointerTimeline.build(
                capture: pointerCapture,
                duration: sourceDuration,
                recordingSizeInPoints: recordingPointSize,
                fallbackArtwork: PointerArtworkCapture.defaultArtwork(),
                clipTimeline: clipTimeline
            )
        }
        return reframeFocusTimeline
    }

    private func rebuildPreviewReframe() {
        guard isLoaded else { return }
        previewReframe = makeReframeTrack()
    }

    // MARK: - Preview canvas

    /// What the Studio canvas shows: the target-aspect canvas when a
    /// non-original aspect is selected, the visible source plus padding otherwise.
    var basePreviewCanvasSize: CGSize {
        exportAspect == .original
            ? RecordingStudioLayout.originalCanvasSize(
                sourceSize: videoSize, style: style, contentCropRect: videoCropRect
            )
            : exportAspect.canvasSize(for: videoSize)
    }

    var previewCanvasSize: CGSize {
        if isEditingSourceRegion {
            RecordingStudioLayout.originalCanvasSize(
                sourceSize: videoSize, style: style, contentCropRect: CropRectEditor.unit
            )
        } else {
            basePreviewCanvasSize
        }
    }

    var sourceVideoAspect: CGFloat {
        videoSize.height > 0 ? videoSize.width / videoSize.height : 1
    }

    /// The source aspect remains independent of the padded canvas and video crop.
    var previewContentAspect: CGFloat? {
        guard videoSize.height > 0 else { return nil }
        return sourceVideoAspect
    }

    var previewVideoCropRect: CGRect {
        isEditingSourceRegion ? CropRectEditor.unit : videoCropRect
    }

    /// How the content occupies the card on a target-aspect canvas.
    var previewContentMode: RecordingStudioLayout.ContentMode {
        exportAspect == .original || exportAspectMode == .fit ? .fit : .fill
    }

    /// Virtual camera for the preview: identity on imported clips (zooms,
    /// reframe, and primary video crop apply only to primary-recording clips);
    /// reframe crop or zoom viewport on primary segments.
    func previewViewportFrame(at time: TimeInterval) -> ViewportFrame {
        if activeTrimSourcePreviewTime != nil {
            return RecordingVideoCropGeometry.viewport(.identity, crop: previewVideoCropRect)
        }
        guard isPrimaryRecording(at: time) else {
            return .identity
        }
        let base = previewReframe?.frame(at: time) ?? viewportFrame(at: time)
        return RecordingVideoCropGeometry.viewport(base, crop: previewVideoCropRect)
    }

    /// The flattened deliverable when it provably matches the current
    /// in-memory edits - the render is stamped with the document that
    /// produced it. Both Export and Share can then skip the render entirely.
    func freshDeliverableURL(forLocalExport: Bool = false) -> URL? {
        // Measure the actual renderer during development comparisons, even
        // when this exact document already has a flattened deliverable.
        guard ProcessInfo.processInfo.environment["SCREENDROP_EXPORT_BYPASS_CACHE"] != "1" else { return nil }
        guard let session else { return nil }
        return session.freshFinalURL(matching: currentDocument(), forLocalExport: forLocalExport)
    }

    /// `recording_<date>_<time>`, not the session package's internal name.
    private var exportSuggestedFileName: String {
        let source = session?.directoryURL ?? screenURL
        guard exportSettings.effectiveExportsGIF else {
            return VideoFileActions.exportFileName(for: source, container: exportSettings.effectiveContainer)
        }
        return ScreenshotFileNaming.recordingFileName(date: VideoFileActions.recordingDate(for: source), extension: "gif")
    }

    /// Saves a rendered movie to the export folder, or the GIF made from it
    /// when the settings ask for one. `progress` follows the GIF's frames.
    private static func save(
        movie: URL,
        as settings: VideoCompressionSettings,
        suggestedFileName: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard settings.effectiveExportsGIF else {
            return try await VideoFileActions.saveToDefaultLocation(from: movie, suggestedFileName: suggestedFileName)
        }
        let gif = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: gif) }
        try await RecordingGIFExport.write(movie: movie, to: gif, frameRate: settings.effectiveGIFFrameRate,
                                           width: settings.effectiveGIFWidth, progress: progress)
        return try await VideoFileActions.saveToDefaultLocation(from: gif, suggestedFileName: suggestedFileName)
    }

    /// Entry point for the export options popover. Assigning settings marks
    /// the project dirty and drops the cached render, so an unchanged
    /// confirmation must not touch them.
    func export(settings: VideoCompressionSettings) {
        guard !isReadOnlyNewerFormat else { return }
        if settings != exportSettings {
            exportSettings = settings
        }
        export()
    }

    /// The prompt's movie for a bare movie, rendered like a share (H.264).
    /// Sessions use their shared deliverable instead, so they need none.
    func makeAgentPromptConfiguration() throws -> RecordingStudioExporter.Configuration? {
        if isReadOnlyNewerFormat {
            throw RecordingPackageMedia.ValidationError.unsupportedFormatVersion(
                newerFormatVersion ?? (RecordingEditDocument.currentFormatVersion + 1)
            )
        }
        return session == nil ? try makeExportConfiguration(settings: currentDocument().forVideoRendering.exportSettings) : nil
    }

    /// The How-To Guide, with the edits as they stand: saved to the export location, its
    /// Markdown copied, and shown in Finder.
    func exportGuide() {
        guard let session, isLoaded, !isExportingGuide, !hasRunningWork, !hasUnreadableDraft,
              !isReadOnlyNewerFormat, !transcriptionState.isTranscribing else { return }
        pause()
        isExportingGuide = true
        Task {
            defer { isExportingGuide = false }
            do { _ = try await RecordingStepsExport.exportGuide(session: session) }
            catch is CancellationError {}
            catch { exportState = .failed(error.localizedDescription) }
        }
    }

    func exportAgentPrompt() {
        guard isLoaded, !hasRunningWork, !hasUnreadableDraft, !isReadOnlyNewerFormat,
              !transcriptionState.isTranscribing else { return }
        pause()
        let session = self.session
        let deliverableDocument: RecordingEditDocument?
        do { deliverableDocument = try session.map { try RecordingSessionRenderer.documentForDelivery(for: $0) } ?? nil }
        catch { exportState = .failed(error.localizedDescription); return }
        let document = currentDocument()
        let title = projectDisplayName
        let timeline = clipTimeline
        let configuration: RecordingStudioExporter.Configuration?
        do { configuration = try makeAgentPromptConfiguration() }
        catch { exportState = .failed(error.localizedDescription); return }
        let report: @Sendable (Double) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                if self?.exportState.isExporting == true { self?.exportState = .exporting(progress: progress) }
            }
        }
        startExportTask { [weak self] in
            self?.isExportingAgentPrompt = true
            defer { self?.isExportingAgentPrompt = false }
            do {
                let directory = try RecordingAgentPromptWriter.centralDirectory()
                let folder: URL
                if let session {
                    folder = try await RecordingAgentPromptExport.write(session: session, document: deliverableDocument, to: directory, progress: report)
                } else if let configuration {
                    let plan = RecordingAgentPromptPlan(title: title, timeline: timeline,
                                                       cues: document.subtitleCues ?? [], words: document.subtitleWords ?? [], capture: nil)
                    let movie = try await RecordingStudioExporter().export(configuration) { report($0 * 0.8) }
                    defer { try? FileManager.default.removeItem(at: movie) }
                    folder = try await RecordingAgentPromptWriter.write(movie: movie, plan: plan, to: directory) { report(0.8 + $0 * 0.2) }
                    try Task.checkCancellation()
                    // A bare movie's title is its file name.
                    try RecordingAgentPromptWriter.recordLatest(folder, title: title, recording: title)
                } else { return }
                RecordingAgentPromptExport.finished(folder)
                self?.exportState = .finished(folder)
                self?.showAgentPromptSaved()
            } catch is CancellationError {
                self?.exportState = .idle
            } catch RecordingStudioExporter.ExportError.cancelled {
                self?.exportState = .idle
            } catch {
                self?.exportState = .failed(error.localizedDescription)
            }
        }
    }

    func export() {
        // One render at a time: the share pipeline uses the same exporter,
        // so a second encode would just fight it for the media engine.
        guard !hasRunningWork, isLoaded, !hasUnreadableDraft, !isReadOnlyNewerFormat else { return }
        pause()
        let previewURL = sessionURL

        // A fresh deliverable (e.g. right after a share) is byte-identical
        // to what this render would produce - same configuration builds
        // both - so exporting becomes a plain copy into the save folder.
        // Only when the settings match exactly: shares are always H.264.
        if let cached = freshDeliverableURL(forLocalExport: true) {
            let suggestedFileName = exportSuggestedFileName
            let settings = exportSettings
            startExportTask { [weak self] in
                do {
                    let savedURL = try await Self.save(movie: cached, as: settings, suggestedFileName: suggestedFileName) { progress in
                        Task { @MainActor [weak self] in
                            if self?.exportState.isExporting == true { self?.exportState = .exporting(progress: progress) }
                        }
                    }
                    RecordingExportNotifier.notifySuccess(fileURL: savedURL)
                    RecordingExportNotifier.revealIfPreferred(fileURL: savedURL)
                    ScreenshotPreviewStack.shared.dismissVideo(for: previewURL)
                    self?.exportState = .finished(savedURL)
                } catch is CancellationError {
                    self?.exportState = .idle
                } catch {
                    self?.exportState = .failed(error.localizedDescription)
                }
            }
            return
        }

        let configuration: RecordingStudioExporter.Configuration
        do {
            configuration = try makeExportConfiguration()
        } catch {
            exportState = .failed(error.localizedDescription)
            return
        }
        let suggestedFileName = exportSuggestedFileName
        let settings = exportSettings
        // The render's share of the bar; a GIF's frames take the rest.
        let renderShare = settings.effectiveExportsGIF ? 0.8 : 1.0

        let dockProgressID = DockExportProgressCoordinator.shared.start()

        startExportTask { [weak self] in
            do {
                let exporter = RecordingStudioExporter()
                let report: @Sendable (Double) -> Void = { progress in
                    Task { @MainActor [weak self] in
                        DockExportProgressCoordinator.shared.update(dockProgressID, progress: progress)
                        if self?.exportState.isExporting == true {
                            self?.exportState = .exporting(progress: progress)
                        }
                    }
                }
                let temporaryURL = try await exporter.export(configuration) { report($0 * renderShare) }
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                let savedURL = try await Self.save(movie: temporaryURL, as: settings, suggestedFileName: suggestedFileName) {
                    report(renderShare + $0 * (1 - renderShare))
                }
                DockExportProgressCoordinator.shared.finish(dockProgressID, completed: true)
                RecordingExportNotifier.notifySuccess(fileURL: savedURL)
                RecordingExportNotifier.revealIfPreferred(fileURL: savedURL)
                ScreenshotPreviewStack.shared.dismissVideo(for: previewURL)
                self?.exportState = .finished(savedURL)
            } catch is CancellationError {
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                self?.exportState = .idle
            } catch RecordingStudioExporter.ExportError.cancelled {
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                self?.exportState = .idle
            } catch {
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                self?.exportState = .failed(error.localizedDescription)
            }
        }
    }

    private func showAgentPromptSaved() {
        showsAgentPromptSaved = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.showsAgentPromptSaved = false
        }
    }

    func startExportTask(_ operation: @escaping @MainActor () async -> Void) {
        guard exportTask == nil else { return }
        exportState = .exporting(progress: 0)
        exportTask = Task { [weak self] in
            defer { self?.exportTask = nil }
            await operation()
        }
    }

    func cancelExport() {
        // Cancellation is cooperative; keep retry and close guarded until the task exits.
        exportTask?.cancel()
    }

    // MARK: - In-sequence video clips

    var canImportVideoClip: Bool {
        mediaDirectoryURL != nil && isLoaded && !isRestoringDocument && !isEditingSourceRegion && !isImportingVideoClip && !isReadOnlyNewerFormat
    }

    /// Opens a file picker accepting movie files and Sukusho `.sukushorec`
    /// recordings, inserting after the selected clip or at the playhead/end.
    func presentInsertVideoClipPanel() {
        guard canImportVideoClip else { return }
        pause()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Insert"
        panel.title = "Insert Video Clip"
        panel.message = "Choose movie files or Sukusho recordings to insert into the timeline."
        let delegate = StudioVideoOpenPanelDelegate()
        panel.delegate = delegate
        let insertionIndex = StudioEditing.videoClipInsertionIndex(
            selectedClipID: selectedClipID,
            playheadTime: currentTime,
            in: clipTimeline
        )
        let response = withExtendedLifetime(delegate) { panel.runModal() }
        guard response == .OK, !panel.urls.isEmpty else { return }
        requestImportVideoClips(panel.urls, insertionIndex: insertionIndex)
    }

    /// Entry point shared by `+ › Video Clip`, `Clip › Insert Video Clip…`,
    /// and Finder drops onto the clips lane. Plain movies import immediately;
    /// Sukusho `.sukushorec` recordings ask raw vs finished each time.
    func requestImportVideoClips(_ urls: [URL], insertionIndex: Int) {
        guard canImportVideoClip, !urls.isEmpty else { return }
        mediaImportError = nil

        var accepted: [URL] = []
        var rejectedSelf = false
        var rejectedPackages: [String] = []
        var unsupportedNames: [String] = []
        var recordingNames: [String] = []
        var allFinishedValid = true

        for url in urls {
            if RecordingSession.isSessionDirectory(url) || StudioVideoClipImport.isSukushoRecording(url) {
                if RecordingVideoOverlayMedia.isSelfRecording(url, openSessionURL: sessionURL) {
                    rejectedSelf = true
                    continue
                }
                let fallbackName = url.deletingPathExtension().lastPathComponent
                guard (try? RecordingSessionRenderer.validateRawImport(in: url)) != nil else {
                    rejectedPackages.append(fallbackName)
                    continue
                }
                let finishedValid = (try? RecordingPackageMedia.validateRenderInputs(in: url)) != nil
                if !finishedValid {
                    allFinishedValid = false
                }
                let safeDisplayName: String
                if finishedValid
                    || (try? RecordingPackageMedia.resolveOptionalPackageFile(
                        named: RecordingSession.projectMetadataFileName,
                        in: url
                    )) != nil {
                    safeDisplayName = RecordingSession(directoryURL: url).displayName
                } else {
                    safeDisplayName = fallbackName
                }
                recordingNames.append(safeDisplayName)
                accepted.append(url)
            } else if StudioVideoClipImport.isMovieFile(url) {
                accepted.append(url)
            } else {
                unsupportedNames.append(url.lastPathComponent)
            }
        }

        if accepted.isEmpty {
            if !rejectedPackages.isEmpty {
                mediaImportError = "Couldn't add \(rejectedPackages.joined(separator: ", ")). Check that the recording package and its media files are readable."
            } else if rejectedSelf {
                mediaImportError = RecordingVideoOverlayMedia.selfImportErrorMessage
            } else if !unsupportedNames.isEmpty {
                mediaImportError = "Couldn't add \(unsupportedNames.joined(separator: ", ")). Choose movie files or Sukusho recordings."
            }
            return
        }

        if rejectedSelf {
            mediaImportError = RecordingVideoOverlayMedia.selfImportErrorMessage
        } else if !rejectedPackages.isEmpty {
            mediaImportError = "Couldn't add \(rejectedPackages.joined(separator: ", ")). Check that the recording package and its media files are readable."
        }

        if !recordingNames.isEmpty {
            pause()
            pendingRecordingImport = PendingRecordingImport(
                urls: accepted,
                insertionIndex: insertionIndex,
                recordingNames: recordingNames,
                canImportFinished: allFinishedValid
            )
            return
        }
        importVideoClips(accepted, insertionIndex: insertionIndex, recordingMode: .rawRecording)
    }

    func confirmPendingRecordingImport(mode: StudioVideoClipImport.SukushoRecordingMode) {
        guard let pending = pendingRecordingImport else { return }
        pendingRecordingImport = nil
        importVideoClips(pending.urls, insertionIndex: pending.insertionIndex, recordingMode: mode)
    }

    func cancelVideoImport() {
        videoImportTask?.cancel()
    }

    private func importVideoClips(
        _ urls: [URL],
        insertionIndex: Int,
        recordingMode: StudioVideoClipImport.SukushoRecordingMode
    ) {
        guard let directory = mediaDirectoryURL, videoImportTask == nil, !isReadOnlyNewerFormat else { return }
        pause()
        let initialError = mediaImportError
        mediaImportError = nil

        videoImportTask = Task { [weak self] in
            defer {
                self?.videoImportTask = nil
                self?.videoImportProgress = nil
                self?.videoImportTitle = nil
            }
            var newSegments: [RecordingClipSegment] = []
            var rejected: [String] = []
            var sawSelfImport = false
            var copiedFilesToCleanupOnCancel: [URL] = []

            for url in urls {
                guard let self, !self.isTornDown, !Task.isCancelled else {
                    for temp in copiedFilesToCleanupOnCancel { try? FileManager.default.removeItem(at: temp) }
                    return
                }
                let displayName: String
                let sourceFileURL: URL
                var temporaryRawRenderURL: URL?
                if RecordingSession.isSessionDirectory(url) || StudioVideoClipImport.isSukushoRecording(url) {
                    if RecordingVideoOverlayMedia.isSelfRecording(url, openSessionURL: self.sessionURL) {
                        sawSelfImport = true
                        continue
                    }
                    let fallbackName = url.deletingPathExtension().lastPathComponent
                    let sourceSession = RecordingSession(directoryURL: url)
                    switch recordingMode {
                    case .rawRecording:
                        let safeName: String
                        if (try? RecordingPackageMedia.resolveOptionalPackageFile(
                            named: RecordingSession.projectMetadataFileName,
                            in: url
                        )) != nil {
                            safeName = sourceSession.displayName
                        } else {
                            safeName = fallbackName
                        }
                        do {
                            let prepared = try await RecordingSessionRenderer.prepareRawImport(for: url) { [weak self] progress in
                                Task { @MainActor [weak self] in
                                    if self?.videoImportTask != nil {
                                        self?.videoImportTitle = safeName
                                        self?.videoImportProgress = progress
                                    }
                                }
                            }
                            self.videoImportProgress = nil
                            self.videoImportTitle = nil
                            displayName = safeName
                            sourceFileURL = prepared.url
                            if prepared.isTemporary {
                                temporaryRawRenderURL = prepared.url
                            }
                        } catch is CancellationError {
                            for temp in copiedFilesToCleanupOnCancel { try? FileManager.default.removeItem(at: temp) }
                            return
                        } catch RecordingStudioExporter.ExportError.cancelled {
                            for temp in copiedFilesToCleanupOnCancel { try? FileManager.default.removeItem(at: temp) }
                            return
                        } catch {
                            self.videoImportProgress = nil
                            self.videoImportTitle = nil
                            rejected.append(fallbackName)
                            continue
                        }
                    case .finishedMovie:
                        guard (try? RecordingPackageMedia.validateRenderInputs(in: url)) != nil else {
                            rejected.append(fallbackName)
                            continue
                        }
                        displayName = sourceSession.displayName
                        self.videoImportTitle = displayName
                        self.videoImportProgress = 0
                        do {
                            sourceFileURL = try await RecordingSessionRenderer.ensureDeliverable(for: sourceSession) { [weak self] progress in
                                Task { @MainActor [weak self] in
                                    if self?.videoImportTask != nil {
                                        self?.videoImportProgress = progress
                                    }
                                }
                            }
                        } catch is CancellationError {
                            for temp in copiedFilesToCleanupOnCancel { try? FileManager.default.removeItem(at: temp) }
                            return
                        } catch RecordingStudioExporter.ExportError.cancelled {
                            for temp in copiedFilesToCleanupOnCancel { try? FileManager.default.removeItem(at: temp) }
                            return
                        } catch {
                            self.videoImportProgress = nil
                            self.videoImportTitle = nil
                            rejected.append("\(displayName) (\(error.localizedDescription))")
                            continue
                        }
                        self.videoImportProgress = nil
                        self.videoImportTitle = nil
                    }
                } else {
                    displayName = url.deletingPathExtension().lastPathComponent
                    sourceFileURL = url
                }
                defer {
                    if let temporaryRawRenderURL {
                        try? FileManager.default.removeItem(at: temporaryRawRenderURL)
                    }
                }

                guard !Task.isCancelled, !self.isTornDown else {
                    for temp in copiedFilesToCleanupOnCancel { try? FileManager.default.removeItem(at: temp) }
                    return
                }

                guard let fileName = self.copyMediaIntoProject(sourceFileURL, directory: directory),
                      let storedURL = RecordingOverlayMedia.resolveRegularFile(named: fileName, in: directory) else {
                    rejected.append(displayName)
                    continue
                }
                copiedFilesToCleanupOnCancel.append(storedURL)

                do {
                    let source = try await StudioVideoSource.load(url: storedURL)
                    let audioTracks = await StudioAudioSources.Track.loadAll(of: source.asset)
                    guard !Task.isCancelled, !self.isTornDown else {
                        for temp in copiedFilesToCleanupOnCancel { try? FileManager.default.removeItem(at: temp) }
                        return
                    }
                    self.importedVideoSources[fileName] = source
                    self.missingVideoClipFiles.remove(fileName)
                    if !audioTracks.isEmpty {
                        self.audioSources.files[fileName] = audioTracks
                    }
                    self.undoReferencedFiles.insert(fileName)
                    self.timelineThumbnails.registerSource(key: fileName, url: storedURL, duration: source.duration)
                    newSegments.append(RecordingClipSegment(
                        sourceStart: 0,
                        sourceEnd: source.duration,
                        mediaFileName: fileName,
                        displayName: displayName,
                        sourceDuration: source.duration
                    ))
                } catch {
                    try? FileManager.default.removeItem(at: storedURL)
                    rejected.append(displayName)
                }
            }

            guard let self, !self.isTornDown, !Task.isCancelled else {
                for temp in copiedFilesToCleanupOnCancel { try? FileManager.default.removeItem(at: temp) }
                return
            }

            if !newSegments.isEmpty {
                var segments = self.clipTimeline.segments
                let targetIndex = min(max(insertionIndex, 0), segments.count)
                segments.insert(contentsOf: newSegments, at: targetIndex)
                let nextTimeline = RecordingClipTimeline(segments: segments)
                let insertedStart = newSegments.first.flatMap { nextTimeline.editorRange(for: $0.id)?.lowerBound } ?? self.currentTime
                self.applyClipTimeline(
                    nextTimeline,
                    selectedID: newSegments.first?.id,
                    playheadTime: insertedStart,
                    actionName: newSegments.count == 1 ? "Add Video Clip" : "Add Video Clips"
                )
            }

            if !rejected.isEmpty {
                self.mediaImportError = "Couldn't add \(rejected.joined(separator: ", "))."
            } else if sawSelfImport {
                self.mediaImportError = RecordingVideoOverlayMedia.selfImportErrorMessage
            } else if let initialError {
                self.mediaImportError = initialError
            }
        }
    }

    /// Resolves imported video sources and their audio tracks from `media/`
    /// before building playback (probing metadata only, without decoding frames).
    private func resolveImportedVideoSources() async {
        missingVideoClipFiles.removeAll()
        let importedNames = Set(clipTimeline.segments.compactMap(\.mediaFileName))
        guard !importedNames.isEmpty else { return }
        guard let directory = mediaDirectoryURL else {
            missingVideoClipFiles.formUnion(importedNames)
            return
        }
        for fileName in importedNames {
            guard let url = RecordingOverlayMedia.resolveRegularFile(named: fileName, in: directory) else {
                missingVideoClipFiles.insert(fileName)
                continue
            }
            undoReferencedFiles.insert(fileName)
            if importedVideoSources[fileName] == nil {
                do {
                    let source = try await StudioVideoSource.load(url: url)
                    guard !Task.isCancelled, !isTornDown else { return }
                    importedVideoSources[fileName] = source
                    if audioSources.files[fileName] == nil {
                        let audioTracks = await StudioAudioSources.Track.loadAll(of: source.asset)
                        guard !Task.isCancelled, !isTornDown else { return }
                        if !audioTracks.isEmpty {
                            audioSources.files[fileName] = audioTracks
                        }
                    }
                } catch {
                    missingVideoClipFiles.insert(fileName)
                }
            }
        }
    }

    private func syncImportedThumbnails() {
        let activeNames = Set(clipTimeline.segments.compactMap(\.mediaFileName))
        timelineThumbnails.syncImportedSources(keeping: activeNames)
        guard let directory = mediaDirectoryURL else { return }
        for fileName in activeNames {
            guard let source = importedVideoSources[fileName],
                  let url = RecordingOverlayMedia.resolveRegularFile(named: fileName, in: directory) else { continue }
            timelineThumbnails.registerSource(key: fileName, url: url, duration: source.duration)
        }
    }

    // MARK: - Audio clips

    var canImportAudioMedia: Bool { mediaDirectoryURL != nil && isLoaded && !isReadOnlyNewerFormat }

    /// Copies picked audio files into the project's media folder and places
    /// them sequentially from `time` on `preferredLane`.
    func importAudioFiles(_ urls: [URL], atEditorTime time: TimeInterval, preferredLane: Int = 0) {
        guard let directory = mediaDirectoryURL else { return }
        mediaImportError = nil
        Task { [weak self] in
            var audioTime = time
            var rejected: [String] = []
            for url in urls {
                guard let self, !self.isTornDown else { return }
                if RecordingAudioClip.canImport(url),
                   let placed = await self.importAudio(url, into: directory, atEditorTime: audioTime, preferredLane: preferredLane) {
                    audioTime = placed
                } else {
                    rejected.append(url.lastPathComponent)
                }
            }
            if !rejected.isEmpty {
                self?.mediaImportError = "Couldn't add \(rejected.joined(separator: ", ")). Audio files can be added."
            }
        }
    }

    /// Adds one audio file into the project's media folder at `time`.
    func importAudioFile(_ url: URL, atEditorTime time: TimeInterval, preferredLane: Int = 0) async -> TimeInterval? {
        guard let directory = mediaDirectoryURL, !isTornDown, RecordingAudioClip.canImport(url) else { return nil }
        return await importAudio(url, into: directory, atEditorTime: time, preferredLane: preferredLane)
    }

    private func importAudio(
        _ url: URL,
        into directory: URL,
        atEditorTime time: TimeInterval,
        preferredLane: Int = 0
    ) async -> TimeInterval? {
        guard let fileName = copyMediaIntoProject(url, directory: directory),
              let storedURL = RecordingOverlayMedia.resolveRegularFile(named: fileName, in: directory) else {
            return nil
        }
        let asset = AVURLAsset(url: storedURL)
        let tracks = Array(await StudioAudioSources.Track.loadAll(of: asset).prefix(1))
        guard !tracks.isEmpty,
              let fileDuration = try? await asset.load(.duration).seconds,
              fileDuration.isFinite, fileDuration >= RecordingAudioClip.minimumDuration, !isTornDown else {
            try? FileManager.default.removeItem(at: storedURL)
            return nil
        }
        audioSources.files[fileName] = tracks
        missingAudioClipFiles.remove(fileName)
        undoReferencedFiles.insert(fileName)
        loadPeaks(for: fileName, url: storedURL)
        // Dropped at the very end, it ends there instead of starting past everything.
        let start = time > duration - 0.5
            ? max(0, duration - min(fileDuration, duration))
            : max(0, time)
        var clip = RecordingAudioClip(
            fileName: fileName,
            displayName: url.deletingPathExtension().lastPathComponent,
            start: start,
            fileDuration: fileDuration
        )
        clip.trimEnd = min(fileDuration, max(RecordingAudioClip.minimumDuration, duration - start))
        flushPendingAudioEdits()
        let nextClips = StudioAudioConform.inserting(clip, into: audioClips, preferredLane: preferredLane)
        applyAudioClips(nextClips, actionName: "Add Audio")
        selectAudioClip(id: clip.id)
        return clip.end
    }

    private func loadPeaks(for fileName: String, url: URL) {
        guard audioPeaks[fileName] == nil, audioPeakTasks[fileName] == nil else { return }
        audioPeakTasks[fileName] = Task { [weak self] in
            let decode = Task.detached(priority: .utility) {
                guard !Task.isCancelled else { return RecordingAudioWaveform.empty }
                return await RecordingAudioPeaks.loadWaveform(url: url)
            }
            let waveform = await withTaskCancellationHandler {
                await decode.value
            } onCancel: {
                decode.cancel()
            }
            guard let self, !Task.isCancelled, !self.isTornDown else { return }
            self.audioPeakTasks[fileName] = nil
            // A soundtrack replaced while this one was being read must not
            // have its outline taken over by the old file's.
            if fileName == Self.soundtrackPeaksKey, self.replacementAudio?.url != url { return }
            self.audioPeaks[fileName] = waveform
        }
    }

    /// Resolves audio clip tracks from disk before building playback, and
    /// kicks off background peak extraction for waveforms. Also preloads media
    /// referenced by hidden linked ranges so re-trimming heals immediately.
    private func resolveAudioClipSources() async {
        missingAudioClipFiles.removeAll()
        let allKnownClips = audioClips + hiddenLinkedAudio.map(\.clip)
        guard !allKnownClips.isEmpty else { return }
        let fileClips = allKnownClips.filter { $0.source == .file }
        if !fileClips.isEmpty {
            if let directory = mediaDirectoryURL {
                for name in Set(fileClips.map(\.fileName)) {
                    guard let url = RecordingOverlayMedia.resolveRegularFile(named: name, in: directory) else {
                        missingAudioClipFiles.insert(name)
                        continue
                    }
                    undoReferencedFiles.insert(name)
                    if audioSources.files[name] == nil {
                        let tracks = Array(await StudioAudioSources.Track.loadAll(of: AVURLAsset(url: url)).prefix(1))
                        guard !Task.isCancelled, !isTornDown else { return }
                        if tracks.isEmpty {
                            missingAudioClipFiles.insert(name)
                            continue
                        }
                        audioSources.files[name] = tracks
                    }
                    loadPeaks(for: name, url: url)
                }
            } else {
                missingAudioClipFiles.formUnion(fileClips.map(\.fileName))
            }
        }
        let pinnedClips = allKnownClips.filter { $0.source == .replacement && !$0.fileName.isEmpty }
        if !pinnedClips.isEmpty {
            if let directory = session?.directoryURL {
                for name in Set(pinnedClips.map(\.fileName)) {
                    guard RecordingAudioClip.isSafeFileName(name) else {
                        missingAudioClipFiles.insert(name)
                        continue
                    }
                    undoReferencedFiles.insert(name)
                    let url = directory.appendingPathComponent(name)
                    if audioSources.pinnedReplacements[name] == nil {
                        let tracks: [StudioAudioSources.Track]
                        if FileManager.default.fileExists(atPath: url.path) {
                            tracks = Array(await StudioAudioSources.Track.loadAll(of: AVURLAsset(url: url)).prefix(1))
                            guard !Task.isCancelled, !isTornDown else { return }
                        } else {
                            tracks = []
                        }
                        if tracks.isEmpty {
                            missingAudioClipFiles.insert(name)
                            continue
                        }
                        audioSources.pinnedReplacements[name] = tracks
                    }
                    loadPeaks(for: name, url: url)
                }
            } else {
                missingAudioClipFiles.formUnion(pinnedClips.map(\.fileName))
            }
        }
    }

    func isAudioClipMissing(_ clip: RecordingAudioClip) -> Bool {
        switch clip.source {
        case .file: missingAudioClipFiles.contains(clip.fileName)
        case .replacement: !clip.fileName.isEmpty && missingAudioClipFiles.contains(clip.fileName)
        case .recording: false
        }
    }

    var selectedAudioClip: RecordingAudioClip? {
        audioClips.first { $0.id == selectedAudioClipID }
    }

    /// Audio clips that start after the last frame and so never play,
    /// usually left there by removing video under unlinked music.
    var audioClipsPastEnd: [RecordingAudioClip] {
        audioClips.filter { $0.start >= duration - 0.01 }
    }

    func removeAudioClipsPastEnd() {
        let ids = Set(audioClipsPastEnd.map(\.id))
        guard !ids.isEmpty else { return }
        applyAudioClips(audioClips.filter { !ids.contains($0.id) }, actionName: "Remove Audio After the End")
    }

    /// How many audio lanes the timeline shows: every lane in use, and
    /// always at least one.
    var audioLaneCount: Int {
        // While a clip is dragged, lanes never close under it, and one spare
        // lane waits below to drop it into (up to StudioAudioConform.maximumLanes).
        if isDraggingTimelineBlock {
            return min(StudioAudioConform.maximumLanes, max(usedAudioLaneCount, laneCountAtDragStart) + 1)
        }
        return usedAudioLaneCount
    }

    private var usedAudioLaneCount: Int {
        max(1, (audioClips.map(\.lane).max() ?? 0) + 1)
    }

    /// The waveform outline of whatever a clip plays.
    func waveformPeaks(for clip: RecordingAudioClip) -> RecordingAudioWaveform {
        switch clip.source {
        case .file: return audioPeaks[clip.fileName] ?? .empty
        case .recording: return audioPeaks[Self.recordingPeaksKey] ?? .empty
        case .replacement:
            if !clip.fileName.isEmpty, let pinned = audioPeaks[clip.fileName] { return pinned }
            return audioPeaks[Self.soundtrackPeaksKey] ?? .empty
        }
    }

    func selectAudioClip(id: UUID) {
        guard audioClips.contains(where: { $0.id == id }) else { return }
        clearTimelineSelection()
        selectedAudioClipID = id
    }

    /// ⇧- or ⌘-click: adds a clip to the selection, or takes a selected one
    /// back out.
    func toggleAudioClipInSelection(id: UUID) {
        guard audioClips.contains(where: { $0.id == id }) else { return }
        var ids = selectedAudioClipIDs
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        let primary = ids.contains(id) ? id : ids.first
        clearTimelineSelection()
        selectedAudioClipIDs = ids
        selectedAudioClipID = primary
    }

    /// The clips an audio command acts on: the whole selection when the
    /// clip is part of it, otherwise just that clip.
    private func audioTargets(for id: UUID) -> Set<UUID> {
        selectedAudioClipIDs.contains(id) ? selectedAudioClipIDs : [id]
    }

    /// Moves every selected clip by the same amount, measured from where
    /// the drag started.
    func moveSelectedAudioClips(by delta: TimeInterval, lanes laneDelta: Int, anchor: UUID) {
        let base = audioEditSnapshot ?? audioClips
        let ids = audioTargets(for: anchor)
        let earliest = base.filter { ids.contains($0.id) }.map(\.start).min() ?? 0
        let shift = max(delta, -earliest)
        let topLane = base.filter { ids.contains($0.id) }.map(\.lane).min() ?? 0
        let laneShift = max(laneDelta, -topLane)
        replaceAudioClips(base.map { clip in
            guard ids.contains(clip.id) else { return clip }
            var moved = clip
            moved.start = clip.start + shift
            moved.lane = min(StudioAudioConform.maximumLanes - 1, clip.lane + laneShift)
            return moved
        })
    }

    /// Mutes or unmutes every clip on `lane` in one undoable step, clearing
    /// any active solo without altering other lanes' stored mute states.
    func setAudioLaneMuted(_ muted: Bool, lane: Int) {
        let next = audioClips.map { clip in
            var clip = clip
            if clip.lane == lane { clip.isMuted = muted }
            return clip
        }
        applyAudioClips(next, solo: .some(nil), actionName: muted ? "Mute Lane" : "Unmute Lane")
    }

    /// Toggles live-monitoring solo on `lane` in one undoable step without
    /// modifying any clip's stored `isMuted` flag.
    func toggleSoloAudioLane(_ lane: Int) {
        let updated = StudioAudioLaneSolo.toggle(lane: lane, current: soloAudioLane)
        setSoloAudioLane(updated.soloLane, actionName: updated.actionName)
    }

    private func setSoloAudioLane(_ nextSolo: Int?, actionName: String) {
        let resolved = StudioAudioLaneSolo.reconcile(clips: audioClips, soloLane: nextSolo)
        guard resolved != soloAudioLane else { return }
        let previous = soloAudioLane
        registerUndo(actionName) { target in
            target.setSoloAudioLane(previous, actionName: actionName)
        }
        soloAudioLane = resolved
        updatePlaybackVolume()
    }

    func isAudioClipEffectivelyMuted(_ clip: RecordingAudioClip) -> Bool {
        StudioAudioLaneSolo.isEffectivelyMuted(clip, soloLane: soloAudioLane)
    }

    func isAudioLaneMuted(_ lane: Int) -> Bool {
        let onLane = audioClips.filter { $0.lane == lane }
        return !onLane.isEmpty && onLane.allSatisfy(\.isMuted)
    }

    func removeAudioClip(id: UUID) {
        let ids = audioTargets(for: id)
        applyAudioClips(audioClips.filter { !ids.contains($0.id) }, actionName: ids.count > 1 ? "Remove Audio Clips" : "Remove Audio")
        if let selectedAudioClipID, ids.contains(selectedAudioClipID) { self.selectedAudioClipID = nil }
    }

    func beginAudioClipEdit() {
        if audioEditSnapshot == nil { audioEditSnapshot = audioClips }
    }

    func endAudioClipEdit(actionName: String = "Edit Audio") {
        audioCoalesceTask?.cancel()
        audioCoalesceTask = nil
        guard let previous = audioEditSnapshot else { return }
        audioEditSnapshot = nil
        // A clip dropped onto another moves to a lane with room.
        let settled = StudioAudioConform.resolvingLanes(audioClips, last: selectedAudioClipID)
        if settled != audioClips { replaceAudioClips(settled) }
        guard previous != audioClips else { return }
        registerUndo(actionName) { target in
            target.applyAudioClips(previous, actionName: actionName)
        }
    }

    /// Applies an edited clip, keeping its trim inside the file.
    func setAudioClip(_ clip: RecordingAudioClip) {
        guard let index = audioClips.firstIndex(where: { $0.id == clip.id }) else { return }
        var all = audioClips
        all[index] = clip.sanitized()
        replaceAudioClips(all)
    }

    func editAudioClip(_ clip: RecordingAudioClip, actionName: String) {
        beginAudioClipEdit()
        setAudioClip(clip)
        audioCoalesceTask?.cancel()
        audioCoalesceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.endAudioClipEdit(actionName: actionName)
        }
    }

    /// One whole change to a clip, as its own undo step.
    func changeAudioClip(id: UUID, actionName: String, _ change: (inout RecordingAudioClip) -> Void) {
        guard var clip = audioClips.first(where: { $0.id == id }) else { return }
        change(&clip)
        clip = clip.sanitized()
        applyAudioClips(audioClips.map { $0.id == id ? clip : $0 }, actionName: actionName)
    }

    func toggleAudioClipMuted(id: UUID) {
        guard let clip = audioClips.first(where: { $0.id == id }) else { return }
        let ids = audioTargets(for: id)
        let muted = !clip.isMuted
        applyAudioClips(audioClips.map { other in
            var other = other
            if ids.contains(other.id) { other.isMuted = muted }
            return other
        }, actionName: muted ? "Mute Audio" : "Unmute Audio")
        showNotice(muted ? "Muted" : "Unmuted")
    }

    /// Whether the clip is cut along with the video above it.
    func setAudioClipLinked(_ linked: Bool, id: UUID) {
        let ids = audioTargets(for: id)
        applyAudioClips(audioClips.map { other in
            var other = other
            if ids.contains(other.id) { other.isLinked = linked }
            return other
        }, actionName: linked ? "Link Audio to Video" : "Unlink Audio")
    }

    /// Plays an unlinked clip faster or slower; it keeps its start.
    func setAudioClipSpeed(_ speed: Double, id: UUID) {
        guard let clip = audioClips.first(where: { $0.id == id }), !clip.isLinked else { return }
        let clamped = min(max(speed, RecordingAudioClip.speedRange.lowerBound), RecordingAudioClip.speedRange.upperBound)
        changeAudioClip(id: id, actionName: "Change Audio Speed") { $0.speed = clamped }
    }

    /// Moves a clip a lane up or down. Whatever is in the way there makes
    /// room by moving down itself.
    func moveAudioClip(id: UUID, byLanes delta: Int) {
        guard let clip = audioClips.first(where: { $0.id == id }) else { return }
        let lane = min(StudioAudioConform.maximumLanes - 1, max(0, clip.lane + delta))
        guard lane != clip.lane else { return }
        applyAudioClips(
            audioClips.map {
                var clip = $0
                if clip.id == id { clip.lane = lane }
                return clip
            },
            actionName: "Move Audio to Lane \(lane + 1)",
            keeping: id
        )
    }

    /// Splits an audio clip at `time` on the edited timeline.
    func splitAudioClip(id: UUID, at time: TimeInterval) {
        guard let clip = audioClips.first(where: { $0.id == id }),
              let halves = StudioAudioConform.split(clip, at: time) else { return }
        applyAudioClips(
            audioClips.flatMap { $0.id == id ? [halves.leading, halves.trailing] : [$0] },
            actionName: "Split Audio"
        )
        selectAudioClip(id: halves.trailing.id)
    }

    /// A copy placed straight after the clip.
    func duplicateAudioClip(id: UUID) {
        guard let clip = audioClips.first(where: { $0.id == id }) else { return }
        // A copy past the end of the video would never play.
        guard clip.end < duration - RecordingAudioClip.minimumDuration else {
            NSSound.beep()
            showNotice("No room after the video ends")
            return
        }
        var copy = clip
        copy.id = UUID()
        copy.originID = nil
        copy.keepsLeadingSplit = false
        copy.keepsTrailingSplit = false
        copy.start = clip.end
        applyAudioClips(audioClips + [copy], actionName: "Duplicate Audio")
        selectAudioClip(id: copy.id)
    }

    private func flushPendingAudioEdits() {
        endAudioClipEdit()
        endClipSoundEdit(actionName: "Change Clip Volume")
        endSoundtrackOffsetEdit()
    }

    private func replaceAudioClips(_ all: [RecordingAudioClip]) {
        audioClips = all
        scheduleProjectSave()
        // Volume and fades only change the mix; anything that moves audio
        // in time needs the composition rebuilt.
        if audioPlan.placement != playbackAudioPlacement {
            scheduleAudioPlaybackRebuild()
        } else {
            updatePlaybackVolume()
        }
    }

    /// A drag reports many moves; the player item is rebuilt once they
    /// settle.
    private func scheduleAudioPlaybackRebuild() {
        audioPlaybackRebuildTask?.cancel()
        audioPlaybackRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled, self.isLoaded else { return }
            let wasPlaying = self.isPlaying
            let rate = self.shuttleRate
            self.pause()
            try? self.rebuildScreenPlayerItem(preserving: self.currentTime)
            if wasPlaying {
                self.shuttleRate = rate
                self.startPlayback()
            }
        }
    }

    /// `keeping` names a clip that gets the lane it asks for; anything in
    /// its way moves down.
    private func applyAudioClips(
        _ requested: [RecordingAudioClip],
        solo requestedSolo: Int?? = nil,
        actionName: String,
        keeping: UUID? = nil
    ) {
        flushPendingAudioEdits()
        let all = StudioAudioConform.resolvingLanes(requested, first: keeping)
        let nextSolo = StudioAudioLaneSolo.reconcile(clips: all, soloLane: requestedSolo ?? soloAudioLane)
        guard all != audioClips || nextSolo != soloAudioLane else { return }
        let previous = audioClips
        let previousSolo = soloAudioLane
        registerUndo(actionName) { target in
            target.applyAudioClips(previous, solo: .some(previousSolo), actionName: actionName)
        }
        soloAudioLane = nextSolo
        replaceAudioClips(all)
        if let selectedAudioClipID, !all.contains(where: { $0.id == selectedAudioClipID }) {
            self.selectedAudioClipID = nil
        }
        selectedAudioClipIDs = selectedAudioClipIDs.filter { id in
            all.contains(where: { $0.id == id })
        }
    }

    // MARK: - Audio only

    /// True when the recording itself or a replacement soundtrack provides audio.
    var hasPrimaryAudio: Bool {
        hasRecordedAudio || hasReplacementAudio
    }

    /// True once there is a soundtrack to export or swap - the recording's
    /// own audio, one imported over it, background music, audio clips,
    /// audible layered video overlays, or audible imported video clips.
    var hasAudio: Bool {
        hasPrimaryAudio
            || hasBackgroundMusic
            || !audioClips.isEmpty
            || hasAudibleVideoOverlays
            || clipTimeline.segments.contains { !$0.isPrimaryRecording && clipHasOwnAudio($0) }
    }

    var hasAudibleVideoOverlays: Bool {
        videoOverlays.contains { $0.hasAudio && !$0.isMuted && $0.audibleVolume > 0 }
    }

    /// True when the project has background music, audio lane clips, or audible
    /// layered videos that can be excluded from a speech-cleanup export or
    /// included in a full mix.
    var hasAudioExportExtras: Bool {
        !audioClips.isEmpty || hasBackgroundMusic || hasAudibleVideoOverlays
    }

    /// True when clips or background music are the only audio in the project.
    var audioExportDefaultsToExtras: Bool {
        !hasPrimaryAudio && hasAudioExportExtras
    }

    var effectiveAudioExportIncludesClips: Bool {
        RecordingAudioExporter.effectiveIncludeExtras(
            hasPrimaryAudio: hasPrimaryAudio,
            hasBackgroundMusic: hasBackgroundMusic,
            hasAudioClips: !audioClips.isEmpty || hasAudibleVideoOverlays,
            userSelection: audioExportIncludesClips
        )
    }

    /// How far the imported soundtrack falls short of (or overruns) the
    /// cut it was imported over. Nil when there is nothing imported or the
    /// two agree closely enough to be the same take.
    var replacementAudioDrift: TimeInterval? {
        guard let replacementAudio else { return nil }
        let expected = replacementAudioSync?.coveredFileDuration ?? duration
        let drift = replacementAudio.duration - expected
        return abs(drift) > 0.25 ? drift : nil
    }

    private var audioExportSuggestedFileName: String {
        let base = session.map {
            $0.directoryURL.deletingPathExtension().lastPathComponent
        } ?? screenURL.deletingPathExtension().lastPathComponent
        return "\(base).\(audioExportFormat.fileExtension)"
    }

    /// Writes the edited soundtrack on its own, for cleanup in a tool that
    /// has no API - the outbound half of the replace-audio round trip.
    func exportAudio() {
        guard !hasRunningWork, isLoaded, hasAudio, !hasUnreadableDraft, !isReadOnlyNewerFormat else { return }
        pause()

        audioExportState = .exporting(progress: 0)

        let replacementURL: URL?
        do {
            replacementURL = try replacementAudioURLForExport(includeAudio: true)
        } catch {
            audioExportState = .failed(error.localizedDescription)
            return
        }
        let includeMix = effectiveAudioExportIncludesClips
        let configuration = RecordingAudioExporter.Configuration(
            screenURL: screenURL,
            clipTimeline: clipTimeline,
            replacementURL: replacementURL,
            format: audioExportFormat,
            volume: Double(audioVolume),
            isolatedMicrophoneURL: voiceIsolationEnabled ? isolatedMicrophone?.url : nil,
            microphoneTrackID: microphoneTrackID,
            backgroundMusic: includeMix ? backgroundMusicConfiguration(includeAudio: true) : nil,
            replacementSync: replacementURL == nil ? nil : replacementAudioSync,
            audioClips: includeMix ? audioClips : [],
            videoOverlays: includeMix ? videoOverlays : [],
            mediaDirectory: includeMix ? mediaDirectoryURL : nil,
            externalReplacementURLs: includeMix ? externalPinnedReplacementURLs : [:]
        )
        let suggestedFileName = audioExportSuggestedFileName
        let dockProgressID = DockExportProgressCoordinator.shared.start()

        audioExportTask = Task { [weak self] in
            do {
                let temporaryURL = try await RecordingAudioExporter().export(configuration) { progress in
                    Task { @MainActor [weak self] in
                        DockExportProgressCoordinator.shared.update(dockProgressID, progress: progress)
                        if self?.audioExportState.isExporting == true {
                            self?.audioExportState = .exporting(progress: progress)
                        }
                    }
                }
                let savedURL = try await VideoFileActions.saveToDefaultLocation(
                    from: temporaryURL,
                    suggestedFileName: suggestedFileName
                )
                try? FileManager.default.removeItem(at: temporaryURL)
                DockExportProgressCoordinator.shared.finish(dockProgressID, completed: true)
                RecordingExportNotifier.notifySuccess(fileURL: savedURL)
                RecordingExportNotifier.revealIfPreferred(fileURL: savedURL)
                self?.audioExportState = .finished(savedURL)
            } catch is CancellationError {
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                self?.audioExportState = .idle
            } catch {
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                self?.audioExportState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelAudioExport() {
        audioExportTask?.cancel()
        audioExportTask = nil
        if audioExportState.isExporting {
            audioExportState = .idle
        }
    }

    /// The inbound half: adopts a cleaned-up soundtrack as the project's
    /// audio. The file is copied into the session so the project keeps
    /// playing after the original is moved, and playback switches to it
    /// immediately rather than only revealing itself at export.
    func replaceAudio(with pickedURL: URL) {
        guard isLoaded, !isReadOnlyNewerFormat else { return }
        pause()
        replacementAudioTask?.cancel()

        replacementAudioError = nil
        let displayName = pickedURL.lastPathComponent
        let importSession = session
        let storedURL: URL
        if let session = importSession {
            let destination = session.directoryURL
                .appendingPathComponent("\(RecordingSession.replacementAudioBaseName).\(UUID().uuidString)")
                .appendingPathExtension(pickedURL.pathExtension.isEmpty ? "m4a" : pickedURL.pathExtension)
            do {
                try FileManager.default.copyItem(at: pickedURL, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                replacementAudioError = "Could not import that file: \(error.localizedDescription)"
                return
            }
            storedURL = destination
        } else {
            // Bare movies have no project folder to copy into; they
            // reference the picked file where it sits.
            storedURL = pickedURL
        }

        replacementAudioTask = Task { [weak self] in
            var adopted = false
            defer {
                if !adopted, importSession != nil {
                    try? FileManager.default.removeItem(at: storedURL)
                }
            }
            let resolved = await RecordingReplacementAudio.load(
                url: storedURL,
                displayName: displayName
            )
            guard let self, !self.isTornDown, !Task.isCancelled else { return }
            self.replacementAudioTask = nil
            guard let resolved else {
                self.replacementAudioError = "That file has no audio track."
                return
            }
            adopted = true
            self.setSoundtrack(
                SoundtrackState(audio: resolved, sync: .flat(over: self.clipTimeline), clips: self.audioClips),
                actionName: "Replace Audio"
            )
        }
    }

    /// Stable key identifying a replacement soundtrack file: the session file
    /// name for packaged projects, or a session-scoped token mapped in
    /// `externalPinnedReplacementURLs` for standalone movies.
    private func pinnedReplacementKey(for url: URL) -> String {
        if session != nil { return url.lastPathComponent }
        let standardized = url.standardizedFileURL
        if let existing = externalPinnedReplacementURLs.first(where: { $0.value.standardizedFileURL == standardized }) {
            return existing.key
        }
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
        let key = "external-replacement.\(UUID().uuidString).\(ext)"
        externalPinnedReplacementURLs[key] = standardized
        return key
    }

    private func adoptReplacementAudio(
        _ audio: RecordingReplacementAudio?,
        reference: StudioReplacementReference? = nil,
        sync: RecordingAudioSync?
    ) {
        replacementAudio = audio
        audioPeaks[Self.soundtrackPeaksKey] = nil
        audioPeakTasks.removeValue(forKey: Self.soundtrackPeaksKey)?.cancel()
        if let audio {
            replacementAudioReference = nil
            replacementAudioError = nil
            let pinnedKey = pinnedReplacementKey(for: audio.url)
            undoReferencedFiles.insert(pinnedKey)
            replacementAudioSync = sync ?? .legacyFlat(over: clipTimeline)
            let track = StudioAudioSources.Track(track: audio.track, range: audio.range, asset: audio.asset)
            audioSources.replacement = [track]
            audioSources.pinnedReplacements[pinnedKey] = [track]
            loadPeaks(for: Self.soundtrackPeaksKey, url: audio.url)
            return
        }
        let outcome = StudioReplacementReference.resolve(
            fileName: reference?.fileName,
            displayName: reference?.displayName,
            sync: sync,
            loadedExists: false
        )
        replacementAudioReference = outcome.unresolvedReference
        replacementAudioSync = outcome.sync
        replacementAudioError = outcome.error
        if let fileName = outcome.unresolvedReference?.fileName {
            undoReferencedFiles.insert(fileName)
        }
        audioSources.replacement = []
    }

    /// Slides the soundtrack against the picture. A slider sweep undoes
    /// as one step; the player is rebuilt once it settles.
    func setReplacementAudioOffset(_ offset: TimeInterval) {
        guard var sync = replacementAudioSync, replacementAudio != nil else { return }
        let clamped = min(max(offset.isFinite ? offset : 0, -RecordingAudioSync.offsetLimit), RecordingAudioSync.offsetLimit)
        guard abs(sync.offset - clamped) > 0.000_1 else { return }
        if soundtrackOffsetSnapshot == nil { soundtrackOffsetSnapshot = sync.offset }
        sync.offset = clamped
        replacementAudioSync = sync
        scheduleProjectSave()
        scheduleAudioPlaybackRebuild()
        soundtrackOffsetTask?.cancel()
        soundtrackOffsetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.endSoundtrackOffsetEdit()
        }
    }

    private func endSoundtrackOffsetEdit() {
        soundtrackOffsetTask?.cancel()
        soundtrackOffsetTask = nil
        guard let previous = soundtrackOffsetSnapshot else { return }
        soundtrackOffsetSnapshot = nil
        guard let current = replacementAudioSync?.offset, abs(current - previous) > 0.000_1 else { return }
        registerUndo("Change Audio Sync") { target in
            target.restoreSoundtrackOffset(previous, redoing: current)
        }
    }

    private func restoreSoundtrackOffset(_ offset: TimeInterval, redoing other: TimeInterval) {
        guard var sync = replacementAudioSync else { return }
        registerUndo("Change Audio Sync") { target in
            target.restoreSoundtrackOffset(other, redoing: offset)
        }
        sync.offset = offset
        replacementAudioSync = sync
        scheduleProjectSave()
        scheduleAudioPlaybackRebuild()
    }

    func removeReplacementAudio() {
        replacementAudioTask?.cancel()
        replacementAudioTask = nil
        guard hasReplacementAudio else { return }
        pause()
        replacementAudioError = nil
        // Legacy unpinned replacement clips have nothing left to play; clips
        // pinned to their own replacement file keep playing independently.
        setSoundtrack(
            SoundtrackState(
                audio: nil,
                reference: nil,
                sync: nil,
                clips: audioClips.filter { $0.source != .replacement || !$0.fileName.isEmpty }
            ),
            actionName: "Remove Replaced Audio"
        )
    }

    /// The soundtrack and everything that depends on it, as one undoable
    /// value. Holding the resolved audio and unresolved reference makes undo
    /// synchronous without losing a missing or unreadable replacement.
    private struct SoundtrackState {
        var audio: RecordingReplacementAudio?
        var reference: StudioReplacementReference? = nil
        var sync: RecordingAudioSync?
        var clips: [RecordingAudioClip]
        var solo: Int?? = nil
    }

    private func setSoundtrack(_ state: SoundtrackState, actionName: String) {
        flushPendingAudioEdits()
        let previous = SoundtrackState(
            audio: replacementAudio,
            reference: replacementAudioReference,
            sync: replacementAudioSync,
            clips: audioClips,
            solo: .some(soloAudioLane)
        )
        registerUndo(actionName) { target in
            target.setSoundtrack(previous, actionName: actionName)
        }
        pause()
        adoptReplacementAudio(state.audio, reference: state.reference, sync: state.sync)
        audioClips = StudioAudioConform.resolvingLanes(state.clips)
        soloAudioLane = StudioAudioLaneSolo.reconcile(clips: audioClips, soloLane: state.solo ?? soloAudioLane)
        if let selectedAudioClipID, !audioClips.contains(where: { $0.id == selectedAudioClipID }) {
            self.selectedAudioClipID = nil
        }
        selectedAudioClipIDs = selectedAudioClipIDs.filter { id in
            audioClips.contains(where: { $0.id == id })
        }
        applyReplacementAudioToPlayback()
    }

    private func applyReplacementAudioToPlayback() {
        do {
            try rebuildScreenPlayerItem(preserving: currentTime)
        } catch {
            loadError = "Could not update the recording timeline: \(error.localizedDescription)"
        }
        scheduleProjectSave()
    }

    /// Wait until close to collect old imports; the saved project and its
    /// working draft may still need different soundtracks.
    private func removeUnusedReplacementAudio(in session: RecordingSession) {
        guard !isReadOnlyNewerFormat else { return }
        if let savedVersion = RecordingPackageMedia.readFormatVersion(at: session.editDocumentURL),
           savedVersion > RecordingEditDocument.currentFormatVersion {
            return
        }
        if let draftVersion = RecordingPackageMedia.readFormatVersion(at: session.draftDocumentURL),
           draftVersion > RecordingEditDocument.currentFormatVersion {
            return
        }
        let savedDocument = session.loadEditDocument()
        let draftDocument = session.loadDraftDocument()
        // A document that exists but cannot be read is not evidence that its
        // soundtrack is unused. Leave the files alone in that case.
        guard !session.hasSavedProject || savedDocument != nil,
              !FileManager.default.fileExists(atPath: session.draftDocumentURL.path)
                || draftDocument != nil else { return }
        let store = CaptureSessionSnapshots(directory: session.sessionSnapshotsURL)
        let keptDocuments: [RecordingEditDocument]
        do {
            keptDocuments = try store.strictEntries().map { entry in
                let raw = try store.read(entry).document
                guard let version = RecordingPackageMedia.readFormatVersion(from: raw),
                      version <= RecordingEditDocument.currentFormatVersion else {
                    throw RecordingPackageMedia.ValidationError.unsupportedFormatVersion(
                        RecordingPackageMedia.readFormatVersion(from: raw) ?? (RecordingEditDocument.currentFormatVersion + 1)
                    )
                }
                let decoded = try CaptureManifest.decoder.decode(RecordingEditDocument.self, from: raw)
                if decoded.isUnsupportedFutureVersion {
                    throw RecordingPackageMedia.ValidationError.unsupportedFormatVersion(decoded.formatVersion)
                }
                return decoded
            }
        } catch { return } // An unreadable or newer-format snapshot may still reference media in unknown fields.
        let referencedMusic = Set([savedDocument?.backgroundMusic?.fileName, draftDocument?.backgroundMusic?.fileName, lastSavedDocument?.backgroundMusic?.fileName, backgroundMusicSettings?.fileName].compactMap { $0 } + keptDocuments.compactMap { $0.backgroundMusic?.fileName })
        let allDocuments = [savedDocument, draftDocument, lastSavedDocument].compactMap { $0 } + keptDocuments
        var pinnedClipFiles: [String] = []
        for document in allDocuments {
            for clip in document.audioClips ?? [] where clip.source == .replacement && !clip.fileName.isEmpty {
                pinnedClipFiles.append(clip.fileName)
            }
            for hidden in document.hiddenLinkedAudio ?? [] where hidden.clip.source == .replacement && !hidden.clip.fileName.isEmpty {
                pinnedClipFiles.append(hidden.clip.fileName)
            }
        }
        for clip in audioClips where clip.source == .replacement && !clip.fileName.isEmpty {
            pinnedClipFiles.append(clip.fileName)
        }
        for hidden in hiddenLinkedAudio where hidden.clip.source == .replacement && !hidden.clip.fileName.isEmpty {
            pinnedClipFiles.append(hidden.clip.fileName)
        }
        let referencedNames = Set([
            savedDocument?.replacementAudioFileName,
            draftDocument?.replacementAudioFileName,
            lastSavedDocument?.replacementAudioFileName,
            replacementAudio?.url.lastPathComponent,
            replacementAudioReference?.fileName
        ].compactMap { $0 } + keptDocuments.compactMap(\.replacementAudioFileName) + pinnedClipFiles + Array(undoReferencedFiles))
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: session.directoryURL.path
        )) ?? []
        for name in names
        where (name.hasPrefix("\(RecordingSession.replacementAudioBaseName).") && !referencedNames.contains(name))
            || (name.hasPrefix("\(RecordingBackgroundMusic.baseName).") && !referencedMusic.contains(name)) {
            try? FileManager.default.removeItem(
                at: session.directoryURL.appendingPathComponent(name)
            )
        }
        let mediaDirectory = session.mediaDirectoryURL
        var referencedMedia = Set<String>(undoReferencedFiles)
        for document in allDocuments {
            referencedMedia.formUnion((document.clips ?? []).compactMap(\.mediaFileName))
            referencedMedia.formUnion((document.videoOverlays ?? []).map(\.fileName))
            referencedMedia.formUnion((document.imageOverlays ?? []).map(\.fileName))
            referencedMedia.formUnion((document.audioClips ?? []).filter { $0.source == .file }.map(\.fileName))
            referencedMedia.formUnion((document.hiddenLinkedAudio ?? []).filter { $0.clip.source == .file }.map(\.clip.fileName))
        }
        referencedMedia.formUnion(clipTimeline.segments.compactMap(\.mediaFileName))
        referencedMedia.formUnion(videoOverlays.map(\.fileName))
        referencedMedia.formUnion(imageOverlays.map(\.fileName))
        referencedMedia.formUnion(audioClips.filter { $0.source == .file }.map(\.fileName))
        referencedMedia.formUnion(hiddenLinkedAudio.filter { $0.clip.source == .file }.map(\.clip.fileName))
        RecordingOverlayMedia.cleanupUnreferencedMedia(in: mediaDirectory, referenced: referencedMedia)
    }

    // MARK: - Share to cloud

    var canShareToCloud: Bool {
        CloudUploader.shared.isConfigured
    }

    private var sharedHistoryItem: ScreenshotHistoryItem? {
        guard let id = historyItemID(for: session) else { return nil }
        return ScreenshotHistoryStore.shared.items.first { $0.id == id }
    }

    var needsSharedVideoReplacement: Bool {
        sharedHistoryItem?.cloudURL != nil
            && RecordingRedaction.needsSharedReplacement(redactions, shared: sharedHistoryItem?.cloudRedactions)
    }

    private var sharedUploadID: String? {
        CloudUploadList.replacementID(of: sharedHistoryItem?.cloudURL, workerBase: CloudUploader.shared.workerBase)
    }

    var canManageSharedVideo: Bool { canShareToCloud && sharedUploadID != nil && !hasRunningWork && !isReadOnlyNewerFormat }

    func replaceSharedVideo() {
        guard canManageSharedVideo, let id = sharedUploadID else { return }
        shareToCloud(options: CloudUploadOptions(title: "", socialEnabled: true), replacingUploadID: id)
    }

    func deleteSharedLink() {
        guard canManageSharedVideo, let item = sharedHistoryItem, let id = sharedUploadID else { return }
        isDeletingSharedLink = true
        sharedVideoError = nil
        startShareTask { [weak self] in
            defer { self?.isDeletingSharedLink = false }
            do {
                try await CloudUploader.shared.deleteFromCloud(uploadID: id)
                ScreenshotHistoryStore.shared.setLibraryCloudURL(id: item.id, cloudURL: nil)
                CloudUploader.shared.clearUploadState(for: item.id)
                CloudLibraryModel.shared.refreshUsage()
                CloudLibraryModel.shared.refreshCommentsAndLikes()
                self?.shareState = .idle
            } catch { self?.sharedVideoError = error.localizedDescription }
        }
    }

    /// The Loom loop: render the current edits, cache the result as the
    /// session's flattened deliverable, upload it, and copy the share
    /// link - without leaving the Studio or touching a save panel.
    func shareToCloud(options: CloudUploadOptions, replacingUploadID: String? = nil) {
        guard !hasRunningWork, isLoaded, !hasUnreadableDraft, !isReadOnlyNewerFormat,
              canShareToCloud else {
            return
        }
        sharedVideoError = nil
        pause()
        // Flush the draft first so the deliverable-invalidation in the
        // debounced autosave can't race the file this render produces.
        projectSaveTask?.cancel()
        guard writeDraftNow() else {
            shareState = .failed("The recording edits could not be saved. Try again after resolving the storage problem.")
            return
        }

        // A fresh deliverable (e.g. sharing again without edits) skips
        // the render and goes straight to upload.
        let sharedDocument = currentDocument()
        let videoDocument = sharedDocument.forVideoRendering
        let cachedDeliverable = freshDeliverableURL()
        let configuration: RecordingStudioExporter.Configuration?
        do {
            configuration = cachedDeliverable == nil ? try makeExportConfiguration(settings: videoDocument.exportSettings) : nil
        } catch {
            shareState = .failed(error.localizedDescription)
            return
        }
        let session = session
        let sharedChapterData = try? RecordingChapterPlanner.shareData(chapters, through: clipTimeline, cues: subtitleCues, words: transcriptWords)
        let renderedDocument = session == nil ? nil : videoDocument
        shareItemID = nil
        shareState = cachedDeliverable == nil ? .rendering(progress: 0) : .uploading

        startShareTask { [weak self] in
            // Bare (session-less) videos upload straight from the render's
            // temp file; whatever happens, it must not outlive the share.
            var temporaryUploadURL: URL?
            defer {
                if let temporaryUploadURL {
                    try? FileManager.default.removeItem(at: temporaryUploadURL)
                }
            }
            do {
                let uploadURL: URL
                if let cachedDeliverable {
                    uploadURL = cachedDeliverable
                } else if let configuration {
                    // The render leg gets its own Dock entry; the upload
                    // leg's Dock progress is owned by CloudUploader, so
                    // the two never overlap.
                    let dockProgressID = DockExportProgressCoordinator.shared.start()
                    let temporaryURL: URL
                    do {
                        temporaryURL = try await RecordingStudioExporter().export(configuration) { progress in
                            Task { @MainActor [weak self] in
                                DockExportProgressCoordinator.shared.update(dockProgressID, progress: progress)
                                if case .rendering = self?.shareState {
                                    self?.shareState = .rendering(progress: progress)
                                }
                            }
                        }
                        DockExportProgressCoordinator.shared.finish(dockProgressID)
                    } catch {
                        DockExportProgressCoordinator.shared.finish(dockProgressID)
                        throw error
                    }
                    // From here the deferred cleanup owns the temp render;
                    // once it moves into the session the delete is a
                    // harmless no-op.
                    temporaryUploadURL = temporaryURL

                    // Session recordings keep the render as the flattened
                    // deliverable, so history, preview, and sidecar mapping
                    // all agree on what was shared.
                    if let session {
                        uploadURL = try session.installFinalVideo(
                            movingFrom: temporaryURL,
                            renderedFrom: renderedDocument
                        )
                    } else {
                        uploadURL = temporaryURL
                    }
                } else {
                    return
                }

                guard let self, !Task.isCancelled else { return }
                self.shareState = .uploading
                let itemID = self.historyItemID(for: session) ?? UUID()
                self.shareItemID = itemID
                let result = try await CloudUploader.shared.upload(
                    itemID: itemID,
                    fileURL: uploadURL,
                    title: options.trimmedTitleOrNil,
                    socialEnabled: options.socialEnabled,
                    expiresAt: options.expiry.date(),
                    allowAnonymousComments: options.allowAnonymousComments,
                    password: options.password,
                    replacingUploadID: replacingUploadID,
                    chapterData: sharedChapterData
                )

                CloudShareLinks.copy([result.url], message: options.message)
                if session != nil {
                    ScreenshotHistoryStore.shared.setCloudURL(for: uploadURL, cloudURL: result.url)
                }
                ScreenshotPreviewStack.shared.dismissVideo(for: self.sessionURL)
                // An edit made during the render or upload isn't in the link:
                // the link is still copied, but Upload stays rather than
                // claiming it's current.
                self.shareState = self.currentDocument() == sharedDocument ? .finished(result.url) : .idle
            } catch is CancellationError {
                self?.shareState = .idle
            } catch RecordingStudioExporter.ExportError.cancelled {
                self?.shareState = .idle
            } catch {
                self?.shareState = .failed(error.localizedDescription)
                if replacingUploadID != nil { self?.sharedVideoError = error.localizedDescription }
            }
        }
    }

    func startShareTask(_ operation: @escaping @MainActor () async -> Void) {
        guard shareTask == nil else { return }
        shareTask = Task { [weak self] in
            defer {
                if Task.isCancelled, self?.shareState.isBusy == true { self?.shareState = .idle }
                self?.shareTask = nil
            }
            await operation()
        }
    }

    func cancelShare() {
        // Cancellation is cooperative; keep replacement, deletion and close guarded until exit.
        shareTask?.cancel()
        if shareState.isBusy, let shareItemID {
            CloudUploader.shared.cancelUpload(for: shareItemID)
        }
    }

    /// History item for this session, so the share upload's progress and
    /// resulting link also appear on the preview card.
    private func historyItemID(for session: RecordingSession?) -> UUID? {
        guard let session else { return nil }
        let standardizedPath = session.directoryURL.standardizedFileURL.path
        return ScreenshotHistoryStore.shared.items
            .first { $0.recordingSessionPath == standardizedPath }?
            .id
    }
}

/// A zoom cue's single merged footprint on the edited timeline.
extension RecordingStudioModel: StudioBlockLaneHost {}

/// Convenience over `studioMovedSourceRange(clipTimeline:editorStart:editorLength:)`
/// for lanes holding a `RecordingStudioModel`.
func studioMovedSourceRange(
    model: RecordingStudioModel,
    editorStart: TimeInterval,
    editorLength: TimeInterval
) -> (start: TimeInterval, end: TimeInterval) {
    studioMovedSourceRange(
        clipTimeline: model.clipTimeline,
        editorStart: editorStart,
        editorLength: editorLength
    )
}

struct RecordingZoomTimelineBlock: Identifiable, Equatable, Sendable {
    let cue: ZoomCue
    let editorStart: TimeInterval
    let editorEnd: TimeInterval

    var id: UUID {
        cue.id
    }
}

/// Allows picking plain movie files and `.sukushorec` recording folders in the
/// same `NSOpenPanel`, while keeping ordinary folders navigable instead of
/// selectable as clips.
private final class StudioVideoOpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if StudioVideoClipImport.canImport(url) {
            return true
        }
        // Keep ordinary folders enabled so the user can browse into them.
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func panel(_ sender: Any, validate url: URL) throws {
        if StudioVideoClipImport.canImport(url) {
            return
        }
        throw NSError(
            domain: "StudioVideoOpenPanel",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Choose a movie file or a Sukusho recording."]
        )
    }
}
