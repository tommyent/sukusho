//
//  SettingsOptimizePane.swift
//  Screendrop
//
//  Settings › Optimize: what the image optimizer does by itself (copies, new
//  captures, Cloud shares) and how hard it works when asked.
//

import SwiftUI

nonisolated enum OptimizePreferences {
    static let whenCopyingKey = "optimizeWhenCopying"
    static let newCapturesKey = "optimizeNewCaptures"
    static let beforeCloudKey = "optimizeBeforeCloud"
    static let effortKey = "optimizePNGEffort"
    static let webPLosslessKey = "optimizeWebPLossless"
    static let webPQualityKey = "optimizeWebPQuality"
    static let jpegQualityKey = "optimizeJPEGQuality"
    static let defaultQuality = 80.0

    static var whenCopying: Bool { isOn(whenCopyingKey) }
    static var newCaptures: Bool { isOn(newCapturesKey) }
    static var beforeCloud: Bool { isOn(beforeCloudKey) }

    static var effort: ImageOptimizationEffort {
        UserDefaults.standard.string(forKey: effortKey).flatMap(ImageOptimizationEffort.init) ?? .balanced
    }

    /// Work nobody asked for by name (a copy, a new capture, an upload) never takes Smallest's time.
    static var quietEffort: ImageOptimizationEffort { effort == .smallest ? .balanced : effort }

    static var webP: ImageOptimizationTarget { .webP(quality: isOn(webPLosslessKey) ? nil : quality(webPQualityKey)) }
    static var jpeg: ImageOptimizationTarget { .jpeg(quality: quality(jpegQualityKey)) }

    /// The switches are on until turned off.
    private static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private static func quality(_ key: String) -> Int {
        Int((UserDefaults.standard.object(forKey: key) as? NSNumber)?.doubleValue ?? defaultQuality)
    }
}

extension ImageOptimizationEffort {
    var title: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .smallest: "Smallest"
        }
    }
}

struct OptimizeSettingsPane: View {
    @AppStorage(OptimizePreferences.whenCopyingKey) private var whenCopying = true
    @AppStorage(OptimizePreferences.effortKey) private var effort = ImageOptimizationEffort.balanced
    @AppStorage(OptimizePreferences.webPLosslessKey) private var webPLossless = true
    @AppStorage(OptimizePreferences.webPQualityKey) private var webPQuality = OptimizePreferences.defaultQuality
    @AppStorage(OptimizePreferences.jpegQualityKey) private var jpegQuality = OptimizePreferences.defaultQuality

    var body: some View {
        Form {
            Section("Copying") {
                SettingsControlLabel(
                    "Optimize when copying",
                    detail: "Copies a smaller image with the same pixels. Esc while it works, or ⇧⌘C, copies the original."
                ).control { label in
                    Toggle(isOn: $whenCopying) { label }
                }
                .toggleStyle(.switch)
            }

            Section("PNG") {
                SettingsControlLabel(
                    "Effort",
                    detail: "Balanced is the everyday setting. Smallest takes several times longer for a little more, and is used only for Optimize and the shelf."
                ).control { label in
                    Picker(selection: $effort) {
                        ForEach(ImageOptimizationEffort.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        label
                    }
                }
            }

            Section("Converting") {
                SettingsControlLabel(
                    "WebP",
                    detail: "Lossless keeps every pixel. Smaller trades detail for size."
                ).control { label in
                    Picker(selection: $webPLossless) {
                        Text("Lossless").tag(true)
                        Text("Smaller").tag(false)
                    } label: {
                        label
                    }
                    .pickerStyle(.segmented)
                }

                if !webPLossless {
                    OptimizeQualitySlider(title: "WebP quality", quality: $webPQuality)
                }

                OptimizeQualitySlider(title: "JPEG quality", quality: $jpegQuality)

                Text("JPEG quality is for Convert to JPEG. A JPEG you optimize is repacked without re-encoding, so it loses nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

/// A quality from 10 to 100, shown as a percentage: Settings and the Convert sheet use the same one.
struct OptimizeQualitySlider: View {
    let title: String
    @Binding var quality: Double

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: $quality, in: 10...100, step: 5)
                    .frame(width: 180)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(Int(quality)) percent")

                Text("\(Int(quality))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}
