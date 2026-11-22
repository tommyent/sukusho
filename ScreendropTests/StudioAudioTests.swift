import AVFoundation
import Foundation
import Testing

struct StudioAudioTests {
    // MARK: - Conform across cuts and trims

    @Test func conformSplitsLinkedClipAcrossDeletedMiddleAndPreservesOuterFades() {
        let old = RecordingClipTimeline.full(sourceDuration: 10)
        // Cut out 3...6 from the video.
        let new = RecordingClipTimeline(segments: [
            RecordingClipSegment(id: old.segments[0].id, sourceStart: 0, sourceEnd: 3),
            RecordingClipSegment(sourceStart: 6, sourceEnd: 10)
        ])
        var linked = RecordingAudioClip(fileName: "voice.wav", displayName: "Voice", start: 1, fileDuration: 8)
        linked.trimStart = 0
        linked.trimEnd = 8
        linked.fadeIn = 0.5
        linked.fadeOut = 0.5
        linked.isLinked = true

        let conformed = StudioAudioConform.conform([linked], from: old, to: new)
        #expect(conformed.count == 2)
        // First piece covers video 1...3 -> editor 1...3, file 0...2; keeps original fadeIn, drops inner fadeOut.
        #expect(abs(conformed[0].start - 1) < 0.001)
        #expect(abs(conformed[0].trimStart - 0) < 0.001)
        #expect(abs(conformed[0].trimEnd - 2) < 0.001)
        #expect(abs(conformed[0].fadeIn - 0.5) < 0.001)
        #expect(conformed[0].fadeOut == 0)
        // Second piece covers video 6...9 -> editor 3...6, file 5...8; drops inner fadeIn, keeps original fadeOut.
        #expect(abs(conformed[1].start - 3) < 0.001)
        #expect(abs(conformed[1].trimStart - 5) < 0.001)
        #expect(abs(conformed[1].trimEnd - 8) < 0.001)
        #expect(conformed[1].fadeIn == 0)
        #expect(abs(conformed[1].fadeOut - 0.5) < 0.001)
        #expect(conformed[0].id != conformed[1].id)
    }

    @Test func conformJoinsSeamlessSplitAndRetimesSpeedChange() {
        let segID = UUID()
        let old = RecordingClipTimeline(segments: [
            RecordingClipSegment(id: segID, sourceStart: 0, sourceEnd: 10)
        ])
        // Split video at 5 without removing anything.
        let split = RecordingClipTimeline(segments: [
            RecordingClipSegment(id: segID, sourceStart: 0, sourceEnd: 5),
            RecordingClipSegment(sourceStart: 5, sourceEnd: 10)
        ])
        var linked = RecordingAudioClip(fileName: "narration.wav", displayName: "Narration", start: 2, fileDuration: 6)
        linked.isLinked = true
        let afterSplit = StudioAudioConform.conform([linked], from: old, to: split)
        #expect(afterSplit.count == 1)
        #expect(abs(afterSplit[0].start - 2) < 0.001)
        #expect(abs(afterSplit[0].duration - 6) < 0.001)

        // Speed up the second segment to 2x.
        let sped = RecordingClipTimeline(segments: [
            RecordingClipSegment(id: segID, sourceStart: 0, sourceEnd: 5, speed: 1),
            RecordingClipSegment(id: split.segments[1].id, sourceStart: 5, sourceEnd: 10, speed: 2)
        ])
        let afterSpeed = StudioAudioConform.conform(afterSplit, from: split, to: sped)
        #expect(afterSpeed.count == 2)
        #expect(abs(afterSpeed[0].speed - 1) < 0.001)
        #expect(abs(afterSpeed[0].duration - 3) < 0.001)
        #expect(abs(afterSpeed[1].start - 5) < 0.001)
        #expect(abs(afterSpeed[1].speed - 2) < 0.001)
        #expect(abs(afterSpeed[1].duration - 1.5) < 0.001)
    }

    @Test func conformUnlinkedClipStaysWholeAndFollowsAnchoredFootageMoment() {
        let old = RecordingClipTimeline.full(sourceDuration: 10)
        let new = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 3, sourceEnd: 10)
        ])
        var music = RecordingAudioClip(fileName: "bed.wav", displayName: "Bed", start: 5, fileDuration: 4)
        music.isLinked = false
        let conformed = StudioAudioConform.conform([music], from: old, to: new)
        #expect(conformed.count == 1)
        // Video moment 5 moved to editor 2; clip stays whole at 4 seconds.
        #expect(abs(conformed[0].start - 2) < 0.001)
        #expect(abs(conformed[0].duration - 4) < 0.001)
    }

    @Test func conformHealsLinkedClipWhenVideoTrimReopens() {
        let segID = UUID()
        let trimmed = RecordingClipTimeline(segments: [
            RecordingClipSegment(id: segID, sourceStart: 2, sourceEnd: 7)
        ])
        let reopened = RecordingClipTimeline(segments: [
            RecordingClipSegment(id: segID, sourceStart: 1, sourceEnd: 9)
        ])
        var detached = RecordingAudioClip(fileName: "", displayName: "Detached", start: 0, fileDuration: 10)
        detached.source = .recording
        detached.trimStart = 2
        detached.trimEnd = 7
        detached.isLinked = true

        let healed = StudioAudioConform.conform([detached], from: trimmed, to: reopened)
        #expect(healed.count == 1)
        #expect(abs(healed[0].start - 0) < 0.001)
        #expect(abs(healed[0].trimStart - 1) < 0.001)
        #expect(abs(healed[0].trimEnd - 9) < 0.001)
    }

    @Test func conformFollowsClipReordering() {
        let aID = UUID()
        let bID = UUID()
        let old = RecordingClipTimeline(segments: [
            RecordingClipSegment(id: aID, sourceStart: 0, sourceEnd: 4),
            RecordingClipSegment(id: bID, sourceStart: 4, sourceEnd: 10)
        ])
        let reordered = RecordingClipTimeline(segments: [
            RecordingClipSegment(id: bID, sourceStart: 4, sourceEnd: 10),
            RecordingClipSegment(id: aID, sourceStart: 0, sourceEnd: 4)
        ])
        var linked = RecordingAudioClip(fileName: "a.wav", displayName: "A", start: 1, fileDuration: 2)
        linked.isLinked = true
        let moved = StudioAudioConform.conform([linked], from: old, to: reordered)
        #expect(moved.count == 1)
        // Segment A moved to editor 6...10, so offset 1 inside A lands at 7.
        #expect(abs(moved[0].start - 7) < 0.001)
        #expect(abs(moved[0].duration - 2) < 0.001)
    }

    // MARK: - Lane overlap resolution

    @Test func laneResolutionSeparatesOverlapsRespectsPriorityCompactsAndCapsAtEight() {
        var a = RecordingAudioClip(fileName: "a.wav", displayName: "A", start: 0, fileDuration: 3)
        a.lane = 0
        var b = RecordingAudioClip(fileName: "b.wav", displayName: "B", start: 1, fileDuration: 3)
        b.lane = 0
        var c = RecordingAudioClip(fileName: "c.wav", displayName: "C", start: 4, fileDuration: 2)
        c.lane = 3 // gap lane should compact down

        let resolved = StudioAudioConform.resolvingLanes([a, b, c])
        let laneByID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0.lane) })
        #expect(laneByID[a.id] == 0)
        #expect(laneByID[b.id] == 1)
        #expect(laneByID[c.id] == 2)

        // Priority: `first: b.id` gives `b` lane 0 and pushes `a` to lane 1.
        let prioritized = StudioAudioConform.resolvingLanes([a, b], first: b.id)
        let prioritizedByID = Dictionary(uniqueKeysWithValues: prioritized.map { ($0.id, $0.lane) })
        #expect(prioritizedByID[b.id] == 0)
        #expect(prioritizedByID[a.id] == 1)

        // 10 overlapping clips cap at `StudioAudioConform.maximumLanes` (lanes 0...7).
        let ten = (0..<10).map { index -> RecordingAudioClip in
            var clip = RecordingAudioClip(fileName: "\(index).wav", displayName: "\(index)", start: 0, fileDuration: 2)
            clip.lane = 0
            return clip
        }
        let capped = StudioAudioConform.resolvingLanes(ten)
        #expect(capped.map(\.lane).max() == StudioAudioConform.maximumLanes - 1)
        #expect(Set(capped.map(\.lane)).count == StudioAudioConform.maximumLanes)
    }

    // MARK: - Soundtrack sync

    @Test func audioSyncPiecesHonorOffsetAndFileDuration() {
        let timeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 4, speed: 1),
            RecordingClipSegment(sourceStart: 6, sourceEnd: 10, speed: 2)
        ])
        var sync = RecordingAudioSync.flat(over: timeline)
        #expect(abs(sync.coveredFileDuration - 6) < 0.0001)

        // Positive offset delays playback by 0.25s, clipping the head of the first span.
        sync.offset = 0.25
        let pieces = sync.pieces(from: 0, to: 4, fileDuration: 6)
        #expect(pieces.count == 1)
        #expect(abs(pieces[0].sourceStart - 0.25) < 0.001)
        #expect(abs(pieces[0].sourceEnd - 4) < 0.001)
        #expect(abs(pieces[0].fileStart - 0) < 0.001)
        #expect(abs(pieces[0].fileEnd - 3.75) < 0.001)
    }

    // MARK: - Envelope ramps at cuts

    @Test func envelopeSpansAddCutRampOnlyAtRealCutsAndRespectFades() {
        let seg1 = RecordingClipSegment(sourceStart: 0, sourceEnd: 2)
        let seg2 = RecordingClipSegment(sourceStart: 4, sourceEnd: 6) // real cut (2...4 removed)
        let seg3 = RecordingClipSegment(sourceStart: 6, sourceEnd: 8) // continuous split at 6
        let timeline = RecordingClipTimeline(segments: [seg1, seg2, seg3])
        let plan = StudioAudioPlan(timeline: timeline, sync: nil, clips: [], volume: 1)
        let layout = StudioAudioLayout(placements: [
            .init(trackID: 1, start: 0, end: 2, owner: .segment(seg1.id), mediaStart: 0, mediaEnd: 2),
            .init(trackID: 1, start: 2, end: 4, owner: .segment(seg2.id), mediaStart: 4, mediaEnd: 6),
            .init(trackID: 1, start: 4, end: 6, owner: .segment(seg3.id), mediaStart: 6, mediaEnd: 8)
        ])

        let spans = StudioAudioComposer.envelopeSpans(for: layout, plan: plan)[1] ?? []
        #expect(!spans.isEmpty)
        // Video start (t = 0) stays at unity (no fade-in ramp).
        #expect(abs(RecordingAudioGain.envelopeGain(at: 0, in: spans) - 1) < 0.001)
        // Real cut at t = 2 ramps down over 4 ms before and up over 4 ms after.
        #expect(abs(RecordingAudioGain.envelopeGain(at: 1.998, in: spans) - 0.5) < 0.05)
        #expect(RecordingAudioGain.envelopeGain(at: 2.0, in: spans) < 0.01)
        #expect(abs(RecordingAudioGain.envelopeGain(at: 2.002, in: spans) - 0.5) < 0.05)
        #expect(abs(RecordingAudioGain.envelopeGain(at: 2.01, in: spans) - 1) < 0.001)
        // Continuous split at t = 4 keeps unity right across the boundary.
        #expect(abs(RecordingAudioGain.envelopeGain(at: 3.998, in: spans) - 1) < 0.001)
        #expect(abs(RecordingAudioGain.envelopeGain(at: 4.0, in: spans) - 1) < 0.001)
        #expect(abs(RecordingAudioGain.envelopeGain(at: 4.002, in: spans) - 1) < 0.001)
        // Video end (t = 6) stays at unity (no fade-out ramp).
        #expect(abs(RecordingAudioGain.envelopeGain(at: 5.999, in: spans) - 1) < 0.001)
    }

    @Test func envelopeTapRendersSampleAccurateCutRampAndAmplification() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let toneURL = try makeTone(in: dir, name: "tone", frequency: 440, amplitude: 0.4, duration: 4)
        let asset = AVURLAsset(url: toneURL)
        let sources = try await StudioAudioSources.load(
            screenAsset: asset,
            replacementURL: nil,
            clips: [],
            mediaDirectory: nil
        )
        // Cut out 1...2 so there is a real cut at editor t = 1, and boost volume to 1.5x.
        let timeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 1),
            RecordingClipSegment(sourceStart: 2, sourceEnd: 3)
        ])
        let plan = StudioAudioPlan(timeline: timeline, sync: nil, clips: [], volume: 1.5)
        let (composition, layout) = StudioAudioComposer.makeComposition(plan: plan, sources: sources)
        let mix = try #require(StudioAudioComposer.mix(for: layout, plan: plan))
        let samples = try await renderMonoSamples(asset: composition, mix: mix, duration: timeline.duration)
        let sampleRate = 48_000.0

        // Mid-clip (0.5s) is amplified to ~0.6 peak (0.4 * 1.5).
        let midPeak = peakAmplitude(in: samples, from: 0.45, to: 0.55, sampleRate: sampleRate)
        #expect(midPeak > 0.52 && midPeak < 0.68)

        // Exact cut boundary (1.0s ± 0.5ms) is ramped near zero to eliminate clicks.
        let cutPeak = peakAmplitude(in: samples, from: 0.9995, to: 1.0005, sampleRate: sampleRate)
        #expect(cutPeak < 0.12)
        withExtendedLifetime(sources) {}
    }

    // MARK: - Background music + voice isolation + audio clips in one mix

    @Test func backgroundMusicVoiceIsolationAndAudioClipsMixCleanlyTogether() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mediaDir = dir.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        // Recording has system audio (900 Hz) + raw mic (220 Hz, active 0.5...1.5 for speech ducking).
        let systemURL = try makeTone(in: dir, name: "system", frequency: 900, amplitude: 0.25, duration: 3)
        let rawMicURL = try makeTone(in: dir, name: "raw-mic", frequency: 220, amplitude: 0.25, duration: 3) { t in
            t >= 0.5 && t <= 1.5
        }
        let screenURL = dir.appendingPathComponent("screen.mov")
        let micTrackID = try await writeDualTrackAudioMovie(systemURL: systemURL, micURL: rawMicURL, to: screenURL)

        // Isolated mic replaces raw mic (220 Hz) with isolated voice (440 Hz).
        let isolatedURL = try makeTone(in: dir, name: "isolated", frequency: 440, amplitude: 0.25, duration: 3)
        // Background music (660 Hz) loops and ducks during mic speech (0.5...1.5).
        let musicURL = try makeTone(in: dir, name: "background-music.test", frequency: 660, amplitude: 0.25, duration: 3)
        // Extra audio clip on lane 0 (1200 Hz) enters at 0.2...2.2.
        let clipURL = try makeTone(in: mediaDir, name: "fx.wav", frequency: 1200, amplitude: 0.25, duration: 2)
        var clip = RecordingAudioClip(fileName: clipURL.lastPathComponent, displayName: "FX", start: 0.2, fileDuration: 2)
        clip.lane = 0

        let musicSettings = RecordingBackgroundMusic(
            fileName: musicURL.lastPathComponent,
            displayName: "Bed",
            volume: 0.4,
            loop: true,
            duck: true,
            duckAmount: .aLot
        )
        let timeline = RecordingClipTimeline.full(sourceDuration: 3)
        let screenAsset = AVURLAsset(url: screenURL)
        let prepared = try await StudioAudioComposer.prepareExport(
            screenAsset: screenAsset,
            screenURL: screenURL,
            timeline: timeline,
            replacementURL: nil,
            replacementSync: nil,
            clips: [clip],
            mediaDirectory: mediaDir,
            volume: 1,
            microphoneTrackID: micTrackID,
            isolatedMicrophoneURL: isolatedURL,
            backgroundMusic: .init(url: musicURL, settings: musicSettings)
        )
        let samples = try await renderMonoSamples(asset: prepared.composition, mix: prepared.mix, duration: timeline.duration)
        withExtendedLifetime(prepared) {}

        // At t = 1.0 (during speech): raw mic (220 Hz) is replaced by isolated mic (440 Hz),
        // system audio (900 Hz) and the audio clip (1200 Hz) are present, and music (660 Hz) is ducked.
        let rawMic = goertzel(samples, at: 0.9, length: 0.15, frequency: 220)
        let isolated = goertzel(samples, at: 0.9, length: 0.15, frequency: 440)
        let system = goertzel(samples, at: 0.9, length: 0.15, frequency: 900)
        let fxClip = goertzel(samples, at: 0.9, length: 0.15, frequency: 1200)
        let duckedMusic = goertzel(samples, at: 0.9, length: 0.15, frequency: 660)
        let quietMusic = goertzel(samples, at: 0.15, length: 0.15, frequency: 660)

        #expect(rawMic < 0.01)
        #expect(isolated > 0.08)
        #expect(system > 0.08)
        #expect(fxClip > 0.08)
        #expect(quietMusic > 0.04)
        #expect(duckedMusic < quietMusic * 0.4)
    }

    // MARK: - Audio-only export with clips

    @Test func audioOnlyExportIncludesAudioClipsAndRespectsFades() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mediaDir = dir.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let screenURL = try makeTone(in: dir, name: "recording", frequency: 220, amplitude: 0.25, duration: 3)
        let clipURL = try makeTone(in: mediaDir, name: "sting.wav", frequency: 880, amplitude: 0.3, duration: 1.5)
        var clip = RecordingAudioClip(fileName: clipURL.lastPathComponent, displayName: "Sting", start: 1.0, fileDuration: 1.5)
        clip.fadeIn = 0.4
        clip.fadeOut = 0.4

        let exportedURL = try await RecordingAudioExporter().export(
            RecordingAudioExporter.Configuration(
                screenURL: screenURL,
                clipTimeline: .full(sourceDuration: 3),
                replacementURL: nil,
                format: .wav,
                volume: 1,
                audioClips: [clip],
                mediaDirectory: mediaDir
            ),
            progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: exportedURL) }

        let exportedAsset = AVURLAsset(url: exportedURL)
        let exportedDuration = try await exportedAsset.load(.duration).seconds
        #expect(abs(exportedDuration - 3) < 0.05)

        let samples = try await renderMonoSamples(asset: exportedAsset, mix: nil, duration: 3)
        let beforeClip = goertzel(samples, at: 0.3, length: 0.15, frequency: 880)
        let midClip = goertzel(samples, at: 1.7, length: 0.15, frequency: 880)
        let fadeInClip = goertzel(samples, at: 1.02, length: 0.08, frequency: 880)
        let baseTone = goertzel(samples, at: 1.7, length: 0.15, frequency: 220)

        #expect(beforeClip < 0.005)
        #expect(midClip > 0.1)
        #expect(fadeInClip < midClip * 0.4)
        #expect(baseTone > 0.1)
    }

    @Test func clipSanitizationCodableSafetyAndPeaks() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        var dirty = RecordingAudioClip(fileName: "song.wav", displayName: "Song", start: -5, fileDuration: 4)
        dirty.trimStart = -2
        dirty.trimEnd = 99
        dirty.volume = .nan
        dirty.fadeIn = -1
        dirty.fadeOut = 20
        dirty.speed = .infinity
        dirty.lane = -3
        let clean = dirty.sanitized()
        #expect(clean.start == 0)
        #expect(clean.trimStart == 0)
        #expect(clean.trimEnd == 4)
        #expect(clean.volume == 1)
        #expect(clean.fadeIn == 0)
        #expect(clean.fadeOut == RecordingAudioClip.fadeRange.upperBound)
        #expect(clean.speed == 1)
        #expect(clean.lane == 0)

        let decoded = try JSONDecoder().decode(RecordingAudioClip.self, from: JSONEncoder().encode(clean))
        #expect(decoded == clean)

        #expect(RecordingAudioClip.isSafeFileName("abc-123.m4a"))
        for bad in ["", ".", "..", "../screen.mov", "/tmp/a.wav", "sub/a.wav"] {
            #expect(!RecordingAudioClip.isSafeFileName(bad))
        }

        // Split clears inner fades and preserves outer fades.
        var clip = RecordingAudioClip(fileName: "a.wav", displayName: "A", start: 1, fileDuration: 4)
        clip.fadeIn = 0.5
        clip.fadeOut = 0.5
        let halves = try #require(StudioAudioConform.split(clip, at: 3))
        #expect(abs(halves.leading.trimEnd - 2) < 0.001 && halves.leading.fadeIn == 0.5 && halves.leading.fadeOut == 0)
        #expect(abs(halves.trailing.start - 3) < 0.001 && abs(halves.trailing.trimStart - 2) < 0.001 && halves.trailing.fadeIn == 0 && halves.trailing.fadeOut == 0.5)
        #expect(StudioAudioConform.split(clip, at: 1.02) == nil)

        // Peaks extraction normalizes loudest peak to 1 and yields ~100 peaks/sec.
        let toneURL = try makeTone(in: dir, name: "peaks", frequency: 440, amplitude: 0.2, duration: 1)
        let peaks = await RecordingAudioPeaks.load(url: toneURL)
        #expect(peaks.count >= 90 && peaks.count <= 110)
        #expect((peaks.max() ?? 0) > 0.95)
    }

    @Test func mutedSegmentIsSilentRightUpToCutWhileNeighborPlays() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let toneURL = try makeTone(in: dir, name: "muted-cut", frequency: 440, amplitude: 0.4, duration: 4)
        let asset = AVURLAsset(url: toneURL)
        let sources = try await StudioAudioSources.load(
            screenAsset: asset,
            replacementURL: nil,
            clips: [],
            mediaDirectory: nil
        )
        let muted = RecordingClipSegment(sourceStart: 0, sourceEnd: 1.5, speed: 1, volume: 1, isMuted: true)
        let audible = RecordingClipSegment(sourceStart: 1.5, sourceEnd: 3.0, speed: 1, volume: 1, isMuted: false)
        let timeline = RecordingClipTimeline(segments: [muted, audible])
        let plan = StudioAudioPlan(timeline: timeline, sync: nil, clips: [], volume: 1)
        let (composition, layout) = StudioAudioComposer.makeComposition(plan: plan, sources: sources)
        let mix = try #require(StudioAudioComposer.mix(for: layout, plan: plan))
        let samples = try await renderMonoSamples(asset: composition, mix: mix, duration: timeline.duration)
        withExtendedLifetime(sources) {}

        // Muted segment must be strictly silent even 5ms before the boundary (no volume-ramp smear).
        #expect(peakAmplitude(in: samples, from: 0.2, to: 1.495, sampleRate: 48_000) < 0.001)
        // Audible neighbor plays at full amplitude right after the 4ms cut ramp.
        #expect(peakAmplitude(in: samples, from: 1.52, to: 2.5, sampleRate: 48_000) > 0.35)
    }

    @Test func unresolvedReplacementPreservesReferenceSyncAndError() {
        let sync = RecordingAudioSync(
            spans: [.init(sourceStart: 0, sourceEnd: 8, fileStart: 0, rate: 1)],
            offset: 0.15
        )
        let unresolved = StudioReplacementReference.resolve(
            fileName: "audio-replacement.123.wav",
            displayName: "Cleaned Voice.wav",
            sync: sync,
            loadedExists: false
        )
        #expect(unresolved.unresolvedReference == StudioReplacementReference(
            fileName: "audio-replacement.123.wav",
            displayName: "Cleaned Voice.wav"
        ))
        #expect(unresolved.sync == sync)
        #expect(unresolved.error?.contains("Cleaned Voice.wav") == true)

        let cleared = StudioReplacementReference.resolve(
            fileName: nil,
            displayName: nil,
            sync: sync,
            loadedExists: false
        )
        #expect(cleared.unresolvedReference == nil)
        #expect(cleared.sync == nil)
        #expect(cleared.error == nil)
    }

    @Test func missingAudibleImportedClipFailsExportWhileMutedMissingClipSucceeds() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioAudioMissingTest-\(UUID().uuidString)", isDirectory: true)
        let mediaDir = dir.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let screenURL = try makeTone(in: dir, name: "screen", frequency: 440, amplitude: 0.4, duration: 1.5)
        let musicURL = try makeTone(in: dir, name: "music", frequency: 660, amplitude: 0.3, duration: 1.5)

        let missingClip = RecordingAudioClip(
            fileName: "deleted-narration.wav",
            displayName: "Narration",
            start: 0.2,
            fileDuration: 1.0
        )
        let timeline = RecordingClipTimeline.full(sourceDuration: 1.5)
        let musicSettings = RecordingBackgroundMusic(
            fileName: musicURL.lastPathComponent,
            displayName: "Bed",
            volume: 0.5,
            loop: true,
            duck: false,
            duckAmount: .medium
        )

        var threwMissing = false
        do {
            _ = try await StudioAudioComposer.prepareExport(
                screenAsset: AVURLAsset(url: screenURL),
                screenURL: screenURL,
                timeline: timeline,
                replacementURL: nil,
                replacementSync: nil,
                clips: [missingClip],
                mediaDirectory: mediaDir,
                volume: 1,
                microphoneTrackID: nil,
                isolatedMicrophoneURL: nil,
                backgroundMusic: .init(url: musicURL, settings: musicSettings)
            )
        } catch StudioAudioComposer.AudioError.missingAudioClip(let name) {
            threwMissing = (name == "Narration")
        }
        #expect(threwMissing)

        // Muting the missing clip allows export to succeed cleanly.
        var mutedClip = missingClip
        mutedClip.isMuted = true
        let prepared = try await StudioAudioComposer.prepareExport(
            screenAsset: AVURLAsset(url: screenURL),
            screenURL: screenURL,
            timeline: timeline,
            replacementURL: nil,
            replacementSync: nil,
            clips: [mutedClip],
            mediaDirectory: mediaDir,
            volume: 1,
            microphoneTrackID: nil,
            isolatedMicrophoneURL: nil,
            backgroundMusic: .init(url: musicURL, settings: musicSettings)
        )
        #expect(!prepared.composition.tracks(withMediaType: .audio).isEmpty)
    }

    @Test func audioOnlyExportDefaultsToIncludingClipsWhenClipsAreOnlyAudio() {
        #expect(RecordingAudioExporter.effectiveIncludeExtras(
            hasPrimaryAudio: false,
            hasBackgroundMusic: false,
            hasAudioClips: true,
            userSelection: false
        ) == true)
        #expect(RecordingAudioExporter.effectiveIncludeExtras(
            hasPrimaryAudio: true,
            hasBackgroundMusic: false,
            hasAudioClips: true,
            userSelection: false
        ) == false)
        #expect(RecordingAudioExporter.effectiveIncludeExtras(
            hasPrimaryAudio: true,
            hasBackgroundMusic: false,
            hasAudioClips: true,
            userSelection: true
        ) == true)
    }

    @Test func detachedReplacementClipPinnedToSourceFileSurvivesReplacementSwapAndReset() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioAudioPinnedTest-\(UUID().uuidString)", isDirectory: true)
        let mediaDir = dir.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let screenURL = try makeTone(in: dir, name: "screen", frequency: 220, amplitude: 0.3, duration: 2.0)
        let soundtrackA = try makeTone(in: dir, name: "audio-replacement.A", frequency: 520, amplitude: 0.4, duration: 2.0)
        let soundtrackB = try makeTone(in: dir, name: "audio-replacement.B", frequency: 980, amplitude: 0.4, duration: 1.0)

        // Segment 0 plays soundtrack B (0..1s); segment 1 is muted and detached to pinned soundtrack A (1..2s).
        let seg0 = RecordingClipSegment(sourceStart: 0, sourceEnd: 1.0)
        var seg1 = RecordingClipSegment(sourceStart: 1.0, sourceEnd: 2.0)
        seg1.isMuted = true
        let timeline = RecordingClipTimeline(segments: [seg0, seg1])

        var detachedA = RecordingAudioClip(
            fileName: soundtrackA.lastPathComponent,
            displayName: "Soundtrack A",
            start: 1.0,
            fileDuration: 2.0
        )
        detachedA.source = .replacement
        detachedA.trimStart = 1.0
        detachedA.trimEnd = 2.0

        // Active replacement is now shorter soundtrack B.
        let preparedWithB = try await StudioAudioComposer.prepareExport(
            screenAsset: AVURLAsset(url: screenURL),
            screenURL: screenURL,
            timeline: timeline,
            replacementURL: soundtrackB,
            replacementSync: .flat(over: timeline),
            clips: [detachedA],
            mediaDirectory: mediaDir,
            volume: 1,
            microphoneTrackID: nil,
            isolatedMicrophoneURL: nil,
            backgroundMusic: nil
        )
        let samplesWithB = try await renderMonoSamples(asset: preparedWithB.composition, mix: preparedWithB.mix, duration: 2.0)
        // First half plays B (980 Hz); second half plays pinned A (520 Hz), NOT B or silence.
        #expect(goertzel(samplesWithB, at: 0.25, length: 0.4, frequency: 980) > 0.25)
        #expect(goertzel(samplesWithB, at: 1.25, length: 0.4, frequency: 520) > 0.25)
        #expect(goertzel(samplesWithB, at: 1.25, length: 0.4, frequency: 980) < 0.03)

        // Resetting replacement to nil still plays pinned A in the detached clip!
        let preparedAfterReset = try await StudioAudioComposer.prepareExport(
            screenAsset: AVURLAsset(url: screenURL),
            screenURL: screenURL,
            timeline: timeline,
            replacementURL: nil,
            replacementSync: nil,
            clips: [detachedA],
            mediaDirectory: mediaDir,
            volume: 1,
            microphoneTrackID: nil,
            isolatedMicrophoneURL: nil,
            backgroundMusic: nil
        )
        let samplesAfterReset = try await renderMonoSamples(asset: preparedAfterReset.composition, mix: preparedAfterReset.mix, duration: 2.0)
        #expect(goertzel(samplesAfterReset, at: 0.25, length: 0.4, frequency: 220) > 0.15)
        #expect(goertzel(samplesAfterReset, at: 1.25, length: 0.4, frequency: 520) > 0.25)
    }

    @Test func detachAudioMatchesPlaybackSlicesAndEffectiveLevel() throws {
        let segment = RecordingClipSegment(sourceStart: 0, sourceEnd: 2.0, volume: 1.0)
        let sync = RecordingAudioSync(
            spans: [.init(sourceStart: 0, sourceEnd: 2.0, fileStart: 0, rate: 1)],
            offset: 0.05 // 50 ms positive offset leaves 50 ms of original audio at head
        )

        let detached = try #require(StudioAudioComposer.detachedClips(
            for: segment,
            editorStart: 0,
            editorEnd: 2.0,
            projectVolume: 0.25,
            sync: sync,
            replacementFileName: "audio-replacement.1.wav",
            replacementDisplayName: "Clean.wav",
            replacementDuration: 2.0,
            recordingDisplayName: "Take audio",
            sourceDuration: 2.0,
            hasRecording: true,
            lane: 0
        ))
        // Both the 50 ms original audio head and the 1.95 s replacement piece are preserved at 25% level!
        #expect(detached.count == 2)
        #expect(detached[0].source == .recording)
        #expect(abs(detached[0].start - 0) < 0.001)
        #expect(abs(detached[0].duration - 0.05) < 0.001)
        #expect(abs(detached[0].volume - 0.25) < 0.001)
        #expect(detached[1].source == .replacement)
        #expect(detached[1].fileName == "audio-replacement.1.wav")
        #expect(abs(detached[1].start - 0.05) < 0.001)
        #expect(abs(detached[1].duration - 1.95) < 0.001)
        #expect(abs(detached[1].volume - 0.25) < 0.001)
    }

    @Test func consistentPlayableSpanAndDerivedRateBoundsAcrossConformSplitAndReload() throws {
        // 1. Linked 0.32 s sting over video sped up to 8x (40 ms editor duration) survives conform and reload.
        let seg = RecordingClipSegment(sourceStart: 0, sourceEnd: 10, speed: 1)
        let old = RecordingClipTimeline(segments: [seg])
        var fastSeg = seg
        fastSeg.speed = 8
        let fast = RecordingClipTimeline(segments: [fastSeg])
        var sting = RecordingAudioClip(fileName: "sting.wav", displayName: "Sting", start: 2.0, fileDuration: 0.32)
        sting.isLinked = true
        let conformedSting = StudioAudioConform.conform([sting], from: old, to: fast)
        #expect(conformedSting.count == 1)
        #expect(abs(conformedSting[0].duration - 0.04) < 0.001)
        #expect(abs(conformedSting[0].speed - 8.0) < 0.001)
        let reloadedSting = try JSONDecoder().decode(RecordingAudioClip.self, from: JSONEncoder().encode(conformedSting[0])).sanitized()
        #expect(abs(reloadedSting.duration - 0.04) < 0.001)
        #expect(abs(reloadedSting.fileSpan - 0.32) < 0.001)

        // 2. 0.5x clip split 120 ms from start (60 ms file span) keeps its exact 60 ms span after reload.
        var halfSpeed = RecordingAudioClip(fileName: "pad.wav", displayName: "Pad", start: 1.0, fileDuration: 4.0)
        halfSpeed.speed = 0.5
        let halves = try #require(StudioAudioConform.split(halfSpeed, at: 1.12))
        #expect(abs(halves.leading.fileSpan - 0.06) < 0.000_5)
        let reloadedLeading = try JSONDecoder().decode(RecordingAudioClip.self, from: JSONEncoder().encode(halves.leading)).sanitized()
        #expect(abs(reloadedLeading.fileSpan - 0.06) < 0.000_5)
        #expect(abs(reloadedLeading.duration - 0.12) < 0.000_5)

        // 3. Imported 2x clip linked over 1x video acquires 16x derived rate when video speeds to 8x and keeps 16x on reload.
        var doubleClip = RecordingAudioClip(fileName: "fast.wav", displayName: "Fast", start: 0, fileDuration: 4.0)
        doubleClip.speed = 2.0
        doubleClip.isLinked = true
        let conformedDouble = StudioAudioConform.conform([doubleClip], from: old, to: fast)
        #expect(conformedDouble.count == 1)
        #expect(abs(conformedDouble[0].speed - 16.0) < 0.001)
        let reloadedDouble = try JSONDecoder().decode(RecordingAudioClip.self, from: JSONEncoder().encode(conformedDouble[0])).sanitized()
        #expect(abs(reloadedDouble.speed - 16.0) < 0.001)
    }

    @Test func fullyHiddenLinkedClipHealsOnTrimReopenAndDropsOnSegmentDelete() {
        let seg = RecordingClipSegment(sourceStart: 0, sourceEnd: 10)
        let full = RecordingClipTimeline(segments: [seg])

        var linked = RecordingAudioClip(fileName: "sfx.wav", displayName: "SFX", start: 8, fileDuration: 1)
        linked.isLinked = true
        linked.volume = 0.75
        linked.fadeIn = 0.15
        linked.fadeOut = 0.2

        // Trim segment to 0...7 s: linked clip at 8...9 s is fully hidden.
        var trimmedSeg = seg
        trimmedSeg.sourceEnd = 7
        let trimmed = RecordingClipTimeline(segments: [trimmedSeg])
        let afterTrim = StudioAudioConform.conform([linked], hidden: [], from: full, to: trimmed)
        #expect(afterTrim.clips.isEmpty)
        #expect(afterTrim.hidden.count == 1)

        // Partially reopen to 0...8.5 s: heals 8...8.5 s and retains 8.5...9 s hidden.
        var halfOpenSeg = trimmedSeg
        halfOpenSeg.sourceEnd = 8.5
        let halfOpen = RecordingClipTimeline(segments: [halfOpenSeg])
        let afterHalf = StudioAudioConform.conform(afterTrim.clips, hidden: afterTrim.hidden, from: trimmed, to: halfOpen)
        #expect(afterHalf.clips.count == 1)
        #expect(abs(afterHalf.clips[0].start - 8) < 0.001)
        #expect(abs(afterHalf.clips[0].end - 8.5) < 0.001)
        #expect(!afterHalf.hidden.isEmpty)

        // Reopen fully to 0...10 s: heals the full 8...9 s clip back seamlessly!
        let afterReopen = StudioAudioConform.conform(afterHalf.clips, hidden: afterHalf.hidden, from: halfOpen, to: full)
        #expect(afterReopen.clips.count == 1)
        #expect(abs(afterReopen.clips[0].start - 8) < 0.001)
        #expect(abs(afterReopen.clips[0].end - 9) < 0.001)
        #expect(abs(afterReopen.clips[0].volume - 0.75) < 0.001)
        #expect(abs(afterReopen.clips[0].fadeIn - 0.15) < 0.001)
        #expect(abs(afterReopen.clips[0].fadeOut - 0.2) < 0.001)
        #expect(afterReopen.hidden.isEmpty)

        // Deliberate delete of the segment drops its hidden ranges.
        let otherSeg = RecordingClipSegment(sourceStart: 0, sourceEnd: 5)
        let deleted = RecordingClipTimeline(segments: [otherSeg])
        let afterDelete = StudioAudioConform.conform(afterTrim.clips, hidden: afterTrim.hidden, from: trimmed, to: deleted)
        #expect(afterDelete.clips.isEmpty)
        #expect(afterDelete.hidden.isEmpty)
    }

    @Test func legacyReplacementGapsStaySilentAndIsolatedMicAppliesWhereverOriginalAudioPlays() async throws {
        let dir = try makeDirectory()
        let mediaDir = dir.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Screen has 900 Hz system + 220 Hz raw mic; isolated mic is 440 Hz; replacement is 520 Hz.
        let systemURL = try makeTone(in: dir, name: "sys", frequency: 900, amplitude: 0.25, duration: 1.5)
        let micURL = try makeTone(in: dir, name: "mic", frequency: 220, amplitude: 0.35, duration: 1.5)
        let screenURL = dir.appendingPathComponent("screen.mov")
        let micTrackID = try await writeDualTrackAudioMovie(systemURL: systemURL, micURL: micURL, to: screenURL)
        let isolatedURL = try makeTone(in: dir, name: "isolated", frequency: 440, amplitude: 0.35, duration: 1.5)
        let shortReplacementURL = try makeTone(in: dir, name: "short-repl", frequency: 520, amplitude: 0.35, duration: 0.8)
        let fullReplacementURL = try makeTone(in: dir, name: "full-repl", frequency: 520, amplitude: 0.35, duration: 1.5)
        let timeline = RecordingClipTimeline.full(sourceDuration: 1.5)

        // 1. Legacy v6 project (replacementSync == nil) with 0.8 s replacement over 1.5 s cut:
        //    the uncovered 0.8...1.5 s tail stays silent (does NOT bring back original audio).
        let legacyPrepared = try await StudioAudioComposer.prepareExport(
            screenAsset: AVURLAsset(url: screenURL),
            screenURL: screenURL,
            timeline: timeline,
            replacementURL: shortReplacementURL,
            replacementSync: nil,
            clips: [],
            mediaDirectory: mediaDir,
            volume: 1,
            microphoneTrackID: micTrackID,
            isolatedMicrophoneURL: isolatedURL,
            backgroundMusic: nil
        )
        let legacySamples = try await renderMonoSamples(asset: legacyPrepared.composition, mix: legacyPrepared.mix, duration: 1.5)
        #expect(goertzel(legacySamples, at: 0.2, length: 0.4, frequency: 520) > 0.2)
        #expect(peakAmplitude(in: legacySamples, from: 0.9, to: 1.4, sampleRate: 48_000) < 0.01)

        // 2. Full replacement + voice isolation + detached .recording clip:
        //    detached .recording clip plays 440 Hz isolated mic (NOT 220 Hz raw mic),
        //    while a fully covering replacement without recording clips contributes only 520 Hz.
        var detachedRec = RecordingAudioClip(fileName: "", displayName: "Take audio", start: 0.2, fileDuration: 1.5)
        detachedRec.source = .recording
        detachedRec.trimStart = 0.2
        detachedRec.trimEnd = 1.2
        let withDetached = try await StudioAudioComposer.prepareExport(
            screenAsset: AVURLAsset(url: screenURL),
            screenURL: screenURL,
            timeline: timeline,
            replacementURL: fullReplacementURL,
            replacementSync: .flat(over: timeline),
            clips: [detachedRec],
            mediaDirectory: mediaDir,
            volume: 1,
            microphoneTrackID: micTrackID,
            isolatedMicrophoneURL: isolatedURL,
            backgroundMusic: nil
        )
        let detachedSamples = try await renderMonoSamples(asset: withDetached.composition, mix: withDetached.mix, duration: 1.5)
        #expect(goertzel(detachedSamples, at: 0.4, length: 0.5, frequency: 440) > 0.15)
        #expect(goertzel(detachedSamples, at: 0.4, length: 0.5, frequency: 220) < 0.03)
        #expect(goertzel(detachedSamples, at: 0.4, length: 0.5, frequency: 520) > 0.15)

        let fullOnly = try await StudioAudioComposer.prepareExport(
            screenAsset: AVURLAsset(url: screenURL),
            screenURL: screenURL,
            timeline: timeline,
            replacementURL: fullReplacementURL,
            replacementSync: .flat(over: timeline),
            clips: [],
            mediaDirectory: mediaDir,
            volume: 1,
            microphoneTrackID: micTrackID,
            isolatedMicrophoneURL: isolatedURL,
            backgroundMusic: nil
        )
        let fullSamples = try await renderMonoSamples(asset: fullOnly.composition, mix: fullOnly.mix, duration: 1.5)
        #expect(goertzel(fullSamples, at: 0.4, length: 0.5, frequency: 520) > 0.2)
        #expect(goertzel(fullSamples, at: 0.4, length: 0.5, frequency: 440) < 0.03)
        #expect(goertzel(fullSamples, at: 0.4, length: 0.5, frequency: 220) < 0.03)
    }

    @Test func speechCleanupExportOmitsMusicAndLanesWhileFullMixIncludesBoth() async throws {
        let dir = try makeDirectory()
        let mediaDir = dir.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let screenURL = try makeTone(in: dir, name: "speech", frequency: 440, amplitude: 0.35, duration: 1.5)
        let musicURL = try makeTone(in: dir, name: "bed", frequency: 660, amplitude: 0.3, duration: 1.5)
        let clipURL = try makeTone(in: mediaDir, name: "lane-fx", frequency: 1200, amplitude: 0.3, duration: 1.2)
        let clip = RecordingAudioClip(fileName: clipURL.lastPathComponent, displayName: "FX", start: 0.1, fileDuration: 1.2)
        let music = RecordingBackgroundMusicMixer.Configuration(
            url: musicURL,
            settings: RecordingBackgroundMusic(
                fileName: musicURL.lastPathComponent,
                displayName: "Bed",
                volume: 0.5,
                loop: true,
                duck: false,
                duckAmount: .medium
            )
        )
        let timeline = RecordingClipTimeline.full(sourceDuration: 1.5)

        // Default cleanup mode (userSelection == false) omits both music bed and audio lanes.
        let cleanupInclude = RecordingAudioExporter.effectiveIncludeExtras(
            hasPrimaryAudio: true,
            hasBackgroundMusic: true,
            hasAudioClips: true,
            userSelection: false
        )
        #expect(cleanupInclude == false)
        let cleanupURL = try await RecordingAudioExporter().export(
            RecordingAudioExporter.Configuration(
                screenURL: screenURL,
                clipTimeline: timeline,
                replacementURL: nil,
                format: .wav,
                volume: 1,
                backgroundMusic: cleanupInclude ? music : nil,
                audioClips: cleanupInclude ? [clip] : [],
                mediaDirectory: cleanupInclude ? mediaDir : nil
            ),
            progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: cleanupURL) }
        let cleanupSamples = try await renderMonoSamples(asset: AVURLAsset(url: cleanupURL), mix: nil, duration: 1.5)
        #expect(goertzel(cleanupSamples, at: 0.3, length: 0.5, frequency: 440) > 0.2)
        #expect(goertzel(cleanupSamples, at: 0.3, length: 0.5, frequency: 660) < 0.02)
        #expect(goertzel(cleanupSamples, at: 0.3, length: 0.5, frequency: 1200) < 0.02)

        // Full-mix mode (userSelection == true) includes speech, music bed, and audio lanes once.
        let fullMixInclude = RecordingAudioExporter.effectiveIncludeExtras(
            hasPrimaryAudio: true,
            hasBackgroundMusic: true,
            hasAudioClips: true,
            userSelection: true
        )
        #expect(fullMixInclude == true)
        let fullMixURL = try await RecordingAudioExporter().export(
            RecordingAudioExporter.Configuration(
                screenURL: screenURL,
                clipTimeline: timeline,
                replacementURL: nil,
                format: .wav,
                volume: 1,
                backgroundMusic: fullMixInclude ? music : nil,
                audioClips: fullMixInclude ? [clip] : [],
                mediaDirectory: fullMixInclude ? mediaDir : nil
            ),
            progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: fullMixURL) }
        let fullSamples = try await renderMonoSamples(asset: AVURLAsset(url: fullMixURL), mix: nil, duration: 1.5)
        #expect(goertzel(fullSamples, at: 0.3, length: 0.5, frequency: 440) > 0.15)
        #expect(goertzel(fullSamples, at: 0.3, length: 0.5, frequency: 660) > 0.08)
        #expect(goertzel(fullSamples, at: 0.3, length: 0.5, frequency: 1200) > 0.15)
    }

    @Test func eighthLaneUsesFreeLaneBeforeStackingAndSub10msOverlapUsesFreshCompositionTrack() async throws {
        // Fill lanes 0..7 except leave lane 2 free at 3...5 s (anchored elsewhere so compaction keeps 8 lanes).
        var clips: [RecordingAudioClip] = []
        for lane in 0..<8 {
            var anchor = RecordingAudioClip(fileName: "a.wav", displayName: "Anchor\(lane)", start: 0, fileDuration: 1)
            anchor.lane = lane
            clips.append(anchor)
            if lane != 2 {
                var mid = RecordingAudioClip(fileName: "a.wav", displayName: "Mid\(lane)", start: 3, fileDuration: 2)
                mid.lane = lane
                clips.append(mid)
            }
        }
        var dropped = RecordingAudioClip(fileName: "b.wav", displayName: "Dropped", start: 3, fileDuration: 2)
        dropped.lane = 7
        clips.append(dropped)

        let resolved = StudioAudioConform.resolvingLanes(clips, last: dropped.id)
        let placed = try #require(resolved.first { $0.id == dropped.id })
        // Searches upward and finds free lane 2 instead of stacking on lane 7!
        #expect(placed.lane == 2)

        // Sub-10 ms overlap (5 ms) allocates a separate composition track instead of pushing clip 2 later.
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let toneURL = try makeTone(in: dir, name: "tone", frequency: 440, amplitude: 0.4, duration: 2.0)
        var c1 = RecordingAudioClip(fileName: toneURL.lastPathComponent, displayName: "C1", start: 0, fileDuration: 2.0)
        c1.trimEnd = 1.005
        var c2 = RecordingAudioClip(fileName: toneURL.lastPathComponent, displayName: "C2", start: 1.0, fileDuration: 2.0)
        c2.trimEnd = 1.0
        let timeline = RecordingClipTimeline.full(sourceDuration: 2.5)
        let sources = try await StudioAudioSources.load(
            screenAsset: AVURLAsset(url: toneURL),
            replacementURL: nil,
            clips: [c1, c2],
            mediaDirectory: dir
        )
        let plan = StudioAudioPlan(timeline: timeline, sync: nil, clips: [c1, c2], volume: 1)
        let (_, layout) = StudioAudioComposer.makeComposition(plan: plan, sources: sources)
        let p1 = try #require(layout.placements.first { $0.owner == .clip(c1.id) })
        let p2 = try #require(layout.placements.first { $0.owner == .clip(c2.id) })
        #expect(p1.trackID != p2.trackID)
        #expect(abs(p2.start - 1.0) < 0.002)
    }

    @Test func spliceBetweenDifferentFilesAtMatchingTimesStillReceivesCutRamps() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileA = try makeTone(in: dir, name: "fileA", frequency: 440, amplitude: 0.4, duration: 4.0)
        let fileB = try makeTone(in: dir, name: "fileB", frequency: 880, amplitude: 0.4, duration: 4.0)

        var clipA = RecordingAudioClip(fileName: fileA.lastPathComponent, displayName: "A", start: 0, fileDuration: 4.0)
        clipA.trimStart = 0
        clipA.trimEnd = 2.0
        var clipB = RecordingAudioClip(fileName: fileB.lastPathComponent, displayName: "B", start: 2.0, fileDuration: 4.0)
        clipB.trimStart = 2.0
        clipB.trimEnd = 4.0

        let timeline = RecordingClipTimeline.full(sourceDuration: 4.0)
        let sources = try await StudioAudioSources.load(
            screenAsset: AVURLAsset(url: fileA),
            replacementURL: nil,
            clips: [clipA, clipB],
            mediaDirectory: dir
        )
        let plan = StudioAudioPlan(timeline: timeline, sync: nil, clips: [clipA, clipB], volume: 1)
        let (_, layout) = StudioAudioComposer.makeComposition(plan: plan, sources: sources)
        let clipTrackID = try #require(layout.placements.first { $0.owner == .clip(clipA.id) }?.trackID)
        let spans = try #require(StudioAudioComposer.envelopeSpans(for: layout, plan: plan)[clipTrackID])
        // Both edgeOut on A (ending at 2.0) and edgeIn on B (starting at 2.0) must exist!
        let rampOut = spans.first { abs($0.end - 2.0) < 0.001 && $0.endGain == 0 && $0.startGain == 1 }
        let rampIn = spans.first { abs($0.start - 2.0) < 0.001 && $0.startGain == 0 && $0.endGain == 1 }
        #expect(rampOut != nil)
        #expect(rampIn != nil)

        // Contrast: two contiguous pieces of the SAME file have no cut ramps at 2.0.
        var clipA2 = RecordingAudioClip(fileName: fileA.lastPathComponent, displayName: "A2", start: 2.0, fileDuration: 4.0)
        clipA2.trimStart = 2.0
        clipA2.trimEnd = 4.0
        let samePlan = StudioAudioPlan(timeline: timeline, sync: nil, clips: [clipA, clipA2], volume: 1)
        let (_, sameLayout) = StudioAudioComposer.makeComposition(plan: samePlan, sources: sources)
        let sameTrackID = try #require(sameLayout.placements.first { $0.owner == .clip(clipA.id) }?.trackID)
        #expect(StudioAudioComposer.envelopeSpans(for: sameLayout, plan: samePlan)[sameTrackID] == nil)
    }

    @Test func audioLaneSoloAppliesAtMixTimeWithoutMutatingClipStoredMutes() {
        var c0 = RecordingAudioClip(fileName: "a.wav", displayName: "A", start: 0, fileDuration: 2)
        c0.lane = 0
        var c1 = RecordingAudioClip(fileName: "b.wav", displayName: "B", start: 0, fileDuration: 2)
        c1.lane = 1
        var c2 = RecordingAudioClip(fileName: "c.wav", displayName: "C", start: 0, fileDuration: 2)
        c2.lane = 2
        c2.isMuted = true // lane 2 has a stored mute

        // Solo lane 0: effective gain silences lane 1 and 2 while stored isMuted stays untouched.
        let step1 = StudioAudioLaneSolo.toggle(lane: 0, current: nil)
        #expect(step1.soloLane == 0)
        #expect(StudioAudioLaneSolo.effectiveGain(for: c0, soloLane: step1.soloLane) == 1)
        #expect(StudioAudioLaneSolo.effectiveGain(for: c1, soloLane: step1.soloLane) == 0)
        #expect(StudioAudioLaneSolo.effectiveGain(for: c2, soloLane: step1.soloLane) == 0)
        #expect(c0.isMuted == false && c1.isMuted == false && c2.isMuted == true)

        // Switching solo to lane 1 switches audible lane cleanly; lane 2 stays stored-muted.
        let step2 = StudioAudioLaneSolo.toggle(lane: 1, current: step1.soloLane)
        #expect(step2.soloLane == 1)
        #expect(StudioAudioLaneSolo.effectiveGain(for: c0, soloLane: step2.soloLane) == 0)
        #expect(StudioAudioLaneSolo.effectiveGain(for: c1, soloLane: step2.soloLane) == 1)
        #expect(StudioAudioLaneSolo.effectiveGain(for: c2, soloLane: step2.soloLane) == 0)

        // Unsoloing lane 1 immediately restores normal playback according to stored isMuted.
        let step3 = StudioAudioLaneSolo.toggle(lane: 1, current: step2.soloLane)
        #expect(step3.soloLane == nil)
        #expect(StudioAudioLaneSolo.effectiveGain(for: c0, soloLane: step3.soloLane) == 1)
        #expect(StudioAudioLaneSolo.effectiveGain(for: c1, soloLane: step3.soloLane) == 1)
        #expect(StudioAudioLaneSolo.effectiveGain(for: c2, soloLane: step3.soloLane) == 0)
    }

    @Test func envelopeTapScalesPacked24BitAndPadded24In32PCMWithCorrectStride() {
        // 1. Packed signed 24-bit little-endian (3 bytes/sample), 2 frames mono:
        //    frame 0 = +4_000_000 at gain 0.5 -> +2_000_000;
        //    frame 1 = -6_000_000 at gain 2.0 -> clipped to -8_388_608.
        var packedBytes: [UInt8] = [
            UInt8(4_000_000 & 0xFF), UInt8((4_000_000 >> 8) & 0xFF), UInt8((4_000_000 >> 16) & 0xFF),
            UInt8(UInt32(bitPattern: -6_000_000) & 0xFF),
            UInt8((UInt32(bitPattern: -6_000_000) >> 8) & 0xFF),
            UInt8((UInt32(bitPattern: -6_000_000) >> 16) & 0xFF)
        ]
        let packedFormat = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 3,
            mFramesPerPacket: 1,
            mBytesPerFrame: 3,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 24,
            mReserved: 0
        )
        packedBytes.withUnsafeMutableBytes { raw in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
            )
            RecordingAudioGain.applyEnvelope(
                to: &abl,
                frameCount: 2,
                startTime: 0,
                duration: 2.0,
                format: packedFormat,
                gainAt: { $0 < 0.5 ? 0.5 : 2.0 }
            )
        }
        let s0 = ((Int32(packedBytes[0]) | (Int32(packedBytes[1]) << 8) | (Int32(packedBytes[2]) << 16)) << 8) >> 8
        let s1 = ((Int32(packedBytes[3]) | (Int32(packedBytes[4]) << 8) | (Int32(packedBytes[5]) << 16)) << 8) >> 8
        #expect(s0 == 2_000_000)
        #expect(s1 == -8_388_608)

        // 2. 24-bit valid bits inside 32-bit container (4 bytes/sample, stereo interleaved => 8 bytes/frame),
        //    high-aligned: frame 0 scaled by 0.5, frame 1 muted to 0 without touching adjacent samples!
        var paddedHigh: [Int32] = [
            4_000_000 << 8, -2_000_000 << 8, // frame 0 L, R
            3_000_000 << 8, -1_000_000 << 8  // frame 1 L, R
        ]
        let paddedHighFormat = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 24,
            mReserved: 0
        )
        paddedHigh.withUnsafeMutableBytes { raw in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
            )
            RecordingAudioGain.applyEnvelope(
                to: &abl,
                frameCount: 2,
                startTime: 0,
                duration: 2.0,
                format: paddedHighFormat,
                gainAt: { $0 < 0.5 ? 0.5 : 0.0 }
            )
        }
        #expect((paddedHigh[0] >> 8) == 2_000_000)
        #expect((paddedHigh[1] >> 8) == -1_000_000)
        #expect(paddedHigh[2] == 0)
        #expect(paddedHigh[3] == 0)

        // 3. 24-bit valid bits inside 32-bit container, low-aligned:
        var paddedLow: [Int32] = [4_000_000, -2_000_000]
        let paddedLowFormat = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 24,
            mReserved: 0
        )
        paddedLow.withUnsafeMutableBytes { raw in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
            )
            RecordingAudioGain.applyEnvelope(
                to: &abl,
                frameCount: 2,
                startTime: 0,
                duration: 2.0,
                format: paddedLowFormat,
                gainAt: { _ in 0.5 }
            )
        }
        #expect(paddedLow[0] == 2_000_000)
        #expect(paddedLow[1] == -1_000_000)
    }

    @Test func waveformPeakStorageCapsLongMediaAndDrawsOnlyVisibleViewportSlice() {
        // Simulate an hour-long recording (360,000 peaks at 100/sec) with one loud impulse.
        var peaks = [Float](repeating: 0.1, count: 360_000)
        peaks[180_000] = 0.95
        var rate = Double(RecordingAudioPeaks.peaksPerSecond)
        RecordingAudioPeaks.compactInPlace(&peaks, peaksPerSecond: &rate)
        #expect(peaks.count <= RecordingAudioPeaks.maximumPeaks)
        #expect(abs((peaks.max() ?? 0) - 0.95) < 0.001)
        // Duration represented by peaks / rate remains ~3600 seconds.
        let representedDuration = Double(peaks.count) / rate
        #expect(abs(representedDuration - 3600) < 1.0)

        // Zoomed 100,000 pt wide clip with a 1,000 pt viewport only draws ~250 bars instead of 25,000.
        let bounds = RecordingAudioPeaks.visibleBarBounds(
            width: 100_000,
            visibleXRange: 40_000...41_000,
            bar: 2,
            gap: 2
        )
        let barsDrawn = Int((bounds.end - bounds.start) / 4)
        #expect(bounds.start >= 39_996 && bounds.start <= 40_002)
        #expect(bounds.end <= 41_000)
        #expect(barsDrawn >= 245 && barsDrawn <= 255)
    }

    @Test func standaloneMovieDetachedReplacementUsesStableExternalReferenceAcrossSwapResetAndExport() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let screenURL = try makeTone(in: dir, name: "standalone", frequency: 220, amplitude: 0.3, duration: 2.0)
        let extA = try makeTone(in: dir, name: "externalA", frequency: 520, amplitude: 0.4, duration: 2.0)
        let extB = try makeTone(in: dir, name: "externalB", frequency: 980, amplitude: 0.4, duration: 1.0)

        let seg0 = RecordingClipSegment(sourceStart: 0, sourceEnd: 1.0)
        var seg1 = RecordingClipSegment(sourceStart: 1.0, sourceEnd: 2.0)
        seg1.isMuted = true
        let timeline = RecordingClipTimeline(segments: [seg0, seg1])

        let keyA = "external-replacement.\(UUID().uuidString).wav"
        var detachedA = RecordingAudioClip(fileName: keyA, displayName: "externalA.wav", start: 1.0, fileDuration: 2.0)
        detachedA.source = .replacement
        detachedA.trimStart = 1.0
        detachedA.trimEnd = 2.0

        // Standalone movie: mediaDirectory is nil, externalReplacementURLs holds keyA -> extA.
        // Replacing active soundtrack with B keeps detached clip playing A.
        let withB = try await StudioAudioComposer.prepareExport(
            screenAsset: AVURLAsset(url: screenURL),
            screenURL: screenURL,
            timeline: timeline,
            replacementURL: extB,
            replacementSync: .flat(over: timeline),
            clips: [detachedA],
            mediaDirectory: nil,
            externalReplacementURLs: [keyA: extA],
            volume: 1,
            microphoneTrackID: nil,
            isolatedMicrophoneURL: nil,
            backgroundMusic: nil
        )
        let samplesB = try await renderMonoSamples(asset: withB.composition, mix: withB.mix, duration: 2.0)
        #expect(goertzel(samplesB, at: 0.25, length: 0.4, frequency: 980) > 0.2)
        #expect(goertzel(samplesB, at: 1.25, length: 0.4, frequency: 520) > 0.2)
        #expect(goertzel(samplesB, at: 1.25, length: 0.4, frequency: 980) < 0.03)

        // Resetting active replacement to nil keeps detached clip playing A via audio-only export too.
        let exportedURL = try await RecordingAudioExporter().export(
            RecordingAudioExporter.Configuration(
                screenURL: screenURL,
                clipTimeline: timeline,
                replacementURL: nil,
                format: .wav,
                volume: 1,
                audioClips: [detachedA],
                mediaDirectory: nil,
                externalReplacementURLs: [keyA: extA]
            ),
            progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: exportedURL) }
        let samplesReset = try await renderMonoSamples(asset: AVURLAsset(url: exportedURL), mix: nil, duration: 2.0)
        #expect(goertzel(samplesReset, at: 0.25, length: 0.4, frequency: 220) > 0.15)
        #expect(goertzel(samplesReset, at: 1.25, length: 0.4, frequency: 520) > 0.2)
    }

    @Test func detachAudioMatchesLaneComposerAt7Point5msBoundaryAnd4xAmplifiedGain() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let screenURL = try makeTone(in: dir, name: "screen", frequency: 440, amplitude: 0.2, duration: 2.0)
        let replURL = try makeTone(in: dir, name: "repl", frequency: 880, amplitude: 0.2, duration: 2.0)

        // Replacement at 1x, offset +60 ms, video sped up to 8x => 7.5 ms recorded lead-in,
        // plus 200% segment volume * 200% project volume = 4x effective gain!
        let segment = RecordingClipSegment(sourceStart: 0, sourceEnd: 2.0, speed: 8.0, volume: 2.0)
        let sync = RecordingAudioSync(
            spans: [.init(sourceStart: 0, sourceEnd: 2.0, fileStart: 0, rate: 1)],
            offset: 0.06
        )
        let editorDuration = segment.editorDuration // 0.25 s

        let detached = try #require(StudioAudioComposer.detachedClips(
            for: segment,
            editorStart: 0,
            editorEnd: editorDuration,
            projectVolume: 2.0,
            sync: sync,
            replacementFileName: replURL.lastPathComponent,
            replacementDisplayName: "Repl",
            replacementDuration: 2.0,
            recordingDisplayName: "Take",
            sourceDuration: 2.0,
            hasRecording: true,
            lane: 0
        ))
        #expect(detached.count == 2)
        // 7.5 ms lead-in survives detach, sanitize, AND lane composition!
        #expect(abs(detached[0].duration - 0.0075) < 0.000_5)
        #expect(abs(detached[0].volume - 4.0) < 0.001)
        #expect(abs(detached[0].sanitized().volume - 4.0) < 0.001)
        #expect(abs(detached[1].volume - 4.0) < 0.001)

        var mutedSegment = segment
        mutedSegment.isMuted = true
        let timeline = RecordingClipTimeline(segments: [mutedSegment])
        let sources = try await StudioAudioSources.load(
            screenAsset: AVURLAsset(url: screenURL),
            replacementURL: replURL,
            clips: detached,
            mediaDirectory: nil,
            externalReplacementURLs: [replURL.lastPathComponent: replURL],
            timeline: timeline,
            strictMissingClips: true
        )
        let plan = StudioAudioPlan(timeline: timeline, sync: sync, clips: detached, volume: 2.0)
        let (_, layout) = try StudioAudioComposer.makeExportComposition(plan: plan, sources: sources)
        // Both the 7.5 ms lead-in clip AND the replacement clip were placed into the lane composition!
        #expect(layout.placements.contains { $0.owner == .clip(detached[0].id) })
        #expect(layout.placements.contains { $0.owner == .clip(detached[1].id) })
        let spans = StudioAudioComposer.envelopeSpans(for: layout, plan: plan)
        let leadTrack = try #require(layout.placements.first { $0.owner == .clip(detached[0].id) }?.trackID)
        let leadMaxGain = spans[leadTrack]?.map { max($0.startGain, $0.endGain) }.max() ?? 0
        #expect(abs(leadMaxGain - 4.0) < 0.01)
    }

    @Test func twoHiddenLinkedInstancesOfSameFileHealIndependentlyAndSurviveCodableReload() throws {
        let seg = RecordingClipSegment(sourceStart: 0, sourceEnd: 10)
        let full = RecordingClipTimeline(segments: [seg])

        var clipA = RecordingAudioClip(fileName: "shared.wav", displayName: "Shared A", start: 8, fileDuration: 1)
        clipA.isLinked = true
        clipA.lane = 0
        clipA.volume = 0.5

        var clipB = RecordingAudioClip(fileName: "shared.wav", displayName: "Shared B", start: 8, fileDuration: 1)
        clipB.isLinked = true
        clipB.lane = 1
        clipB.volume = 1.5

        // Trim video to 7 s: both linked clips at 8...9 s are hidden.
        var trimmedSeg = seg
        trimmedSeg.sourceEnd = 7
        let trimmed = RecordingClipTimeline(segments: [trimmedSeg])
        let afterTrim = StudioAudioConform.conform([clipA, clipB], hidden: [], from: full, to: trimmed)
        #expect(afterTrim.clips.isEmpty)
        #expect(afterTrim.hidden.count == 2)

        // Simulate save + reload of hiddenLinkedAudio through JSON.
        let reloadedHidden = try JSONDecoder().decode(
            [StudioAudioConform.HiddenLinkedRange].self,
            from: JSONEncoder().encode(afterTrim.hidden)
        )

        // Reopen trim to 10 s: BOTH instances restore with their distinct IDs, lanes, and volumes!
        let afterReopen = StudioAudioConform.conform([], hidden: reloadedHidden, from: trimmed, to: full)
        #expect(afterReopen.clips.count == 2)
        let restoredA = try #require(afterReopen.clips.first { $0.id == clipA.id })
        let restoredB = try #require(afterReopen.clips.first { $0.id == clipB.id })
        #expect(abs(restoredA.volume - 0.5) < 0.001)
        #expect(abs(restoredB.volume - 1.5) < 0.001)
        #expect(restoredA.lane != restoredB.lane)
        #expect(afterReopen.hidden.isEmpty)
    }

    @Test func duplicateMadeDuringSoloIsAudibleAfterUnsoloAndAfterSaveReopen() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let toneURL = try makeTone(in: dir, name: "tone", frequency: 440, amplitude: 0.4, duration: 2.0)

        var lane0Clip = RecordingAudioClip(fileName: toneURL.lastPathComponent, displayName: "Lane0", start: 0, fileDuration: 2.0)
        lane0Clip.lane = 0
        var lane1Clip = RecordingAudioClip(fileName: toneURL.lastPathComponent, displayName: "Lane1", start: 0, fileDuration: 1.0)
        lane1Clip.lane = 1

        // 1. Solo lane 0: lane 1 clip is silenced in the mix, but its stored isMuted stays false.
        let solo = StudioAudioLaneSolo.toggle(lane: 0, current: nil).soloLane
        #expect(solo == 0)
        #expect(lane1Clip.isMuted == false)

        // 2. Duplicate the lane 1 clip during solo (same logic as RecordingStudioModel.duplicateAudioClip).
        var duplicate = lane1Clip
        duplicate.id = UUID()
        duplicate.originID = nil
        duplicate.start = lane1Clip.end
        #expect(duplicate.isMuted == false)

        let clips = [lane0Clip, lane1Clip, duplicate]
        let timeline = RecordingClipTimeline.full(sourceDuration: 2.5)
        let sources = try await StudioAudioSources.load(
            screenAsset: AVURLAsset(url: toneURL),
            replacementURL: nil,
            clips: clips,
            mediaDirectory: dir
        )

        // While soloed on lane 0, the mix gives lane 0 gain 1 and both lane 1 clips (including duplicate) gain 0.
        let soloPlan = StudioAudioPlan(timeline: timeline, sync: nil, clips: clips, volume: 1, soloLane: solo)
        let (_, layout) = StudioAudioComposer.makeComposition(plan: soloPlan, sources: sources)
        let soloSpans = StudioAudioComposer.envelopeSpans(for: layout, plan: soloPlan)
        let dupTrack = try #require(layout.placements.first { $0.owner == .clip(duplicate.id) }?.trackID)
        let dupGainWhileSoloed = soloSpans[dupTrack]?.filter { $0.start >= 1.0 && $0.end <= 2.0 }.map { max($0.startGain, $0.endGain) }.max() ?? 1
        #expect(dupGainWhileSoloed == 0)

        // 3a. Unsolo path: duplicate plays at full level (1.0) immediately!
        let unsoloed = StudioAudioLaneSolo.toggle(lane: 0, current: solo).soloLane
        #expect(unsoloed == nil)
        let unsoloPlan = StudioAudioPlan(timeline: timeline, sync: nil, clips: clips, volume: 1, soloLane: unsoloed)
        let unsoloSpans = StudioAudioComposer.envelopeSpans(for: layout, plan: unsoloPlan)
        let dupGainAfterUnsolo = unsoloSpans[dupTrack]?.filter { $0.start >= 1.0 && $0.end <= 2.0 }.map { max($0.startGain, $0.endGain) }.max() ?? 1
        #expect(abs(dupGainAfterUnsolo - 1.0) < 0.001)

        // 3b. Save & reopen while soloed: document encodes clips without solo; reopened duplicate is NOT muted!
        let reloaded = try JSONDecoder().decode([RecordingAudioClip].self, from: JSONEncoder().encode(clips))
        let reloadedDup = try #require(reloaded.first { $0.id == duplicate.id })
        #expect(reloadedDup.isMuted == false)
        let reopenedPlan = StudioAudioPlan(timeline: timeline, sync: nil, clips: reloaded, volume: 1, soloLane: nil)
        let reopenedSpans = StudioAudioComposer.envelopeSpans(for: layout, plan: reopenedPlan)
        let dupGainAfterReopen = reopenedSpans[dupTrack]?.filter { $0.start >= 1.0 && $0.end <= 2.0 }.map { max($0.startGain, $0.endGain) }.max() ?? 1
        #expect(abs(dupGainAfterReopen - 1.0) < 0.001)

        // 4. Deleting lane 0's only clip reconciles solo to nil so lane 1 & duplicate are immediately audible.
        let afterDelete = clips.filter { $0.id != lane0Clip.id }
        #expect(StudioAudioLaneSolo.reconcile(clips: afterDelete, soloLane: solo) == nil)
    }

    @Test func splitPlusLeadingTrimReopenDoesNotDoubleRestore5To6Seconds() {
        let full = RecordingClipTimeline.full(sourceDuration: 10)
        var linked = RecordingAudioClip(fileName: "voice.wav", displayName: "Voice", start: 0, fileDuration: 10)
        linked.isLinked = true

        // Step 1: Split video at 5 s (two seamless segments 0...5 and 5...10).
        let segA = RecordingClipSegment(sourceStart: 0, sourceEnd: 5)
        let segB = RecordingClipSegment(sourceStart: 5, sourceEnd: 10)
        let splitTimeline = RecordingClipTimeline(segments: [segA, segB])
        let afterSplit = StudioAudioConform.conform([linked], hidden: [], from: full, to: splitTimeline)
        #expect(afterSplit.clips.count == 1)

        // Step 2: Trim second video clip's leading edge from 5 s to 6 s.
        var trimmedB = segB
        trimmedB.sourceStart = 6
        let trimmedTimeline = RecordingClipTimeline(segments: [segA, trimmedB])
        let afterTrim = StudioAudioConform.conform(afterSplit.clips, hidden: afterSplit.hidden, from: splitTimeline, to: trimmedTimeline)
        #expect(afterTrim.clips.count == 2)
        // Both conformed pieces share the same original clip lineage.
        #expect(afterTrim.clips[0].lineageID == afterTrim.clips[1].lineageID)
        #expect(afterTrim.hidden.count == 1)

        // Step 3: Reopen second video clip's leading edge back to 5 s.
        let afterReopen = StudioAudioConform.conform(afterTrim.clips, hidden: afterTrim.hidden, from: trimmedTimeline, to: splitTimeline)
        // 5...6 s must NOT be doubled onto a second lane; the clip heals seamlessly into 0...10 s on lane 0!
        let covering5to6 = afterReopen.clips.filter { $0.start < 6.0 - 0.001 && $0.end > 5.0 + 0.001 }
        #expect(covering5to6.count == 1)
        #expect(afterReopen.clips.count == 1)
        #expect(afterReopen.clips[0].lane == 0)
        #expect(abs(afterReopen.clips[0].start - 0) < 0.001)
        #expect(abs(afterReopen.clips[0].end - 10) < 0.001)
        #expect(afterReopen.hidden.isEmpty)
    }

    @Test func explicitAudioSplitAndFadesSurviveLaterVideoSplitAndTrimReopen() throws {
        let full = RecordingClipTimeline.full(sourceDuration: 10)
        var linked = RecordingAudioClip(fileName: "voice.wav", displayName: "Voice", start: 0, fileDuration: 10)
        linked.isLinked = true

        // 1. Split video at 5 s, then trim second video clip to source 6...9 s.
        let segA = RecordingClipSegment(sourceStart: 0, sourceEnd: 5)
        let segB = RecordingClipSegment(sourceStart: 5, sourceEnd: 10)
        let split5 = RecordingClipTimeline(segments: [segA, segB])
        let afterSplit5 = StudioAudioConform.conform([linked], hidden: [], from: full, to: split5)

        var trimmedB = segB
        trimmedB.sourceStart = 6
        trimmedB.sourceEnd = 9
        let trimmed6to9 = RecordingClipTimeline(segments: [segA, trimmedB])
        let afterTrim = StudioAudioConform.conform(afterSplit5.clips, hidden: afterSplit5.hidden, from: split5, to: trimmed6to9)
        #expect(afterTrim.clips.count == 2)
        let trailingPiece = try #require(afterTrim.clips.first { abs($0.start - 5) < 0.001 })
        #expect(abs(trailingPiece.end - 8) < 0.001)

        // 2. Deliberately Split Audio on the trailing piece (editor 5...8 s) at editor 7 s,
        //    and add Fade Out on the leading half and Fade In on the trailing half.
        let halves = try #require(StudioAudioConform.split(trailingPiece, at: 7))
        var leadHalf = halves.leading
        leadHalf.fadeOut = 0.35
        var trailHalf = halves.trailing
        trailHalf.fadeIn = 0.45
        #expect(leadHalf.lineageID == trailHalf.lineageID)
        #expect(leadHalf.keepsTrailingSplit)
        #expect(trailHalf.keepsLeadingSplit)
        // Codable round-trip preserves explicit split flags and omits them when false.
        let roundTripped = try JSONDecoder().decode([RecordingAudioClip].self, from: JSONEncoder().encode([leadHalf, trailHalf]))
        #expect(roundTripped[0].keepsTrailingSplit && !roundTripped[0].keepsLeadingSplit)
        #expect(roundTripped[1].keepsLeadingSplit && !roundTripped[1].keepsTrailingSplit)

        let clipsWithUserSplit = afterTrim.clips.filter { $0.id != trailingPiece.id } + [leadHalf, trailHalf]

        // 3. Split the first video clip at 2 s (triggers conform without healing).
        let segA1 = RecordingClipSegment(sourceStart: 0, sourceEnd: 2)
        let segA2 = RecordingClipSegment(sourceStart: 2, sourceEnd: 5)
        let split2 = RecordingClipTimeline(segments: [segA1, segA2, trimmedB])
        let afterSplit2 = StudioAudioConform.conform(clipsWithUserSplit, hidden: afterTrim.hidden, from: trimmed6to9, to: split2)

        // The deliberate split at 7 s AND both fades must survive completely intact.
        let keptLead = try #require(afterSplit2.clips.first { $0.id == leadHalf.id })
        let keptTrail = try #require(afterSplit2.clips.first { $0.id == trailHalf.id })
        #expect(abs(keptLead.start - 5) < 0.001 && abs(keptLead.end - 7) < 0.001)
        #expect(abs(keptLead.fadeOut - 0.35) < 0.001)
        #expect(abs(keptTrail.start - 7) < 0.001 && abs(keptTrail.end - 8) < 0.001)
        #expect(abs(keptTrail.fadeIn - 0.45) < 0.001)

        // 4. Reopen ONLY segB's trailing edge from source 9 s to 10 s:
        //    8...9 s must play ONCE (zero doubling onto another lane) while keeping the split & fades at 7 s.
        var reopenedTrailingB = trimmedB
        reopenedTrailingB.sourceEnd = 10
        let reopenedTrailing = RecordingClipTimeline(segments: [segA1, segA2, reopenedTrailingB])
        let afterTrailingReopen = StudioAudioConform.conform(afterSplit2.clips, hidden: afterSplit2.hidden, from: split2, to: reopenedTrailing)
        let covering8to9 = afterTrailingReopen.clips.filter { $0.start < 9 - 0.001 && $0.end > 8 + 0.001 }
        #expect(covering8to9.count == 1)
        let trailAfterTrailingReopen = try #require(afterTrailingReopen.clips.first { $0.id == trailHalf.id })
        #expect(trailAfterTrailingReopen.lane == 0)
        #expect(abs(trailAfterTrailingReopen.start - 7) < 0.001 && abs(trailAfterTrailingReopen.end - 9) < 0.001)
        #expect(abs(trailAfterTrailingReopen.fadeIn - 0.45) < 0.001)
        let leadAfterTrailingReopen = try #require(afterTrailingReopen.clips.first { $0.id == leadHalf.id })
        #expect(abs(leadAfterTrailingReopen.start - 5) < 0.001 && abs(leadAfterTrailingReopen.end - 7) < 0.001)
        #expect(abs(leadAfterTrailingReopen.fadeOut - 0.35) < 0.001)

        // 5. Then reopen segB's leading edge from source 6 s back to 5 s:
        //    5...6 s and 9...10 s each play ONCE, and the deliberate split & fades survive at editor 8 s.
        let reopenedBoth = RecordingClipTimeline(segments: [segA1, segA2, segB])
        let afterBothReopened = StudioAudioConform.conform(afterTrailingReopen.clips, hidden: afterTrailingReopen.hidden, from: reopenedTrailing, to: reopenedBoth)
        let covering5to6 = afterBothReopened.clips.filter { $0.start < 6 - 0.001 && $0.end > 5 + 0.001 }
        let covering9to10 = afterBothReopened.clips.filter { $0.start < 10 - 0.001 && $0.end > 9 + 0.001 }
        #expect(covering5to6.count == 1)
        #expect(covering9to10.count == 1)
        #expect(afterBothReopened.clips.count == 2)
        #expect(afterBothReopened.hidden.isEmpty)
        let healedTrail = try #require(afterBothReopened.clips.first { $0.id == trailHalf.id })
        #expect(healedTrail.lane == 0)
        #expect(abs(healedTrail.start - 8) < 0.001 && abs(healedTrail.end - 10) < 0.001)
        #expect(abs(healedTrail.fadeIn - 0.45) < 0.001)
        let beforeSplit = try #require(afterBothReopened.clips.first { abs($0.end - 8) < 0.001 })
        #expect(beforeSplit.lane == 0)
        #expect(abs(beforeSplit.start - 0) < 0.001)
        #expect(abs(beforeSplit.fadeOut - 0.35) < 0.001)

        // 6. Another video split afterward must STILL preserve the explicit audio split and fades at 8 s.
        let segA1a = RecordingClipSegment(sourceStart: 0, sourceEnd: 1)
        let segA1b = RecordingClipSegment(sourceStart: 1, sourceEnd: 2)
        let split1 = RecordingClipTimeline(segments: [segA1a, segA1b, segA2, segB])
        let afterLaterSplit = StudioAudioConform.conform(afterBothReopened.clips, hidden: afterBothReopened.hidden, from: reopenedBoth, to: split1)
        #expect(afterLaterSplit.clips.count == 2)
        let finalBefore = try #require(afterLaterSplit.clips.first { abs($0.end - 8) < 0.001 })
        let finalAfter = try #require(afterLaterSplit.clips.first { abs($0.start - 8) < 0.001 })
        #expect(abs(finalBefore.fadeOut - 0.35) < 0.001)
        #expect(abs(finalAfter.fadeIn - 0.45) < 0.001)
    }

    @Test func rippleDeleteConformsLinkedAndUnlinkedAudioClips() throws {
        // 1. Single 10 s clip with linked audio (0...10 s) and unlinked audio anchored at 6 s.
        let full = RecordingClipTimeline.full(sourceDuration: 10)
        var linked = RecordingAudioClip(fileName: "voice.wav", displayName: "Voice", start: 0, fileDuration: 10)
        linked.isLinked = true
        linked.fadeIn = 0.25
        linked.fadeOut = 0.35
        linked.lane = 0

        var music = RecordingAudioClip(fileName: "music.wav", displayName: "Music", start: 6.0, fileDuration: 2.0)
        music.isLinked = false
        music.lane = 1

        // Plain video split via RecordingClipTimeline.split(at:) keeps the leading segment ID
        // and must NOT store phantom hidden ranges for the still-visible trailing half.
        let splitAt5 = try #require(full.split(at: 5)).timeline
        let conformedSplit = StudioAudioConform.conform([linked], hidden: [], from: full, to: splitAt5)
        #expect(conformedSplit.clips.count == 1)
        #expect(conformedSplit.hidden.isEmpty)

        // Ripple-delete editor range 2...4 s: removes source 2...4 s, closing up 4...10 s to editor 2...8 s.
        let afterRipple = try #require(full.removingEditorRange(2.0...4.0))
        let conformed = StudioAudioConform.conform([linked, music], hidden: [], from: full, to: afterRipple)
        let linkedPieces = conformed.clips.filter(\.isLinked).sorted { $0.start < $1.start }
        #expect(linkedPieces.count == 2)
        #expect(abs(linkedPieces[0].start - 0) < 0.001 && abs(linkedPieces[0].end - 2) < 0.001)
        #expect(abs(linkedPieces[0].trimStart - 0) < 0.001 && abs(linkedPieces[0].trimEnd - 2) < 0.001)
        #expect(abs(linkedPieces[0].fadeIn - 0.25) < 0.001 && linkedPieces[0].fadeOut == 0)
        #expect(abs(linkedPieces[1].start - 2) < 0.001 && abs(linkedPieces[1].end - 8) < 0.001)
        #expect(abs(linkedPieces[1].trimStart - 4) < 0.001 && abs(linkedPieces[1].trimEnd - 10) < 0.001)
        #expect(linkedPieces[1].fadeIn == 0 && abs(linkedPieces[1].fadeOut - 0.35) < 0.001)
        // Hidden ranges record ONLY the removed 2...4 s gap (never the surviving 4...10 s).
        #expect(conformed.hidden.count == 1)
        #expect(abs(conformed.hidden[0].sourceStart - 2) < 0.001 && abs(conformed.hidden[0].sourceEnd - 4) < 0.001)

        // Unlinked clip stays whole (2 s) and shifts with its anchored footage moment (6 s -> 4 s).
        let unlinked = try #require(conformed.clips.first { !$0.isLinked })
        #expect(abs(unlinked.start - 4.0) < 0.001)
        #expect(abs(unlinked.duration - 2.0) < 0.001)

        // 2. Ripple-delete across a speed boundary (0...4 @ 1x + 4...10 @ 2x -> editor 0...7 s).
        let segA = RecordingClipSegment(sourceStart: 0, sourceEnd: 4, speed: 1)
        let segB = RecordingClipSegment(sourceStart: 4, sourceEnd: 10, speed: 2)
        let mixed = RecordingClipTimeline(segments: [segA, segB])
        var fastLinkedA = RecordingAudioClip(fileName: "narration.wav", displayName: "Narration", start: 0, fileDuration: 10)
        fastLinkedA.isLinked = true
        fastLinkedA.trimStart = 0
        fastLinkedA.trimEnd = 4
        var fastLinkedB = RecordingAudioClip(fileName: "narration.wav", displayName: "Narration", start: 4, fileDuration: 10)
        fastLinkedB.isLinked = true
        fastLinkedB.trimStart = 4
        fastLinkedB.trimEnd = 10
        fastLinkedB.speed = 2

        let mixedAfterRipple = try #require(mixed.removingEditorRange(2.5...5.5))
        let mixedConformed = StudioAudioConform.conform([fastLinkedA, fastLinkedB], hidden: [], from: mixed, to: mixedAfterRipple)
        let mixedPieces = mixedConformed.clips.sorted { $0.start < $1.start }
        #expect(mixedPieces.count == 2)
        #expect(abs(mixedPieces[0].start - 0) < 0.001 && abs(mixedPieces[0].end - 2.5) < 0.001)
        #expect(abs(mixedPieces[0].trimStart - 0) < 0.001 && abs(mixedPieces[0].trimEnd - 2.5) < 0.001)
        #expect(abs(mixedPieces[0].speed - 1) < 0.001)
        // Editor 5.5...7.0 in 2x segB corresponds to source 7...10 s, now at editor 2.5...4.0 s @ 2x.
        #expect(abs(mixedPieces[1].start - 2.5) < 0.001 && abs(mixedPieces[1].end - 4.0) < 0.001)
        #expect(abs(mixedPieces[1].trimStart - 7.0) < 0.001 && abs(mixedPieces[1].trimEnd - 10.0) < 0.001)
        #expect(abs(mixedPieces[1].speed - 2) < 0.001)
    }

    @Test func clipReorderConformsLinkedAndUnlinkedAudioAndPlaysInNewOrder() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Build a 4 s two-tone WAV: 440 Hz in 0...2 s, 880 Hz in 2...4 s.
        let sampleRate = 48_000.0
        let audioURL = dir.appendingPathComponent("two-tone.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let totalFrames = Int((4.0 * sampleRate).rounded())
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)))
        buffer.frameLength = AVAudioFrameCount(totalFrames)
        let samplesPtr = buffer.floatChannelData![0]
        for frame in 0..<totalFrames {
            let t = Double(frame) / sampleRate
            let freq = t < 2.0 ? 440.0 : 880.0
            samplesPtr[frame] = 0.5 * Float(sin(2 * .pi * freq * t))
        }
        let wav = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        try wav.write(from: buffer)
        wav.close()

        let full = RecordingClipTimeline.full(sourceDuration: 4)
        let split = try #require(full.split(at: 2.0)).timeline
        let segB = split.segments[1]

        var linked = RecordingAudioClip(fileName: "two-tone.wav", displayName: "Two Tone", start: 0, fileDuration: 4)
        linked.isLinked = true
        linked.fadeIn = 0.15
        linked.fadeOut = 0.25
        linked.lane = 0

        var unlinked = RecordingAudioClip(fileName: "two-tone.wav", displayName: "Stinger", start: 2.5, fileDuration: 0.8)
        unlinked.isLinked = false
        unlinked.lane = 1

        // Reorder segB (2...4 s) ahead of segA (0...2 s) via RecordingClipTimeline.moving(segmentID:to:).
        let reordered = try #require(split.moving(segmentID: segB.id, to: 0))
        let conformed = StudioAudioConform.conform([linked, unlinked], hidden: [], from: split, to: reordered)
        #expect(conformed.hidden.isEmpty)

        let linkedPieces = conformed.clips.filter(\.isLinked).sorted { $0.start < $1.start }
        #expect(linkedPieces.count == 2)
        // First on the reordered timeline (editor 0...2 s) is segB's 2...4 s slice (880 Hz).
        #expect(linkedPieces[0].lane == 0)
        #expect(abs(linkedPieces[0].start - 0) < 0.001 && abs(linkedPieces[0].end - 2) < 0.001)
        #expect(abs(linkedPieces[0].trimStart - 2) < 0.001 && abs(linkedPieces[0].trimEnd - 4) < 0.001)
        #expect(linkedPieces[0].fadeIn == 0 && abs(linkedPieces[0].fadeOut - 0.25) < 0.001)
        // Second (editor 2...4 s) is segA's 0...2 s slice (440 Hz).
        #expect(linkedPieces[1].lane == 0)
        #expect(abs(linkedPieces[1].start - 2) < 0.001 && abs(linkedPieces[1].end - 4) < 0.001)
        #expect(abs(linkedPieces[1].trimStart - 0) < 0.001 && abs(linkedPieces[1].trimEnd - 2) < 0.001)
        #expect(abs(linkedPieces[1].fadeIn - 0.15) < 0.001 && linkedPieces[1].fadeOut == 0)

        // Unlinked clip anchored at source 2.5 s (0.5 s into segB) moves to editor 0.5 s.
        let movedUnlinked = try #require(conformed.clips.first { !$0.isLinked })
        #expect(abs(movedUnlinked.start - 0.5) < 0.001)
        #expect(abs(movedUnlinked.duration - 0.8) < 0.001)

        // Audio clip edges surface in both clipSnapPoints and editPoints.
        let edges = linkedPieces.flatMap { [$0.start, $0.end] }
        let snapPoints = StudioEditing.clipSnapPoints(markers: [], recordedClicks: [], audioClipEdges: edges)
        #expect(snapPoints.contains { abs($0 - 2.0) < 0.001 })
        let editPoints = StudioEditing.editPoints(timeline: reordered, markerTimes: [], audioClipEdges: [movedUnlinked.start, movedUnlinked.end], duration: reordered.duration)
        #expect(editPoints.contains { abs($0 - 0.5) < 0.001 })
        #expect(editPoints.contains { abs($0 - 1.3) < 0.001 })

        // Verify actual rendered mix plays 880 Hz first (0.5...1.5 s) and 440 Hz second (2.5...3.5 s).
        let silentScreen = try makeTone(in: dir, name: "screen-silent", frequency: 100, amplitude: 0, duration: 4.0)
        let built = try await StudioAudioComposer.prepareExport(
            screenAsset: AVURLAsset(url: silentScreen),
            screenURL: silentScreen,
            timeline: reordered,
            replacementURL: nil,
            replacementSync: nil,
            clips: linkedPieces,
            mediaDirectory: dir,
            volume: 0,
            microphoneTrackID: nil,
            isolatedMicrophoneURL: nil,
            backgroundMusic: nil
        )
        let rendered = try await renderMonoSamples(asset: built.composition, mix: built.mix, duration: 4.0)
        #expect(goertzel(rendered, at: 0.5, length: 0.5, frequency: 880) > 0.25)
        #expect(goertzel(rendered, at: 0.5, length: 0.5, frequency: 440) < 0.05)
        #expect(goertzel(rendered, at: 2.5, length: 0.5, frequency: 440) > 0.25)
        #expect(goertzel(rendered, at: 2.5, length: 0.5, frequency: 880) < 0.05)
    }

    @Test func trimHidingExplicitAudioSplitReopensSplitAndMutedSecondHalf() throws {
        let seg = RecordingClipSegment(sourceStart: 0, sourceEnd: 10)
        let full = RecordingClipTimeline(segments: [seg])

        // 1. Link one 10 s audio clip, split audio at 5 s, and mute the second half (no fades).
        var linked = RecordingAudioClip(fileName: "voice.wav", displayName: "Voice", start: 0, fileDuration: 10)
        linked.isLinked = true
        let halves = try #require(StudioAudioConform.split(linked, at: 5))
        let firstHalf = halves.leading
        var secondHalf = halves.trailing
        secondHalf.isMuted = true

        // 2. Trim the video end to 4 s, completely hiding the 5 s split and muted second half.
        var trimmedSeg = seg
        trimmedSeg.sourceEnd = 4
        let trimmed4 = RecordingClipTimeline(segments: [trimmedSeg])
        let afterTrim = StudioAudioConform.conform([firstHalf, secondHalf], hidden: [], from: full, to: trimmed4)
        #expect(afterTrim.clips.count == 1)
        #expect(abs(afterTrim.clips[0].start - 0) < 0.001 && abs(afterTrim.clips[0].end - 4) < 0.001)
        #expect(!afterTrim.clips[0].isMuted)

        // 3. Reopen the video end directly to 10 s: the explicit split at 5 s AND the
        //    muted second half (5...10 s) must come back intact as two separate pieces.
        let afterReopen = StudioAudioConform.conform(afterTrim.clips, hidden: afterTrim.hidden, from: trimmed4, to: full)
        let reopened = afterReopen.clips.sorted { $0.start < $1.start }
        try #require(reopened.count == 2)
        #expect(afterReopen.hidden.isEmpty)
        #expect(reopened[0].lane == 0)
        #expect(abs(reopened[0].start - 0) < 0.001 && abs(reopened[0].end - 5) < 0.001)
        #expect(!reopened[0].isMuted)
        #expect(reopened[0].keepsTrailingSplit)
        #expect(reopened[1].lane == 0)
        #expect(abs(reopened[1].start - 5) < 0.001 && abs(reopened[1].end - 10) < 0.001)
        #expect(reopened[1].isMuted)
        #expect(reopened[1].keepsLeadingSplit)

        // 4. Two-step reopen (4 -> 7 -> 10 s) also preserves the split and muted second half.
        var midSeg = seg
        midSeg.sourceEnd = 7
        let mid7 = RecordingClipTimeline(segments: [midSeg])
        let afterMid = StudioAudioConform.conform(afterTrim.clips, hidden: afterTrim.hidden, from: trimmed4, to: mid7)
        let midClips = afterMid.clips.sorted { $0.start < $1.start }
        try #require(midClips.count == 2)
        #expect(abs(midClips[0].start - 0) < 0.001 && abs(midClips[0].end - 5) < 0.001 && !midClips[0].isMuted)
        #expect(abs(midClips[1].start - 5) < 0.001 && abs(midClips[1].end - 7) < 0.001 && midClips[1].isMuted)

        let afterFull = StudioAudioConform.conform(afterMid.clips, hidden: afterMid.hidden, from: mid7, to: full)
        let fullClips = afterFull.clips.sorted { $0.start < $1.start }
        try #require(fullClips.count == 2)
        #expect(afterFull.hidden.isEmpty)
        #expect(abs(fullClips[0].start - 0) < 0.001 && abs(fullClips[0].end - 5) < 0.001 && !fullClips[0].isMuted)
        #expect(abs(fullClips[1].start - 5) < 0.001 && abs(fullClips[1].end - 10) < 0.001 && fullClips[1].isMuted)
    }

    @Test func rippleGapRestoresHiddenLinkedAudioFromEitherSide() throws {
        // Put a linked clip entirely at 2.5...3.0 s under one 10 s video and ripple-delete 2...4 s.
        let full = RecordingClipTimeline.full(sourceDuration: 10)
        var linked = RecordingAudioClip(fileName: "sfx.wav", displayName: "SFX", start: 2.5, fileDuration: 0.5)
        linked.isLinked = true
        linked.volume = 0.8

        let afterRipple = try #require(full.removingEditorRange(2.0...4.0))
        try #require(afterRipple.segments.count == 2)
        let leftSeg = afterRipple.segments[0]
        let rightSeg = afterRipple.segments[1]

        let conformedRipple = StudioAudioConform.conform([linked], hidden: [], from: full, to: afterRipple)
        #expect(conformedRipple.clips.isEmpty)
        try #require(conformedRipple.hidden.count == 1)

        // 1. Reopen the RIGHT video piece's leading edge from source 4 s to 2 s:
        //    the hidden clip at 2.5...3.0 s must restore on the right piece.
        var reopenedRightSeg = rightSeg
        reopenedRightSeg.sourceStart = 2.0
        let reopenedFromRight = RecordingClipTimeline(segments: [leftSeg, reopenedRightSeg])
        let restoredRight = StudioAudioConform.conform(
            conformedRipple.clips,
            hidden: conformedRipple.hidden,
            from: afterRipple,
            to: reopenedFromRight
        )
        try #require(restoredRight.clips.count == 1)
        #expect(restoredRight.hidden.isEmpty)
        #expect(abs(restoredRight.clips[0].start - 2.5) < 0.001)
        #expect(abs(restoredRight.clips[0].end - 3.0) < 0.001)
        #expect(abs(restoredRight.clips[0].volume - 0.8) < 0.001)

        // 2. Delete the LEFT video piece so only the right survives: the hidden interval
        //    stays alive on the surviving right side and restores when right reopens to 2 s.
        let rightOnly = try #require(afterRipple.deleting(segmentID: leftSeg.id))
        let afterDeleteLeft = StudioAudioConform.conform(
            conformedRipple.clips,
            hidden: conformedRipple.hidden,
            from: afterRipple,
            to: rightOnly
        )
        try #require(afterDeleteLeft.hidden.count == 1)
        let reopenedRightOnly = RecordingClipTimeline(segments: [reopenedRightSeg])
        let restoredRightOnly = StudioAudioConform.conform(
            afterDeleteLeft.clips,
            hidden: afterDeleteLeft.hidden,
            from: rightOnly,
            to: reopenedRightOnly
        )
        try #require(restoredRightOnly.clips.count == 1)
        #expect(restoredRightOnly.hidden.isEmpty)
        #expect(abs(restoredRightOnly.clips[0].start - 0.5) < 0.001)
        #expect(abs(restoredRightOnly.clips[0].end - 1.0) < 0.001)

        // 3. Partial reopen from BOTH sides: right opens 4 -> 2.7 s (revealing 2.7...3.0 s),
        //    then left opens 2 -> 2.7 s (revealing 2.5...2.7 s) and heals into one 2.5...3.0 s clip.
        var rightAt27 = rightSeg
        rightAt27.sourceStart = 2.7
        let partialRight = RecordingClipTimeline(segments: [leftSeg, rightAt27])
        let afterPartialRight = StudioAudioConform.conform(
            conformedRipple.clips,
            hidden: conformedRipple.hidden,
            from: afterRipple,
            to: partialRight
        )
        try #require(afterPartialRight.clips.count == 1)
        #expect(abs(afterPartialRight.clips[0].start - 2.0) < 0.001)
        #expect(abs(afterPartialRight.clips[0].end - 2.3) < 0.001)
        try #require(afterPartialRight.hidden.count == 1)

        var leftAt27 = leftSeg
        leftAt27.sourceEnd = 2.7
        let metAt27 = RecordingClipTimeline(segments: [leftAt27, rightAt27])
        let afterMet = StudioAudioConform.conform(
            afterPartialRight.clips,
            hidden: afterPartialRight.hidden,
            from: partialRight,
            to: metAt27
        )
        try #require(afterMet.clips.count == 1)
        #expect(afterMet.hidden.isEmpty)
        #expect(abs(afterMet.clips[0].start - 2.5) < 0.001)
        #expect(abs(afterMet.clips[0].end - 3.0) < 0.001)
    }

    @Test func importedAudioRejectsSymlinkedFileAndMediaRootWhileLoadingRegularWAV() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let package = root.appendingPathComponent("take.sukushorec", isDirectory: true)
        let mediaDir = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

        let screenURL = try makeTone(in: package, name: "screen.wav", frequency: 220, amplitude: 0.2, duration: 3)
        let screenAsset = AVURLAsset(url: screenURL)
        let timeline = RecordingClipTimeline.full(sourceDuration: 3)

        let normalSource = try makeTone(in: outside, name: "normal.wav", frequency: 440, amplitude: 0.4, duration: 2)
        let linkedSource = outside.appendingPathComponent("linked-source.wav")
        try FileManager.default.createSymbolicLink(at: linkedSource, withDestinationURL: normalSource)

        // 1. Picker / Finder copy path: normal WAV copies into a real package media root and loads cleanly.
        let copiedName = try #require(RecordingOverlayMedia.copyRegularFile(from: normalSource, into: mediaDir))
        #expect(RecordingOverlayMedia.resolveRegularFile(named: copiedName, in: mediaDir) != nil)
        let normalClip = RecordingAudioClip(fileName: copiedName, displayName: "Normal WAV", start: 0, fileDuration: 2)
        let loadedNormal = try await StudioAudioSources.load(
            screenAsset: screenAsset,
            replacementURL: nil,
            clips: [normalClip],
            mediaDirectory: mediaDir,
            timeline: timeline,
            strictMissingClips: true
        )
        #expect(!(loadedNormal.files[copiedName] ?? []).isEmpty)

        // 2. Symlinked source WAV is rejected by the copier (never creates a link in media/).
        #expect(RecordingOverlayMedia.copyRegularFile(from: linkedSource, into: mediaDir) == nil)

        // 3. Symlinked WAV placed directly inside media/ is rejected by resolver and render source loader
        //    with the named missingAudioClip failure for an audible clip.
        let linkedInMedia = mediaDir.appendingPathComponent("escaped.wav")
        try FileManager.default.createSymbolicLink(at: linkedInMedia, withDestinationURL: normalSource)
        #expect(RecordingOverlayMedia.resolveRegularFile(named: "escaped.wav", in: mediaDir) == nil)
        let linkedClip = RecordingAudioClip(fileName: "escaped.wav", displayName: "Escaped WAV", start: 0, fileDuration: 2)
        let nonStrictLinked = try await StudioAudioSources.load(
            screenAsset: screenAsset,
            replacementURL: nil,
            clips: [linkedClip],
            mediaDirectory: mediaDir,
            timeline: timeline,
            strictMissingClips: false
        )
        #expect(nonStrictLinked.files["escaped.wav"] == nil)
        do {
            _ = try await StudioAudioSources.load(
                screenAsset: screenAsset,
                replacementURL: nil,
                clips: [linkedClip],
                mediaDirectory: mediaDir,
                timeline: timeline,
                strictMissingClips: true
            )
            Issue.record("Expected missingAudioClip for symlinked audio file inside media/")
        } catch StudioAudioComposer.AudioError.missingAudioClip(let name) {
            #expect(name == "Escaped WAV")
        }

        // 4. Symlinked media root directory is rejected by copier, resolver, and render source loader.
        let linkedPackage = root.appendingPathComponent("linked-pkg.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedPackage, withIntermediateDirectories: true)
        let linkedMediaDir = linkedPackage.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedMediaDir, withDestinationURL: outside)

        #expect(RecordingOverlayMedia.copyRegularFile(from: normalSource, into: linkedMediaDir) == nil)
        #expect(RecordingOverlayMedia.resolveRegularFile(named: "normal.wav", in: linkedMediaDir) == nil)
        let linkedRootClip = RecordingAudioClip(fileName: "normal.wav", displayName: "Linked Root WAV", start: 0, fileDuration: 2)
        let nonStrictRoot = try await StudioAudioSources.load(
            screenAsset: screenAsset,
            replacementURL: nil,
            clips: [linkedRootClip],
            mediaDirectory: linkedMediaDir,
            timeline: timeline,
            strictMissingClips: false
        )
        #expect(nonStrictRoot.files["normal.wav"] == nil)
        do {
            _ = try await StudioAudioSources.load(
                screenAsset: screenAsset,
                replacementURL: nil,
                clips: [linkedRootClip],
                mediaDirectory: linkedMediaDir,
                timeline: timeline,
                strictMissingClips: true
            )
            Issue.record("Expected missingAudioClip for symlinked media root directory")
        } catch StudioAudioComposer.AudioError.missingAudioClip(let name) {
            #expect(name == "Linked Root WAV")
        }
    }

    @Test func finderAudioDropTargetsHighlightedLowerLaneAndKeepsCollisionPolicy() throws {
        // Both Audio 1 (lane 0) and Audio 2 (lane 1) exist and are free at t = 2...4.
        var lane0Clip = RecordingAudioClip(fileName: "a.wav", displayName: "A", start: 0, fileDuration: 1)
        lane0Clip.lane = 0
        var lane1Clip = RecordingAudioClip(fileName: "b.wav", displayName: "B", start: 0, fileDuration: 1)
        lane1Clip.lane = 1
        let existing = [lane0Clip, lane1Clip]

        // Dropping onto Audio 2 (preferredLane = 1) lands on lane 1 even though lane 0 is free at 2...4.
        let droppedOnLower = RecordingAudioClip(fileName: "c.wav", displayName: "C", start: 2, fileDuration: 2)
        let afterLowerDrop = StudioAudioConform.inserting(droppedOnLower, into: existing, preferredLane: 1)
        let placedC = try #require(afterLowerDrop.first { $0.id == droppedOnLower.id })
        #expect(placedC.lane == 1)
        #expect(afterLowerDrop.first { $0.id == lane0Clip.id }?.lane == 0)
        #expect(afterLowerDrop.first { $0.id == lane1Clip.id }?.lane == 1)

        // A second clip dropped sequentially onto Audio 2 at 4...5 also lands on lane 1.
        let secondDropped = RecordingAudioClip(fileName: "d.wav", displayName: "D", start: 4, fileDuration: 1)
        let afterSecond = StudioAudioConform.inserting(secondDropped, into: afterLowerDrop, preferredLane: 1)
        #expect(afterSecond.first { $0.id == secondDropped.id }?.lane == 1)

        // Collision policy: dropping an overlapping clip onto occupied Audio 2 (0.5...2.5)
        // keeps existing Audio 2 clips on lane 1 and moves the newly dropped clip down to lane 2.
        let overlapping = RecordingAudioClip(fileName: "e.wav", displayName: "E", start: 0.5, fileDuration: 2)
        let afterCollision = StudioAudioConform.inserting(overlapping, into: afterSecond, preferredLane: 1)
        #expect(afterCollision.first { $0.id == lane1Clip.id }?.lane == 1)
        #expect(afterCollision.first { $0.id == droppedOnLower.id }?.lane == 1)
        #expect(afterCollision.first { $0.id == overlapping.id }?.lane == 2)
    }

    // MARK: - Helpers

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StudioAudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTone(
        in directory: URL,
        name: String,
        frequency: Double,
        amplitude: Float,
        duration: Double,
        active: ((Double) -> Bool)? = nil
    ) throws -> URL {
        let url = name.hasSuffix(".wav")
            ? directory.appendingPathComponent(name)
            : directory.appendingPathComponent(name).appendingPathExtension("wav")
        let sampleRate = 48_000.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let count = Int((duration * sampleRate).rounded())
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let data = buffer.floatChannelData![0]
        for frame in 0..<count {
            let t = Double(frame) / sampleRate
            let isOn = active?(t) ?? true
            data[frame] = isOn ? amplitude * Float(sin(2 * .pi * frequency * t)) : 0
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
        return url
    }

    private func writeDualTrackAudioMovie(systemURL: URL, micURL: URL, to destination: URL) async throws -> CMPersistentTrackID {
        let composition = AVMutableComposition()
        let systemAsset = AVURLAsset(url: systemURL)
        let micAsset = AVURLAsset(url: micURL)
        let systemTrack = try #require(try await systemAsset.loadTracks(withMediaType: .audio).first)
        let micTrack = try #require(try await micAsset.loadTracks(withMediaType: .audio).first)
        let duration = try await systemAsset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)

        let dstSystem = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 1))
        let dstMic = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 2))
        try dstSystem.insertTimeRange(range, of: systemTrack, at: .zero)
        try dstMic.insertTimeRange(range, of: micTrack, at: .zero)

        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: destination, as: .mov)
        let writtenTracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio)
        return try #require(RecordingVoiceIsolation.microphoneTrack(
            in: writtenTracks,
            includesMicrophone: true,
            includesSystemAudio: true
        )?.trackID)
    }

    private func renderMonoSamples(asset: AVAsset, mix: AVAudioMix?, duration: TimeInterval) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix
        reader.add(output)
        #expect(reader.startReading())
        var result: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                result.append(contentsOf: UnsafeBufferPointer(start: samples, count: length / 4))
            }
        }
        #expect(reader.status != .failed)
        return result
    }

    private func peakAmplitude(in samples: [Float], from start: Double, to end: Double, sampleRate: Double) -> Float {
        let low = max(0, Int((start * sampleRate).rounded()))
        let high = min(samples.count, Int((end * sampleRate).rounded()))
        guard high > low else { return 0 }
        var peak: Float = 0
        for i in low..<high { peak = max(peak, abs(samples[i])) }
        return peak
    }

    private func goertzel(_ samples: [Float], at start: Double, length: Double, frequency: Double, sampleRate: Double = 48_000) -> Double {
        let low = max(0, Int((start * sampleRate).rounded()))
        let count = max(1, min(samples.count - low, Int((length * sampleRate).rounded())))
        let omega = 2 * Double.pi * frequency / sampleRate
        let coeff = 2 * cos(omega)
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for i in 0..<count {
            s0 = Double(samples[low + i]) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return 2 * sqrt(max(0, power)) / Double(count)
    }
}
