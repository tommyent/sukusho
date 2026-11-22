//
//  RecordingSessionRenderer.swift
//  Screendrop
//
//  On-demand utility for workflows that require a single flattened movie.
//  The capture pipeline keeps screen and camera as separate safety masters;
//  this renderer must not run on the recording Stop/presentation path.
//

import AppKit
import AVFoundation
import CoreGraphics

@MainActor
enum RecordingSessionRenderer {
    private enum RenderError: LocalizedError {
        case missingCameraTrack
        case missingReplacementAudio

        var errorDescription: String? {
            switch self {
            case .missingCameraTrack:
                "The camera recording does not contain a readable video track."
            case .missingReplacementAudio:
                "The project's replacement soundtrack is missing. Open the recording in Studio, then reset to recorded audio or import the soundtrack again."
            }
        }
    }

    private struct RenderKey: Equatable {
        /// A path: the after-capture Copy finds the package from its movie, with a trailing slash.
        let package: String
        let document: RecordingEditDocument?
    }

    private static let renders = InFlightRenders<RenderKey, URL>()

    struct PreparedRawImport: Sendable {
        let url: URL
        /// True when a redacted copy was rendered to a temporary movie that
        /// the caller should remove after copying into the target project.
        let isTemporary: Bool
    }

    /// Validates a `.sukushorec` package for Raw recording import, decoding its
    /// effective edit document so any
    /// unreadable or future-format edit is refused before copying raw.
    @discardableResult
    static func validateRawImport(in packageURL: URL) throws -> RecordingPackageMedia.ResolvedRawImport {
        let resolved = try RecordingPackageMedia.validateRawImportInputs(in: packageURL)
        let document = try RecordingSession(directoryURL: packageURL).editDocumentForRendering()
        return RecordingPackageMedia.ResolvedRawImport(
            screenURL: resolved.screenURL,
            activeEditURL: resolved.activeEditURL,
            redactions: document?.redactions ?? []
        )
    }

    /// Shared Raw-recording import resolver used by both the sequence lane and
    /// the layered video overlay lane:
    /// - No source redactions: returns `screen.mov` directly for a byte-for-byte copy.
    /// - Has source redactions: renders a full-size, full-length copy of `screen.mov`
    ///   with ONLY those redactions applied and original audio intact.
    /// - Unreadable edit sidecar: throws rather than exposing raw footage.
    static func prepareRawImport(
        for packageURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> PreparedRawImport {
        let resolved = try validateRawImport(in: packageURL)
        guard !resolved.redactions.isEmpty else {
            return PreparedRawImport(url: resolved.screenURL, isTemporary: false)
        }

        let asset = AVURLAsset(url: resolved.screenURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw RecordingStudioExporter.ExportError.noVideoTrack
        }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingStudioExporter.ExportError.noVideoTrack
        }
        for region in resolved.redactions {
            try region.validate(sourceDuration: duration)
        }
        let (naturalSize, preferredTransform) = try await videoTrack.load(.naturalSize, .preferredTransform)
        guard RecordingCompositionBuilder.isSupportedDisplayTransform(
            preferredTransform,
            naturalSize: naturalSize
        ) else {
            throw RecordingRedactionError.filterFailed
        }
        let displaySize = RecordingCompositionBuilder.displaySize(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        )
        guard displaySize.width > 0, displaySize.height > 0 else {
            throw RecordingStudioExporter.ExportError.noVideoTrack
        }

        let originalAudioTracks = try await asset.loadTracks(withMediaType: .audio)

        let rawStyle = RecordingStudioStyle(
            background: .none,
            padding: 0,
            cornerRadius: 0,
            shadow: 0,
            camera: RecordingCameraBubbleSettings(isVisible: false)
        )
        var exportSettings = VideoCompressionSettings()
        exportSettings.codec = .h264
        exportSettings.resolution = .original
        exportSettings.frameRate = .fps60
        exportSettings.quality = .high
        // Render only the redacted picture; original audio tracks are
        // passthrough-muxed below without remixing or re-encoding.
        exportSettings.removeAudio = true
        exportSettings.container = .mov

        let configuration = RecordingStudioExporter.Configuration(
            screenURL: resolved.screenURL,
            cameraURL: nil,
            cameraOffset: 0,
            style: rawStyle,
            viewportTimeline: .identity,
            pointerTimeline: nil,
            showsPressEffects: false,
            keystrokeTimeline: nil,
            keystrokePlacement: .bottomCenter,
            subtitleTimeline: nil,
            subtitleStyle: SubtitleBarStyle(),
            canvasSize: displaySize,
            videoCropRect: CropRectEditor.unit,
            clipTimeline: .full(sourceDuration: duration),
            exportSettings: exportSettings,
            audioVolume: 1,
            redactions: resolved.redactions
        )
        onProgress?(0)
        let hasAudioToMux = !originalAudioTracks.isEmpty
        let renderedURL = try await RecordingStudioExporter().export(configuration) { progress in
            onProgress?(hasAudioToMux ? progress * 0.9 : progress)
        }
        guard hasAudioToMux else {
            onProgress?(1)
            return PreparedRawImport(url: renderedURL, isTemporary: true)
        }

        let muxComposition = AVMutableComposition()
        let renderedAsset = AVURLAsset(url: renderedURL)
        guard let renderedVideoTrack = try await renderedAsset.loadTracks(withMediaType: .video).first else {
            try? FileManager.default.removeItem(at: renderedURL)
            throw RecordingStudioExporter.ExportError.noVideoTrack
        }
        let renderedVideoRange = try await renderedVideoTrack.load(.timeRange)
        guard let compVideo = muxComposition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            try? FileManager.default.removeItem(at: renderedURL)
            throw CocoaError(.fileReadCorruptFile)
        }
        do {
            try compVideo.insertTimeRange(renderedVideoRange, of: renderedVideoTrack, at: .zero)
        } catch {
            try? FileManager.default.removeItem(at: renderedURL)
            throw error
        }

        var insertedAudioCount = 0
        for audioTrack in originalAudioTracks {
            let trackRange = try await audioTrack.load(.timeRange)
            guard trackRange.duration > .zero else { continue }
            guard let compAudio = muxComposition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                try? FileManager.default.removeItem(at: renderedURL)
                throw CocoaError(.fileReadCorruptFile)
            }
            do {
                try compAudio.insertTimeRange(trackRange, of: audioTrack, at: trackRange.start)
                insertedAudioCount += 1
            } catch {
                try? FileManager.default.removeItem(at: renderedURL)
                throw error
            }
        }
        guard insertedAudioCount > 0 else {
            onProgress?(1)
            return PreparedRawImport(url: renderedURL, isTemporary: true)
        }

        defer { try? FileManager.default.removeItem(at: renderedURL) }
        let muxedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-redacted-\(UUID().uuidString).mov")
        guard let exportSession = AVAssetExportSession(
            asset: muxComposition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw RecordingRedactionError.filterFailed
        }
        do {
            try await exportSession.export(to: muxedURL, as: .mov)
        } catch {
            try? FileManager.default.removeItem(at: muxedURL)
            throw error
        }
        onProgress?(1)
        return PreparedRawImport(url: muxedURL, isTemporary: true)
    }

    static func documentForDelivery(for session: RecordingSession) throws -> RecordingEditDocument? {
        try StudioProjectRegistry.shared.flushDraft(for: session.directoryURL)
        return try session.editDocumentForRendering()
    }

    /// Creates a flattened deliverable when explicitly requested for a session
    /// whose raw screen master would not match what the user sees: a camera
    /// source, a cursor-hidden capture, or any saved Studio project. Only a
    /// never-edited, cursor-visible, camera-less capture is already its own
    /// complete result and skips the expensive second encode.
    static func ensureDeliverable(
        for session: RecordingSession,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        try await ensureDeliverable(for: session, editDocument: documentForDelivery(for: session), onProgress: onProgress)
    }

    static func readyDeliverable(for session: RecordingSession, editDocument: RecordingEditDocument?) -> URL? {
        if editDocument?.isUnsupportedFutureVersion == true { return nil }
        guard let resolved = try? RecordingPackageMedia.validateRenderInputs(in: session.directoryURL) else {
            return nil
        }
        guard resolved.cameraURL != nil || session.loadCaptureManifest()?.pointerSynthesized == true || editDocument != nil else {
            return resolved.screenURL
        }
        return session.freshFinalURL(matching: editDocument)
    }

    /// Keep evidence and rendered pixels on the same frozen edit, even if Studio changes during export.
    static func ensureDeliverable(
        for session: RecordingSession,
        editDocument: RecordingEditDocument?,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if let editDocument, editDocument.isUnsupportedFutureVersion {
            throw RecordingPackageMedia.ValidationError.unsupportedFormatVersion(editDocument.formatVersion)
        }
        try RecordingPackageMedia.validateRenderInputs(in: session.directoryURL)
        let editDocument = editDocument?.forVideoRendering
        if let ready = readyDeliverable(for: session, editDocument: editDocument) { return ready }

        // A second encode of the same edits would only fight this one for the media engine.
        let key = RenderKey(package: session.directoryURL.standardizedFileURL.path, document: editDocument)
        return try await renders.value(for: key, onProgress: onProgress) { progress in
            let configuration = try await makeConfiguration(for: session, editDocument: editDocument)
            let temporaryURL = try await RecordingStudioExporter().export(configuration, progress: progress)
            do {
                return try session.installFinalVideo(
                    movingFrom: temporaryURL,
                    renderedFrom: editDocument
                )
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
        }
    }

    /// The export a session's saved (or draft) Studio edits describe,
    /// resolved without any editor UI.
    static func makeConfiguration(
        for session: RecordingSession
    ) async throws -> RecordingStudioExporter.Configuration {
        try RecordingPackageMedia.validateRenderInputs(in: session.directoryURL)
        return try await makeConfiguration(for: session, editDocument: documentForDelivery(for: session))
    }

    private static func makeConfiguration(
        for session: RecordingSession,
        editDocument: RecordingEditDocument?
    ) async throws -> RecordingStudioExporter.Configuration {
        if let editDocument, editDocument.isUnsupportedFutureVersion {
            throw RecordingPackageMedia.ValidationError.unsupportedFormatVersion(editDocument.formatVersion)
        }
        let resolvedInputs = try RecordingPackageMedia.validateRenderInputs(in: session.directoryURL)
        let manifest = session.loadCaptureManifest()
        let pointerSynthesized = manifest?.pointerSynthesized == true
        // No saved choice: the one Studio would open the recording with, as a share.
        // shortcut: a render stamped with no document keeps its size after the remembered choice changes; stamp the settings if that matters.
        let exportSettings = editDocument?.exportSettings ?? RecordingExportPreferences.lastSettings.forVideoRendering
        let audioVolume = RecordingAudioGain.normalized(editDocument?.audioVolume ?? 1)
        let audioClips = editDocument?.audioClips ?? []
        let usesUnpinnedReplacementClip = audioClips.contains { $0.source == .replacement && $0.fileName.isEmpty }
        let usesRecordingClip = audioClips.contains { $0.source == .recording }
        let audioReplacementURL: URL?
        if !exportSettings.removeAudio && (audioVolume > 0 || usesUnpinnedReplacementClip),
           let replacementName = editDocument?.replacementAudioFileName, !replacementName.isEmpty {
            guard let resolvedAudio = RecordingPackageMedia.resolvePackageFile(
                named: replacementName,
                in: resolvedInputs.packageDirectory
            ) else {
                throw RenderError.missingReplacementAudio
            }
            audioReplacementURL = resolvedAudio
        } else {
            audioReplacementURL = nil
        }
        let asset = AVURLAsset(url: resolvedInputs.screenURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw RecordingStudioExporter.ExportError.noVideoTrack
        }

        if let cameraURL = resolvedInputs.cameraURL {
            let cameraAsset = AVURLAsset(url: cameraURL)
            guard try await !cameraAsset.loadTracks(withMediaType: .video).isEmpty else {
                throw RenderError.missingCameraTrack
            }
        }

        var isolatedMicrophoneURL: URL?
        let tracks = try await asset.load(.tracks)
        let microphoneTrackID = RecordingVoiceIsolation.microphoneTrack(in: tracks,
            includesMicrophone: manifest?.includesMicrophone == true,
            includesSystemAudio: manifest?.includesSystemAudio == true)?.trackID
        let mayUseRecordingAudio = audioReplacementURL == nil
            || usesRecordingClip
            || editDocument?.replacementAudioSync != nil
        if editDocument?.isolateVoice == true, mayUseRecordingAudio,
           !exportSettings.removeAudio, audioVolume > 0 || usesRecordingClip {
            guard let microphone = RecordingVoiceIsolation.microphoneTrack(in: tracks,
                includesMicrophone: manifest?.includesMicrophone == true,
                includesSystemAudio: manifest?.includesSystemAudio == true) else {
                throw RecordingVoiceIsolation.IsolationError.missingMicrophone
            }
            _ = try RecordingPackageMedia.resolveOptionalPackageFile(
                named: RecordingVoiceIsolation.fileName,
                in: resolvedInputs.packageDirectory
            )
            let url = resolvedInputs.packageDirectory.appendingPathComponent(RecordingVoiceIsolation.fileName)
            try await RecordingVoiceIsolation.render(sourceURL: resolvedInputs.screenURL,
                microphoneTrackID: microphone.trackID, destinationURL: url, progress: { _ in })
            isolatedMicrophoneURL = url
        }

        let canvasSize = try await outputSize(for: asset, manifest: manifest)
        let recordingPointScale = max(manifest?.pixelScale ?? 1, 1)
        let recordingPointSize = CGSize(
            width: canvasSize.width / CGFloat(recordingPointScale),
            height: canvasSize.height / CGFloat(recordingPointScale)
        )
        let capture = PointerStreamSanitizer.sanitize(
            session.loadPointerCapture() ?? PointerCaptureFile(),
            options: PointerSanitizeOptions(
                recordingSizeInPoints: recordingPointSize
            )
        ).sanitizedCapture
        let document = editDocument
        var style = document?.style.value ?? RecordingStudioStyle()
        // Selecting a camera means the default delivered recording includes
        // it; a saved Studio project that explicitly hid the bubble wins.
        style.camera.isVisible = resolvedInputs.cameraURL != nil && (document?.style.value.camera.isVisible ?? true)
        let zoomEnabled = document?.zoomEnabled ?? true
        let zoomCues = document?.zoomCues
            ?? ZoomCueSynthesizer.cues(from: capture, duration: duration)
        let clipTimeline: RecordingClipTimeline
        if let clips = document?.clips, !clips.isEmpty {
            clipTimeline = RecordingClipTimeline(segments: clips).normalized(to: duration)
        } else {
            clipTimeline = .legacyTrim(
                start: document?.trimStart,
                end: document?.trimEnd,
                sourceDuration: duration
            )
        }
        let viewportTimeline = zoomEnabled
            ? ViewportTimeline.build(cues: zoomCues, capture: capture, clipTimeline: clipTimeline)
            : .identity
        let showsPressEffects = pointerSynthesized
            && manifest?.pressEffectsBaked == false
            && (document?.showsClickEffects ?? manifest?.pressEffectsEnabled ?? true)
        let showsKeystrokes = (document?.showsKeystrokes ?? true) && !capture.keystrokes.isEmpty

        // One pointer timeline serves both jobs: drawing the synthetic
        // cursor and steering the reframe camera's focus.
        let hasPointerData = !capture.travel.isEmpty || !capture.presses.isEmpty
        let pointerTimeline = hasPointerData
            ? PointerTimeline.build(
                capture: capture,
                duration: duration,
                recordingSizeInPoints: recordingPointSize,
                fallbackArtwork: PointerArtworkCapture.defaultArtwork(),
                clipTimeline: clipTimeline
            )
            : nil

        let showsSubtitles = document?.showsSubtitles ?? true
        let captions = RecordingTranscript(words: document?.subtitleWords ?? [], cues: document?.subtitleCues ?? [])
            .renderCaptions(in: clipTimeline)
        let cues = captions.cues
        let words = captions.words

        let aspect = document?.exportAspectPreset ?? .original
        let aspectMode = document?.exportAspectContentMode ?? .fill
        let reframe: ReframeTrack? = aspectMode == .fill
            ? ReframeTrack.build(
                preset: aspect,
                sourceSize: canvasSize,
                viewportTimeline: viewportTimeline,
                duration: clipTimeline.duration
            ) { editorTime in
                pointerTimeline?.location(at: editorTime)
            }
            : nil
        let fitContentAspect: CGFloat? =
            (aspect == .original || aspectMode == .fit) && canvasSize.height > 0
                ? canvasSize.width / canvasSize.height
                : nil

        let backgroundMusic: RecordingBackgroundMusicMixer.Configuration?
        if !exportSettings.removeAudio && !exportSettings.effectiveExportsGIF,
           let music = document?.backgroundMusic {
            guard let musicURL = RecordingPackageMedia.resolvePackageFile(
                named: music.fileName,
                in: resolvedInputs.packageDirectory
            ) else {
                throw RecordingPackageMedia.ValidationError.unsafeFile(music.fileName)
            }
            backgroundMusic = .init(url: musicURL, settings: music)
        } else {
            backgroundMusic = nil
        }

        return RecordingStudioExporter.Configuration(
            screenURL: resolvedInputs.screenURL,
            cameraURL: resolvedInputs.cameraURL,
            cameraOffset: manifest?.cameraLeadIn ?? 0,
            style: style,
            viewportTimeline: viewportTimeline,
            pointerTimeline: pointerSynthesized ? pointerTimeline : nil,
            showsPressEffects: showsPressEffects,
            keystrokeTimeline: showsKeystrokes
                ? KeystrokeCaptionTimeline(events: capture.keystrokes)
                : nil,
            keystrokePlacement: document?.keystrokePlacement ?? .bottomCenter,
            subtitleTimeline: showsSubtitles && !cues.isEmpty
                ? SubtitleTimeline(cues: cues)
                : nil,
            subtitleStyle: document?.subtitleStyle ?? SubtitleBarStyle(),
            karaokeTimeline: showsSubtitles && !cues.isEmpty && !words.isEmpty
                ? KaraokeTimeline(cues: cues, words: words)
                : nil,
            canvasSize: aspect == .original
                ? RecordingStudioLayout.originalCanvasSize(
                    sourceSize: canvasSize,
                    style: style,
                    contentCropRect: document?.normalizedVideoCropRect ?? RecordingVideoCropGeometry.unit
                )
                : aspect.canvasSize(for: canvasSize),
            videoCropRect: document?.normalizedVideoCropRect
                ?? CGRect(x: 0, y: 0, width: 1, height: 1),
            clipTimeline: clipTimeline,
            exportSettings: exportSettings,
            audioReplacementURL: audioReplacementURL,
            audioReplacementSync: document?.replacementAudioSync,
            audioVolume: audioVolume,
            isolatedMicrophoneURL: isolatedMicrophoneURL,
            microphoneTrackID: microphoneTrackID,
            backgroundMusic: backgroundMusic,
            audioClips: audioClips,
            mediaDirectory: resolvedInputs.mediaDirectory ?? session.mediaDirectoryURL,
            reframe: reframe,
            fitContentAspect: fitContentAspect,
            usesUniformPadding: aspect == .original,
            redactions: document?.redactions ?? [],
            textOverlays: document?.textOverlays ?? [],
            imageOverlays: document?.imageOverlays ?? [],
            videoOverlays: document?.videoOverlays ?? [],
            ink: document?.showsInk ?? true
                ? RecordingInkTimeline(strokes: capture.ink, hiding: Set(document?.hiddenInkStrokeIDs ?? []))
                : nil
        )
    }

    private static func outputSize(
        for asset: AVURLAsset,
        manifest: CaptureManifest?
    ) async throws -> CGSize {
        if let manifest, manifest.pixelWidth > 0, manifest.pixelHeight > 0 {
            return CGSize(width: manifest.pixelWidth, height: manifest.pixelHeight)
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingStudioExporter.ExportError.noVideoTrack
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = size.applying(transform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }
}
