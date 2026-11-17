import CoreGraphics
import Testing

/// Fable #3: a drawn recording area can be moved and resized before Record, and stays on the display.
struct AreaHandleTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let area = CGRect(x: 100, y: 100, width: 300, height: 200)

    @Test func movingKeepsTheSizeAndStaysOnTheDisplay() {
        #expect(AreaHandle.adjust(area, handle: nil, by: CGSize(width: 50, height: -20), within: bounds, minimum: 16)
                == CGRect(x: 150, y: 80, width: 300, height: 200))
        // Pushed past the edges, it stops at them.
        #expect(AreaHandle.adjust(area, handle: nil, by: CGSize(width: 5000, height: -5000), within: bounds, minimum: 16)
                == CGRect(x: 700, y: 0, width: 300, height: 200))
    }

    @Test func aHandleMovesOnlyItsOwnEdges() {
        #expect(AreaHandle.adjust(area, handle: .topRight, by: CGSize(width: 40, height: 30), within: bounds, minimum: 16)
                == CGRect(x: 100, y: 100, width: 340, height: 230))
        #expect(AreaHandle.adjust(area, handle: .left, by: CGSize(width: -60, height: 99), within: bounds, minimum: 16)
                == CGRect(x: 40, y: 100, width: 360, height: 200))
        #expect(AreaHandle.adjust(area, handle: .bottom, by: CGSize(width: 99, height: -40), within: bounds, minimum: 16)
                == CGRect(x: 100, y: 60, width: 300, height: 240))
    }

    @Test func aResizeStopsAtTheMinimumAndTheDisplay() {
        // Dragged past the opposite edge, the area keeps its minimum size rather than flipping.
        #expect(AreaHandle.adjust(area, handle: .bottomLeft, by: CGSize(width: 900, height: 900), within: bounds, minimum: 16)
                == CGRect(x: 384, y: 284, width: 16, height: 16))
        #expect(AreaHandle.adjust(area, handle: .topRight, by: CGSize(width: 5000, height: 5000), within: bounds, minimum: 16)
                == CGRect(x: 100, y: 100, width: 900, height: 700))
    }

    @Test func handlesSitOnTheCornersAndEdgeMiddles() {
        #expect(AreaHandle.bottomLeft.rect(in: area).center == CGPoint(x: 100, y: 100))
        #expect(AreaHandle.top.rect(in: area).center == CGPoint(x: 250, y: 300))
        #expect(AreaHandle.right.rect(in: area).center == CGPoint(x: 400, y: 200))
    }
}

/// sd-7l2f: only macOS's own Screenshot UI running ends the picker; nothing else that runs or starts does.
struct AreaPickerSystemScreenshotTests {
    @Test func onlyMacOSsScreenshotUIEndsThePicker() {
        #expect(AreaPickerSystemScreenshot.endsPicker(running: ["com.apple.screencaptureui"]))
        #expect(AreaPickerSystemScreenshot.endsPicker(running: ["com.apple.finder", nil, "com.apple.screencaptureui"]))
        // Sukusho itself, the private-window prompt's process, any other app, or one without an ID: the picker stays.
        let others: [String?] = ["com.tommyent.Sukusho", "com.tommyent.Sukusho.dev", "com.apple.UserNotificationCenter",
                                 "com.apple.finder", "com.apple.screencaptureui.helper", "", nil]
        #expect(!AreaPickerSystemScreenshot.endsPicker(running: others))
        #expect(!AreaPickerSystemScreenshot.endsPicker(running: []))
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
