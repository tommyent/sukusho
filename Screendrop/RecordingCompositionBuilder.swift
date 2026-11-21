//
//  RecordingCompositionBuilder.swift
//  Screendrop
//
//  Shared gap-closing composition used by Studio playback and export.
//

import AVFoundation
import CoreVideo

nonisolated enum RecordingCompositionBuilder {
    static func makeAsset(
        from sourceAsset: AVAsset,
        timeline: RecordingClipTimeline,
        sourceDuration: TimeInterval,
        microphoneTrackID: CMPersistentTrackID? = nil,
        isolatedMicrophone: AVAssetTrack? = nil
    ) throws -> AVAsset {
        let normalized = timeline.normalized(to: sourceDuration)
        if isolatedMicrophone == nil, normalized.isUnedited(sourceDuration: sourceDuration) {
            return sourceAsset
        }

        let composition = AVMutableComposition()
        let trackPairs: [(AVAssetTrack, AVMutableCompositionTrack)]
        if let isolatedMicrophone {
            guard let microphoneTrackID else { throw CocoaError(.fileReadCorruptFile) }
            let tracks = sourceAsset.tracks
            guard tracks.contains(where: { $0.trackID == microphoneTrackID && $0.mediaType == .audio }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            trackPairs = try tracks.map { original in
                guard let destination = composition.addMutableTrack(
                    withMediaType: original.mediaType, preferredTrackID: original.trackID
                ) else { throw CocoaError(.fileReadCorruptFile) }
                destination.preferredTransform = original.preferredTransform
                return (original.trackID == microphoneTrackID ? isolatedMicrophone : original, destination)
            }
        } else {
            trackPairs = []
        }
        var insertionTime = CMTime.zero
        for clip in normalized.segments {
            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.duration, preferredTimescale: 600)
            )
            if trackPairs.isEmpty {
                try composition.insertTimeRange(range, of: sourceAsset, at: insertionTime)
            } else {
                for (source, destination) in trackPairs {
                    // Audio can begin late or end before the screen; retain those silent gaps.
                    let available = CMTimeRangeGetIntersection(range, otherRange: source.timeRange)
                    if available.duration > .zero {
                        try destination.insertTimeRange(available, of: source,
                            at: insertionTime + available.start - range.start)
                    }
                }
            }

            // Retiming here scales every track inserted above together
            // (video and audio alike), so a sped-up clip never drifts out
            // of sync the way independently retiming each track would.
            if abs(clip.speed - 1) > 0.000_001 {
                let insertedRange = CMTimeRange(start: insertionTime, duration: range.duration)
                let scaledDuration = CMTime(seconds: clip.editorDuration, preferredTimescale: 600)
                composition.scaleTimeRange(insertedRange, toDuration: scaledDuration)
                insertionTime = insertionTime + scaledDuration
            } else {
                insertionTime = insertionTime + range.duration
            }
        }
        return composition
    }

    /// Playback asset whose soundtrack comes from an imported file instead
    /// of the recording's own audio. The video track arrives already
    /// resolved so Studio can rebuild the player item synchronously, the
    /// way it does on every trim.
    static func makeAsset(
        videoTrack: AVAssetTrack,
        timeline: RecordingClipTimeline,
        sourceDuration: TimeInterval,
        replacementAudio: RecordingReplacementAudio
    ) throws -> AVAsset {
        let normalized = timeline.normalized(to: sourceDuration)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var insertionTime = CMTime.zero
        for clip in normalized.segments {
            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.duration, preferredTimescale: 600)
            )
            try video.insertTimeRange(range, of: videoTrack, at: insertionTime)

            if abs(clip.speed - 1) > 0.000_001 {
                let insertedRange = CMTimeRange(start: insertionTime, duration: range.duration)
                let scaledDuration = CMTime(seconds: clip.editorDuration, preferredTimescale: 600)
                video.scaleTimeRange(insertedRange, toDuration: scaledDuration)
                insertionTime = insertionTime + scaledDuration
            } else {
                insertionTime = insertionTime + range.duration
            }
        }

        // The import is already the finished cut's soundtrack, so it lies
        // flat from zero rather than being re-cut through the clip list -
        // and is clipped to whatever the timeline still holds.
        let audioLength = min(replacementAudio.duration, insertionTime.seconds)
        if audioLength > 0,
           let audio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try audio.insertTimeRange(
                CMTimeRange(
                    start: .zero,
                    duration: CMTime(seconds: audioLength, preferredTimescale: 600)
                ),
                of: replacementAudio.track,
                at: .zero
            )
        }
        return composition
    }

    /// The cut's picture alone, from a video track resolved ahead of time
    /// so Studio can rebuild its player item synchronously on every edit.
    /// `StudioAudioComposer` adds the sound.
    static func makeVideoComposition(
        videoTrack: AVAssetTrack,
        timeline: RecordingClipTimeline
    ) throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        video.preferredTransform = videoTrack.preferredTransform

        // The same ranges the sound is laid on, so both share every cut.
        let ranges = StudioAudioComposer.editorRanges(for: timeline)
        for (clip, editorRange) in zip(timeline.segments, ranges) {
            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.duration, preferredTimescale: 600)
            )
            try video.insertTimeRange(range, of: videoTrack, at: editorRange.start)
            if abs(clip.speed - 1) > 0.000_001 {
                video.scaleTimeRange(
                    CMTimeRange(start: editorRange.start, duration: range.duration),
                    toDuration: editorRange.duration
                )
            }
        }
        return composition
    }
}

/// Sequential decoder for the camera movie that answers "latest camera frame
/// at screen-time t". Reordered clips can jump backward in source time, so a
/// backward jump cancels and restarts the reader near the target moment and
/// drops the cached frame rather than freezing on later footage.
nonisolated final class RecordingCameraFrameFeed: @unchecked Sendable {
    private static let readerOutputSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        // IOSurface-backed so the bubble scaler can read it on the GPU.
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    /// Lookback when restarting a reader after a backward cut, so sparse
    /// camera frames just before the cut boundary are still decoded.
    private static let restartLookback: TimeInterval = 1.0

    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let offset: TimeInterval
    private let trackDuration: TimeInterval
    private var reader: AVAssetReader
    private var output: AVAssetReaderTrackOutput
    private var currentFrame: CVPixelBuffer?
    private var pendingFrame: (buffer: CVPixelBuffer, time: TimeInterval)?
    private var lastScreenTime: TimeInterval?
    private var isFinished = false

    init?(url: URL?, offset: TimeInterval) async throws {
        guard let url else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }
        let durationSeconds = (try? await asset.load(.duration).seconds) ?? 0
        let (reader, output) = try Self.makeReader(asset: asset, track: track, startTime: nil)

        self.asset = asset
        self.track = track
        self.offset = offset
        self.trackDuration = durationSeconds.isFinite ? max(0, durationSeconds) : 0
        self.reader = reader
        self.output = output
    }

    private static func makeReader(
        asset: AVURLAsset,
        track: AVAssetTrack,
        startTime: TimeInterval?
    ) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: readerOutputSettings
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        if let startTime, startTime > 0 {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: startTime, preferredTimescale: 600),
                duration: .positiveInfinity
            )
        }
        guard reader.startReading() else {
            throw reader.error ?? CocoaError(.fileReadCorruptFile)
        }
        return (reader, output)
    }

    private func restart(for screenTime: TimeInterval) throws {
        reader.cancelReading()
        currentFrame = nil
        pendingFrame = nil
        isFinished = false

        let rawStart = max(0, screenTime - offset - Self.restartLookback)
        let clampedStart = trackDuration > 0
            ? min(rawStart, max(0, trackDuration - Self.restartLookback))
            : rawStart
        let (nextReader, nextOutput) = try Self.makeReader(
            asset: asset,
            track: track,
            startTime: clampedStart > 0 ? clampedStart : nil
        )
        reader = nextReader
        output = nextOutput
    }

    func latestFrame(at screenTime: TimeInterval) throws -> CVPixelBuffer? {
        if let last = lastScreenTime, screenTime < last - 0.000_5 {
            try restart(for: screenTime)
        }
        lastScreenTime = screenTime

        while !isFinished {
            if let pending = pendingFrame {
                // Promote the very first frame unconditionally: the camera
                // starts a beat after the screen (capture warmup), and holding
                // its first frame from t=0 beats the bubble popping in late.
                guard pending.time <= screenTime || currentFrame == nil else { break }
                currentFrame = pending.buffer
                pendingFrame = nil
            }
            guard let sample = output.copyNextSampleBuffer() else {
                isFinished = true
                break
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds + offset
            pendingFrame = (buffer: buffer, time: time)
        }
        return currentFrame
    }

    func cancel() {
        reader.cancelReading()
    }

    var failureError: Error? {
        reader.status == .failed ? reader.error : nil
    }
}
