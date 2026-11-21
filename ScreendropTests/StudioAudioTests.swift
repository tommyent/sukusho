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
