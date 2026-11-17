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

    /// A capture saved with a camera tilt opens with the switch on.
    @Test static func aSavedTiltOpensWithTheSwitchOn() {
        var settings = AnnotationBackgroundSettings()
        settings.camera.tiltYDegrees = 12
        let reopened = StoredBackground(settings).settings
        #expect(AnnotationCameraSwitch.isOn(reopened.camera))
    }
}
