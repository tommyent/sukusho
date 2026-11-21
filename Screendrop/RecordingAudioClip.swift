//
//  RecordingAudioClip.swift
//  Screendrop
//
//  Sound placed under a Studio recording: music, effects, a voiceover, or
//  a clip's own sound detached from its picture. Clips sit on audio lanes
//  on the finished video's clock.
//
//  How a clip answers a cut of the video is its own choice. A linked clip
//  belongs to the picture above it: cutting, trimming or speeding up the
//  video does the same to the sound under it. An unlinked clip (music)
//  stays in one piece and only keeps its starting moment, so removing
//  video ahead of it moves it earlier. `StudioAudioConform` applies both.
//
//  Playback and export build their sound through `StudioAudioComposer`,
//  so what plays is what exports.
//

import AVFoundation
import Foundation
import UniformTypeIdentifiers

nonisolated struct RecordingAudioClip: Identifiable, Codable, Equatable, Hashable, Sendable {
    /// Where a clip's sound comes from.
    enum Source: String, Codable, Sendable {
        /// A file copied into the project's media folder.
        case file
        /// The recording's own audio, detached from its picture.
        case recording
        /// The soundtrack that stands in for the recording's audio.
        case replacement
    }

    static let minimumDuration: TimeInterval = 0.1
    /// Single shared minimum playable duration/span across segment playback,
    /// Detach Audio, conform, sanitization, and lane composition.
    static let minimumPlayableDuration: TimeInterval = 0.006
    /// Shortest source file span that inserts cleanly into the composer.
    static let minimumFileSpan: TimeInterval = 0.006
    static let fadeRange: ClosedRange<TimeInterval> = 0...5
    /// User-chosen volume slider range (0%...200%).
    static let volumeRange: ClosedRange<Double> = 0...2
    /// Effective gain range matching a segment's volume (up to 200%) times
    /// project volume (up to 200%), so Detach Audio preserves level verbatim.
    static let derivedVolumeRange: ClosedRange<Double> = 0...4
    /// User-chosen speed range for unlinked clips.
    static let speedRange: ClosedRange<Double> = 0.25...8
    /// Playable speed range including derived rates when linked clips follow sped-up video.
    static let derivedSpeedRange: ClosedRange<Double> = 0.03...64
    /// Speeds offered for an unlinked clip; a linked one follows the video.
    static let speedPresets: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var id = UUID()
    var source: Source = .file
    /// The copy inside the project's media folder; empty for sound taken
    /// from the recording.
    var fileName: String
    var displayName: String
    /// Where it starts in the edited video.
    var start: TimeInterval
    /// The stretch of the file that plays.
    var trimStart: TimeInterval = 0
    var trimEnd: TimeInterval
    /// The file's own length, the most a trim can open up to.
    var fileDuration: TimeInterval
    /// 0...2; above 1 amplifies.
    var volume: Double = 1
    var fadeIn: TimeInterval = 0
    var fadeOut: TimeInterval = 0
    /// File seconds played per second of video. Follows the speed of the
    /// video above a linked clip.
    var speed: Double = 1
    /// The audio lane it sits on, 0 at the top.
    var lane = 0
    /// Cut, trimmed and retimed with the video above it.
    var isLinked = false
    var isMuted = false
    /// Shared identity of the original clip when split by video conform, so
    /// edge healing and hidden-range restoration never double-restore the same
    /// interval across split pieces.
    var originID: UUID? = nil

    /// Stable clip-lineage identifier shared by pieces conformed from one clip.
    var lineageID: UUID { originID ?? id }

    /// How much of the file plays.
    var fileSpan: TimeInterval { max(0, trimEnd - trimStart) }
    /// How long it lasts in the video.
    var duration: TimeInterval { fileSpan / max(speed, 0.01) }
    var end: TimeInterval { start + duration }
    var audibleVolume: Double {
        isMuted ? 0 : min(max(volume, Self.derivedVolumeRange.lowerBound), Self.derivedVolumeRange.upperBound)
    }

    init(fileName: String, displayName: String, start: TimeInterval, fileDuration: TimeInterval) {
        self.fileName = fileName
        self.displayName = displayName
        self.start = start
        self.fileDuration = fileDuration
        trimEnd = fileDuration
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, fileName, displayName, start, trimStart, trimEnd, fileDuration
        case volume, fadeIn, fadeOut, speed, lane, isLinked, isMuted, originID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .file
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? fileName
        start = try container.decode(TimeInterval.self, forKey: .start)
        trimStart = try container.decodeIfPresent(TimeInterval.self, forKey: .trimStart) ?? 0
        trimEnd = try container.decode(TimeInterval.self, forKey: .trimEnd)
        fileDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .fileDuration) ?? trimEnd
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        fadeIn = try container.decodeIfPresent(TimeInterval.self, forKey: .fadeIn) ?? 0
        fadeOut = try container.decodeIfPresent(TimeInterval.self, forKey: .fadeOut) ?? 0
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        lane = try container.decodeIfPresent(Int.self, forKey: .lane) ?? 0
        isLinked = try container.decodeIfPresent(Bool.self, forKey: .isLinked) ?? false
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        originID = try container.decodeIfPresent(UUID.self, forKey: .originID)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if source != .file { try container.encode(source, forKey: .source) }
        try container.encode(fileName, forKey: .fileName)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(start, forKey: .start)
        try container.encode(trimStart, forKey: .trimStart)
        try container.encode(trimEnd, forKey: .trimEnd)
        try container.encode(fileDuration, forKey: .fileDuration)
        try container.encode(volume, forKey: .volume)
        try container.encode(fadeIn, forKey: .fadeIn)
        try container.encode(fadeOut, forKey: .fadeOut)
        if speed != 1 { try container.encode(speed, forKey: .speed) }
        if lane != 0 { try container.encode(lane, forKey: .lane) }
        if isLinked { try container.encode(isLinked, forKey: .isLinked) }
        if isMuted { try container.encode(isMuted, forKey: .isMuted) }
        if let originID { try container.encode(originID, forKey: .originID) }
    }

    /// Kept inside its file, its ranges and the video without clamping valid
    /// derived rates or short playable splits/conformed spans.
    func sanitized() -> RecordingAudioClip {
        var clip = self
        clip.speed = min(max(clip.speed.isFinite ? clip.speed : 1, Self.derivedSpeedRange.lowerBound), Self.derivedSpeedRange.upperBound)
        let minFileSpan = max(Self.minimumFileSpan, Self.minimumPlayableDuration * clip.speed)
        clip.fileDuration = clip.fileDuration.isFinite ? max(Self.minimumFileSpan, clip.fileDuration) : Self.minimumDuration
        let rawTrimStart = clip.trimStart.isFinite ? clip.trimStart : 0
        let rawTrimEnd = clip.trimEnd.isFinite ? clip.trimEnd : clip.fileDuration
        let boundedMinSpan = min(minFileSpan, clip.fileDuration)
        clip.trimStart = min(max(0, rawTrimStart), max(0, clip.fileDuration - boundedMinSpan))
        clip.trimEnd = min(max(rawTrimEnd, clip.trimStart + boundedMinSpan), max(clip.fileDuration, clip.trimStart + boundedMinSpan))
        clip.start = clip.start.isFinite ? max(0, clip.start) : 0
        clip.volume = min(max(clip.volume.isFinite ? clip.volume : 1, Self.derivedVolumeRange.lowerBound), Self.derivedVolumeRange.upperBound)
        clip.fadeIn = min(max(clip.fadeIn.isFinite ? clip.fadeIn : 0, Self.fadeRange.lowerBound), Self.fadeRange.upperBound)
        clip.fadeOut = min(max(clip.fadeOut.isFinite ? clip.fadeOut : 0, Self.fadeRange.lowerBound), Self.fadeRange.upperBound)
        clip.lane = max(0, clip.lane)
        return clip
    }

    /// Rejects path traversal when resolving `.file` clips against the media directory.
    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name == URL(fileURLWithPath: name).lastPathComponent
            && !name.contains("/")
            && ![".", ".."].contains(name)
    }

    static func canImport(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio)
    }
}

/// A bounded loudness outline of an audio file for the timeline.
nonisolated struct RecordingAudioWaveform: Equatable, Sendable {
    var samples: [Float]
    var peaksPerSecond: Double

    static let empty = RecordingAudioWaveform(
        samples: [],
        peaksPerSecond: Double(RecordingAudioPeaks.peaksPerSecond)
    )

    var isEmpty: Bool { samples.isEmpty }
}

/// A coarse loudness outline of an audio file for the timeline.
nonisolated enum RecordingAudioPeaks {
    /// Enough for a bar every few points at the timeline's closest zoom.
    static let peaksPerSecond = 100
    /// Upper bound on retained peak samples per audio source (~48 KB max even
    /// for multi-hour recordings).
    static let maximumPeaks = 12_000

    /// Compacts `peaks` in place by pairwise maxima whenever it reaches or
    /// exceeds `maxCount`, halving `peaksPerSecond` on each pass. Using an even
    /// threshold avoids leaving an odd half-bucket during streaming.
    static func compactInPlace(
        _ peaks: inout [Float],
        peaksPerSecond: inout Double,
        maxCount: Int = maximumPeaks
    ) {
        let cap = max(2, maxCount)
        while peaks.count > cap {
            compactOnce(&peaks, peaksPerSecond: &peaksPerSecond)
        }
    }

    private static func compactOnce(_ peaks: inout [Float], peaksPerSecond: inout Double) {
        let pairs = peaks.count / 2
        for i in 0..<pairs {
            peaks[i] = max(peaks[i * 2], peaks[i * 2 + 1])
        }
        if peaks.count.isMultiple(of: 2) {
            peaks.removeLast(peaks.count - pairs)
        } else {
            peaks[pairs] = peaks[peaks.count - 1]
            peaks.removeLast(peaks.count - (pairs + 1))
        }
        peaksPerSecond /= 2
    }

    /// Computes the aligned start and end X coordinates of waveform bars that
    /// intersect `visibleXRange`, so zoomed multi-hour clips only draw bars
    /// inside the viewport.
    static func visibleBarBounds(
        width: CGFloat,
        visibleXRange: ClosedRange<CGFloat>?,
        bar: CGFloat = 2,
        gap: CGFloat = 2
    ) -> (start: CGFloat, end: CGFloat) {
        let maxEnd = width - bar
        guard maxEnd > gap else { return (gap, gap) }
        guard let visibleXRange else { return (gap, maxEnd) }
        let stride = bar + gap
        let low = max(gap, visibleXRange.lowerBound - bar)
        let firstIndex = max(0, floor((low - gap) / stride))
        let start = gap + firstIndex * stride
        let end = min(maxEnd, visibleXRange.upperBound)
        return (start, max(start, end))
    }

    /// Normalized 0...1 peaks, bounded to `maximumPeaks` samples.
    static func load(url: URL) async -> [Float] {
        await loadWaveform(url: url).samples
    }

    /// Streams audio into a bounded, in-place normalized waveform outline.
    static func loadWaveform(url: URL) async -> RecordingAudioWaveform {
        let asset = AVURLAsset(url: url)
        // Every track, mixed: a recording's system audio and microphone are
        // separate tracks, and either may be the silent one.
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let reader = try? AVAssetReader(asset: asset) else { return .empty }
        let sampleRate = 8_000
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        guard reader.startReading() else { return .empty }

        var effectivePeaksPerSecond = Double(peaksPerSecond)
        var samplesPerPeak = max(1, sampleRate / peaksPerSecond)
        var peaks: [Float] = []
        var current: Int16 = 0
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return .empty }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                for index in 0..<(length / 2) {
                    let magnitude = samples[index] == .min ? Int16.max : abs(samples[index])
                    current = max(current, magnitude)
                    count += 1
                    if count == samplesPerPeak {
                        peaks.append(Float(current) / Float(Int16.max))
                        current = 0
                        count = 0
                        if peaks.count == maximumPeaks {
                            compactOnce(&peaks, peaksPerSecond: &effectivePeaksPerSecond)
                            samplesPerPeak *= 2
                        }
                    }
                }
            }
        }
        if count > 0 {
            peaks.append(Float(current) / Float(Int16.max))
            if peaks.count > maximumPeaks {
                compactInPlace(&peaks, peaksPerSecond: &effectivePeaksPerSecond, maxCount: maximumPeaks)
            }
        }
        // Quiet tracks still read: normalize in place without allocating a second array.
        if let loudest = peaks.max(), loudest > 0.01 {
            let scale = 1 / loudest
            for index in peaks.indices {
                peaks[index] = min(1, peaks[index] * scale)
            }
        }
        return RecordingAudioWaveform(samples: peaks, peaksPerSecond: effectivePeaksPerSecond)
    }
}
