#if THEME_TUNER
//
//  ThemeTunerView.swift
//  Screendrop
//
//  The Theme Tuner window (Sukusho › Theme Tuner…), in the owner's own builds only (see ThemeTuning.swift).
//

import AppKit
import SwiftUI

/// Chip's line, edge, shadow and paper, or Glass's frost, picture and text, on the live Library, Light and Dark apart:
/// whichever the edited appearance's slot draws. Moving any control turns that theme's tuning on.
struct ThemeTunerView: View {
    static let windowID = "THEME_TUNER"

    @AppStorage(ThemeTuning.key) private var data: Data?
    @AppStorage(GlassTuning.key) private var glassData: Data?
    @AppStorage(AppTheme.lightKey) private var lightSlot = AppTheme.classicLight.id
    @AppStorage(AppTheme.darkKey) private var darkSlot = AppTheme.classicDark.id
    @Environment(\.colorScheme) private var scheme
    @State private var editsDark: Bool?

    private var tuning: ThemeTuning { ThemeTuning(data) }
    private var glass: GlassTuning { GlassTuning(glassData) }
    /// The side being edited: the window's own appearance until the picker says otherwise.
    private var dark: Bool { editsDark ?? (scheme == .dark) }
    private var tunesGlass: Bool { (dark ? darkSlot : lightSlot).hasPrefix("glass") }

    var body: some View {
        Form {
            Toggle("Use tuned values", isOn: Binding(get: { tunesGlass ? glass.on : tuning.on }, set: { on in
                if tunesGlass { var g = glass; g.on = on; glassData = g.data } else { var t = tuning; t.on = on; data = t.data }
            }))
            Picker("Appearance", selection: Binding(get: { dark }, set: { editsDark = $0 })) {
                Text("Light").tag(false)
                Text("Dark").tag(true)
            }
            .pickerStyle(.segmented)
            if tunesGlass {
                glassSections
            } else {
                if !(dark ? darkSlot : lightSlot).hasPrefix("chip") {
                    Text("Pick Chip or Glass for \(dark ? "Dark" : "Light") in Settings › Appearance to see these values.")
                        .foregroundStyle(.secondary)
                }
                chipSections
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            // Outside the form, so they stay in view when it scrolls.
            HStack {
                Button("Reset") {
                    if tunesGlass { var g = GlassTuning(); g.on = glass.on; glassData = g.data }
                    else { var t = ThemeTuning(); t.on = tuning.on; data = t.data }
                }
                Spacer()
                Button("Copy Values") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tunesGlass ? glass.swift : tuning.swift, forType: .string)
                }
            }
            .padding(12)
            .background(.bar)
        }
        .frame(width: 380, height: 830)
        .onAppear { AppActivationPolicy.enter() }
        .onDisappear { AppActivationPolicy.leave() }
    }

    @ViewBuilder private var glassSections: some View {
        Section("Frost") {
            Picker("Material", selection: glassSide(\.material)) {
                ForEach(AppTheme.FrostMaterial.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            ColorPicker("Tint", selection: glassColor(\.tint), supportsOpacity: false)
            glassSlider("Tint opacity", \.tintOpacity, 0...1)
            glassSlider("Rim", \.rimOpacity, 0...1)
        }
        Section("Picture") {
            glassSlider("Blur", \.blur, 0...60, stepsPerUnit: 1)
            glassSlider("Dim", \.dim, 0...0.9)
        }
    }

    @ViewBuilder private var chipSections: some View {
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

    /// The edited side's Glass value, saved at once, which turns Glass's tuning on.
    private func glassSide<Value>(_ path: WritableKeyPath<GlassTuning.Side, Value>) -> Binding<Value> {
        let dark = dark
        return Binding(get: { glass[isDark: dark][keyPath: path] }, set: { value in
            var g = glass
            g[isDark: dark][keyPath: path] = value
            g.on = true
            glassData = g.data
        })
    }

    private func glassColor(_ path: WritableKeyPath<GlassTuning.Side, UInt32>) -> Binding<Color> {
        let hex = glassSide(path)
        return Binding(get: { ThemeColor.rgb(hex.wrappedValue).color }, set: { hex.wrappedValue = ThemeTuning.hex($0) })
    }

    private func glassSlider(_ title: String, _ path: WritableKeyPath<GlassTuning.Side, Double>, _ range: ClosedRange<Double>,
                             stepsPerUnit: Double = 100) -> some View {
        stepSlider(title, glassSide(path), range, stepsPerUnit: stepsPerUnit)
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
        stepSlider(title, side(path), range, stepsPerUnit: stepsPerUnit)
    }

    private func stepSlider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                            stepsPerUnit: Double) -> some View {
        LabeledContent(title) {
            HStack {
                // Whole steps (hundredths by default), so the copied lines are exactly what's on screen.
                Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 * stepsPerUnit).rounded() / stepsPerUnit }), in: range)
                    .labelsHidden()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .frame(minWidth: 34, alignment: .trailing)   // Glass's blur runs to two digits before the point
            }
        }
    }
}
#endif
