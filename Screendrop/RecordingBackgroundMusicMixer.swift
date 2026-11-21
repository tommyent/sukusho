import AVFoundation
import Foundation

nonisolated enum RecordingBackgroundMusicMixer {
    struct Configuration: Sendable {
        var url: URL
        var settings: RecordingBackgroundMusic
    }

    /// Adds the background music track directly onto a mutable composition,
    /// preserving every existing track ID (and any `StudioAudioLayout`).
    static func addTrack(to composition: AVMutableComposition, music: RecordingReplacementAudio,
                         settings: RecordingBackgroundMusic, timeline: RecordingClipTimeline) throws -> CMPersistentTrackID {
        try settings.validate()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let range = music.track.timeRange
        let start = range.start.seconds
        let length = min(music.duration, range.end.seconds) - start
        guard length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        for part in RecordingMusicEnvelope.placements(trackDuration: length, startOffset: settings.startOffset - start, duration: timeline.duration, loop: settings.loop) {
            try track.insertTimeRange(CMTimeRange(start: time(start + part.sourceStart), duration: time(part.duration)),
                                      of: music.track, at: time(part.editorStart))
        }
        return track.trackID
    }

    /// The recording/replacement is already cut; music follows editor time at its original speed.
    static func adding(to asset: AVAsset, music: RecordingReplacementAudio, settings: RecordingBackgroundMusic,
                       timeline: RecordingClipTimeline) throws -> (asset: AVAsset, trackID: CMPersistentTrackID) {
        try settings.validate()
        let composition: AVMutableComposition
        if let existing = asset as? AVComposition, let copy = existing.mutableCopy() as? AVMutableComposition {
            composition = copy
        } else {
            composition = AVMutableComposition()
            let length = min(asset.duration.seconds, timeline.duration)
            if length > 0 {
                try composition.insertTimeRange(CMTimeRange(start: .zero, duration: time(length)), of: asset, at: .zero)
            }
        }
        let trackID = try addTrack(to: composition, music: music, settings: settings, timeline: timeline)
        return (composition, trackID)
    }

    static func inputParameters(trackID: CMPersistentTrackID?, settings: RecordingBackgroundMusic?,
                                speech: [ClosedRange<Double>], timeline: RecordingClipTimeline) -> AVMutableAudioMixInputParameters? {
        guard let trackID, let settings else { return nil }
        let parameters = AVMutableAudioMixInputParameters()
        parameters.trackID = trackID
        let points = RecordingMusicEnvelope.points(settings: settings, speech: speech, timeline: timeline)
        if let first = points.first { parameters.setVolume(Float(first.volume), at: .zero) }
        for (start, end) in zip(points, points.dropFirst()) where end.time > start.time {
            parameters.setVolumeRamp(fromStartVolume: Float(start.volume), toEndVolume: Float(end.volume),
                timeRange: CMTimeRange(start: time(start.time), duration: time(end.time - start.time)))
        }
        return parameters
    }

    static func combinedMix(base: AVAudioMix?, musicTrackID: CMPersistentTrackID?, settings: RecordingBackgroundMusic?,
                            speech: [ClosedRange<Double>], timeline: RecordingClipTimeline) -> AVAudioMix? {
        guard let musicParameters = inputParameters(trackID: musicTrackID, settings: settings, speech: speech, timeline: timeline) else {
            return base
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = (base?.inputParameters ?? []) + [musicParameters]
        return mix
    }

    static func mix(asset: AVAsset, volume: Double, musicTrackID: CMPersistentTrackID?, settings: RecordingBackgroundMusic?,
                    speech: [ClosedRange<Double>], timeline: RecordingClipTimeline) -> AVAudioMix? {
        let tracks = asset.tracks(withMediaType: .audio)
        let recorded = tracks.filter { $0.trackID != musicTrackID }
        let base = RecordingAudioGain.makeMix(tracks: recorded, volume: volume)
        guard tracks.contains(where: { $0.trackID == musicTrackID }) else { return base }
        return combinedMix(base: base, musicTrackID: musicTrackID, settings: settings, speech: speech, timeline: timeline)
    }

    /// Loads the music file and speech-ducking analysis, adds the music track
    /// directly onto `composition`, and returns its mix parameters plus the
    /// loaded asset handle to keep alive during reading.
    static func addPreparedMusic(
        to composition: AVMutableComposition,
        music: Configuration?,
        sourceURL: URL,
        microphoneTrackID: CMPersistentTrackID?,
        timeline: RecordingClipTimeline
    ) async throws -> (trackID: CMPersistentTrackID, parameters: AVMutableAudioMixInputParameters, loaded: RecordingReplacementAudio)? {
        guard let music else { return nil }
        guard let loaded = await RecordingReplacementAudio.load(url: music.url, displayName: music.settings.displayName) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The background music file is missing or unreadable. Add it again or remove it."])
        }
        let speech: [ClosedRange<Double>]
        if music.settings.duck, let microphoneTrackID {
            speech = try await RecordingMusicAnalysisCache.shared.availableAnalysis(url: sourceURL, trackID: microphoneTrackID)?.speech ?? []
        } else { speech = [] }
        try Task.checkCancellation()
        let trackID = try addTrack(to: composition, music: loaded, settings: music.settings, timeline: timeline)
        guard let parameters = inputParameters(trackID: trackID, settings: music.settings, speech: speech, timeline: timeline) else {
            return nil
        }
        return (trackID, parameters, loaded)
    }

    static func prepare(asset: AVAsset, music: Configuration?, sourceURL: URL, microphoneTrackID: CMPersistentTrackID?,
                        timeline: RecordingClipTimeline, volume: Double) async throws -> (asset: AVAsset, mix: AVAudioMix?) {
        guard let music else {
            return (asset, RecordingAudioGain.makeMix(tracks: try await asset.loadTracks(withMediaType: .audio), volume: volume))
        }
        guard let loaded = await RecordingReplacementAudio.load(url: music.url, displayName: music.settings.displayName) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The background music file is missing or unreadable. Add it again or remove it."])
        }
        let speech: [ClosedRange<Double>]
        if music.settings.duck, let microphoneTrackID {
            speech = try await RecordingMusicAnalysisCache.shared.availableAnalysis(url: sourceURL, trackID: microphoneTrackID)?.speech ?? []
        } else { speech = [] }
        try Task.checkCancellation()
        let combined = try adding(to: asset, music: loaded, settings: music.settings, timeline: timeline)
        return (combined.asset, mix(asset: combined.asset, volume: volume, musicTrackID: combined.trackID,
                                    settings: music.settings, speech: speech, timeline: timeline))
    }

    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }
}
