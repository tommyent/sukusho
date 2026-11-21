import SwiftUI

struct RecordingRedactionControls: View {
    @Bindable var model: RecordingStudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            if model.isSelectingRedaction {
                InspectorHint("Draw or resize a rectangle over the screen video.")
                HStack {
                    geometryField("X", keyPath: \.origin.x)
                    geometryField("Y", keyPath: \.origin.y)
                }
                HStack {
                    geometryField("Width", keyPath: \.size.width)
                    geometryField("Height", keyPath: \.size.height)
                }
                HStack {
                    InspectorActionButton("Cancel", systemImage: "xmark") { model.cancelRedaction() }
                    InspectorActionButton("Add", systemImage: "plus") { model.addRedaction() }
                }
            } else {
                InspectorActionButton("Add Redaction", systemImage: "rectangle.dashed") { model.beginRedaction() }
                    .disabled(!model.isLoaded || model.hasRunningWork)
            }
            ForEach(model.redactions) { region in
                Button {
                    model.selectRedaction(id: region.id)
                    if let time = model.editorTime(forSourceTime: region.start) { model.seek(to: time) }
                } label: {
                    HStack {
                        Image(systemName: region.mode.systemImage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(region.mode.title)
                        Spacer()
                        Text("\(region.start, format: .number.precision(.fractionLength(2)))–\(region.end, format: .number.precision(.fractionLength(2))) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(region.mode.title), source seconds \(region.start) to \(region.end)")
            }
            if let error = model.redactionEditError { InspectorHint(error, tint: .orange) }
            InspectorHint("Times use the original recording. The original stays in the package; previews and exports are redacted. Camera, audio and captions are unchanged.")
        }
        .disabled(!model.isLoaded || model.hasRunningWork)
    }

    private func geometryField(_ label: String, keyPath: WritableKeyPath<CGRect, CGFloat>) -> some View {
        VStack(alignment: .leading) {
            Text(label)
            TextField(label, value: Binding<Double>(
                get: { Double(model.workingVideoCropRect[keyPath: keyPath]) },
                set: { value in
                    guard value.isFinite else { return }
                    var rect = model.workingVideoCropRect
                    rect[keyPath: keyPath] = CGFloat(min(max(value, 0), 1))
                    let clipped = rect.intersection(CropRectEditor.unit)
                    if clipped.width > 0, clipped.height > 0 { model.workingVideoCropRect = clipped }
                }
            ), format: .percent.precision(.fractionLength(0)))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Redaction \(label.lowercased()) as a percentage of the source")
        }
    }
}
