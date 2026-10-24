import Foundation

/// Sidecar of everything the user did during the recording, on the screen
/// movie's timeline. Coordinates are normalized (0...1) with a top-left
/// origin so they stay valid at any render resolution.
nonisolated struct PointerCaptureFile: Codable, Sendable, Equatable {
    static let currentFormatVersion = 1

    var formatVersion = Self.currentFormatVersion
    var travel: [PointerTravelSample] = []
    var presses: [PointerPressEvent] = []
    var keystrokes: [RecordingKeystrokeEvent] = []
    var artwork: [PointerArtwork] = []
    /// Pen strokes drawn during the take; empty for older recordings.
    var ink: [RecordingInkStroke] = []
    /// Scrolling under the pointer; empty for older recordings.
    var scrolls: [PointerScrollEvent] = []
    /// Prevents deterministic cleanup from being applied repeatedly when the
    /// same sidecar passes through Studio, flattening, and export builders.
    var isSanitized = false
}

/// Scroll-wheel or trackpad scrolling at one pointer position, summed over at
/// most 0.1 s so a long scroll stays small on disk.
nonisolated struct PointerScrollEvent: Codable, Sendable, Equatable {
    /// Seconds on the screen movie timeline.
    var time: TimeInterval
    var x: Double
    var y: Double
    /// Points scrolled. Positive `dy` moves the view toward the top of the
    /// content (scrolling up); positive `dx` toward its left.
    var dx: Double
    var dy: Double
    /// How many scroll events were summed into this one.
    var count = 1

    /// Sums each event into the first of its group, starting a new group
    /// `window` seconds after the last one started.
    static func coalesced(_ events: [PointerScrollEvent], window: TimeInterval = 0.1) -> [PointerScrollEvent] {
        var result: [PointerScrollEvent] = []
        for event in events.sorted(by: { $0.time < $1.time }) {
            if let last = result.last, event.time - last.time < window {
                result[result.count - 1].dx += event.dx
                result[result.count - 1].dy += event.dy
                result[result.count - 1].count += event.count
            } else {
                result.append(event)
            }
        }
        return result
    }
}

/// A completed keyboard chord captured during recording: a special key press
/// (Tab, Esc, arrows, …) or a modifier shortcut (⌘C). Plain typing is never
/// recorded. Labels are display-ready strings so Studio and export render
/// exactly what was captured without re-deriving key names.
nonisolated struct RecordingKeystrokeEvent: Codable, Sendable, Equatable {
    /// Seconds on the screen movie timeline.
    var time: TimeInterval
    /// Held modifier symbols in keyboard order, e.g. ["⌃", "⌘"].
    var modifiers: [String] = []
    /// The trigger key's label, e.g. "K", "⇥", "esc".
    var key: String
}

nonisolated struct PointerTravelSample: Codable, Sendable, Equatable {
    enum PointerTravelKind: String, Codable, Sendable {
        case move
        case drag
    }

    /// Seconds on the screen movie timeline.
    var time: TimeInterval
    var x: Double
    var y: Double
    var kind: PointerTravelKind = .move
    /// References an entry in `PointerCaptureFile.artwork`. A nil ID means
    /// the renderer should use an AppKit-provided system arrow.
    var artworkID: String? = nil
}

nonisolated struct PointerPressEvent: Codable, Sendable, Equatable {
    enum PressPhase: String, Codable, Sendable {
        case down
        case up
    }

    var time: TimeInterval
    var x: Double
    var y: Double
    var button: Int
    var phase: PressPhase
    /// Pointer appearance active when the button event was captured.
    var artworkID: String? = nil
}

/// A captured pointer image embedded in input.json. `Data` is encoded as a
/// base-64 JSON string by Foundation's Codable implementation.
nonisolated struct PointerArtwork: Codable, Sendable, Equatable {
    nonisolated struct Point: Codable, Sendable, Equatable {
        var x: Double
        var y: Double
    }

    nonisolated struct Size: Codable, Sendable, Equatable {
        var width: Double
        var height: Double
    }

    var artworkID: String
    var imageData: Data
    /// Anchor point in the captured artwork's reference-size coordinate space.
    var anchorPoint: Point
    var referenceSize: Size
}

nonisolated extension PointerCaptureFile {
    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case travel
        case presses
        case keystrokes
        case artwork
        case ink
        case scrolls
        case isSanitized
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        travel = try container.decodeIfPresent([PointerTravelSample].self, forKey: .travel) ?? []
        presses = try container.decodeIfPresent([PointerPressEvent].self, forKey: .presses) ?? []
        keystrokes = try container.decodeIfPresent(
            [RecordingKeystrokeEvent].self,
            forKey: .keystrokes
        ) ?? []
        artwork = try container.decodeIfPresent(
            [PointerArtwork].self,
            forKey: .artwork
        ) ?? []
        ink = try container.decodeIfPresent([RecordingInkStroke].self, forKey: .ink) ?? []
        scrolls = try container.decodeIfPresent([PointerScrollEvent].self, forKey: .scrolls) ?? []
        isSanitized = try container.decodeIfPresent(Bool.self, forKey: .isSanitized) ?? false
    }
}

nonisolated extension PointerTravelSample {
    private enum CodingKeys: String, CodingKey {
        case time
        case x
        case y
        case kind
        case artworkID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decode(TimeInterval.self, forKey: .time)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        kind = try container.decodeIfPresent(
            PointerTravelKind.self,
            forKey: .kind
        ) ?? .move
        artworkID = try container.decodeIfPresent(String.self, forKey: .artworkID)
    }
}
