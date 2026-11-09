//
//  ShakeDetector.swift
//  Screendrop
//
//  Shake to upload: tells a shake of the pointer from an ordinary drag, from
//  its horizontal positions alone, and says which files a shelf may share as
//  a gallery. Apart from the app, so both can be tested without events,
//  pasteboards or a Worker.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fires on `reversals` horizontal turns within `window` seconds, each stroke between
/// them at least `minimumStroke` points long. A turn counts once the pointer has come
/// back `minimumStroke` from its furthest point, so jitter and the small corrections
/// of aiming at a drop target never count.
nonisolated struct ShakeDetector: Sendable {
    /// A wrist shake is about 3 to 6 strokes a second, 50 to 200 points each; a hand
    /// tremor or a correction near a target is under 30.
    var minimumStroke: CGFloat = 40
    var reversals = 3
    /// Three turns in half a second is a shake of 2 Hz or faster: slower wiggles are aiming.
    var window: TimeInterval = 0.5

    private var direction: CGFloat = 0
    /// The furthest point of the stroke so far, and when the pointer was there.
    private var extreme: (x: CGFloat, time: TimeInterval)?
    /// Before the first stroke: the range covered, to tell its direction.
    private var low: CGFloat = .infinity
    private var high: CGFloat = -.infinity
    private var turns: [TimeInterval] = []
    private var lastTime: TimeInterval?

    init() {}

    /// Adds a pointer sample; true when it completes a shake, which starts the count over.
    mutating func add(x: CGFloat, time: TimeInterval) -> Bool {
        // A pause ends the shake.
        if let lastTime, time - lastTime > window { reset() }
        lastTime = time
        guard let current = extreme, direction != 0 else {
            low = min(low, x)
            high = max(high, x)
            if high - low >= minimumStroke {
                direction = x == high ? 1 : -1
                extreme = (x, time)
            }
            return false
        }
        if (x - current.x) * direction > 0 {
            extreme = (x, time)
        } else if (current.x - x) * direction >= minimumStroke {
            turns.append(current.time)
            direction = -direction
            extreme = (x, time)
            if turns.count > reversals { turns.removeFirst() }
            if turns.count == reversals, let first = turns.first, current.time - first <= window {
                reset()
                return true
            }
        }
        return false
    }

    mutating func reset() {
        direction = 0
        extreme = nil
        low = .infinity
        high = -.infinity
        turns = []
        lastTime = nil
    }
}

nonisolated enum ShakeShelfFiles {
    /// Several images, all of a kind Image I/O reads, can go up as one gallery when
    /// the Worker has galleries; a gallery's images need a thumbnail each.
    static func canShareGallery(_ files: [URL], workerSupportsGalleries: Bool) -> Bool {
        guard workerSupportsGalleries, CloudGalleryAPI.canShare(count: files.count, includesRecording: false) else { return false }
        let readable = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
        return files.allSatisfy { file in
            guard let type = UTType(filenameExtension: file.pathExtension) else { return false }
            return type.conforms(to: .image) && readable.contains(type.identifier)
        }
    }
}
