#if THEME_TUNER
//
//  ThemeTunerView.swift
//  Screendrop
//
//  The Theme Tuner window (Sukusho › Theme Tuner…), in the owner's own builds only (see ThemeTuning.swift).
//

import AppKit
import SwiftUI

/// Chip's line, edge, shadow and paper on the live Library, Light and Dark apart. Moving any control turns the tuner on.
struct ThemeTunerView: View {
    static let windowID = "THEME_TUNER"

    @AppStorage(ThemeTuning.key) private var data: Data?
    @AppStorage(AppTheme.lightKey) private var lightSlot = AppTheme.classicLight.id
    @AppStorage(AppTheme.darkKey) private var darkSlot = AppTheme.classicDark.id
    @Environment(\.colorScheme) private var scheme
    @State private var editsDark: Bool?

    private var tuning: ThemeTuning { ThemeTuning(data) }
    /// The side being edited: the window's own appearance until the picker says otherwise.
    private var dark: Bool { editsDark ?? (scheme == .dark) }

    var body: some View {
        Form {
            Toggle("Use tuned values", isOn: Binding(get: { tuning.on }, set: { var t = tuning; t.on = $0; data = t.data }))
            Picker("Appearance", selection: Binding(get: { dark }, set: { editsDark = $0 })) {
                Text("Light").tag(false)
                Text("Dark").tag(true)
            }
            .pickerStyle(.segmented)
            if !(dark ? darkSlot : lightSlot).hasPrefix("chip") {
                Text("Pick Chip for \(dark ? "Dark" : "Light") in Settings › Appearance to see these values.")
                    .foregroundStyle(.secondary)
            }
            Section("Picture") {
                slider("Inset", \.inset, 0...20, stepsPerUnit: 2)   // half points
            }
            Section("Line under the picture") {
                ColorPicker("Color", selection: color(\.line), supportsOpacity: false)
                Toggle("Solid", isOn: side(\.lineSolid))
                slider("Opacity", \.lineOpacity, 0...1).disabled(tuning[isDark: dark].lineSolid)
            }
            Section("Outer edge") {
                ColorPicker("Color", selection: color(\.edge), supportsOpacity: false)
                slider("Opacity", \.edgeOpacity, 0...1)
            }
            Section("Shadow") {
                slider("Opacity", \.shadow, 0...1)
                slider("Radius ×", \.shadowBlur, 0...3)
                slider("Offset ×", \.shadowOffset, 0...3)
            }
            Section("Paper grain") {
                slider("Strength", \.paper, 0...1)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            // Outside the form, so they stay in view when it scrolls.
            HStack {
                Button("Reset") { var t = ThemeTuning(); t.on = tuning.on; data = t.data }
                Spacer()
                Button("Copy Values") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tuning.swift, forType: .string)
                }
            }
            .padding(12)
            .background(.bar)
        }
        .frame(width: 380, height: 830)
        .onAppear { AppActivationPolicy.enter() }
        .onDisappear { AppActivationPolicy.leave() }
    }

    /// The edited side's value. A change is saved at once, which the Library's cards redraw from, and turns the tuner on.
    private func side<Value>(_ path: WritableKeyPath<ThemeTuning.Side, Value>) -> Binding<Value> {
        let dark = dark
        return Binding(get: { tuning[isDark: dark][keyPath: path] }, set: { value in
            var t = tuning
            t[isDark: dark][keyPath: path] = value
            t.on = true
            data = t.data
        })
    }

    private func color(_ path: WritableKeyPath<ThemeTuning.Side, UInt32>) -> Binding<Color> {
        let hex = side(path)
        return Binding(get: { ThemeColor.rgb(hex.wrappedValue).color }, set: { hex.wrappedValue = ThemeTuning.hex($0) })
    }

    private func slider(_ title: String, _ path: WritableKeyPath<ThemeTuning.Side, Double>, _ range: ClosedRange<Double>,
                        stepsPerUnit: Double = 100) -> some View {
        let value = side(path)
        return LabeledContent(title) {
            HStack {
                // Whole steps (hundredths by default), so the copied lines are exactly what's on screen.
                Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 * stepsPerUnit).rounded() / stepsPerUnit }), in: range)
                    .labelsHidden()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }
}
#endif
