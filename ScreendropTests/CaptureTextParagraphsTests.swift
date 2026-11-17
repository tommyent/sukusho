import CoreGraphics
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
        #expect(CaptureTextParagraphs.reflowed("as a camera[3] would") == "as a camera would")
        // Vision's reading of "display.[2]" in the VM check (2026-11-17), at a line's end and mid-line.
        #expect(CaptureTextParagraphs.reflowed("that powers the display. [2]") == "that powers the display.")
        #expect(CaptureTextParagraphs.reflowed("the display. [2] It is") == "the display. It is")
        // A bracket that isn't a footnote mark stays.
        #expect(CaptureTextParagraphs.reflowed("array [2] of items") == "array [2] of items")
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

    @Test func theMessageNamesTheFirstWords() {
        #expect(CaptureTextParagraphs.firstWords(of: "A screenshot is a digital image that shows the contents")
                == "A screenshot is a digital image that shows…")
        #expect(CaptureTextParagraphs.firstWords(of: "Two words") == "Two words")
        #expect(CaptureTextParagraphs.wordCount(of: "One two\nthree") == 3)
    }
}
