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

    /// A capture saved with a camera tilt opens with the switch on.
    @Test static func aSavedTiltOpensWithTheSwitchOn() {
        var settings = AnnotationBackgroundSettings()
        settings.camera.tiltYDegrees = 12
        let reopened = StoredBackground(settings).settings
        #expect(AnnotationCameraSwitch.isOn(reopened.camera))
    }
}
