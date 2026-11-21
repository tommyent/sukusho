import AppKit
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

    @Test static func imageInspectorStaysOpenAsTheWindowSettles() {
        let opened = InspectorFoldState().resized(to: 990, foldBelow: 1000, isPresented: true, canFold: false)
        #expect(opened.isPresented && !opened.state.isFolded)

        let settled = opened.state.resized(to: 950, foldBelow: 1000, isPresented: true, canFold: false)
        #expect(settled.isPresented && !settled.state.isFolded)

        let resized = settled.state.resized(to: 920, foldBelow: 1000, isPresented: true)
        #expect(!resized.isPresented && resized.state.isFolded)
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
}
