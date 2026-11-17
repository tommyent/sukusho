import Foundation
import Testing

/// Astra R5-1: after a clipboard image's first saved edit imports it, the editor works on the capture.
struct EditorSaveIdentityTests {
    let history = URL(fileURLWithPath: "/History")
    func isHistory(_ url: URL) -> Bool { url.path.hasPrefix(history.path + "/") }

    @Test func theFirstSaveOfAnOutsideFileMovesTheEditorToItsCapture() {
        let copy = URL(fileURLWithPath: "/tmp/Clipboard Edits/E1/image.png")
        let capture = history.appendingPathComponent("screenshot_1.png")
        let afterFirst = EditorSaveIdentity.afterSave(editing: copy, savedTo: capture, isHistory: isHistory)
        #expect(afterFirst == capture)
        // Clear all and save: the capture's own removal, which returns the capture.
        #expect(EditorSaveIdentity.afterSave(editing: afterFirst, savedTo: capture, isHistory: isHistory) == capture)
    }

    @Test func otherSavesKeepTheFile() {
        let capture = history.appendingPathComponent("screenshot_1.png")
        let outside = URL(fileURLWithPath: "/Users/someone/Desktop/a.png")
        #expect(EditorSaveIdentity.afterSave(editing: capture, savedTo: capture, isHistory: isHistory) == capture)
        // An outside file whose last shape was removed before any import stays outside.
        #expect(EditorSaveIdentity.afterSave(editing: outside, savedTo: outside, isHistory: isHistory) == outside)
    }
}
