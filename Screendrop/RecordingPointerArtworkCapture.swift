//
//  RecordingPointerArtworkCapture.swift
//  Screendrop
//
//  Converts AppKit-provided cursor images into the recording sidecar format.
//  Screendrop does not ship or substitute its own pointer artwork.
//

import AppKit
import Foundation

@MainActor
enum PointerArtworkCapture {
    static func defaultArtwork() -> PointerArtwork? {
        capture(NSCursor.arrow, id: "pointer-default")
    }

    /// Plain names for recorded cursor images that are AppKit's own cursors,
    /// or the editor's plus, by artwork ID: the recorder captures them the
    /// same way, so the image data matches exactly.
    // shortcut: matches only on the macOS version that drew the recording's cursors; name them at record time if exports move between Macs.
    static func names(for artwork: [PointerArtwork]) -> [String: String] {
        var names: [String: String] = [:]
        for item in artwork {
            names[item.artworkID] = knownCursors.first {
                $0.artwork.imageData == item.imageData
                    && $0.artwork.anchorPoint == item.anchorPoint && $0.artwork.referenceSize == item.referenceSize
            }?.name
        }
        return names
    }

    private static let knownCursors: [(artwork: PointerArtwork, name: String)] = { () -> [(NSCursor, String)] in [
        (.arrow, "arrow"), (.iBeam, "I-beam (text)"), (.iBeamCursorForVerticalLayout, "vertical I-beam"),
        (.crosshair, "crosshair"), (.annotationPlus, "plus (Sukusho's drawing cursor)"),
        (.pointingHand, "pointing hand (link or button)"), (.openHand, "open hand (can grab)"),
        (.closedHand, "closed hand (grabbing)"), (.resizeLeftRight, "left-right resize"), (.resizeUpDown, "up-down resize"),
        (.resizeLeft, "resize left"), (.resizeRight, "resize right"), (.resizeUp, "resize up"), (.resizeDown, "resize down"),
        (.operationNotAllowed, "not allowed"), (.dragCopy, "copy"), (.dragLink, "make alias"),
        (.contextualMenu, "context menu"), (.disappearingItem, "remove (poof)"), (.zoomIn, "zoom in"), (.zoomOut, "zoom out"),
    ] }().compactMap { cursor, name in capture(cursor, id: name).map { (artwork: $0, name: name) } }

    static func capture(_ cursor: NSCursor, id: String) -> PointerArtwork? {
        let image = cursor.image
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let imageData = bitmap.representation(using: .png, properties: [:]),
              !imageData.isEmpty else {
            return nil
        }

        let imageSize = image.size
        let width = imageSize.width.isFinite && imageSize.width > 0
            ? imageSize.width
            : CGFloat(bitmap.pixelsWide)
        let height = imageSize.height.isFinite && imageSize.height > 0
            ? imageSize.height
            : CGFloat(bitmap.pixelsHigh)
        guard width > 0, height > 0 else { return nil }

        let hotSpot = cursor.hotSpot
        return PointerArtwork(
            artworkID: id,
            imageData: imageData,
            anchorPoint: PointerArtwork.Point(
                x: min(max(hotSpot.x.isFinite ? hotSpot.x : 0, 0), width),
                y: min(max(hotSpot.y.isFinite ? hotSpot.y : 0, 0), height)
            ),
            referenceSize: PointerArtwork.Size(
                width: width,
                height: height
            )
        )
    }
}
