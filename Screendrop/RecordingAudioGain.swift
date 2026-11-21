import AVFoundation
import AudioToolbox
import MediaToolbox

/// Shared by player items and both export paths. A processing tap supports
/// amplification above unity, unlike AVAudioMix's 0...1 volume parameter.
nonisolated enum RecordingAudioGain {
    static func normalized(_ volume: Double) -> Double {
        volume.isFinite ? min(2, max(0, volume)) : 1
    }

    static func makeMix(tracks: [AVAssetTrack], volume: Double) -> AVAudioMix? {
        let parameters = inputParameters(tracks: tracks, volume: volume)
        guard !parameters.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    /// The parameters that apply `volume` to each track; empty at unity,
    /// which needs none. Shared with mixes that carry other tracks too.
    static func inputParameters(tracks: [AVAssetTrack], volume: Double) -> [AVMutableAudioMixInputParameters] {
        let gain = Float(normalized(volume))
        guard gain != 1 else { return [] }
        return tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            if gain <= 1 {
                parameters.setVolume(gain, at: .zero)
            } else {
                parameters.audioTapProcessor = makeTap(gain: gain)
            }
            return parameters
        }
    }

    private final class State {
        let gain: Float
        var format = AudioStreamBasicDescription()
        init(gain: Float) { self.gain = gain }
    }

    static func makeTap(gain: Float) -> MTAudioProcessingTap? {
        let storage = Unmanaged.passRetained(State(gain: gain)).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: storage,
            init: { _, clientInfo, tapStorage in tapStorage.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let state = Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                state.format = format.pointee
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut)
                guard status == noErr else { framesOut.pointee = 0; return }
                let state = Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let format = state.format
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    guard let data = buffer.mData else { continue }
                    let bytes = Int(buffer.mDataByteSize)
                    if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                        if format.mBitsPerChannel == 32 {
                            let samples = data.assumingMemoryBound(to: Float.self)
                            for i in 0..<(bytes / 4) { samples[i] = min(1, max(-1, samples[i] * state.gain)) }
                        } else if format.mBitsPerChannel == 64 {
                            let samples = data.assumingMemoryBound(to: Double.self)
                            for i in 0..<(bytes / 8) { samples[i] = min(1, max(-1, samples[i] * Double(state.gain))) }
                        }
                    } else if format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
                        if format.mBitsPerChannel == 16 {
                            let samples = data.assumingMemoryBound(to: Int16.self)
                            for i in 0..<(bytes / 2) {
                                samples[i] = Int16(min(Double(Int16.max), max(Double(Int16.min), Double(samples[i]) * Double(state.gain))))
                            }
                        } else if format.mBitsPerChannel == 32 {
                            let samples = data.assumingMemoryBound(to: Int32.self)
                            for i in 0..<(bytes / 4) {
                                samples[i] = Int32(min(Double(Int32.max), max(Double(Int32.min), Double(samples[i]) * Double(state.gain))))
                            }
                        }
                    }
                }
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                               kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr else {
            Unmanaged<State>.fromOpaque(storage).release()
            return nil
        }
        return tap
    }

    // MARK: Envelope

    /// A stretch of a track and the gain it plays at, sliding evenly from
    /// `startGain` to `endGain`.
    struct EnvelopeSpan: Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var startGain: Float
        var endGain: Float
    }

    private final class EnvelopeState {
        let spans: [EnvelopeSpan]
        var format = AudioStreamBasicDescription()
        /// Where the last lookup landed; audio arrives in order, so the
        /// next one is almost always the same span or the one after.
        var cursor = 0
        init(spans: [EnvelopeSpan]) { self.spans = spans }

        func gain(at time: Double) -> Float {
            guard !spans.isEmpty else { return 1 }
            if cursor >= spans.count || time < spans[cursor].start { cursor = 0 }
            while cursor < spans.count - 1, time >= spans[cursor].end { cursor += 1 }
            let span = spans[cursor]
            // Between two sounds there is nothing to play; before the
            // first and after the last, hold the nearest level.
            if time <= span.start { return span.startGain }
            if time >= span.end { return span.endGain }
            let progress = Float((time - span.start) / max(span.end - span.start, 0.000_001))
            return span.startGain + (span.endGain - span.startGain) * progress
        }
    }

    /// Evaluates the gain an envelope tap applies at `time`.
    static func envelopeGain(at time: Double, in spans: [EnvelopeSpan]) -> Float {
        let sorted = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        return EnvelopeState(spans: sorted).gain(at: time)
    }

    /// A tap that plays a track at a gain that changes over time, exact to
    /// the sample. The mix's own volume ramps can't do this: they smear a
    /// change over the audio around it, so a muted clip would fade into its
    /// neighbour instead of ending at the cut. Gains above 1 amplify.
    static func makeEnvelopeTap(spans: [EnvelopeSpan]) -> MTAudioProcessingTap? {
        let sorted = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        let storage = Unmanaged.passRetained(EnvelopeState(spans: sorted)).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: storage,
            init: { _, clientInfo, tapStorage in tapStorage.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<EnvelopeState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let state = Unmanaged<EnvelopeState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                state.format = format.pointee
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                var range = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, framesOut)
                guard status == noErr else { framesOut.pointee = 0; return }
                let count = Int(framesOut.pointee)
                guard count > 0, range.start.isNumeric else { return }
                let state = Unmanaged<EnvelopeState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let format = state.format
                let start = range.start.seconds
                let duration = range.duration.isNumeric && range.duration.seconds > 0
                    ? range.duration.seconds
                    : Double(count) / max(format.mSampleRate, 1)
                applyEnvelope(
                    to: buffers,
                    frameCount: count,
                    startTime: start,
                    duration: duration,
                    format: format,
                    gainAt: { state.gain(at: $0) }
                )
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                               kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr else {
            Unmanaged<EnvelopeState>.fromOpaque(storage).release()
            return nil
        }
        return tap
    }

    /// Applies `gainAt` sample-by-sample across an `AudioBufferList` honoring
    /// the prepared ASBD's frame byte stride, interleaving, bit depth,
    /// alignment, and endianness without allocating or locking.
    static func applyEnvelope(
        to buffers: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int,
        startTime: Double,
        duration: Double,
        format: AudioStreamBasicDescription,
        gainAt: (Double) -> Float
    ) {
        guard frameCount > 0 else { return }
        let step = duration / Double(frameCount)
        let flags = format.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSigned = flags & kAudioFormatFlagIsSignedInteger != 0
        let isBigEndian = flags & kAudioFormatFlagIsBigEndian != 0
        let isAlignedHigh = flags & kAudioFormatFlagIsAlignedHigh != 0
        let isNonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let bits = Int(format.mBitsPerChannel)

        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let frameStride: Int
            if format.mBytesPerFrame > 0 {
                frameStride = Int(format.mBytesPerFrame)
            } else {
                frameStride = max(1, (bits + 7) / 8) * channels
            }
            let bytesPerSample = isNonInterleaved ? frameStride : (frameStride / channels)
            guard bytesPerSample > 0, frameStride >= bytesPerSample * channels else { continue }
            let available = Int(buffer.mDataByteSize) / frameStride
            let totalFrames = min(frameCount, available)
            guard totalFrames > 0 else { continue }

            for frame in 0..<totalFrames {
                let gain = gainAt(startTime + Double(frame) * step)
                if gain == 1 { continue }
                let frameBase = data + frame * frameStride
                for channel in 0..<channels {
                    let ptr = frameBase + channel * bytesPerSample
                    if isFloat, bits == 32, bytesPerSample == 4 {
                        let raw = ptr.loadUnaligned(as: UInt32.self)
                        let sample = Float(bitPattern: isBigEndian ? UInt32(bigEndian: raw) : UInt32(littleEndian: raw))
                        let scaled = min(1, max(-1, sample * gain)).bitPattern
                        ptr.storeBytes(of: isBigEndian ? scaled.bigEndian : scaled.littleEndian, as: UInt32.self)
                    } else if isFloat, bits == 64, bytesPerSample == 8 {
                        let raw = ptr.loadUnaligned(as: UInt64.self)
                        let sample = Double(bitPattern: isBigEndian ? UInt64(bigEndian: raw) : UInt64(littleEndian: raw))
                        let scaled = min(1, max(-1, sample * Double(gain))).bitPattern
                        ptr.storeBytes(of: isBigEndian ? scaled.bigEndian : scaled.littleEndian, as: UInt64.self)
                    } else if isSigned, bits == 16, bytesPerSample == 2 {
                        let raw = ptr.loadUnaligned(as: Int16.self)
                        let sample = isBigEndian ? Int16(bigEndian: raw) : Int16(littleEndian: raw)
                        let scaled = Int16(min(Double(Int16.max), max(Double(Int16.min), (Double(sample) * Double(gain)).rounded())))
                        ptr.storeBytes(of: isBigEndian ? scaled.bigEndian : scaled.littleEndian, as: Int16.self)
                    } else if isSigned, bits == 24, bytesPerSample == 3 {
                        let bytes = ptr.assumingMemoryBound(to: UInt8.self)
                        let raw: Int32 = isBigEndian
                            ? (Int32(bytes[0]) << 16) | (Int32(bytes[1]) << 8) | Int32(bytes[2])
                            : Int32(bytes[0]) | (Int32(bytes[1]) << 8) | (Int32(bytes[2]) << 16)
                        let signed = (raw << 8) >> 8
                        let clamped = Int32(min(8_388_607.0, max(-8_388_608.0, (Double(signed) * Double(gain)).rounded())))
                        let u = UInt32(bitPattern: clamped)
                        if isBigEndian {
                            bytes[0] = UInt8((u >> 16) & 0xFF)
                            bytes[1] = UInt8((u >> 8) & 0xFF)
                            bytes[2] = UInt8(u & 0xFF)
                        } else {
                            bytes[0] = UInt8(u & 0xFF)
                            bytes[1] = UInt8((u >> 8) & 0xFF)
                            bytes[2] = UInt8((u >> 16) & 0xFF)
                        }
                    } else if isSigned, bytesPerSample == 4, (bits == 32 || bits == 24) {
                        let raw = ptr.loadUnaligned(as: Int32.self)
                        let host = isBigEndian ? Int32(bigEndian: raw) : Int32(littleEndian: raw)
                        let scaledHost: Int32
                        if bits == 32 {
                            scaledHost = Int32(min(Double(Int32.max), max(Double(Int32.min), (Double(host) * Double(gain)).rounded())))
                        } else if isAlignedHigh {
                            let sample24 = host >> 8
                            let clamped = Int32(min(8_388_607.0, max(-8_388_608.0, (Double(sample24) * Double(gain)).rounded())))
                            scaledHost = clamped << 8
                        } else {
                            let sample24 = (host << 8) >> 8
                            scaledHost = Int32(min(8_388_607.0, max(-8_388_608.0, (Double(sample24) * Double(gain)).rounded())))
                        }
                        ptr.storeBytes(of: isBigEndian ? scaledHost.bigEndian : scaledHost.littleEndian, as: Int32.self)
                    } else if gain < 0.000_1 {
                        // A format this can't scale still goes silent where it
                        // should using the container's exact sample stride.
                        memset(ptr, 0, bytesPerSample)
                    }
                }
            }
        }
    }
}
