import AppKit
import SwiftUI
import Testing

/// The editor inspector's rules that don't need a view (sd-g18y).
@MainActor
@Suite
struct EditorInspectorTests {
    /// Camera is a switch: off is flat and keeps the last values, on brings them back, and the
    /// first time on applies a gentle tilt so the switch visibly does something.
    @Test static func cameraSwitchParksAndRestoresTheLastValues() {
        var cameraSwitch = AnnotationCameraSwitch()
        var camera = AnnotationCameraSettings()
        #expect(!AnnotationCameraSwitch.isOn(camera))

        cameraSwitch.turn(true, camera: &camera)
        #expect(camera == .gentleTilt && camera.hasEffect && AnnotationCameraSwitch.isOn(camera))

        camera.rollDegrees = 9
        let tilted = camera
        cameraSwitch.turn(false, camera: &camera)
        #expect(camera == AnnotationCameraSettings() && !camera.hasEffect)
        #expect(!AnnotationCameraSwitch.isOn(camera))

        cameraSwitch.turn(true, camera: &camera)
        #expect(camera == tilted)

        // Turning on what is already on changes nothing.
        cameraSwitch.turn(true, camera: &camera)
        #expect(camera == tilted)
    }

    /// With nothing to place the screenshot on, the placement and edge rows are hidden; a
    /// background, a border, a camera or scene blur brings them back, and Camera blocks only
    /// Alignment, which then says why.
    @Test static func placementRowsShowOnlyWhenTheyWork() {
        var settings = AnnotationBackgroundSettings()
        #expect(!settings.requiresCanvasLayout && settings.alignmentAvailability == .hidden)

        settings.style = .solid(.transparent)
        #expect(settings.requiresCanvasLayout && settings.alignmentAvailability == .available)

        var cameraSwitch = AnnotationCameraSwitch()
        cameraSwitch.turn(true, camera: &settings.camera)
        #expect(settings.alignmentAvailability == .blockedByCamera)
        cameraSwitch.turn(false, camera: &settings.camera)
        #expect(settings.alignmentAvailability == .available)

        settings.style = .none
        settings.border.isEnabled = true
        #expect(settings.alignmentAvailability == .available, "a border needs a canvas, so padding works")
        settings.border.isEnabled = false
        settings.progressiveBlur.isEnabled = true
        #expect(settings.alignmentAvailability == .available, "scene blur needs a canvas too")
    }

    /// Crop, Pick Color and Measure take precedence over the dock's selected tool.
    @Test static func toolSlotFollowsTheDock() {
        func slot(_ tool: AnnotationTool?, _ count: Int = 0, crop: Bool = false, pick: Bool = false, measure: Bool = false) -> AnnotationToolSlot {
            .current(tool: tool, selectionCount: count, isCropping: crop, isPickingColor: pick, isMeasuring: measure)
        }
        #expect(slot(.magnifier).heading == "Magnifier")
        #expect(slot(.text, 1).heading == "Text")
        #expect(slot(.arrow, 3).heading == "3 Annotations")
        #expect(slot(nil).heading == "Select")
        #expect(slot(.magnifier, crop: true) == .crop)
        #expect(slot(.magnifier, pick: true).heading == "Pick Color")
        #expect(slot(.text, 1, measure: true).heading == "Measure")
        #expect(slot(.text, crop: true, pick: true) == .crop)
        for tool in AnnotationTool.allCases {
            #expect(!AnnotationToolSlot.tool(tool).line.isEmpty)
        }
    }

    /// One letter per tool, shared by the keyboard, the tooltips and the Tools menu; C is Crop's.
    @Test static func toolLettersAreUniqueAndInTheTooltips() {
        let keyed = AnnotationTool.allCases.compactMap { tool in tool.shortcutKey.map { (tool, $0) } }
        #expect(Set(keyed.map(\.1)).count == keyed.count)
        #expect(!keyed.contains { $0.1 == "c" })
        for (tool, key) in keyed {
            #expect(tool.helpText == "\(tool.title) (\(key.uppercased()))")
        }
        #expect(AnnotationTool.rectangle.shortcutKey == "r" && AnnotationTool.numberedCircle.shortcutKey == "n")
        #expect(AnnotationTool.freehand.helpText == "Freehand")
    }

    /// The inspector folds as the window is made narrower past the point, stays folded until there
    /// is room again plus a margin, and a window that opens narrow starts folded (Fable #7).
    @Test static func inspectorFoldsBelowTheWidthAndComesBack() {
        var state = InspectorFoldState()
        var shown = true
        func resize(_ width: CGFloat) {
            let next = state.resized(to: width, foldBelow: 1000, isPresented: shown)
            state = next.state
            shown = next.isPresented
        }
        resize(1100); #expect(shown && !state.isFolded)
        resize(990); #expect(!shown && state.isFolded)
        resize(800); #expect(!shown)
        resize(1020); #expect(!shown, "not back until the margin")
        resize(1040); #expect(shown && !state.isFolded)

        // Hidden by hand, it stays hidden however wide the window gets.
        shown = false
        resize(990); resize(1200)
        #expect(!shown)

        // Shown by hand while narrow (the view clears the fold), it stays at that width and while
        // the window grows, and folds again as soon as the window is made narrower.
        state = InspectorFoldState(width: 800, isFolded: false)
        shown = true
        resize(800); #expect(shown)
        resize(820); #expect(shown)
        resize(810); #expect(!shown)

        var narrow = InspectorFoldState()
        let opened = narrow.resized(to: 900, foldBelow: 1000, isPresented: true)
        narrow = opened.state
        #expect(!opened.isPresented && narrow.isFolded)
    }

    /// Once initial placement settles, tiling or any resize below the fold point folds the inspector
    /// and widening past the return margin brings it back.
    @Test static func imageInspectorFoldsWhenTiledAfterPlacementSettles() {
        let settled = InspectorFoldState().resized(to: 1100, foldBelow: 1000, isPresented: true)
        #expect(settled.isPresented && !settled.state.isFolded)

        let tiled = settled.state.resized(to: 720, foldBelow: 1000, isPresented: settled.isPresented)
        #expect(!tiled.isPresented && tiled.state.isFolded)

        let restored = tiled.state.resized(to: 1100, foldBelow: 1000, isPresented: tiled.isPresented)
        #expect(restored.isPresented && !restored.state.isFolded)
    }

    @Test static func inspectorChoicePersistsMenuTogglesButNotAutoFolds() {
        let suite = "com.tommyent.Sukusho.tests.inspector.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "test.inspectorVisible"

        var shown = InspectorVisibilityStore.initial(forKey: key, defaults: defaults)
        #expect(shown)

        let choice = InspectorVisibilityStore.binding(
            Binding(get: { shown }, set: { shown = $0 }),
            key: key,
            defaults: defaults
        )

        // View › Hide / Show Inspector and ⌘⌥I go through the choice binding and persist.
        choice.wrappedValue = false
        #expect(!shown && !InspectorVisibilityStore.initial(forKey: key, defaults: defaults))
        choice.wrappedValue = true
        #expect(shown && InspectorVisibilityStore.initial(forKey: key, defaults: defaults))

        // Auto-folding updates the state directly; even an echoed false through the binding
        // must not overwrite the saved choice.
        let folded = InspectorFoldState(width: 1100).resized(to: 900, foldBelow: 1000, isPresented: shown)
        shown = folded.isPresented
        #expect(!shown && folded.state.isFolded)
        choice.wrappedValue = false
        #expect(InspectorVisibilityStore.initial(forKey: key, defaults: defaults))

        // Showing by hand while folded updates both the view and the saved choice.
        choice.wrappedValue = true
        #expect(shown && InspectorVisibilityStore.initial(forKey: key, defaults: defaults))
    }

    /// ⌘S saves; ⌃⌘S is View › Show Sidebar and must not save too (Astra E3), and ⇧⌘S is Save As.
    @Test static func onlyPlainCommandSSaves() {
        #expect(EditorKeyChords.isSave([.command], characters: "s"))
        #expect(EditorKeyChords.isSave([.command, .capsLock], characters: "S"))
        #expect(!EditorKeyChords.isSave([.command, .control], characters: "s"))
        #expect(!EditorKeyChords.isSave([.command, .shift], characters: "s"))
        #expect(!EditorKeyChords.isSave([.command, .option], characters: "s"))
        #expect(!EditorKeyChords.isSave([], characters: "s"))
        #expect(!EditorKeyChords.isSave([.command], characters: "d"))
    }

    /// A capture saved with a camera tilt opens with the switch on.
    @Test static func aSavedTiltOpensWithTheSwitchOn() {
        var settings = AnnotationBackgroundSettings()
        settings.camera.tiltYDegrees = 12
        let reopened = StoredBackground(settings).settings
        #expect(AnnotationCameraSwitch.isOn(reopened.camera))
    }

    /// `InspectorAutoFold` must hold its window weakly so SwiftUI's view graph never pins a closed `NSWindow`.
    @Test static func inspectorAutoFoldDoesNotRetainWindow() {
        weak var weakWindow: NSWindow?
        var modifier: InspectorAutoFold?
        var presented = true
        autoreleasepool {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            weakWindow = window
            let host = WeakWindow(window)
            modifier = InspectorAutoFold(
                isPresented: Binding(get: { presented }, set: { presented = $0 }),
                foldBelow: 1000,
                host: host,
                windowID: ObjectIdentifier(window),
                fold: InspectorFoldBox()
            )
        }
        #expect(modifier != nil)
        #expect(weakWindow == nil, "InspectorAutoFold retained its NSWindow strongly")
        modifier = nil
    }

    /// sd-kutk: a resize reaches the view graph only when it folds or unfolds the inspector. Every other
    /// resize, such as each step of a window that SwiftUI or tiling animates, or AppKit settling a frame
    /// back and forth, changes nothing SwiftUI watches, so it can't start another layout pass.
    @Test static func foldBoxTouchesTheViewOnlyWhenItFolds() {
        let fold = InspectorFoldBox()
        var shown = true
        var changes: [(width: CGFloat, shown: Bool)] = []
        func resize(_ width: CGFloat) {
            if let next = fold.resize(to: width, foldBelow: 900, isPresented: shown) {
                shown = next
                changes.append((width, next))
            }
        }
        resize(1180)
        #expect(changes.isEmpty)

        // Narrowed a point at a time down to the minimum: one fold, at the fold point.
        for width in stride(from: 1179, through: 620, by: -1) { resize(CGFloat(width)) }
        #expect(changes.map(\.shown) == [false] && changes.first?.width == 899)

        // A frame that settles back and forth while folded, as the Air's crash did at 2650 and 2655.
        for _ in 0..<500 { resize(760); resize(761) }
        #expect(changes.count == 1)

        // Widened a point at a time past 3000: one unfold, at the fold point plus its margin.
        for width in stride(from: 621, through: 3200, by: 1) { resize(CGFloat(width)) }
        #expect(changes.map(\.shown) == [false, true] && changes.last?.width == 940)

        // Every step of an animated resize far above the fold point, and back and forth there.
        for width in stride(from: 1180, through: 2655, by: 5) { resize(CGFloat(width)) }
        for _ in 0..<500 { resize(2650); resize(2655) }
        #expect(changes.count == 2)

        // A zero width (a window still being set up) is ignored.
        #expect(fold.resize(to: 0, foldBelow: 900, isPresented: shown) == nil)
    }
}
