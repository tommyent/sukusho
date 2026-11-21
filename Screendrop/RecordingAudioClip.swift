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
    /// Shortest derived or conformed clip that plays in the composer.
    static let minimumPlayableDuration: TimeInterval = 0.01
    /// Shortest source file span that inserts cleanly into the composer (> 5 ms).
    static let minimumFileSpan: TimeInterval = 0.006
    static let fadeRange: ClosedRange<TimeInterval> = 0...5
    static let volumeRange: ClosedRange<Double> = 0...2
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

    /// How much of the file plays.
    var fileSpan: TimeInterval { max(0, trimEnd - trimStart) }
    /// How long it lasts in the video.
    var duration: TimeInterval { fileSpan / max(speed, 0.01) }
    var end: TimeInterval { start + duration }
    var audibleVolume: Double {
        isMuted ? 0 : min(max(volume, Self.volumeRange.lowerBound), Self.volumeRange.upperBound)
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
        case volume, fadeIn, fadeOut, speed, lane, isLinked, isMuted
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
        clip.volume = min(max(clip.volume.isFinite ? clip.volume : 1, Self.volumeRange.lowerBound), Self.volumeRange.upperBound)
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

/// A coarse loudness outline of an audio file for the timeline.
nonisolated enum RecordingAudioPeaks {
    /// Enough for a bar every few points at the timeline's closest zoom.
    static let peaksPerSecond = 100

    /// Normalized 0...1 peaks, `peaksPerSecond` per second of audio.
    static func load(url: URL) async -> [Float] {
        let asset = AVURLAsset(url: url)
        // Every track, mixed: a recording's system audio and microphone are
        // separate tracks, and either may be the silent one.
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
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
        guard reader.startReading() else { return [] }

        let samplesPerPeak = sampleRate / peaksPerSecond
        var peaks: [Float] = []
        var current: Int16 = 0
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return [] }
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
                    }
                }
            }
        }
        if count > 0 { peaks.append(Float(current) / Float(Int16.max)) }
        // Quiet tracks still read: scale so the loudest peak fills the lane.
        if let loudest = peaks.max(), loudest > 0.01 {
            peaks = peaks.map { min(1, $0 / loudest) }
        }
        return peaks
    }
}
