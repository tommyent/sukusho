//
//  RecordingVideoOverlay.swift
//  Screendrop
//
//  Video clips layered over a Studio recording: picture-in-picture or full-card
//  B-roll cutaways. Like audio clips, each lives on the edited timeline's clock
//  so it can span cuts cleanly. One non-overlapping lane keeps playback and
//  export memory bounded (one recycled AVPlayer in preview, one on-demand
//  AVAssetReader in export).
//

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import UniformTypeIdentifiers

// MARK: - Model

nonisolated struct RecordingVideoOverlay: Identifiable, Codable, Equatable, Hashable, Sendable {
    enum Presentation: String, Codable, CaseIterable, Identifiable, Sendable {
        case pip
        case cutaway

        var id: Self { self }

        var title: String {
            switch self {
            case .pip: "PiP"
            case .cutaway: "Cutaway"
            }
        }

        var systemImage: String {
            switch self {
            case .pip: "pip"
            case .cutaway: "rectangle.inset.filled"
            }
        }
    }

    enum CutawayContentMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case fill
        case fit

        var id: Self { self }

        var title: String {
            switch self {
            case .fill: "Fill"
            case .fit: "Fit"
            }
        }
    }

    static let minimumDuration: TimeInterval = 0.1
    static let minimumFileSpan: TimeInterval = 0.006
    static let widthRange: ClosedRange<Double> = 0.05...1.5
    static let cornerRadiusRange: ClosedRange<Double> = 0...200
    static let fadeRange: ClosedRange<TimeInterval> = 0...2
    static let audioFadeRange: ClosedRange<TimeInterval> = 0...5
    static let volumeRange: ClosedRange<Double> = 0...2
    /// User-selectable speed range in the inspector and timeline menu.
    static let speedRange: ClosedRange<Double> = 0.25...8
    /// Derived playback speed range after linked main-track retiming (matches `RecordingAudioClip.derivedSpeedRange`).
    static let derivedSpeedRange: ClosedRange<Double> = 0.03...64
    static let speedPresets: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    static let defaultCutawayFade: TimeInterval = 0.25

    /// Initial PiP width fraction: at most 36% of the canvas wide and 45% tall.
    static func initialWidth(aspect: Double, canvasSize: CGSize) -> Double {
        guard aspect.isFinite, aspect > 0 else { return 0.36 }
        let heightLimited = canvasSize.width > 0 ? 0.45 * canvasSize.height * aspect / canvasSize.width : 0.36
        return min(0.36, max(heightLimited, widthRange.lowerBound))
    }

    /// Default PiP corner center that stays clear of a bottom-right camera bubble.
    static func initialCenter(cameraVisible: Bool) -> CGPoint {
        cameraVisible ? CGPoint(x: 0.78, y: 0.24) : CGPoint(x: 0.78, y: 0.74)
    }

    static func sanitizedWidth(_ rawWidth: Double, fallback: Double = 0.32) -> Double {
        guard rawWidth.isFinite, rawWidth > 0 else { return fallback }
        return min(max(rawWidth, widthRange.lowerBound), widthRange.upperBound)
    }

    var id = UUID()
    /// Copy inside the project's `media` directory.
    var fileName: String
    /// Original name shown on the timeline and inspector.
    var displayName: String
    /// Start time on the edited timeline clock.
    var start: TimeInterval
    /// Source-file in-point.
    var trimStart: TimeInterval = 0
    /// Source-file out-point.
    var trimEnd: TimeInterval
    /// Intrinsic file duration; trims never open past `[0, fileDuration]`.
    var fileDuration: TimeInterval
    /// Source seconds played per edited second.
    var speed: Double = 1

    var presentation: Presentation = .pip
    /// PiP center in normalized `[0, 1]` canvas coordinates. Preserved when switching to Cutaway.
    var center = CGPoint(x: 0.78, y: 0.74)
    /// PiP width as a fraction of the canvas width; height follows `aspect`.
    var width: Double = 0.32
    /// Display width / height (incorporating the video track's `preferredTransform`).
    var aspect: Double = 16.0 / 9.0
    /// PiP clockwise rotation in degrees.
    var rotation: Double = 0
    var opacity: Double = 1
    /// PiP corner radius in pixels of a 1080p canvas.
    var cornerRadius: Double = 16
    /// PiP drop shadow strength, `0...1`.
    var shadow: Double = 0.45
    /// Visual fade-in / crossfade-in duration in edited seconds.
    var fadeIn: TimeInterval = 0
    /// Visual fade-out / crossfade-out duration in edited seconds.
    var fadeOut: TimeInterval = 0
    var cutawayContentMode: CutawayContentMode = .fill

    /// Sound gain `0...2` (1 = 100%).
    var volume: Double = 1
    /// Picture-in-picture defaults unmuted (100%); cutaways default muted.
    var isMuted: Bool = false
    var audioFadeIn: TimeInterval = 0
    var audioFadeOut: TimeInterval = 0
    /// Whether the source movie carries an audio track.
    var hasAudio: Bool = true
    /// Linked overlays cut, trim, and retime with the main video beneath them;
    /// unlinked overlays stay whole and follow the footage moment under their start.
    var isLinked: Bool = true

    var fileSpan: TimeInterval { max(0, trimEnd - trimStart) }
    var duration: TimeInterval { fileSpan / max(speed, 0.01) }
    var end: TimeInterval { start + duration }
    var audibleVolume: Double {
        isMuted ? 0 : min(max(volume, Self.volumeRange.lowerBound), Self.volumeRange.upperBound)
    }

    init(
        fileName: String,
        displayName: String,
        start: TimeInterval,
        fileDuration: TimeInterval,
        presentation: Presentation = .pip,
        isLinked: Bool = true
    ) {
        self.fileName = fileName
        self.displayName = displayName
        self.start = start
        self.fileDuration = fileDuration
        self.trimEnd = fileDuration
        self.presentation = presentation
        self.isLinked = isLinked
        self.isMuted = presentation == .cutaway
        if presentation == .cutaway {
            let fade = min(Self.defaultCutawayFade, max(0, fileDuration / 2))
            self.fadeIn = fade
            self.fadeOut = fade
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileName, displayName
        case start, trimStart, trimEnd, fileDuration, speed
        case presentation, center, width, aspect, rotation, opacity, cornerRadius, shadow
        case fadeIn, fadeOut, cutawayContentMode
        case volume, isMuted, audioFadeIn, audioFadeOut, hasAudio, isLinked
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fileName = try container.decode(String.self, forKey: .fileName)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? fileName
        start = try container.decode(TimeInterval.self, forKey: .start)
        trimStart = try container.decodeIfPresent(TimeInterval.self, forKey: .trimStart) ?? 0
        trimEnd = try container.decode(TimeInterval.self, forKey: .trimEnd)
        fileDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .fileDuration) ?? trimEnd
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        presentation = try container.decodeIfPresent(Presentation.self, forKey: .presentation) ?? .pip
        let rawCenter = try container.decodeIfPresent(CGPoint.self, forKey: .center) ?? CGPoint(x: 0.78, y: 0.74)
        center = CGPoint(
            x: rawCenter.x.isFinite ? min(max(rawCenter.x, 0), 1) : 0.78,
            y: rawCenter.y.isFinite ? min(max(rawCenter.y, 0), 1) : 0.74
        )
        width = Self.sanitizedWidth(try container.decodeIfPresent(Double.self, forKey: .width) ?? 0.32)
        let rawAspect = try container.decodeIfPresent(Double.self, forKey: .aspect) ?? (16.0 / 9.0)
        aspect = (rawAspect.isFinite && rawAspect > 0) ? max(rawAspect, 0.01) : (16.0 / 9.0)
        let rawRotation = try container.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        rotation = rawRotation.isFinite ? rawRotation : 0
        let rawOpacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        opacity = rawOpacity.isFinite ? min(max(rawOpacity, 0), 1) : 1
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 16
        shadow = try container.decodeIfPresent(Double.self, forKey: .shadow) ?? 0.45
        fadeIn = try container.decodeIfPresent(TimeInterval.self, forKey: .fadeIn) ?? 0
        fadeOut = try container.decodeIfPresent(TimeInterval.self, forKey: .fadeOut) ?? 0
        cutawayContentMode = try container.decodeIfPresent(CutawayContentMode.self, forKey: .cutawayContentMode) ?? .fill
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? (presentation == .cutaway)
        audioFadeIn = try container.decodeIfPresent(TimeInterval.self, forKey: .audioFadeIn) ?? 0
        audioFadeOut = try container.decodeIfPresent(TimeInterval.self, forKey: .audioFadeOut) ?? 0
        hasAudio = try container.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? true
        isLinked = try container.decodeIfPresent(Bool.self, forKey: .isLinked) ?? true
    }

    func sanitized() -> RecordingVideoOverlay {
        var copy = self
        copy.speed = min(max(copy.speed.isFinite ? copy.speed : 1, Self.derivedSpeedRange.lowerBound), Self.derivedSpeedRange.upperBound)
        let minFileSpan = max(Self.minimumFileSpan, Self.minimumDuration * copy.speed)
        copy.fileDuration = copy.fileDuration.isFinite ? max(Self.minimumFileSpan, copy.fileDuration) : Self.minimumDuration
        let rawTrimStart = copy.trimStart.isFinite ? copy.trimStart : 0
        let rawTrimEnd = copy.trimEnd.isFinite ? copy.trimEnd : copy.fileDuration
        let boundedMinSpan = min(minFileSpan, copy.fileDuration)
        copy.trimStart = min(max(0, rawTrimStart), max(0, copy.fileDuration - boundedMinSpan))
        copy.trimEnd = min(max(rawTrimEnd, copy.trimStart + boundedMinSpan), max(copy.fileDuration, copy.trimStart + boundedMinSpan))
        copy.start = copy.start.isFinite ? max(0, copy.start) : 0
        copy.center = CGPoint(
            x: copy.center.x.isFinite ? min(max(copy.center.x, 0), 1) : 0.78,
            y: copy.center.y.isFinite ? min(max(copy.center.y, 0), 1) : 0.74
        )
        copy.width = Self.sanitizedWidth(copy.width)
        copy.aspect = (copy.aspect.isFinite && copy.aspect > 0) ? max(copy.aspect, 0.01) : (16.0 / 9.0)
        copy.rotation = copy.rotation.isFinite ? min(max(copy.rotation, -180), 180) : 0
        copy.opacity = copy.opacity.isFinite ? min(max(copy.opacity, 0), 1) : 1
        copy.cornerRadius = copy.cornerRadius.isFinite
            ? min(max(copy.cornerRadius, Self.cornerRadiusRange.lowerBound), Self.cornerRadiusRange.upperBound)
            : 16
        copy.shadow = copy.shadow.isFinite ? min(max(copy.shadow, 0), 1) : 0.45
        copy.fadeIn = copy.fadeIn.isFinite
            ? min(max(copy.fadeIn, Self.fadeRange.lowerBound), Self.fadeRange.upperBound)
            : 0
        copy.fadeOut = copy.fadeOut.isFinite
            ? min(max(copy.fadeOut, Self.fadeRange.lowerBound), Self.fadeRange.upperBound)
            : 0
        copy.volume = copy.volume.isFinite
            ? min(max(copy.volume, Self.volumeRange.lowerBound), Self.volumeRange.upperBound)
            : 1
        copy.audioFadeIn = copy.audioFadeIn.isFinite
            ? min(max(copy.audioFadeIn, Self.audioFadeRange.lowerBound), Self.audioFadeRange.upperBound)
            : 0
        copy.audioFadeOut = copy.audioFadeOut.isFinite
            ? min(max(copy.audioFadeOut, Self.audioFadeRange.lowerBound), Self.audioFadeRange.upperBound)
            : 0
        return copy
    }

    func isActive(atEditorTime time: TimeInterval) -> Bool {
        time.isFinite && time >= start && time < end
    }

    /// Corresponding timestamp inside the overlay's source movie for `editorTime`.
    func mediaTime(atEditorTime time: TimeInterval) -> TimeInterval {
        let local = max(0, time - start)
        return min(max(trimStart + local * max(speed, 0.01), trimStart), trimEnd)
    }

    /// 0 outside the overlay's span, ramping linearly through squeezed in/out fades.
    func fade(atEditorTime time: TimeInterval) -> Double {
        guard isActive(atEditorTime: time), duration > 0 else { return 0 }
        let local = time - start
        let effIn = min(max(fadeIn, 0), duration / 2)
        let effOut = min(max(fadeOut, 0), duration / 2)
        var value = 1.0
        if effIn > 0, local < effIn {
            value = min(value, local / effIn)
        }
        if effOut > 0, local > duration - effOut {
            value = min(value, (duration - local) / effOut)
        }
        return min(max(value, 0), 1)
    }

    func effectiveOpacity(atEditorTime time: TimeInterval) -> Double {
        let envelope = fade(atEditorTime: time)
        switch presentation {
        case .pip:
            return min(max(opacity, 0), 1) * envelope
        case .cutaway:
            // Cutaway coverage depends only on its crossfade envelope; saved PiP
            // opacity stays separate so switching modes never leaves a cutaway translucent.
            return envelope
        }
    }

    /// PiP frame on the canvas before rotation (top-left origin).
    func pipRect(canvasSize: CGSize) -> CGRect {
        let drawWidth = CGFloat(width) * canvasSize.width
        let drawHeight = drawWidth / CGFloat(max(aspect, 0.01))
        return CGRect(
            x: center.x * canvasSize.width - drawWidth / 2,
            y: center.y * canvasSize.height - drawHeight / 2,
            width: drawWidth,
            height: drawHeight
        )
    }

    /// Target draw rect inside `cardRect` for a cutaway frame of `sourceAspect` (top-left origin).
    func cutawayDrawRect(cardRect: CGRect, sourceAspect: CGFloat) -> CGRect {
        guard cardRect.width > 0, cardRect.height > 0,
              sourceAspect.isFinite, sourceAspect > 0 else {
            return cardRect
        }
        let cardAspect = cardRect.width / cardRect.height
        let drawSize: CGSize
        switch cutawayContentMode {
        case .fill:
            if sourceAspect > cardAspect {
                drawSize = CGSize(width: cardRect.height * sourceAspect, height: cardRect.height)
            } else {
                drawSize = CGSize(width: cardRect.width, height: cardRect.width / sourceAspect)
            }
        case .fit:
            if sourceAspect > cardAspect {
                drawSize = CGSize(width: cardRect.width, height: cardRect.width / sourceAspect)
            } else {
                drawSize = CGSize(width: cardRect.height * sourceAspect, height: cardRect.height)
            }
        }
        return CGRect(
            x: cardRect.midX - drawSize.width / 2,
            y: cardRect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
    }

    /// Switches between PiP and Cutaway while preserving the saved PiP layout
    /// (`center`, `width`, `rotation`, `cornerRadius`, `shadow`). Applies the
    /// default mute rule (PiP audible, Cutaway muted) and gives a freshly
    /// switched cutaway a gentle default crossfade when fades were both zero.
    func switchingPresentation(to next: Presentation) -> RecordingVideoOverlay {
        guard presentation != next else { return self }
        var copy = self
        copy.presentation = next
        copy.isMuted = (next == .cutaway)
        if next == .cutaway, copy.fadeIn == 0, copy.fadeOut == 0 {
            let fade = min(Self.defaultCutawayFade, max(0, copy.duration / 2))
            copy.fadeIn = fade
            copy.fadeOut = fade
        }
        return copy
    }

    func nudged(dx: CGFloat, dy: CGFloat) -> Self {
        var copy = self
        copy.center = CGPoint(
            x: min(max(center.x + dx, 0), 1),
            y: min(max(center.y + dy, 0), 1)
        )
        return copy
    }

    func scaled(by delta: Double) -> Self {
        var copy = self
        copy.width = min(max(width + delta, Self.widthRange.lowerBound), Self.widthRange.upperBound)
        return copy
    }

    /// Snaps a dragged PiP box to the canvas center lines and safe-margin edges,
    /// returning the snapped center and optional guide coordinates in canvas points.
    static func snapPiPCenter(
        _ proposed: CGPoint,
        size: CGSize,
        canvas: CGSize,
        margin: CGFloat,
        snapDistance: CGFloat = 8
    ) -> (center: CGPoint, guideX: CGFloat?, guideY: CGFloat?) {
        func snapAxis(_ center: CGFloat, halfSpan: CGFloat, length: CGFloat) -> (CGFloat, CGFloat?) {
            let targets: [(center: CGFloat, guide: CGFloat)] = [
                (margin + halfSpan, margin),
                (length / 2, length / 2),
                (length - margin - halfSpan, length - margin)
            ]
            guard let nearest = targets.min(by: { abs($0.center - center) < abs($1.center - center) }),
                  abs(nearest.center - center) <= snapDistance else {
                return (center, nil)
            }
            return (nearest.center, nearest.guide)
        }
        let (x, guideX) = snapAxis(proposed.x, halfSpan: size.width / 2, length: canvas.width)
        let (y, guideY) = snapAxis(proposed.y, halfSpan: size.height / 2, length: canvas.height)
        return (CGPoint(x: x, y: y), guideX, guideY)
    }

    static func canImportVideoFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie)
    }

    static func isRecordingPackage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext == "sukushorec" || ext == "screendroprec" else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("screen.mov").path)
    }

    static func canImport(_ url: URL) -> Bool {
        canImportVideoFile(url) || isRecordingPackage(url)
    }

    static var importContentTypes: [UTType] {
        var types: [UTType] = [.movie, .quickTimeMovie, .mpeg4Movie]
        for ext in ["sukushorec", "screendroprec"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }
}

// MARK: - Single-lane rules

/// Pure single-lane occupancy, placement, move/trim/speed clamping, and
/// timeline conform rules for `RecordingVideoOverlay`. Overlaps are never
/// permitted on the single v1 layered video lane.
nonisolated enum StudioVideoOverlayLane {
    private static let epsilon: TimeInterval = 0.000_5

    static func normalized(
        _ overlays: [RecordingVideoOverlay],
        timelineDuration: TimeInterval? = nil
    ) -> [RecordingVideoOverlay] {
        var seen = Set<UUID>()
        let sorted = overlays
            .map { raw -> RecordingVideoOverlay in
                var item = raw.sanitized()
                if !seen.insert(item.id).inserted {
                    item.id = UUID()
                }
                return item
            }
            .enumerated()
            .sorted {
                if abs($0.element.start - $1.element.start) > 0.000_001 {
                    return $0.element.start < $1.element.start
                }
                return $0.offset < $1.offset
            }
            .map(\.element)

        let limit: TimeInterval? = timelineDuration.flatMap { $0.isFinite ? max(0, $0) : nil }
        var result: [RecordingVideoOverlay] = []
        result.reserveCapacity(sorted.count)
        var cursor: TimeInterval = 0
        for var item in sorted {
            if item.start < cursor {
                item.start = cursor
            }
            if let limit {
                let remaining = limit - item.start
                guard remaining >= RecordingVideoOverlay.minimumDuration - epsilon else {
                    continue
                }
                if item.end > limit {
                    let speed = max(item.speed, 0.01)
                    let clampedTrimEnd = min(item.fileDuration, item.trimStart + remaining * speed)
                    guard clampedTrimEnd - item.trimStart >= RecordingVideoOverlay.minimumFileSpan else {
                        continue
                    }
                    item.trimEnd = clampedTrimEnd
                    item = item.sanitized()
                    guard item.duration >= RecordingVideoOverlay.minimumDuration - epsilon else {
                        continue
                    }
                }
            }
            cursor = item.end
            result.append(item)
        }
        return result
    }

    static func activeOverlay(
        in overlays: [RecordingVideoOverlay],
        atEditorTime time: TimeInterval
    ) -> RecordingVideoOverlay? {
        overlays.first { $0.isActive(atEditorTime: time) }
    }

    /// How strongly an active cutaway currently covers the video card (`0...1`).
    /// Used by both preview and export to crossfade out and hide the webcam bubble.
    static func cutawayCoverage(
        in overlays: [RecordingVideoOverlay],
        atEditorTime time: TimeInterval
    ) -> Double {
        guard let active = activeOverlay(in: overlays, atEditorTime: time),
              active.presentation == .cutaway else { return 0 }
        return active.fade(atEditorTime: time)
    }

    static func neighborBounds(
        for id: UUID,
        in overlays: [RecordingVideoOverlay],
        timelineDuration: TimeInterval? = nil
    ) -> (lower: TimeInterval, upper: TimeInterval) {
        let sorted = overlays.enumerated().sorted {
            if abs($0.element.start - $1.element.start) > 0.000_001 {
                return $0.element.start < $1.element.start
            }
            return $0.offset < $1.offset
        }.map(\.element)
        let limit = timelineDuration.flatMap { $0.isFinite ? max(0, $0) : nil } ?? .infinity
        guard let index = sorted.firstIndex(where: { $0.id == id }) else {
            return (0, limit)
        }
        let lower = index > 0 ? max(0, sorted[index - 1].end) : 0
        let neighborUpper = index + 1 < sorted.count ? max(lower, sorted[index + 1].start) : .infinity
        let upper = max(lower, min(neighborUpper, limit))
        return (lower, upper)
    }

    /// Places a newly imported overlay at or after `requestedTime` on the
    /// single non-overlapping lane, trimming its trailing end to fit the gap
    /// and `timelineDuration`. Returns `nil` when no gap of at least
    /// `RecordingVideoOverlay.minimumDuration` remains inside `[0, timelineDuration]`.
    static func place(
        _ raw: RecordingVideoOverlay,
        at requestedTime: TimeInterval,
        timelineDuration: TimeInterval,
        among existing: [RecordingVideoOverlay]
    ) -> RecordingVideoOverlay? {
        let limit = max(0, timelineDuration.isFinite ? timelineDuration : 0)
        guard limit >= RecordingVideoOverlay.minimumDuration else { return nil }
        let sorted = normalized(existing)
        let overlay = raw.sanitized()
        let speed = max(overlay.speed, 0.01)

        // Dropping near the end of the timeline places the clip ending at `limit`
        // if that range is free (matching audio-clip placement).
        var candidateStart: TimeInterval
        if requestedTime > limit - 0.5 {
            let preferredStart = max(0, limit - min(overlay.duration, limit))
            let overlapsPreferred = sorted.contains { $0.end > preferredStart + 0.000_5 && $0.start < limit - 0.000_5 }
            candidateStart = overlapsPreferred ? max(0, min(requestedTime, limit)) : preferredStart
        } else {
            candidateStart = max(0, min(requestedTime.isFinite ? requestedTime : 0, limit))
        }

        // Advance past any overlapping or too-narrow gap until a valid slot opens.
        for other in sorted {
            if other.end <= candidateStart + 0.000_5 { continue }
            if other.start >= candidateStart + RecordingVideoOverlay.minimumDuration - 0.000_5 {
                let ceiling = min(other.start, limit)
                guard ceiling - candidateStart >= RecordingVideoOverlay.minimumDuration - 0.000_5 else { return nil }
                return fitted(overlay, start: candidateStart, ceiling: ceiling, speed: speed)
            }
            candidateStart = max(candidateStart, other.end)
        }

        guard limit - candidateStart >= RecordingVideoOverlay.minimumDuration - 0.000_5 else {
            return nil
        }
        return fitted(overlay, start: candidateStart, ceiling: limit, speed: speed)
    }

    private static func fitted(
        _ overlay: RecordingVideoOverlay,
        start: TimeInterval,
        ceiling: TimeInterval,
        speed: Double
    ) -> RecordingVideoOverlay {
        var placed = overlay
        placed.start = max(0, start)
        let availableEditorDuration = max(RecordingVideoOverlay.minimumDuration, ceiling - placed.start)
        let maxTrimEnd = min(placed.fileDuration, placed.trimStart + availableEditorDuration * speed)
        placed.trimEnd = min(placed.trimEnd, max(placed.trimStart + RecordingVideoOverlay.minimumFileSpan, maxTrimEnd))
        return placed.sanitized()
    }

    static func moved(
        _ base: RecordingVideoOverlay,
        by delta: TimeInterval,
        among all: [RecordingVideoOverlay],
        timelineDuration: TimeInterval
    ) -> RecordingVideoOverlay {
        let bounds = neighborBounds(for: base.id, in: all, timelineDuration: timelineDuration)
        let maxStart = max(bounds.lower, bounds.upper - base.duration)
        var edited = base
        edited.start = min(max(base.start + delta, bounds.lower), maxStart)
        return edited.sanitized()
    }

    static func trimmedLeading(
        _ base: RecordingVideoOverlay,
        by delta: TimeInterval,
        among all: [RecordingVideoOverlay]
    ) -> RecordingVideoOverlay {
        let bounds = neighborBounds(for: base.id, in: all)
        let speed = max(base.speed, 0.01)
        let minShiftByFile = -base.trimStart / speed
        let minShiftByNeighbor = bounds.lower - base.start
        let maxShift = max(0, base.duration - RecordingVideoOverlay.minimumDuration)
        let shift = min(max(delta, max(minShiftByFile, minShiftByNeighbor)), maxShift)
        var edited = base
        edited.start = base.start + shift
        edited.trimStart = base.trimStart + shift * speed
        return edited.sanitized()
    }

    static func trimmedTrailing(
        _ base: RecordingVideoOverlay,
        by delta: TimeInterval,
        among all: [RecordingVideoOverlay],
        timelineDuration: TimeInterval? = nil
    ) -> RecordingVideoOverlay {
        let bounds = neighborBounds(for: base.id, in: all, timelineDuration: timelineDuration)
        let speed = max(base.speed, 0.01)
        let maxEndByFile = base.start + (base.fileDuration - base.trimStart) / speed
        let maxEnd = min(bounds.upper, maxEndByFile)
        let minEnd = base.start + RecordingVideoOverlay.minimumDuration
        let targetEnd = min(max(base.end + delta, minEnd), max(minEnd, maxEnd))
        var edited = base
        edited.trimEnd = min(
            max(base.trimStart + (targetEnd - base.start) * speed, base.trimStart + RecordingVideoOverlay.minimumFileSpan),
            base.fileDuration
        )
        return edited.sanitized()
    }

    static func withSpeed(
        _ base: RecordingVideoOverlay,
        speed requestedSpeed: Double,
        among all: [RecordingVideoOverlay],
        timelineDuration: TimeInterval? = nil
    ) -> RecordingVideoOverlay {
        let clampedSpeed = min(
            max(requestedSpeed.isFinite ? requestedSpeed : 1, RecordingVideoOverlay.speedRange.lowerBound),
            RecordingVideoOverlay.speedRange.upperBound
        )
        let bounds = neighborBounds(for: base.id, in: all, timelineDuration: timelineDuration)
        var edited = base
        edited.speed = clampedSpeed
        if edited.end > bounds.upper {
            let availableDuration = bounds.upper - edited.start
            guard availableDuration >= RecordingVideoOverlay.minimumDuration - epsilon else {
                return base
            }
            edited.trimEnd = min(
                edited.fileDuration,
                edited.trimStart + availableDuration * clampedSpeed
            )
        }
        return edited.sanitized()
    }

    /// Maps video overlays across main-track clip edits while preserving order,
    /// the single-lane no-overlap invariant, and `[0, new.duration]` bounds.
    /// Linked overlays split, trim, and retime with the video beneath them;
    /// unlinked overlays stay whole and follow the footage moment under their
    /// start. Overlays pushed past the surviving timeline end are dropped
    /// (and restored cleanly by Undo via `applyClipTimeline`).
    static func conform(
        _ overlays: [RecordingVideoOverlay],
        from old: RecordingClipTimeline,
        to new: RecordingClipTimeline
    ) -> [RecordingVideoOverlay] {
        guard old != new, !overlays.isEmpty else { return overlays }
        var mapped: [RecordingVideoOverlay] = []
        mapped.reserveCapacity(overlays.count)
        for overlay in overlays {
            if overlay.isLinked {
                mapped.append(contentsOf: conformLinked(overlay, from: old, to: new))
            } else {
                var copy = overlay
                copy.start = max(0, StudioAudioConform.mapPoint(overlay.start, from: old, to: new))
                mapped.append(copy)
            }
        }
        return normalized(mapped, timelineDuration: new.duration)
    }

    private static func conformLinked(
        _ overlay: RecordingVideoOverlay,
        from old: RecordingClipTimeline,
        to new: RecordingClipTimeline
    ) -> [RecordingVideoOverlay] {
        let overlaySpeed = max(overlay.speed, 0.01)
        var pieces: [RecordingVideoOverlay] = []

        func append(start: TimeInterval, fileStart: TimeInterval, fileEnd: TimeInterval, speed: Double) {
            guard fileEnd - fileStart > epsilon, speed > 0 else { return }
            var piece = overlay
            piece.start = start
            piece.trimStart = fileStart
            piece.trimEnd = fileEnd
            piece.speed = speed
            if var last = pieces.last,
               abs(last.end - piece.start) < 0.002,
               abs(last.trimEnd - piece.trimStart) < 0.002,
               abs(last.speed - piece.speed) < 0.000_1 {
                last.trimEnd = piece.trimEnd
                pieces[pieces.count - 1] = last
            } else {
                pieces.append(piece)
            }
        }

        let oldSegmentIDs = Set(old.segments.map(\.id))
        var oldEditorStart: TimeInterval = 0
        for segment in old.segments {
            let oldEditorEnd = oldEditorStart + segment.editorDuration
            defer { oldEditorStart = oldEditorEnd }
            let low = max(overlay.start, oldEditorStart)
            let high = min(overlay.end, oldEditorEnd)
            guard high - low > epsilon else { continue }
            let sourceLow = segment.sourceStart + (low - oldEditorStart) * segment.speed
            let sourceHigh = segment.sourceStart + (high - oldEditorStart) * segment.speed
            let fileLow = overlay.trimStart + (low - overlay.start) * overlaySpeed
            let filePerSource = overlaySpeed / segment.speed

            var newEditorStart: TimeInterval = 0
            for newSeg in new.segments {
                defer { newEditorStart += newSeg.editorDuration }
                let matchesSource: Bool
                if segment.isPrimaryRecording {
                    matchesSource = newSeg.isPrimaryRecording
                } else {
                    matchesSource = newSeg.mediaFileName == segment.mediaFileName
                        && (newSeg.id == segment.id
                            || newSeg.effectiveOccurrenceID == segment.effectiveOccurrenceID
                            || !oldSegmentIDs.contains(newSeg.id))
                }
                guard matchesSource else { continue }
                let sliceLow = max(sourceLow, newSeg.sourceStart)
                let sliceHigh = min(sourceHigh, newSeg.sourceEnd)
                guard sliceHigh - sliceLow > epsilon else { continue }
                let sliceEditorStart = newEditorStart + (sliceLow - newSeg.sourceStart) / newSeg.speed
                let fileStart = fileLow + (sliceLow - sourceLow) * filePerSource
                let fileEnd = min(overlay.trimEnd, fileLow + (sliceHigh - sourceLow) * filePerSource)
                let derivedSpeed = min(
                    max(filePerSource * newSeg.speed, RecordingVideoOverlay.derivedSpeedRange.lowerBound),
                    RecordingVideoOverlay.derivedSpeedRange.upperBound
                )
                append(start: sliceEditorStart, fileStart: fileStart, fileEnd: fileEnd, speed: derivedSpeed)
            }
        }

        pieces = pieces.filter {
            $0.duration >= RecordingVideoOverlay.minimumDuration - epsilon
                && $0.fileSpan >= RecordingVideoOverlay.minimumFileSpan
        }
        for index in pieces.indices {
            if index > 0 {
                pieces[index].id = UUID()
            }
            if abs(pieces[index].trimStart - overlay.trimStart) > 0.002 {
                pieces[index].fadeIn = 0
                pieces[index].audioFadeIn = 0
            }
            if abs(pieces[index].trimEnd - overlay.trimEnd) > 0.002 {
                pieces[index].fadeOut = 0
                pieces[index].audioFadeOut = 0
            }
        }
        return pieces
    }
}

// MARK: - Recycled AVPlayer playback state machine

/// Pure decision engine for the single recycled `AVPlayer` serving the
/// `.videoOverlay` lane. Guarantees the player loads an item only inside or
/// immediately approaching an overlay span, and clears (`nil`) outside spans.
nonisolated enum StudioVideoOverlayPlaybackPlan: Equatable, Sendable {
    /// Outside every overlay span (and outside preload lead): release the player item.
    case clear
    /// Preloading an upcoming overlay while playing; keep paused at its entry media time.
    case preload(overlay: RecordingVideoOverlay, mediaTime: TimeInterval)
    /// Actively displaying `overlay` at `mediaTime` (playing at `rate` when `isPlaying`).
    case active(overlay: RecordingVideoOverlay, mediaTime: TimeInterval, targetRate: Float?)

    static let defaultPreloadLeadTime: TimeInterval = 1.5

    static func resolve(
        at editorTime: TimeInterval,
        isPlaying: Bool,
        shuttleRate: Float,
        overlays: [RecordingVideoOverlay],
        preloadLeadTime: TimeInterval = defaultPreloadLeadTime
    ) -> Self {
        guard editorTime.isFinite, !overlays.isEmpty else { return .clear }
        if let current = StudioVideoOverlayLane.activeOverlay(in: overlays, atEditorTime: editorTime) {
            let mediaTime = current.mediaTime(atEditorTime: editorTime)
            let rate: Float? = isPlaying ? Float(current.speed) * shuttleRate : nil
            return .active(overlay: current, mediaTime: mediaTime, targetRate: rate)
        }
        guard isPlaying, preloadLeadTime > 0 else { return .clear }
        let lead = preloadLeadTime * Double(max(1, abs(shuttleRate)))
        if shuttleRate >= 0 {
            if let upcoming = overlays
                .filter({ $0.start > editorTime && $0.start - editorTime <= lead })
                .min(by: { $0.start < $1.start }) {
                return .preload(overlay: upcoming, mediaTime: upcoming.trimStart)
            }
        } else {
            if let approaching = overlays
                .filter({ $0.end <= editorTime && editorTime - $0.end <= lead })
                .max(by: { $0.end < $1.end }) {
                return .preload(overlay: approaching, mediaTime: approaching.trimEnd)
            }
        }
        return .clear
    }
}

// MARK: - Media probing & cleanup

nonisolated enum RecordingVideoOverlayMedia {
    enum ResolutionError: LocalizedError, Equatable {
        case missingOrInvalid(String)

        var errorDescription: String? {
            switch self {
            case .missingOrInvalid(let name):
                "The video overlay \"\(name)\" is missing or unreadable."
            }
        }
    }

    struct ProbeResult: Equatable, Sendable {
        let duration: TimeInterval
        let aspect: Double
        let hasAudio: Bool
        let naturalSize: CGSize
    }

    /// Reads duration, display size/aspect (honoring `preferredTransform`), and
    /// audio track presence without spinning up a player or decoding frames.
    static func probe(url: URL) async -> ProbeResult? {
        let asset = AVURLAsset(url: url)
        guard let (durationTime, videoTracks, audioTracks) = try? await (
            asset.load(.duration),
            asset.loadTracks(withMediaType: .video),
            asset.loadTracks(withMediaType: .audio)
        ),
              let videoTrack = videoTracks.first,
              let (naturalSize, preferredTransform) = try? await videoTrack.load(.naturalSize, .preferredTransform) else {
            return nil
        }
        let duration = durationTime.seconds
        guard duration.isFinite, duration >= RecordingVideoOverlay.minimumDuration else { return nil }
        let transformed = naturalSize.applying(preferredTransform)
        let displaySize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        guard displaySize.width > 0, displaySize.height > 0 else { return nil }
        let aspect = Double(displaySize.width / displaySize.height)
        return ProbeResult(
            duration: duration,
            aspect: aspect,
            hasAudio: !audioTracks.isEmpty,
            naturalSize: displaySize
        )
    }

    /// True when `candidateURL` refers to the same recording package as `openSessionURL`
    /// (resolving symlinks and path standardization so `/var` vs `/private/var` match).
    static func isSelfRecording(_ candidateURL: URL, openSessionURL: URL) -> Bool {
        let candidate = candidateURL.resolvingSymlinksInPath().standardizedFileURL.path
        let open = openSessionURL.resolvingSymlinksInPath().standardizedFileURL.path
        return candidate == open
    }

    static let selfImportErrorMessage =
        "This recording is already open. Add a different recording or a movie."

    /// Validates a `.sukushorec` package and its render inputs via the shared
    /// `RecordingPackageMedia` no-follow resolver before offering or starting import.
    static func validateRecordingPackage(at packageURL: URL) -> Bool {
        (try? RecordingPackageMedia.validateRenderInputs(in: packageURL)) != nil
    }

    /// Validates that every overlay visible inside `[0, duration)` resolves to a
    /// regular, non-symlink file inside `mediaDirectory`.
    static func validateOverlays(
        _ overlays: [RecordingVideoOverlay],
        in mediaDirectory: URL?,
        duration: TimeInterval
    ) throws {
        for overlay in overlays where overlay.start < duration && overlay.end > 0 {
            let label = overlay.displayName.isEmpty ? overlay.fileName : overlay.displayName
            guard let mediaDirectory,
                  RecordingOverlayMedia.resolveRegularFile(named: overlay.fileName, in: mediaDirectory) != nil else {
                throw ResolutionError.missingOrInvalid(label)
            }
        }
    }
}

// MARK: - Core Graphics renderer (Export)

nonisolated enum RecordingVideoOverlayRenderer {
    /// Converts a decoded `CVPixelBuffer` into a display-oriented `CGImage`,
    /// applying `preferredTransform` (e.g., 90° portrait phone clips) only when
    /// it differs from identity.
    static func makeOrientedImage(
        from pixelBuffer: CVPixelBuffer,
        preferredTransform: CGAffineTransform,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let sourceContext = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ),
              let rawImage = sourceContext.makeImage() else {
            return nil
        }

        let isIdentity = abs(preferredTransform.a - 1) < 0.001
            && abs(preferredTransform.d - 1) < 0.001
            && abs(preferredTransform.b) < 0.001
            && abs(preferredTransform.c) < 0.001
        if isIdentity {
            return rawImage
        }

        let rawRect = CGRect(x: 0, y: 0, width: width, height: height)
        let transformedRect = rawRect.applying(preferredTransform)
        let outWidth = max(1, Int(abs(transformedRect.width).rounded()))
        let outHeight = max(1, Int(abs(transformedRect.height).rounded()))
        guard let orientedContext = CGContext(
            data: nil,
            width: outWidth,
            height: outHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return rawImage
        }
        orientedContext.interpolationQuality = .high
        // Work in top-down space matching AVFoundation's `preferredTransform`,
        // translate into positive bounds, then flip the image itself into place.
        orientedContext.translateBy(x: 0, y: CGFloat(outHeight))
        orientedContext.scaleBy(x: 1, y: -1)
        orientedContext.translateBy(x: -transformedRect.minX, y: -transformedRect.minY)
        orientedContext.concatenate(preferredTransform)
        orientedContext.translateBy(x: 0, y: CGFloat(height))
        orientedContext.scaleBy(x: 1, y: -1)
        orientedContext.draw(rawImage, in: rawRect)
        return orientedContext.makeImage()
    }

    /// Draws an active video overlay into `context`, whose user space is the
    /// canvas with a **top-left** origin (matching `RecordingImageOverlayRenderer`).
    static func draw(
        _ overlay: RecordingVideoOverlay,
        frame: CGImage,
        atEditorTime editorTime: TimeInterval,
        canvasSize: CGSize,
        cardRect: CGRect,
        cardCornerRadius: CGFloat,
        in context: CGContext
    ) {
        let alpha = overlay.effectiveOpacity(atEditorTime: editorTime)
        guard alpha > 0.001 else { return }
        switch overlay.presentation {
        case .pip:
            drawPiP(overlay, frame: frame, alpha: alpha, canvasSize: canvasSize, in: context)
        case .cutaway:
            drawCutaway(
                overlay,
                frame: frame,
                alpha: alpha,
                cardRect: cardRect,
                cardCornerRadius: cardCornerRadius,
                in: context
            )
        }
    }

    private static func drawPiP(
        _ overlay: RecordingVideoOverlay,
        frame: CGImage,
        alpha: Double,
        canvasSize: CGSize,
        in context: CGContext
    ) {
        let rect = overlay.pipRect(canvasSize: canvasSize)
        guard rect.width >= 1, rect.height >= 1 else { return }
        let unit = min(canvasSize.width, canvasSize.height) / 1080
        let radius = min(CGFloat(overlay.cornerRadius) * unit, rect.width / 2, rect.height / 2)
        let strength = CGFloat(min(max(overlay.shadow, 0), 1))

        // Shadows are specified in Core Graphics base space (+y up, -y down), so
        // a negative height casts the shadow downward matching SwiftUI's `+y` offset.
        let scaleVector = context.convertToDeviceSpace(CGSize(width: 1, height: 0))
        let deviceScale = max(hypot(scaleVector.width, scaleVector.height), 0.001)
        let shadowOffset = CGSize(width: 0, height: -12 * unit * strength * deviceScale)
        let shadowBlur = 40 * unit * strength * deviceScale

        context.saveGState()
        defer { context.restoreGState() }
        context.interpolationQuality = .high
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: CGFloat(overlay.rotation) * .pi / 180)
        context.translateBy(x: -rect.midX, y: -rect.midY)

        // Cast the drop shadow into a transparency layer and punch out the PiP
        // interior with `.clear` so the shadow radiates strictly outside the
        // rounded silhouette and never darkens the video interior at any alpha.
        if strength > 0 {
            let shadowMargin = shadowBlur * 2 + max(abs(shadowOffset.width), abs(shadowOffset.height)) + 4
            let outerBounds = rect.insetBy(dx: -shadowMargin, dy: -shadowMargin)
            let shapePath = radius > 0
                ? CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                : CGPath(rect: rect, transform: nil)
            context.saveGState()
            context.setAlpha(CGFloat(alpha))
            context.beginTransparencyLayer(in: outerBounds, auxiliaryInfo: nil)
            context.saveGState()
            context.setShadow(offset: shadowOffset, blur: shadowBlur, color: CGColor(gray: 0, alpha: 0.5 * strength))
            context.addPath(shapePath)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
            context.setBlendMode(.clear)
            context.addPath(shapePath)
            context.fillPath()
            context.endTransparencyLayer()
            context.restoreGState()
        }

        context.setAlpha(CGFloat(alpha))
        if radius > 0 {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
        }

        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(frame, in: CGRect(origin: .zero, size: rect.size))
    }

    private static func drawCutaway(
        _ overlay: RecordingVideoOverlay,
        frame: CGImage,
        alpha: Double,
        cardRect: CGRect,
        cardCornerRadius: CGFloat,
        in context: CGContext
    ) {
        guard cardRect.width >= 1, cardRect.height >= 1 else { return }
        let radius = min(cardCornerRadius, min(cardRect.width, cardRect.height) / 2)
        let frameAspect = CGFloat(frame.width) / CGFloat(max(frame.height, 1))
        let drawRect = overlay.cutawayDrawRect(cardRect: cardRect, sourceAspect: frameAspect)

        context.saveGState()
        defer { context.restoreGState() }
        context.interpolationQuality = .high

        if radius > 0.5 {
            context.addPath(CGPath(roundedRect: cardRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        } else {
            context.addRect(cardRect)
        }
        context.clip()

        // Composite the opaque letterbox backing and cutaway frame inside one
        // transparency layer so `alpha` dissolves the combined cutaway ONCE
        // over the underlying video instead of double-fading through black.
        context.setAlpha(CGFloat(alpha))
        context.beginTransparencyLayer(in: cardRect, auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(cardRect)

        context.translateBy(x: drawRect.minX, y: drawRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(frame, in: CGRect(origin: .zero, size: drawRect.size))
    }
}

// MARK: - Sequential on-demand export frame feed

/// Sequential decoder for the `.videoOverlay` lane during export. Opens an
/// `AVAssetReader` lazily when the export enters an overlay span and cancels
/// and releases it immediately when the span ends, holding at most one open
/// overlay reader at any point in time.
nonisolated final class VideoOverlayFrameFeed: @unchecked Sendable {
    struct Frame {
        let overlay: RecordingVideoOverlay
        let pixelBuffer: CVPixelBuffer
        let preferredTransform: CGAffineTransform
    }

    private static let readerOutputSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]

    private struct ActiveReader {
        let overlayID: UUID
        let asset: AVURLAsset
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let preferredTransform: CGAffineTransform
        var currentFrame: CVPixelBuffer?
        var pendingFrame: (buffer: CVPixelBuffer, time: TimeInterval)?
        var isFinished = false
    }

    private let overlays: [RecordingVideoOverlay]
    private let mediaDirectory: URL?
    private var active: ActiveReader?

    init(overlays: [RecordingVideoOverlay], mediaDirectory: URL?) {
        self.overlays = StudioVideoOverlayLane.normalized(overlays)
        self.mediaDirectory = mediaDirectory
    }

    /// Exposed for tests verifying that at most one reader is open and that it
    /// is released outside overlay spans.
    var activeOverlayID: UUID? { active?.overlayID }

    var failureError: Error? {
        active?.reader.status == .failed ? active?.reader.error : nil
    }

    func frame(at editorTime: TimeInterval) async throws -> Frame? {
        guard let overlay = StudioVideoOverlayLane.activeOverlay(in: overlays, atEditorTime: editorTime) else {
            closeActive()
            return nil
        }

        if active?.overlayID != overlay.id {
            closeActive()
            try await openActive(for: overlay)
        }

        guard var session = active else { return nil }
        let targetMediaTime = overlay.mediaTime(atEditorTime: editorTime)

        while !session.isFinished {
            if let pending = session.pendingFrame {
                guard pending.time <= targetMediaTime + 0.000_5 || session.currentFrame == nil else { break }
                session.currentFrame = pending.buffer
                session.pendingFrame = nil
            }
            guard let sample = session.output.copyNextSampleBuffer() else {
                session.isFinished = true
                break
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            session.pendingFrame = (buffer: buffer, time: time)
        }
        active = session

        if session.reader.status == .failed {
            throw session.reader.error ?? RecordingVideoOverlayMedia.ResolutionError.missingOrInvalid(overlay.displayName)
        }
        guard let buffer = session.currentFrame else { return nil }
        return Frame(overlay: overlay, pixelBuffer: buffer, preferredTransform: session.preferredTransform)
    }

    func cancel() {
        closeActive()
    }

    private func closeActive() {
        active?.reader.cancelReading()
        active = nil
    }

    private func openActive(for overlay: RecordingVideoOverlay) async throws {
        let label = overlay.displayName.isEmpty ? overlay.fileName : overlay.displayName
        guard let mediaDirectory,
              let url = RecordingOverlayMedia.resolveRegularFile(named: overlay.fileName, in: mediaDirectory) else {
            throw RecordingVideoOverlayMedia.ResolutionError.missingOrInvalid(label)
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingVideoOverlayMedia.ResolutionError.missingOrInvalid(label)
        }
        let preferredTransform = try await track.load(.preferredTransform)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.readerOutputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let startLead = max(0, overlay.trimStart - 0.5)
        let readLength = (overlay.trimEnd - startLead) + 0.5
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: startLead, preferredTimescale: 600),
            duration: CMTime(seconds: max(0.1, readLength), preferredTimescale: 600)
        )
        guard reader.startReading() else {
            throw reader.error ?? RecordingVideoOverlayMedia.ResolutionError.missingOrInvalid(label)
        }
        active = ActiveReader(
            overlayID: overlay.id,
            asset: asset,
            reader: reader,
            output: output,
            preferredTransform: preferredTransform
        )
    }
}
