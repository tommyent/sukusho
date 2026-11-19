//
//  ImageTextRecognizer.swift
//  Screendrop
//

import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Extracts text from a captured image using the Vision framework so users can
/// "Copy text from image" (OCR).
enum ImageTextRecognizer {
    /// Recognises text in the image at `url`, returning the recognised lines
    /// joined by newlines in reading order. Returns an empty string when
    /// nothing is found, or nil if the image could not be read.
    static func recognizeText(at url: URL) async -> String? {
        await read { ScreenshotImageLoader.uprightImage(at: url) }
    }

    /// The same for an image already prepared, such as Capture Text's 2× read (`CapturedDocumentText.readable`).
    static func recognizeText(in image: CGImage) async -> String? {
        await read { image }
    }

    private static func read(_ load: @escaping @Sendable () -> CGImage?) async -> String? {
        await ImageTextWarmUp.shared.waitUntilReady()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let image = load(), let observations = try? observations(in: image) else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
            }
        }
    }

    nonisolated static func withFallback<T>(_ recognize: (VNRequestTextRecognitionLevel) throws -> T) rethrows -> T {
        do { return try recognize(.accurate) } catch { return try recognize(.fast) }
    }

    nonisolated private static func observations(in image: CGImage) throws -> [VNRecognizedTextObservation] {
        try withFallback { level in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return readingOrder(request.results ?? [])
        }
    }

    /// The lines in an image, in reading order. Run off the main thread and cooperative pool.
    nonisolated static func recognizeLines(in image: CGImage) throws -> [CaptureTextLine] {
        try observations(in: image).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return CaptureTextLine(text: text, box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
        }
    }

    /// Vision returns observations in no documented order, which scrambles
    /// anything laid out in columns. Groups them into visual lines top to
    /// bottom, then orders each line left to right.
    ///
    /// Done as an explicit grouping pass rather than one clever comparator:
    /// a tolerance-based comparator is not a strict weak ordering, and
    /// `sorted(by:)` gives undefined results when handed one.
    nonisolated private static func readingOrder(
        _ observations: [VNRecognizedTextObservation]
    ) -> [VNRecognizedTextObservation] {
        // Vision's normalized origin is bottom-left, so a larger midY sits
        // higher on the page.
        let topDown = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        var ordered: [VNRecognizedTextObservation] = []
        var line: [VNRecognizedTextObservation] = []
        var lineMidY: CGFloat = 0

        func flushLine() {
            ordered.append(contentsOf: line.sorted { $0.boundingBox.minX < $1.boundingBox.minX })
            line.removeAll()
        }

        for observation in topDown {
            let box = observation.boundingBox
            // Two fragments belong to the same visual line when their centres
            // sit within half a line height of each other.
            if !line.isEmpty, abs(box.midY - lineMidY) > box.height / 2 {
                flushLine()
            }
            if line.isEmpty {
                lineMidY = box.midY
            }
            line.append(observation)
        }
        flushLine()

        return ordered
    }
}
