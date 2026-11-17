import CoreGraphics
import Foundation
import ImageIO
import Testing

/// Owner, 2026-11-17: Capture Text joins lines that wrapped mid-sentence into paragraphs, and keeps every other break.
struct CaptureTextParagraphsTests {
    @Test func wrappedLinesJoinIntoAParagraph() {
        let read = """
            A screenshot is a digital image that shows the contents of
            a computer display. It is created by the operating system or
            software running on the device.
            """
        #expect(CaptureTextParagraphs.reflowed(read)
                == "A screenshot is a digital image that shows the contents of a computer display. It is created by the operating system or software running on the device.")
    }

    @Test func blankLinesHeadingsAndListsKeepTheirBreaks() {
        let read = """
            History
            The first screenshots were taken by photographing the screen with a camera
            mounted in front of it.

            Uses
            • Recording errors for support
            • Sharing designs
            1. Open the app
            2. Press the shortcut
            """
        #expect(CaptureTextParagraphs.reflowed(read) == """
            History
            The first screenshots were taken by photographing the screen with a camera mounted in front of it.

            Uses
            • Recording errors for support
            • Sharing designs
            1. Open the app
            2. Press the shortcut
            """)
    }

    @Test func codeKeepsEveryLine() {
        let code = """
            func tailPath(radius r: CGFloat) -> CGPath {
                let path = CGMutablePath()
                return path
            }
            """
        #expect(CaptureTextParagraphs.reflowed(code) == code)
    }

    /// A word split at the line's end is joined whole. A compound that happens to break at its own hyphen ("self-")
    /// loses it too: telling the two apart needs a dictionary, and the split word is the common case.
    @Test func aHyphenatedWordIsJoinedWhole() {
        #expect(CaptureTextParagraphs.reflowed("The capture is taken with a timer and an exam-\nple of the screen.")
                == "The capture is taken with a timer and an example of the screen.")
    }

    @Test func misreadFootnoteMarksGo() {
        #expect(CaptureTextParagraphs.reflowed("shows the contents of a computer display.!2] It is created")
                == "shows the contents of a computer display. It is created")
        // A mark stuck to a word goes when the text has a sure one too, and stays on its own (it may be an index).
        #expect(CaptureTextParagraphs.reflowed("the display.!2] Tokyo[3] is big") == "the display. Tokyo is big")
        #expect(CaptureTextParagraphs.reflowed("the display.[2] Tokyo[3] is big") == "the display. Tokyo[3] is big")
        #expect(CaptureTextParagraphs.reflowed("as a camera[3] would") == "as a camera[3] would")
        // Vision's reading of "display.[2]" in the VM check (2026-11-17), at a line's end and mid-line.
        #expect(CaptureTextParagraphs.reflowed("that powers the display. [2]") == "that powers the display.")
        #expect(CaptureTextParagraphs.reflowed("the display. [2] It is") == "the display. It is")
        // A bracket that isn't a footnote mark stays.
        #expect(CaptureTextParagraphs.reflowed("array [2] of items") == "array [2] of items")
        #expect(CaptureTextParagraphs.reflowed("the display.[2] It is") == "the display. It is")
    }

    /// Astra R5-3: an index in code isn't a footnote mark.
    @Test func codeSubscriptsStay() {
        #expect(CaptureTextParagraphs.reflowed("let value = array[2]\nreturn value") == "let value = array[2]\nreturn value")
        #expect(CaptureTextParagraphs.reflowed("result = matrix[12]") == "result = matrix[12]")
        #expect(CaptureTextParagraphs.reflowed("the first is items[0]") == "the first is items[0]")
        #expect(CaptureTextParagraphs.reflowed("if x[2] > 0 then") == "if x[2] > 0 then")
        // Astra R5A-2: one-line code, and an index mid-line.
        #expect(CaptureTextParagraphs.reflowed("let a = [[1],[2]]") == "let a = [[1],[2]]")
        #expect(CaptureTextParagraphs.reflowed("x[2] and y[3]") == "x[2] and y[3]")
        #expect(CaptureTextParagraphs.reflowed("print(a,[2])") == "print(a,[2])")
        // Astra R5A-4: marks inside a call's brackets, after commas.
        #expect(CaptureTextParagraphs.reflowed("print([1],[2], [3])") == "print([1],[2], [3])")
        // Sol, round 4: a comma proves nothing, so a Wikipedia mark after one stays.
        #expect(CaptureTextParagraphs.reflowed("([1], [2]), [3]") == "([1], [2]), [3]")
        #expect(CaptureTextParagraphs.reflowed("[1], [2], [3]") == "[1], [2], [3]")
        #expect(CaptureTextParagraphs.reflowed("Tokyo,[3] Osaka and Kyoto") == "Tokyo,[3] Osaka and Kyoto")
        // Sol, round 5: punctuation alone isn't prose.
        #expect(CaptureTextParagraphs.reflowed("\"abc\"[2]") == "\"abc\"[2]")
        #expect(CaptureTextParagraphs.reflowed("items?.[2]") == "items?.[2]")
        #expect(CaptureTextParagraphs.reflowed("value![2]") == "value![2]")
        #expect(CaptureTextParagraphs.reflowed("the \"abc\"[2] string is long") == "the \"abc\"[2] string is long")
        #expect(CaptureTextParagraphs.reflowed("the value![2] is set here") == "the value![2] is set here")
        #expect(CaptureTextParagraphs.reflowed("use items?.[2] when it exists") == "use items?.[2] when it exists")
        // A full stop inside a name isn't a sentence's end.
        #expect(CaptureTextParagraphs.reflowed("call obj.method.[2] after the setup") == "call obj.method.[2] after the setup")
        #expect(CaptureTextParagraphs.reflowed("print \"abc\".[2] in old Python") == "print \"abc\".[2] in old Python")
    }

    /// Fable live check C: 10 pt text captured at 1× lost "Uses"; read at 2× it didn't.
    @Test func aOneXCaptureIsReadAtTwoX() throws {
        let context = try #require(CGContext(data: nil, width: 120, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let oneX = CapturedDocumentText.readable(image, pixelsPerPoint: 1)
        #expect(oneX.width == 240 && oneX.height == 80)
        #expect(CapturedDocumentText.readable(image, pixelsPerPoint: 2).width == 120)
        #expect(CapturedDocumentText.readable(image, pixelsPerPoint: 1.5).width == 120)
    }

    /// Astra: the 2× read is capped, so an 8K capture at 1× isn't scaled to 15360 × 8640.
    @Test func theTwoXReadHasAPixelCap() throws {
        #expect(CapturedDocumentText.readableScale(width: 1920, height: 1080, pixelsPerPoint: 1) == 2)
        #expect(CapturedDocumentText.readableScale(width: 3840, height: 2160, pixelsPerPoint: 1) == 2)
        let fiveK = try #require(CapturedDocumentText.readableScale(width: 5120, height: 2880, pixelsPerPoint: 1))
        #expect(fiveK < 2 && Double(5120 * 2880) * Double(fiveK * fiveK) <= CapturedDocumentText.readableMaxPixels + 1)
        #expect(CapturedDocumentText.readableScale(width: 7680, height: 4320, pixelsPerPoint: 1) == nil)
        #expect(CapturedDocumentText.readableScale(width: 1920, height: 1080, pixelsPerPoint: 2) == nil)
    }

    /// The image both readers get, from the capture file: scaled when the drawn area says it's 1×, as it is otherwise.
    @Test func theReadableImageComesFromTheFileOnce() throws {
        let context = try #require(CGContext(data: nil, width: 120, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("readable-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(CapturedDocumentText.readableImage(at: url, area: CGRect(x: 0, y: 0, width: 120, height: 40))?.width == 240)
        #expect(CapturedDocumentText.readableImage(at: url, area: CGRect(x: 0, y: 0, width: 60, height: 20))?.width == 120)
        #expect(CapturedDocumentText.readableImage(at: url, area: nil)?.width == 120)
    }

    @Test func theMessageNamesTheFirstWords() {
        #expect(CaptureTextParagraphs.firstWords(of: "A screenshot is a digital image that shows the contents")
                == "A screenshot is a digital image that shows…")
        #expect(CaptureTextParagraphs.firstWords(of: "Two words") == "Two words")
        #expect(CaptureTextParagraphs.wordCount(of: "One two\nthree") == 3)
    }

    /// Astra R5-5: a sentence ends a line in any script.
    @Test func sentenceEndsInOtherScriptsKeepTheirLines() {
        #expect(CaptureTextParagraphs.reflowed("هل هذا صحيح؟\nهذا سطر مستقل.") == "هل هذا صحيح؟\nهذا سطر مستقل.")
        #expect(CaptureTextParagraphs.reflowed("هذه جملة طويلة تكمل في السطر\nالتالي من النص.") == "هذه جملة طويلة تكمل في السطر التالي من النص.")
        #expect(CaptureTextParagraphs.reflowed("यह एक वाक्य है।\nयह दूसरा है।") == "यह एक वाक्य है।\nयह दूसरा है।")
        #expect(CaptureTextParagraphs.reflowed("これは文です。\nこれも文です。") == "これは文です。\nこれも文です。")
    }
}
