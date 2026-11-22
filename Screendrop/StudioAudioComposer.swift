//
//  StudioAudioComposer.swift
//  Screendrop
//
//  Builds all the sound of a Studio project into a composition: each video
//  clip's own sound (the recording's audio, or the soundtrack standing in
//  for it, cut where the picture is cut), every audio clip on its lane,
//  Sukusho's voice-isolated microphone track, and optional ducked background
//  music. Playback, the video export and the audio-only export all go
//  through here, so they cannot disagree about what is heard.
//
//  The composition says *when* each sound plays; the mix says how loud.
//  They are built apart so a level or a fade changes without rebuilding
//  the player item.
//

import AVFoundation

/// The audio tracks a project's sound is read from, resolved ahead of time
/// so a composition can be built synchronously.
nonisolated struct StudioAudioSources: @unchecked Sendable {
    struct Track: @unchecked Sendable {
        let track: AVAssetTrack
        /// The part of its file that holds sound.
        let range: CMTimeRange
        /// Held because a track doesn't keep its asset alive, and a track
        /// whose asset is gone inserts nothing.
        let asset: AVAsset

        static func load(_ track: AVAssetTrack, of asset: AVAsset) async -> Track? {
            guard let range = try? await track.load(.timeRange), range.duration > .zero else { return nil }
            return Track(track: track, range: range, asset: asset)
        }

        static func loadAll(of asset: AVAsset) async -> [Track] {
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return [] }
            var result: [Track] = []
            for track in tracks {
                if let loaded = await load(track, of: asset) { result.append(loaded) }
            }
            return result
        }
    }

    /// The recording's own audio: system sound and microphone.
    var recording: [Track] = []
    /// The soundtrack standing in for it.
    var replacement: [Track] = []
    /// Detached soundtrack clips pinned to their own replacement file in the session folder.
    var pinnedReplacements: [String: [Track]] = [:]
    /// Imported audio, by its name in the media folder.
    var files: [String: [Track]] = [:]

    var replacementDuration: TimeInterval {
        replacement.map { $0.range.end.seconds }.max() ?? 0
    }

    func tracks(for clip: RecordingAudioClip) -> [Track] {
        switch clip.source {
        case .file: files[clip.fileName] ?? []
        case .recording: recording
        case .replacement:
            clip.fileName.isEmpty ? replacement : (pinnedReplacements[clip.fileName] ?? [])
        }
    }

    /// Returns a copy whose microphone track is swapped for an isolated voice
    /// track, leaving system audio untouched.
    func replacingMicrophone(
        trackID: CMPersistentTrackID,
        with isolated: Track
    ) -> StudioAudioSources? {
        guard let index = recording.firstIndex(where: { $0.track.trackID == trackID }) else {
            return nil
        }
        var copy = self
        copy.recording[index] = isolated
        return copy
    }

    /// Everything a project's export needs, read from disk. Validates explicit
    /// replacement, voice-isolation, and (when `strictMissingClips` is true)
    /// audible imported audio clips rather than silently falling back.
    static func load(
        screenAsset: AVAsset,
        replacementURL: URL?,
        clips: [RecordingAudioClip],
        videoOverlays: [RecordingVideoOverlay] = [],
        mediaDirectory: URL?,
        externalReplacementURLs: [String: URL] = [:],
        microphoneTrackID: CMPersistentTrackID? = nil,
        isolatedMicrophoneURL: URL? = nil,
        timeline: RecordingClipTimeline? = nil,
        strictMissingClips: Bool = false
    ) async throws -> StudioAudioSources {
        var sources = StudioAudioSources()
        sources.recording = await Track.loadAll(of: screenAsset)
        if let isolatedMicrophoneURL {
            guard let loaded = await RecordingReplacementAudio.load(
                url: isolatedMicrophoneURL,
                displayName: "Isolated voice"
            ) else {
                throw RecordingVoiceIsolation.IsolationError.invalidAudio
            }
            let isolatedTrack = Track(track: loaded.track, range: loaded.range, asset: loaded.asset)
            guard let microphoneTrackID,
                  let swapped = sources.replacingMicrophone(trackID: microphoneTrackID, with: isolatedTrack) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            sources = swapped
        }
        if let replacementURL {
            guard let loaded = await RecordingReplacementAudio.load(
                url: replacementURL,
                displayName: replacementURL.lastPathComponent
            ) else {
                throw RecordingReplacementAudio.LoadError.unreadable
            }
            let track = Track(track: loaded.track, range: loaded.range, asset: loaded.asset)
            sources.replacement = [track]
            sources.pinnedReplacements[replacementURL.lastPathComponent] = [track]
        }
        let videoDuration = timeline?.duration ?? .infinity
        let sessionDirectory = mediaDirectory?.deletingLastPathComponent()
            ?? replacementURL?.deletingLastPathComponent()
        var seenFiles: Set<String> = []
        // Load all audio tracks for imported in-sequence video clips (silent
        // clips are valid and leave `sources.files[name]` unset).
        if let timeline, let mediaDirectory {
            for segment in timeline.segments {
                guard let fileName = segment.mediaFileName,
                      let url = RecordingOverlayMedia.resolveRegularFile(named: fileName, in: mediaDirectory),
                      seenFiles.insert(fileName).inserted else {
                    continue
                }
                let asset = AVURLAsset(url: url)
                let tracks = await Track.loadAll(of: asset)
                if !tracks.isEmpty {
                    sources.files[fileName] = tracks
                }
            }
        }
        for clip in clips where clip.source == .file {
            let isAudible = !clip.isMuted && clip.audibleVolume > 0
                && min(clip.end, videoDuration) - max(clip.start, 0) >= RecordingAudioClip.minimumPlayableDuration
            guard let mediaDirectory,
                  let url = RecordingOverlayMedia.resolveRegularFile(named: clip.fileName, in: mediaDirectory) else {
                if strictMissingClips && isAudible {
                    throw StudioAudioComposer.AudioError.missingAudioClip(clip.displayName)
                }
                continue
            }
            if !seenFiles.insert(clip.fileName).inserted {
                if strictMissingClips && isAudible && sources.files[clip.fileName] == nil {
                    throw StudioAudioComposer.AudioError.missingAudioClip(clip.displayName)
                }
                continue
            }
            let asset = AVURLAsset(url: url)
            let tracks = await Track.loadAll(of: asset)
            if !tracks.isEmpty {
                sources.files[clip.fileName] = tracks
            } else if strictMissingClips && isAudible {
                throw StudioAudioComposer.AudioError.missingAudioClip(clip.displayName)
            }
        }
        for overlay in videoOverlays {
            let isAudible = !overlay.isMuted && overlay.audibleVolume > 0
                && min(overlay.end, videoDuration) - max(overlay.start, 0) >= RecordingAudioClip.minimumPlayableDuration
            guard let mediaDirectory,
                  let url = RecordingOverlayMedia.resolveRegularFile(named: overlay.fileName, in: mediaDirectory) else {
                if strictMissingClips && isAudible {
                    throw StudioAudioComposer.AudioError.missingAudioClip(overlay.displayName)
                }
                continue
            }
            if !seenFiles.insert(overlay.fileName).inserted {
                continue
            }
            let asset = AVURLAsset(url: url)
            let tracks = await Track.loadAll(of: asset)
            if !tracks.isEmpty {
                sources.files[overlay.fileName] = tracks
            }
        }
        var seenPinned: Set<String> = []
        for clip in clips where clip.source == .replacement && !clip.fileName.isEmpty {
            let isAudible = !clip.isMuted && clip.audibleVolume > 0
                && min(clip.end, videoDuration) - max(clip.start, 0) >= RecordingAudioClip.minimumPlayableDuration
            let resolvedURL: URL?
            if let externalURL = externalReplacementURLs[clip.fileName] {
                resolvedURL = externalURL
            } else if let sessionDirectory {
                resolvedURL = RecordingPackageMedia.resolvePackageFile(named: clip.fileName, in: sessionDirectory)
            } else {
                resolvedURL = nil
            }
            guard let url = resolvedURL else {
                if strictMissingClips && isAudible {
                    throw StudioAudioComposer.AudioError.missingAudioClip(clip.displayName)
                }
                continue
            }
            if sources.pinnedReplacements[clip.fileName] != nil { continue }
            if !seenPinned.insert(clip.fileName).inserted {
                if strictMissingClips && isAudible && sources.pinnedReplacements[clip.fileName] == nil {
                    throw StudioAudioComposer.AudioError.missingAudioClip(clip.displayName)
                }
                continue
            }
            let tracks: [Track]
            if FileManager.default.fileExists(atPath: url.path) {
                let asset = AVURLAsset(url: url)
                tracks = Array(await Track.loadAll(of: asset).prefix(1))
            } else {
                tracks = []
            }
            if !tracks.isEmpty {
                sources.pinnedReplacements[clip.fileName] = tracks
            } else if strictMissingClips && isAudible {
                throw StudioAudioComposer.AudioError.missingAudioClip(clip.displayName)
            }
        }
        return sources
    }
}

/// What should be heard: the cut, how an imported soundtrack lines up with
/// the recording, the audio clips, and the project's volume.
nonisolated struct StudioAudioPlan: Equatable, Sendable {
    var timeline: RecordingClipTimeline
    /// Nil plays the recording's own audio.
    var sync: RecordingAudioSync?
    var clips: [RecordingAudioClip] = []
    /// Applied to the video clips' own sound; audio clips carry their own.
    var volume: Double = 1
    /// Optional live-monitoring solo lane; applied at mix time without mutating
    /// any clip's stored `isMuted` flag. Always nil for exports.
    var soloLane: Int? = nil
    /// Layered video overlays whose sound joins the shared project mix.
    var videoOverlays: [RecordingVideoOverlay] = []

    /// The plan with everything that only changes loudness set aside. Two
    /// plans that agree here need the same composition.
    var placement: StudioAudioPlan {
        var plan = self
        plan.volume = 1
        plan.soloLane = nil
        plan.timeline.segments = plan.timeline.segments.map {
            var segment = $0
            segment.volume = 1
            segment.isMuted = false
            segment.displayName = nil
            segment.contentMode = nil
            return segment
        }
        plan.clips = plan.clips.map {
            var clip = $0
            clip.volume = 1
            clip.isMuted = false
            clip.fadeIn = 0
            clip.fadeOut = 0
            clip.displayName = ""
            return clip
        }
        plan.videoOverlays = plan.videoOverlays.map {
            var overlay = RecordingVideoOverlay(
                fileName: $0.fileName,
                displayName: "",
                start: $0.start,
                fileDuration: $0.fileDuration
            )
            overlay.id = $0.id
            overlay.trimStart = $0.trimStart
            overlay.trimEnd = $0.trimEnd
            overlay.speed = $0.speed
            return overlay
        }
        return plan
    }
}

/// Which composition track carries which sound, and when.
nonisolated struct StudioAudioLayout: Sendable {
    enum Owner: Equatable, Sendable {
        case segment(UUID)
        case clip(UUID)
        case videoOverlay(UUID)
    }

    struct Placement: Sendable {
        var trackID: CMPersistentTrackID
        var start: TimeInterval
        var end: TimeInterval
        var owner: Owner
        /// The stretch of its file it plays, so two placements that simply
        /// continue each other can be told from a real cut.
        var mediaStart: TimeInterval = 0
        var mediaEnd: TimeInterval = 0
        /// Source asset and track identity so splices between two different
        /// files at matching times still receive cut ramps.
        var sourceIdentity: String = ""
    }

    var placements: [Placement] = []

    var isEmpty: Bool { placements.isEmpty }
}

nonisolated enum StudioAudioComposer {
    enum AudioError: LocalizedError {
        case missingAudioClip(String)
        case compositionInsertFailed(Error)

        var errorDescription: String? {
            switch self {
            case .missingAudioClip(let name):
                "Audio clip “\(name)” is missing or unreadable. Mute or remove it before exporting."
            case .compositionInsertFailed(let error):
                "Could not assemble audio for export: \(error.localizedDescription)"
            }
        }
    }

    private static let timescale: CMTimeScale = 600

    private static func time(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: timescale)
    }

    /// Assets retained while an export reader consumes a composed audio track.
    struct PreparedExport: @unchecked Sendable {
        let composition: AVMutableComposition
        let layout: StudioAudioLayout
        let mix: AVAudioMix?
        let sources: StudioAudioSources
        let backgroundMusic: RecordingReplacementAudio?
    }

    /// Builds one audio composition and mix for video and audio-only exports,
    /// keeping Sukusho's voice isolation and ducked background music in the
    /// same pipeline as multi-lane audio clips.
    static func prepareExport(
        screenAsset: AVAsset,
        screenURL: URL,
        timeline: RecordingClipTimeline,
        replacementURL: URL?,
        replacementSync: RecordingAudioSync?,
        clips: [RecordingAudioClip],
        videoOverlays: [RecordingVideoOverlay] = [],
        mediaDirectory: URL?,
        externalReplacementURLs: [String: URL] = [:],
        volume: Double,
        microphoneTrackID: CMPersistentTrackID?,
        isolatedMicrophoneURL: URL?,
        backgroundMusic: RecordingBackgroundMusicMixer.Configuration?
    ) async throws -> PreparedExport {
        let sources = try await StudioAudioSources.load(
            screenAsset: screenAsset,
            replacementURL: replacementURL,
            clips: clips,
            videoOverlays: videoOverlays,
            mediaDirectory: mediaDirectory,
            externalReplacementURLs: externalReplacementURLs,
            microphoneTrackID: microphoneTrackID,
            isolatedMicrophoneURL: isolatedMicrophoneURL,
            timeline: timeline,
            strictMissingClips: true
        )
        let plan = StudioAudioPlan(
            timeline: timeline,
            sync: sources.replacement.isEmpty ? nil : replacementSync ?? .legacyFlat(over: timeline),
            clips: clips,
            volume: volume,
            videoOverlays: videoOverlays
        )
        let (composition, layout) = try makeExportComposition(plan: plan, sources: sources)
        let baseMix = mix(for: layout, plan: plan)
        let preparedMusic = try await RecordingBackgroundMusicMixer.addPreparedMusic(
            to: composition,
            music: backgroundMusic,
            sourceURL: screenURL,
            microphoneTrackID: microphoneTrackID,
            timeline: timeline
        )
        let combinedMix: AVAudioMix?
        if let musicParameters = preparedMusic?.parameters {
            let mix = AVMutableAudioMix()
            mix.inputParameters = (baseMix?.inputParameters ?? []) + [musicParameters]
            combinedMix = mix
        } else {
            combinedMix = baseMix
        }
        return PreparedExport(
            composition: composition,
            layout: layout,
            mix: combinedMix,
            sources: sources,
            backgroundMusic: preparedMusic?.loaded
        )
    }

    /// Where each clip of a cut starts and how long it runs, on the same
    /// 600ths the video track is built from, so sound and picture share
    /// every cut exactly.
    static func editorRanges(for timeline: RecordingClipTimeline) -> [CMTimeRange] {
        var ranges: [CMTimeRange] = []
        var cursor = CMTime.zero
        for segment in timeline.segments {
            let duration = abs(segment.speed - 1) > 0.000_001
                ? time(segment.editorDuration)
                : time(segment.duration)
            ranges.append(CMTimeRange(start: cursor, duration: duration))
            cursor = cursor + duration
        }
        return ranges
    }

    // MARK: Composition

    /// A composition holding only the project's sound, for tests/previews.
    static func makeComposition(
        plan: StudioAudioPlan,
        sources: StudioAudioSources
    ) -> (composition: AVMutableComposition, layout: StudioAudioLayout) {
        let composition = AVMutableComposition()
        let layout = add(plan, sources: sources, to: composition)
        return (composition, layout)
    }

    /// Strict variant for exports: fails if an audible audio clip has no
    /// resolved tracks or if AVFoundation rejects a composition insertion.
    static func makeExportComposition(
        plan: StudioAudioPlan,
        sources: StudioAudioSources
    ) throws -> (composition: AVMutableComposition, layout: StudioAudioLayout) {
        let composition = AVMutableComposition()
        let layout = try addStrict(plan, sources: sources, to: composition)
        return (composition, layout)
    }

    /// Adds the project's sound to a composition that already holds its
    /// picture (or nothing). Best-effort for live playback.
    @discardableResult
    static func add(
        _ plan: StudioAudioPlan,
        sources: StudioAudioSources,
        to composition: AVMutableComposition
    ) -> StudioAudioLayout {
        (try? build(plan, sources: sources, into: composition, strict: false)) ?? StudioAudioLayout()
    }

    @discardableResult
    static func addStrict(
        _ plan: StudioAudioPlan,
        sources: StudioAudioSources,
        to composition: AVMutableComposition
    ) throws -> StudioAudioLayout {
        try build(plan, sources: sources, into: composition, strict: true)
    }

    /// One playable stretch of a video segment's own audio, shared verbatim
    /// between playback/export composition and Detach Audio so detaching never
    /// drops a playable slice or changes its effective level.
    struct SegmentSlice: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case recording
            case replacement
            case imported(String)
        }

        var kind: Kind
        var sourceStart: TimeInterval
        var sourceEnd: TimeInterval
        var mediaStart: TimeInterval
        var mediaEnd: TimeInterval
        var editorStart: TimeInterval
        var editorEnd: TimeInterval
    }

    static let minimumInsertDuration: TimeInterval = RecordingAudioClip.minimumPlayableDuration

    static func segmentSlices(
        for segment: RecordingClipSegment,
        editorStart: TimeInterval,
        editorEnd: TimeInterval,
        sync: RecordingAudioSync?,
        hasReplacement: Bool,
        replacementDuration: TimeInterval,
        hasRecording: Bool,
        hasImportedAudio: Bool = false
    ) -> [SegmentSlice] {
        let speed = max(segment.speed, RecordingClipSegment.minimumSpeed)
        var result: [SegmentSlice] = []

        func appendSlice(
            _ kind: SegmentSlice.Kind,
            sourceStart: TimeInterval,
            sourceEnd: TimeInterval,
            mediaStart: TimeInterval,
            mediaEnd: TimeInterval
        ) {
            let start = editorStart + (sourceStart - segment.sourceStart) / speed
            let end = min(editorEnd, editorStart + (sourceEnd - segment.sourceStart) / speed)
            guard mediaEnd - mediaStart >= RecordingAudioClip.minimumFileSpan,
                  end - start >= minimumInsertDuration else { return }
            result.append(SegmentSlice(
                kind: kind,
                sourceStart: sourceStart,
                sourceEnd: sourceEnd,
                mediaStart: mediaStart,
                mediaEnd: mediaEnd,
                editorStart: start,
                editorEnd: end
            ))
        }

        if let fileName = segment.mediaFileName {
            if hasImportedAudio {
                appendSlice(
                    .imported(fileName),
                    sourceStart: segment.sourceStart,
                    sourceEnd: segment.sourceEnd,
                    mediaStart: segment.sourceStart,
                    mediaEnd: segment.sourceEnd
                )
            }
            return result
        }

        guard hasReplacement, let sync else {
            if hasRecording {
                appendSlice(
                    .recording,
                    sourceStart: segment.sourceStart,
                    sourceEnd: segment.sourceEnd,
                    mediaStart: segment.sourceStart,
                    mediaEnd: segment.sourceEnd
                )
            }
            return result
        }

        var cursor = segment.sourceStart
        let pieces = sync.pieces(
            from: segment.sourceStart,
            to: segment.sourceEnd,
            fileDuration: replacementDuration
        )
        let fillGaps = hasRecording && sync.fillsGapsWithRecording
        for piece in pieces {
            if fillGaps, piece.sourceStart - cursor >= RecordingAudioClip.minimumFileSpan {
                appendSlice(
                    .recording,
                    sourceStart: cursor,
                    sourceEnd: piece.sourceStart,
                    mediaStart: cursor,
                    mediaEnd: piece.sourceStart
                )
            }
            appendSlice(
                .replacement,
                sourceStart: piece.sourceStart,
                sourceEnd: piece.sourceEnd,
                mediaStart: piece.fileStart,
                mediaEnd: piece.fileEnd
            )
            cursor = piece.sourceEnd
        }
        if fillGaps, segment.sourceEnd - cursor >= RecordingAudioClip.minimumFileSpan {
            appendSlice(
                .recording,
                sourceStart: cursor,
                sourceEnd: segment.sourceEnd,
                mediaStart: cursor,
                mediaEnd: segment.sourceEnd
            )
        }
        return result
    }

    /// Builds detached audio clips from the exact same slices and effective
    /// level playback uses. Returns nil if any playable slice cannot be
    /// represented faithfully in the lane, so the caller only mutes the video
    /// segment on a lossless move.
    static func detachedClips(
        for segment: RecordingClipSegment,
        editorStart: TimeInterval,
        editorEnd: TimeInterval,
        projectVolume: Double,
        sync: RecordingAudioSync?,
        replacementFileName: String?,
        replacementDisplayName: String?,
        replacementDuration: TimeInterval,
        recordingDisplayName: String,
        sourceDuration: TimeInterval,
        hasRecording: Bool,
        hasImportedAudio: Bool = false,
        lane: Int
    ) -> [RecordingAudioClip]? {
        let hasReplacement = replacementDisplayName != nil && sync != nil && replacementDuration >= RecordingAudioClip.minimumFileSpan
        let slices = segmentSlices(
            for: segment,
            editorStart: editorStart,
            editorEnd: editorEnd,
            sync: sync,
            hasReplacement: hasReplacement,
            replacementDuration: replacementDuration,
            hasRecording: hasRecording,
            hasImportedAudio: hasImportedAudio
        )
        guard !slices.isEmpty else { return nil }
        let effectiveVolume = segment.audibleVolume * RecordingAudioGain.normalized(projectVolume)
        guard RecordingAudioClip.derivedVolumeRange.contains(effectiveVolume) else { return nil }
        var clips: [RecordingAudioClip] = []
        for slice in slices {
            let length = slice.editorEnd - slice.editorStart
            let mediaSpan = slice.mediaEnd - slice.mediaStart
            guard length >= RecordingAudioClip.minimumPlayableDuration,
                  mediaSpan >= RecordingAudioClip.minimumFileSpan else { return nil }
            let rate = mediaSpan / length
            guard RecordingAudioClip.derivedSpeedRange.contains(rate) else { return nil }
            let fileDuration: TimeInterval
            let source: RecordingAudioClip.Source
            let fileName: String
            let displayName: String
            switch slice.kind {
            case .recording:
                source = .recording
                fileName = ""
                displayName = recordingDisplayName
                fileDuration = max(sourceDuration, slice.mediaEnd)
            case .replacement:
                source = .replacement
                fileName = replacementFileName ?? ""
                displayName = replacementDisplayName ?? recordingDisplayName
                fileDuration = max(replacementDuration, slice.mediaEnd)
            case .imported(let importedFileName):
                source = .file
                fileName = importedFileName
                let baseName = segment.displayName?.isEmpty == false ? segment.displayName! : importedFileName
                displayName = "\(baseName) audio"
                fileDuration = max(segment.sourceDuration ?? slice.mediaEnd, slice.mediaEnd)
            }
            var clip = RecordingAudioClip(
                fileName: fileName,
                displayName: displayName,
                start: slice.editorStart,
                fileDuration: fileDuration
            )
            clip.source = source
            clip.trimStart = slice.mediaStart
            clip.trimEnd = slice.mediaEnd
            clip.speed = rate
            clip.volume = effectiveVolume
            clip.isLinked = true
            clip.lane = lane
            clips.append(clip)
        }
        return clips.count == slices.count ? clips : nil
    }

    private static func build(
        _ plan: StudioAudioPlan,
        sources: StudioAudioSources,
        into composition: AVMutableComposition,
        strict: Bool
    ) throws -> StudioAudioLayout {
        var builder = Builder(composition: composition, strict: strict)
        let ranges = editorRanges(for: plan.timeline)
        let hasSoundtrack = plan.sync != nil && !sources.replacement.isEmpty
        let hasRecording = !sources.recording.isEmpty

        for (segment, range) in zip(plan.timeline.segments, ranges) {
            let owner = StudioAudioLayout.Owner.segment(segment.id)
            let hasImportedAudio = segment.mediaFileName.map { !(sources.files[$0]?.isEmpty ?? true) } ?? false
            let slices = segmentSlices(
                for: segment,
                editorStart: range.start.seconds,
                editorEnd: range.end.seconds,
                sync: plan.sync,
                hasReplacement: hasSoundtrack,
                replacementDuration: sources.replacementDuration,
                hasRecording: hasRecording,
                hasImportedAudio: hasImportedAudio
            )
            for slice in slices {
                switch slice.kind {
                case .recording:
                    try builder.insert(
                        sources.recording,
                        group: "recording",
                        mediaStart: slice.mediaStart,
                        mediaEnd: slice.mediaEnd,
                        editorStart: slice.editorStart,
                        editorEnd: slice.editorEnd,
                        owner: owner
                    )
                case .replacement:
                    try builder.insert(
                        sources.replacement,
                        group: "soundtrack",
                        mediaStart: slice.mediaStart,
                        mediaEnd: slice.mediaEnd,
                        editorStart: slice.editorStart,
                        editorEnd: slice.editorEnd,
                        owner: owner
                    )
                case .imported(let fileName):
                    try builder.insert(
                        sources.files[fileName] ?? [],
                        group: "imported-\(fileName)",
                        mediaStart: slice.mediaStart,
                        mediaEnd: slice.mediaEnd,
                        editorStart: slice.editorStart,
                        editorEnd: slice.editorEnd,
                        owner: owner
                    )
                }
            }
        }

        // Audio clips, a lane at a time, cut to the part inside the video.
        let videoDuration = ranges.last?.end.seconds ?? 0
        for clip in plan.clips.sorted(by: { ($0.lane, $0.start) < ($1.lane, $1.start) }) {
            let visibleStart = max(clip.start, 0)
            let visibleEnd = min(clip.end, videoDuration)
            guard visibleEnd - visibleStart >= RecordingAudioClip.minimumPlayableDuration else { continue }
            let tracks = sources.tracks(for: clip)
            if strict, tracks.isEmpty, !clip.isMuted, clip.audibleVolume > 0, clip.source != .recording {
                throw AudioError.missingAudioClip(clip.displayName)
            }
            let speed = max(clip.speed, 0.01)
            try builder.insert(
                tracks,
                group: "lane\(clip.lane)",
                mediaStart: clip.trimStart + (visibleStart - clip.start) * speed,
                mediaEnd: clip.trimStart + (visibleEnd - clip.start) * speed,
                editorStart: visibleStart,
                editorEnd: visibleEnd,
                owner: .clip(clip.id)
            )
        }

        // Layered video overlays on the single video overlay lane.
        for overlay in plan.videoOverlays.sorted(by: { $0.start < $1.start }) {
            let visibleStart = max(overlay.start, 0)
            let visibleEnd = min(overlay.end, videoDuration)
            guard visibleEnd - visibleStart >= RecordingAudioClip.minimumPlayableDuration else { continue }
            let tracks = sources.files[overlay.fileName] ?? []
            guard !tracks.isEmpty else { continue }
            let speed = max(overlay.speed, 0.01)
            try builder.insert(
                tracks,
                group: "videoOverlay",
                mediaStart: overlay.trimStart + (visibleStart - overlay.start) * speed,
                mediaEnd: overlay.trimStart + (visibleEnd - overlay.start) * speed,
                editorStart: visibleStart,
                editorEnd: visibleEnd,
                owner: .videoOverlay(overlay.id)
            )
        }
        return builder.layout
    }

    /// Lays stretches of source tracks onto composition tracks. Sounds of
    /// one group share a composition track per source track, since they
    /// never overlap; AVFoundation mixes far fewer tracks more happily.
    private struct Builder {
        let composition: AVMutableComposition
        let strict: Bool
        var layout = StudioAudioLayout()
        private var tracks: [String: AVMutableCompositionTrack] = [:]

        init(composition: AVMutableComposition, strict: Bool = false) {
            self.composition = composition
            self.strict = strict
        }

        mutating func insert(
            _ sources: [StudioAudioSources.Track],
            group: String,
            mediaStart: TimeInterval,
            mediaEnd: TimeInterval,
            editorStart: TimeInterval,
            editorEnd: TimeInterval,
            owner: StudioAudioLayout.Owner
        ) throws {
            guard mediaEnd - mediaStart >= RecordingAudioClip.minimumFileSpan,
                  editorEnd - editorStart >= RecordingAudioClip.minimumPlayableDuration else { return }
            let rate = (mediaEnd - mediaStart) / (editorEnd - editorStart)

            for (index, source) in sources.enumerated() {
                // Only the part of the file that holds sound can be placed;
                // what is cut from the head moves the start along.
                let wanted = CMTimeRange(start: time(mediaStart), end: time(mediaEnd))
                let available = CMTimeRangeGetIntersection(wanted, otherRange: source.range)
                guard available.duration.seconds >= RecordingAudioClip.minimumFileSpan else { continue }
                let headTrim = (available.start - wanted.start).seconds

                // The group's first track with room at this moment; sound
                // that overlaps what a track holds (clips piled on the last
                // lane) gets a track of its own rather than being pushed
                // later.
                let wantedStart = time(editorStart + headTrim / rate)
                var track: AVMutableCompositionTrack?
                var copy = 0
                while track == nil {
                    let key = copy == 0 ? "\(group)#\(index)" : "\(group)#\(index)~\(copy)"
                    if let existing = tracks[key] {
                        let end = existing.timeRange.end
                        if !end.isValid || end <= wantedStart { track = existing }
                    } else if let added = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) {
                        tracks[key] = added
                        track = added
                    } else {
                        break
                    }
                    copy += 1
                }
                guard let track else { continue }

                // Never before what the track already holds: inserting
                // there would push later sound along.
                var at = wantedStart
                let trackEnd = track.timeRange.end
                if trackEnd.isValid, at < trackEnd { at = trackEnd }
                let target = time(available.duration.seconds / rate)
                do {
                    try track.insertTimeRange(available, of: source.track, at: at)
                    if abs(rate - 1) > 0.000_1, target > .zero {
                        track.scaleTimeRange(CMTimeRange(start: at, duration: available.duration), toDuration: target)
                    }
                } catch {
                    if strict { throw AudioError.compositionInsertFailed(error) }
                    continue
                }
                let placedDuration = abs(rate - 1) > 0.000_1 ? target : available.duration
                layout.placements.append(StudioAudioLayout.Placement(
                    trackID: track.trackID,
                    start: at.seconds,
                    end: (at + placedDuration).seconds,
                    owner: owner,
                    mediaStart: available.start.seconds,
                    mediaEnd: available.end.seconds,
                    sourceIdentity: "\(ObjectIdentifier(source.asset)):\(source.track.trackID)"
                ))
            }
        }
    }

    // MARK: Mix

    private struct Gain {
        var start: TimeInterval
        var end: TimeInterval
        var level: Double
        var fadeIn: TimeInterval = 0
        var fadeOut: TimeInterval = 0
        var mediaStart: TimeInterval = 0
        var mediaEnd: TimeInterval = 0
        var sourceIdentity: String = ""
        /// The ramps a cut adds at either end; see `cutRamp`.
        var edgeIn: TimeInterval = 0
        var edgeOut: TimeInterval = 0

        /// Whether this picks up exactly where `previous` left off, from the
        /// same source asset/track, in the timeline and in the file, at the
        /// same level, with no fade between.
        func continues(from previous: Gain?) -> Bool {
            guard let previous else { return false }
            return previous.sourceIdentity == sourceIdentity
                && abs(previous.end - start) < 0.002
                && abs(previous.mediaEnd - mediaStart) < 0.002
                && abs(previous.level - level) < 0.000_1
                && previous.fadeOut < 0.01 && fadeIn < 0.01
        }
    }

    /// The length of the ramp at every cut. Short enough to be heard as a
    /// cut, long enough that the waveform never jumps, which clicks.
    static let cutRamp: TimeInterval = 0.004

    /// Per-track envelope spans for every track whose level, fade, or cut
    /// ramp departs from unity playback.
    static func envelopeSpans(
        for layout: StudioAudioLayout,
        plan: StudioAudioPlan
    ) -> [CMPersistentTrackID: [RecordingAudioGain.EnvelopeSpan]] {
        let segments = Dictionary(plan.timeline.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let clips = Dictionary(plan.clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let videoOverlays = Dictionary(plan.videoOverlays.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projectVolume = RecordingAudioGain.normalized(plan.volume)
        let videoEnd = editorRanges(for: plan.timeline).last?.end.seconds ?? 0

        var gains: [CMPersistentTrackID: [Gain]] = [:]
        for placement in layout.placements {
            var gain = Gain(start: placement.start, end: placement.end, level: 1)
            gain.mediaStart = placement.mediaStart
            gain.mediaEnd = placement.mediaEnd
            gain.sourceIdentity = placement.sourceIdentity
            switch placement.owner {
            case .segment(let id):
                gain.level = (segments[id]?.audibleVolume ?? 1) * projectVolume
            case .clip(let id):
                guard let clip = clips[id] else { continue }
                gain.level = StudioAudioLaneSolo.effectiveGain(for: clip, soloLane: plan.soloLane)
                // Fades are squeezed into half the clip each, so they
                // never cross, and belong to the clip's own ends.
                let fadeIn = min(clip.fadeIn, clip.duration / 2)
                let fadeOut = min(clip.fadeOut, clip.duration / 2)
                gain.fadeIn = max(0, min(clip.start + fadeIn, placement.end) - placement.start)
                gain.fadeOut = max(0, placement.end - max(clip.end - fadeOut, placement.start))
                if clip.start + fadeIn <= placement.start { gain.fadeIn = 0 }
                if clip.end - fadeOut >= placement.end { gain.fadeOut = 0 }
            case .videoOverlay(let id):
                guard let overlay = videoOverlays[id] else { continue }
                gain.level = plan.soloLane != nil ? 0 : overlay.audibleVolume
                let fadeIn = min(overlay.audioFadeIn, overlay.duration / 2)
                let fadeOut = min(overlay.audioFadeOut, overlay.duration / 2)
                gain.fadeIn = max(0, min(overlay.start + fadeIn, placement.end) - placement.start)
                gain.fadeOut = max(0, placement.end - max(overlay.end - fadeOut, placement.start))
                if overlay.start + fadeIn <= placement.start { gain.fadeIn = 0 }
                if overlay.end - fadeOut >= placement.end { gain.fadeOut = 0 }
            }
            gains[placement.trackID, default: []].append(gain)
        }

        var result: [CMPersistentTrackID: [RecordingAudioGain.EnvelopeSpan]] = [:]
        for (trackID, unsorted) in gains {
            var trackGains = unsorted.sorted { $0.start < $1.start }
            // A short ramp at every real cut. Where one placement simply
            // carries on from the last at the same level (a split with
            // nothing removed) the sound is continuous and needs none, and
            // the video's first and last frames need none either.
            for index in trackGains.indices {
                let gain = trackGains[index]
                let length = min(cutRamp, (gain.end - gain.start) / 4)
                let previous = index > 0 ? trackGains[index - 1] : nil
                let next = index < trackGains.count - 1 ? trackGains[index + 1] : nil
                if gain.start > 0.000_5, !gain.continues(from: previous) {
                    trackGains[index].edgeIn = length
                }
                if gain.end < videoEnd - 0.000_5, !(next?.continues(from: gain) ?? false) {
                    trackGains[index].edgeOut = length
                }
            }

            let changesNothing = trackGains.allSatisfy {
                abs($0.level - 1) < 0.000_1 && $0.fadeIn < 0.01 && $0.fadeOut < 0.01
                    && $0.edgeIn == 0 && $0.edgeOut == 0
            }
            if changesNothing { continue }

            var spans: [RecordingAudioGain.EnvelopeSpan] = []
            for gain in trackGains {
                let level = Float(gain.level)
                let fadeIn = max(gain.fadeIn >= 0.01 ? gain.fadeIn : 0, gain.edgeIn)
                let fadeOut = max(gain.fadeOut >= 0.01 ? gain.fadeOut : 0, gain.edgeOut)
                let holdStart = gain.start + fadeIn
                let holdEnd = max(holdStart, gain.end - fadeOut)
                if fadeIn > 0 {
                    spans.append(.init(start: gain.start, end: holdStart, startGain: 0, endGain: level))
                }
                if holdEnd > holdStart {
                    spans.append(.init(start: holdStart, end: holdEnd, startGain: level, endGain: level))
                }
                if fadeOut > 0 {
                    spans.append(.init(start: holdEnd, end: gain.end, startGain: level, endGain: 0))
                }
            }
            result[trackID] = spans
        }
        return result
    }

    /// How loud each placed sound plays: a video clip's own sound at its
    /// level times the project's, an audio clip at its level with its
    /// fades. Nil when everything plays as recorded.
    static func mix(for layout: StudioAudioLayout, plan: StudioAudioPlan) -> AVAudioMix? {
        let trackSpans = envelopeSpans(for: layout, plan: plan)
        guard !trackSpans.isEmpty else { return nil }
        let parameters = trackSpans.keys.sorted().map { trackID -> AVMutableAudioMixInputParameters in
            let input = AVMutableAudioMixInputParameters()
            input.trackID = trackID
            // Levels are applied by a tap, exact to the sample: the mix's
            // own volume ramps smear a change over the sound around it,
            // and stop at 1.
            input.audioTapProcessor = RecordingAudioGain.makeEnvelopeTap(spans: trackSpans[trackID] ?? [])
            return input
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }
}
