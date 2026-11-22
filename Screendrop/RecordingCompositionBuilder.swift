//
//  RecordingCompositionBuilder.swift
//  Screendrop
//
//  Shared gap-closing composition used by Studio playback and export.
//

import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import UniformTypeIdentifiers

/// Resolved metadata and track handle for one video source (primary or imported).
/// Probed via async `AVURLAsset.load(...)` without decoding frames.
nonisolated struct StudioVideoSource: @unchecked Sendable {
    let asset: AVAsset
    let videoTrack: AVAssetTrack
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let duration: TimeInterval

    var displaySize: CGSize {
        RecordingCompositionBuilder.displaySize(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        )
    }

    static func load(url: URL) async throws -> StudioVideoSource {
        let asset = AVURLAsset(url: url)
        let (durationTime, tracks) = try await asset.load(.duration, .tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw RecordingCompositionBuilder.VideoSequenceError.unreadableClip(url.lastPathComponent)
        }
        let (naturalSize, preferredTransform, trackTimeRange) = try await videoTrack.load(
            .naturalSize,
            .preferredTransform,
            .timeRange
        )
        let duration = durationTime.seconds.isFinite && durationTime.seconds > 0
            ? durationTime.seconds
            : trackTimeRange.duration.seconds
        guard duration.isFinite, duration >= RecordingClipSegment.minimumDuration,
              naturalSize.width > 0, naturalSize.height > 0 else {
            throw RecordingCompositionBuilder.VideoSequenceError.unreadableClip(url.lastPathComponent)
        }
        return StudioVideoSource(
            asset: asset,
            videoTrack: videoTrack,
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            duration: duration
        )
    }
}

/// File classification for in-sequence video clip imports (plain movie files
/// and Sukusho recording packages).
nonisolated enum StudioVideoClipImport {
    enum SukushoRecordingMode: String, CaseIterable, Identifiable, Sendable {
        case rawRecording
        case finishedMovie

        var id: Self { self }
    }

    static let movieContentTypes: [UTType] = [.movie, .quickTimeMovie, .mpeg4Movie]

    static func isMovieFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie)
    }

    static func isSukushoRecording(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext == "sukushorec" || ext == "screendroprec" else { return false }
        return RecordingOverlayMedia.isRealDirectoryNoFollow(at: url)
            && RecordingOverlayMedia.isRegularFileNoFollow(at: url.appendingPathComponent("screen.mov"))
    }

    static func canImport(_ url: URL) -> Bool {
        isSukushoRecording(url) || isMovieFile(url)
    }
}

nonisolated enum RecordingCompositionBuilder {
    enum VideoSequenceError: LocalizedError, Equatable {
        case missingClip(String)
        case unreadableClip(String)

        var errorDescription: String? {
            switch self {
            case .missingClip(let name):
                "The video clip \"\(name)\" is missing or unreadable."
            case .unreadableClip(let name):
                "Could not read video track from \"\(name)\"."
            }
        }
    }

    /// Oriented display size of a video track after applying its `preferredTransform`.
    static func displaySize(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// The centered sub-rectangle of `renderSize` that stays visible inside the
    /// project's video card when `cardSize` and `contentFillSize` differ (for
    /// example under a 9:16 Fill export aspect or a primary video crop).
    static func visibleCardRect(
        renderSize: CGSize,
        cardSize: CGSize,
        contentFillSize: CGSize
    ) -> CGRect {
        guard renderSize.width > 0, renderSize.height > 0,
              cardSize.width > 0, cardSize.height > 0,
              contentFillSize.width > 0, contentFillSize.height > 0 else {
            return CGRect(origin: .zero, size: renderSize)
        }
        let widthFraction = min(1, cardSize.width / contentFillSize.width)
        let heightFraction = min(1, cardSize.height / contentFillSize.height)
        let width = renderSize.width * widthFraction
        let height = renderSize.height * heightFraction
        return CGRect(
            x: (renderSize.width - width) / 2,
            y: (renderSize.height - height) / 2,
            width: width,
            height: height
        )
    }

    /// Affine transform mapping raw coded pixels `(0, 0, naturalSize)` through
    /// `preferredTransform` (so portrait iPhone `.mov` files stay upright) and
    /// scaling via `Fit` (letterboxed, nothing cropped) or `Fill` (center-cropped)
    /// into `targetRect` inside the composition's `renderSize`.
    static func placementTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        in targetRect: CGRect,
        contentMode: VideoClipContentMode
    ) -> CGAffineTransform {
        guard naturalSize.width > 0, naturalSize.height > 0,
              targetRect.width > 0, targetRect.height > 0 else {
            return .identity
        }
        let orientedBounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let orientedWidth = abs(orientedBounds.width)
        let orientedHeight = abs(orientedBounds.height)
        guard orientedWidth > 0, orientedHeight > 0 else { return .identity }

        // Normalize preferredTransform so the oriented frame starts at (0, 0)
        // regardless of whether tx/ty were populated by the muxer.
        let oriented = preferredTransform.concatenating(
            CGAffineTransform(translationX: -orientedBounds.minX, y: -orientedBounds.minY)
        )
        let scale: CGFloat = switch contentMode {
        case .fit:
            min(targetRect.width / orientedWidth, targetRect.height / orientedHeight)
        case .fill:
            max(targetRect.width / orientedWidth, targetRect.height / orientedHeight)
        }
        let scaledWidth = orientedWidth * scale
        let scaledHeight = orientedHeight * scale
        let offsetX = targetRect.midX - scaledWidth / 2
        let offsetY = targetRect.midY - scaledHeight / 2
        return oriented
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
    }
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
        try makeVideoCompositionWithTimeMap(videoTrack: videoTrack, timeline: timeline).composition
    }

    /// Same single-source composition alongside its exact edit-to-media map.
    static func makeVideoCompositionWithTimeMap(
        videoTrack: AVAssetTrack,
        timeline: RecordingClipTimeline
    ) throws -> (composition: AVMutableComposition, timeMap: StudioCompositionTimeMap) {
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
        var entries: [StudioCompositionTimeMap.Entry] = []
        entries.reserveCapacity(timeline.segments.count)

        for (index, (clip, editorRange)) in zip(timeline.segments, ranges).enumerated() {
            let inserted = try insertVideoSegment(
                clip: clip,
                segmentIndex: index,
                editorRange: editorRange,
                sourceTrack: videoTrack,
                into: video
            )
            entries.append(contentsOf: inserted)
        }
        return (composition, StudioCompositionTimeMap(entries: entries))
    }

    /// Inserts one clip segment onto `destinationTrack` at `editorRange`
    /// without ever stretching a shorter video track across missing leading or
    /// trailing time: covered video stays at its true source-clock rate
    /// (`clip.speed`), and any uncovered portion is filled with an explicit
    /// empty range so picture stays locked to audio and redactions stay exact.
    private static func insertVideoSegment(
        clip: RecordingClipSegment,
        segmentIndex: Int,
        editorRange: CMTimeRange,
        sourceTrack: AVAssetTrack,
        into destinationTrack: AVMutableCompositionTrack
    ) throws -> [StudioCompositionTimeMap.Entry] {
        let requested = CMTimeRange(
            start: CMTime(seconds: max(0, clip.sourceStart), preferredTimescale: 600),
            duration: CMTime(seconds: max(0, clip.duration), preferredTimescale: 600)
        )
        let speed = max(clip.speed, RecordingClipSegment.minimumSpeed)
        let isSpedUp = abs(speed - 1) > 0.000_001
        let trackRange = sourceTrack.timeRange
        let hasValidTrackRange = trackRange.duration > .zero
        let covered = hasValidTrackRange
            ? CMTimeRangeGetIntersection(requested, otherRange: trackRange)
            : requested
        let subTick = CMTime(value: 1, timescale: 600)
        let leadingSourceDur = hasValidTrackRange
            ? max(CMTime.zero, covered.start - requested.start)
            : .zero
        let trailingSourceDur = hasValidTrackRange
            ? max(CMTime.zero, requested.end - covered.end)
            : .zero

        // Normal full coverage (within 1/600s muxer rounding): identical to
        // `main`'s insertion and speed scaling.
        if !hasValidTrackRange
            || CMTimeRangeEqual(covered, requested)
            || (covered.duration > .zero && leadingSourceDur < subTick && trailingSourceDur < subTick) {
            try destinationTrack.insertTimeRange(requested, of: sourceTrack, at: editorRange.start)
            if isSpedUp {
                destinationTrack.scaleTimeRange(
                    CMTimeRange(start: editorRange.start, duration: requested.duration),
                    toDuration: editorRange.duration
                )
            }
            return [
                StudioCompositionTimeMap.Entry(
                    segmentIndex: segmentIndex,
                    segmentID: clip.id,
                    isPrimaryRecording: clip.isPrimaryRecording,
                    mediaFileName: clip.mediaFileName,
                    editorRange: editorRange,
                    sourceRange: requested,
                    hasVideo: true
                )
            ]
        }

        // Completely outside the video track (e.g. audio-only tail): keep empty.
        if covered.duration <= .zero {
            destinationTrack.insertEmptyTimeRange(editorRange)
            return [
                StudioCompositionTimeMap.Entry(
                    segmentIndex: segmentIndex,
                    segmentID: clip.id,
                    isPrimaryRecording: clip.isPrimaryRecording,
                    mediaFileName: clip.mediaFileName,
                    editorRange: editorRange,
                    sourceRange: requested,
                    hasVideo: false
                )
            ]
        }

        // Partial video coverage: keep video at its exact source-clock placement
        // (scaled only by `clip.speed`, never stretched across uncovered time).
        let rawLeadingEd = isSpedUp
            ? CMTime(seconds: leadingSourceDur.seconds / speed, preferredTimescale: 600)
            : leadingSourceDur
        let leadingEditorDur = min(rawLeadingEd, editorRange.duration)
        let remainingAfterLeading = editorRange.duration - leadingEditorDur
        let rawCoveredEd = isSpedUp
            ? CMTime(seconds: covered.duration.seconds / speed, preferredTimescale: 600)
            : covered.duration
        let coveredEditorDur = min(rawCoveredEd, remainingAfterLeading)
        let trailingEditorDur = remainingAfterLeading - coveredEditorDur

        var result: [StudioCompositionTimeMap.Entry] = []
        if leadingEditorDur > .zero {
            let leadEd = CMTimeRange(start: editorRange.start, duration: leadingEditorDur)
            destinationTrack.insertEmptyTimeRange(leadEd)
            result.append(StudioCompositionTimeMap.Entry(
                segmentIndex: segmentIndex,
                segmentID: clip.id,
                isPrimaryRecording: clip.isPrimaryRecording,
                mediaFileName: clip.mediaFileName,
                editorRange: leadEd,
                sourceRange: CMTimeRange(start: requested.start, duration: leadingSourceDur),
                hasVideo: false
            ))
        }
        if coveredEditorDur > .zero {
            let covStart = editorRange.start + leadingEditorDur
            let covEd = CMTimeRange(start: covStart, duration: coveredEditorDur)
            try destinationTrack.insertTimeRange(covered, of: sourceTrack, at: covStart)
            if isSpedUp {
                destinationTrack.scaleTimeRange(
                    CMTimeRange(start: covStart, duration: covered.duration),
                    toDuration: coveredEditorDur
                )
            }
            result.append(StudioCompositionTimeMap.Entry(
                segmentIndex: segmentIndex,
                segmentID: clip.id,
                isPrimaryRecording: clip.isPrimaryRecording,
                mediaFileName: clip.mediaFileName,
                editorRange: covEd,
                sourceRange: covered,
                hasVideo: true
            ))
        }
        if trailingEditorDur > .zero {
            let trailStart = editorRange.start + leadingEditorDur + coveredEditorDur
            let trailEd = CMTimeRange(start: trailStart, duration: trailingEditorDur)
            destinationTrack.insertEmptyTimeRange(trailEd)
            let trailSrcStart = covered.end
            let trailSrcDur = max(CMTime.zero, requested.end - trailSrcStart)
            result.append(StudioCompositionTimeMap.Entry(
                segmentIndex: segmentIndex,
                segmentID: clip.id,
                isPrimaryRecording: clip.isPrimaryRecording,
                mediaFileName: clip.mediaFileName,
                editorRange: trailEd,
                sourceRange: CMTimeRange(start: trailSrcStart, duration: trailSrcDur),
                hasVideo: false
            ))
        }
        return result
    }

    /// Multi-source video composition: inserts segments across alternating
    /// composition tracks with one instruction per segment applying
    /// `preferredTransform` and per-clip `Fit`/`Fill` scaling into `renderSize`.
    /// When `redactionSource` is provided (live preview with redactions),
    /// attaches `StudioMultiSourceRedactionCompositor` so redactions apply
    /// fail-closed to primary-recording segments using each instruction's own
    /// exact edit-to-media time mapping.
    static func makeMultiSourceVideoComposition(
        primarySource: StudioVideoSource,
        importedSources: [String: StudioVideoSource],
        timeline: RecordingClipTimeline,
        renderSize: CGSize,
        targetRect: CGRect? = nil,
        redactionSource: RecordingRedactionPreviewSource? = nil
    ) throws -> (composition: AVMutableComposition, videoComposition: AVMutableVideoComposition, timeMap: StudioCompositionTimeMap) {
        let safeRenderSize = CGSize(
            width: max(2, CGFloat(Int(renderSize.width.rounded()) & ~1)),
            height: max(2, CGFloat(Int(renderSize.height.rounded()) & ~1))
        )
        let fullRect = CGRect(origin: .zero, size: safeRenderSize)
        let importedTargetRect: CGRect
        if let targetRect, targetRect.width > 0, targetRect.height > 0 {
            let scaleX = safeRenderSize.width / max(renderSize.width, 1)
            let scaleY = safeRenderSize.height / max(renderSize.height, 1)
            importedTargetRect = CGRect(
                x: targetRect.minX * scaleX,
                y: targetRect.minY * scaleY,
                width: targetRect.width * scaleX,
                height: targetRect.height * scaleY
            )
        } else {
            importedTargetRect = fullRect
        }

        let composition = AVMutableComposition()
        let trackCount = min(2, max(1, timeline.segments.count))
        var videoTracks: [AVMutableCompositionTrack] = []
        for _ in 0..<trackCount {
            guard let track = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            videoTracks.append(track)
        }

        let frameDuration = CMTime(value: 1, timescale: 60)
        let ranges = StudioAudioComposer.editorRanges(for: timeline)
        var instructions: [any AVVideoCompositionInstructionProtocol] = []
        instructions.reserveCapacity(timeline.segments.count)
        var entries: [StudioCompositionTimeMap.Entry] = []
        entries.reserveCapacity(timeline.segments.count)

        for (index, (clip, editorRange)) in zip(timeline.segments, ranges).enumerated() {
            let source: StudioVideoSource
            if clip.isPrimaryRecording {
                source = primarySource
            } else if let fileName = clip.mediaFileName, let imported = importedSources[fileName] {
                source = imported
            } else {
                throw VideoSequenceError.missingClip(clip.displayName ?? clip.mediaFileName ?? "Video clip")
            }

            let track = videoTracks[index % videoTracks.count]
            let insertedEntries = try insertVideoSegment(
                clip: clip,
                segmentIndex: index,
                editorRange: editorRange,
                sourceTrack: source.videoTrack,
                into: track
            )
            entries.append(contentsOf: insertedEntries)

            let transform = placementTransform(
                naturalSize: source.naturalSize,
                preferredTransform: source.preferredTransform,
                in: clip.isPrimaryRecording ? fullRect : importedTargetRect,
                contentMode: clip.isPrimaryRecording ? .fit : clip.effectiveContentMode
            )

            for entry in insertedEntries {
                let effectiveTrackID = entry.hasVideo ? track.trackID : kCMPersistentTrackID_Invalid
                if let redactionSource {
                    instructions.append(StudioMultiSourceRedactionInstruction(
                        entry: entry,
                        frameDuration: frameDuration.seconds,
                        trackID: effectiveTrackID,
                        transform: transform,
                        redactionSource: redactionSource,
                        renderSize: safeRenderSize
                    ))
                } else {
                    let instruction = AVMutableVideoCompositionInstruction()
                    instruction.timeRange = entry.editorRange
                    instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
                    if entry.hasVideo {
                        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                        layerInstruction.setTransform(transform, at: entry.editorRange.start)
                        instruction.layerInstructions = [layerInstruction]
                    } else {
                        instruction.layerInstructions = []
                    }
                    instructions.append(instruction)
                }
            }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = safeRenderSize
        videoComposition.frameDuration = frameDuration
        videoComposition.instructions = instructions
        if redactionSource != nil {
            videoComposition.customVideoCompositorClass = StudioMultiSourceRedactionCompositor.self
        }
        return (composition, videoComposition, StudioCompositionTimeMap(entries: entries))
    }

    /// Single-clip preview composition for live trim preview of an imported clip.
    static func makeSingleSourcePreviewComposition(
        source: StudioVideoSource,
        contentMode: VideoClipContentMode,
        renderSize: CGSize,
        targetRect: CGRect? = nil
    ) -> AVMutableVideoComposition {
        let safeRenderSize = CGSize(
            width: max(2, CGFloat(Int(renderSize.width.rounded()) & ~1)),
            height: max(2, CGFloat(Int(renderSize.height.rounded()) & ~1))
        )
        let effectiveTarget: CGRect
        if let targetRect, targetRect.width > 0, targetRect.height > 0 {
            let scaleX = safeRenderSize.width / max(renderSize.width, 1)
            let scaleY = safeRenderSize.height / max(renderSize.height, 1)
            effectiveTarget = CGRect(
                x: targetRect.minX * scaleX,
                y: targetRect.minY * scaleY,
                width: targetRect.width * scaleX,
                height: targetRect.height * scaleY
            )
        } else {
            effectiveTarget = CGRect(origin: .zero, size: safeRenderSize)
        }
        let transform = placementTransform(
            naturalSize: source.naturalSize,
            preferredTransform: source.preferredTransform,
            in: effectiveTarget,
            contentMode: contentMode
        )
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: source.videoTrack)
        layerInstruction.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: max(source.duration, RecordingClipSegment.minimumDuration), preferredTimescale: 600)
        )
        instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = safeRenderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        videoComposition.instructions = [instruction]
        return videoComposition
    }
}

/// Single source of truth mapping actual composition (edited) CMTime ranges
/// to each segment's inserted source CMTime range and identity. Built once when
/// the composition is constructed so export provenance, source-time redaction
/// coverage, preview masking, and reader end times never drift from the
/// quantized 600ths composition clock.
nonisolated struct StudioCompositionTimeMap: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let segmentIndex: Int
        let segmentID: UUID
        let isPrimaryRecording: Bool
        let mediaFileName: String?
        let editorRange: CMTimeRange
        let sourceRange: CMTimeRange
        /// False when this span is an explicit empty range where the video
        /// track had no frames (e.g., audio-only tail of a shorter picture track).
        var hasVideo: Bool = true

        /// Maps a composition timestamp (clamped to `editorRange`) to the
        /// corresponding timestamp inside the inserted `sourceRange`.
        func sourceTime(at editorTime: CMTime) -> TimeInterval {
            let editorDuration = editorRange.duration.seconds
            let sourceStart = sourceRange.start.seconds
            let sourceDuration = sourceRange.duration.seconds
            guard editorDuration > 0, sourceDuration >= 0 else { return sourceStart }
            let offset = min(max((editorTime - editorRange.start).seconds, 0), editorDuration)
            return sourceStart + (offset / editorDuration) * sourceDuration
        }

        /// Actual source-time interval represented by a frame starting at
        /// `editorTime` with duration `frameDuration` (clamped inside
        /// `editorRange`), including scaled/intersected track segments.
        func sourceInterval(
            at editorTime: CMTime,
            frameDuration: TimeInterval
        ) -> (start: TimeInterval, end: TimeInterval) {
            let clampedFrame = max(0, frameDuration.isFinite ? frameDuration : 0)
            let start = sourceTime(at: editorTime)
            let endEditor = editorTime + CMTime(seconds: clampedFrame, preferredTimescale: 600)
            let end = sourceTime(at: endEditor)
            if end > start {
                return (start, end)
            }
            // Held terminal frame right at `editorRange.end`: cover the final
            // frame's source span so a mask reaching `sourceRange.end` covers it.
            let editorDuration = editorRange.duration.seconds
            let sourceDuration = sourceRange.duration.seconds
            guard editorDuration > 0, sourceDuration > 0, clampedFrame > 0 else {
                return (start, start)
            }
            let stepSource = (clampedFrame / editorDuration) * sourceDuration
            let backStart = max(sourceRange.start.seconds, start - stepSource)
            return (min(backStart, start), start)
        }
    }

    let entries: [Entry]

    var duration: CMTime {
        entries.last?.editorRange.end ?? .zero
    }

    var timeRange: CMTimeRange {
        CMTimeRange(start: .zero, duration: duration)
    }

    /// Half-open entry lookup `[editorRange.start, editorRange.end)`, matching
    /// exact CMTime boundaries on the composition's 600ths timescale.
    func entry(at time: CMTime) -> Entry? {
        guard !entries.isEmpty else { return nil }
        for (index, entry) in entries.enumerated() {
            if CMTimeCompare(time, entry.editorRange.end) < 0 || index == entries.count - 1 {
                return entry
            }
        }
        return entries.last
    }

    func entry(at seconds: TimeInterval) -> Entry? {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        return entry(at: CMTime(seconds: safe, preferredTimescale: 600))
    }

    /// Active primary redactions at `editorTime` on the composition clock.
    /// If `editorTime` lands in a trailing empty span of a primary segment
    /// whose video ended early, also checks the preceding video span's terminal
    /// source interval so a held last frame stays masked.
    func activeRedactions(
        _ redactions: [RecordingRedaction],
        at editorTime: CMTime,
        frameDuration: TimeInterval
    ) -> [RecordingRedaction] {
        guard !redactions.isEmpty, let entry = entry(at: editorTime), entry.isPrimaryRecording else {
            return []
        }
        if entry.hasVideo {
            let interval = entry.sourceInterval(at: editorTime, frameDuration: frameDuration)
            return redactions.filter { $0.covers(sourceStart: interval.start, sourceEnd: interval.end) }
        }
        // Empty primary span: check both the span's own source interval and any
        // held terminal frame from an earlier video span of the same segment.
        let emptyInterval = entry.sourceInterval(at: editorTime, frameDuration: frameDuration)
        let heldInterval: (start: TimeInterval, end: TimeInterval)? = entries
            .last { $0.segmentID == entry.segmentID && $0.hasVideo && CMTimeCompare($0.editorRange.end, entry.editorRange.start) <= 0 }
            .map { $0.sourceInterval(at: $0.editorRange.end, frameDuration: frameDuration) }
        return redactions.filter { region in
            if region.covers(sourceStart: emptyInterval.start, sourceEnd: emptyInterval.end) {
                return true
            }
            if let heldInterval, region.covers(sourceStart: heldInterval.start, sourceEnd: heldInterval.end) {
                return true
            }
            return false
        }
    }
}

/// Custom video composition instruction carrying one segment's source track,
/// exact edit-to-media time mapping, orientation/aspect transform, and editable
/// primary redaction provider.
nonisolated final class StudioMultiSourceRedactionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let entry: StudioCompositionTimeMap.Entry
    let frameDuration: TimeInterval
    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
    let redactionSource: RecordingRedactionPreviewSource
    let renderSize: CGSize

    var isPrimaryRecording: Bool { entry.isPrimaryRecording }

    init(
        entry: StudioCompositionTimeMap.Entry,
        frameDuration: TimeInterval,
        trackID: CMPersistentTrackID,
        transform: CGAffineTransform,
        redactionSource: RecordingRedactionPreviewSource,
        renderSize: CGSize
    ) {
        self.timeRange = entry.editorRange
        self.entry = entry
        self.frameDuration = frameDuration
        self.requiredSourceTrackIDs = trackID == kCMPersistentTrackID_Invalid ? [] : [NSNumber(value: trackID)]
        self.trackID = trackID
        self.transform = transform
        self.redactionSource = redactionSource
        self.renderSize = renderSize
        super.init()
    }
}

/// Live-playback compositor used only when a multi-source timeline also has
/// active redactions. Transforms each segment into `renderSize` and applies
/// `RecordingRedactionFilter.apply` fail-closed to primary segments using the
/// instruction's own exact source-time mapping.
nonisolated final class StudioMultiSourceRedactionCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? StudioMultiSourceRedactionInstruction,
              let outputBuffer = request.renderContext.newPixelBuffer() else {
            request.finish(with: RecordingRedactionError.filterFailed)
            return
        }
        let renderExtent = CGRect(origin: .zero, size: instruction.renderSize)
        let black = CIImage(color: .black).cropped(to: renderExtent)
        if instruction.trackID == kCMPersistentTrackID_Invalid || !instruction.entry.hasVideo {
            ciContext.render(black, to: outputBuffer, bounds: renderExtent, colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: outputBuffer)
            return
        }
        guard let sourceBuffer = request.sourceFrame(byTrackID: instruction.trackID) else {
            request.finish(with: RecordingRedactionError.filterFailed)
            return
        }
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(sourceBuffer))
        let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceHeight)
        let flipDest = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: instruction.renderSize.height)
        let ciTransform = flipSource.concatenating(instruction.transform).concatenating(flipDest)

        let sourceImage = CIImage(cvPixelBuffer: sourceBuffer).transformed(by: ciTransform)
        var composed = sourceImage.composited(over: black).cropped(to: renderExtent)

        if instruction.entry.isPrimaryRecording {
            let interval = instruction.entry.sourceInterval(
                at: request.compositionTime,
                frameDuration: instruction.frameDuration
            )
            let active = instruction.redactionSource.currentRedactions().filter {
                $0.covers(sourceStart: interval.start, sourceEnd: interval.end)
            }
            if !active.isEmpty {
                do {
                    composed = try RecordingRedactionFilter.apply(active, to: composed)
                } catch {
                    request.finish(with: error)
                    return
                }
            }
        }
        ciContext.render(composed, to: outputBuffer, bounds: renderExtent, colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: outputBuffer)
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
