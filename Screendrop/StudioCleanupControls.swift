//
//  StudioCleanupControls.swift
//  Screendrop
//

import SwiftUI

/// Studio's Edit tab, under the transcript: Remove Filler Words and Shorten
/// Pauses. Each shows its count first, and each applies as Studio's usual
/// cuts in one undoable step.
struct StudioCleanupControls: View {
    @Bindable var model: RecordingStudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            fillerControls
            Divider().opacity(0.6)
            pauseControls
        }
        // Keyed on every pause, checked or not, so the task restarts when the
        // pauses change (a cut, a new threshold), not as each result lands.
        .task(id: allPauseGaps) {
            await model.checkPauseScreens()
        }
    }

    private var allPauseGaps: String {
        let summary = model.pauseSummary
        return (summary.shortenable + summary.kept + summary.checking).map(\.gap.lowerBound).sorted().description
    }

    // MARK: Filler words

    @ViewBuilder
    private var fillerControls: some View {
        let count = model.removableFillerWordCount
        let language = model.transcriptLanguage

        if language.map(TranscriptEditPlanner.fillerLanguages.contains) != true {
            InspectorHint("Filler words aren't listed for this transcript's language.")
        } else {
            HStack(spacing: InspectorMetrics.rowSpacing) {
                Text(count == 0 ? "No filler words" : count == 1 ? "1 filler word" : "\(count) filler words")
                    .font(.inspectorValue)
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: 8)
                if count > 0 {
                    Toggle(isOn: $model.previewsFillerWords) {
                        Label("Preview", systemImage: "eye")
                            .font(.inspectorLabel)
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Show the filler words struck through in the transcript")
                }
            }

            if count > 0 {
                InspectorActionButton(count == 1 ? "Remove Filler Word" : "Remove \(count) Filler Words",
                                      systemImage: "scissors") {
                    model.removeFillerWords()
                }
                .help("Cut them from the video. ⌘Z puts them all back.")
            }

            if let examples = discourseExamples(language) {
                InspectorToggleRow("Also \(examples)", isOn: $model.includesDiscourseFillers)
                    .help("These are often filler but sometimes part of what you mean. Preview before removing.")
            }
        }
    }

    private func discourseExamples(_ language: String?) -> String? {
        switch language {
        case "en": "“like”, “so”, “basically”, “you know”"
        case "de": "„also“, „halt“, „sozusagen“"
        case "fr": "« genre », « bah », « ben », « du coup »"
        case "es": "«pues», «este», «bueno», «o sea»"
        case "it": "«tipo», «cioè», «allora»"
        case "pt": "“tipo”, “né”, “então”"
        case "nl": "‘dus’, ‘zeg maar’"
        case "ja": "「あの」「まあ」"
        case "zh": "“那个”“就是”"
        default: nil
        }
    }

    // MARK: Pauses

    @ViewBuilder
    private var pauseControls: some View {
        let summary = model.pauseSummary
        let count = summary.shortenable.count

        HStack(spacing: 6) {
            Text(pauseLine(summary))
                .font(.inspectorValue)
            if !summary.checking.isEmpty {
                ProgressView().controlSize(.mini)
            }
        }

        InspectorFieldPair {
            InspectorSlider("Over", value: secondsBinding(\.pauseThreshold), range: 0.5...5, format: .seconds)
                .help("Shorten pauses longer than this")
        } trailing: {
            InspectorSlider("Keep", value: secondsBinding(\.pauseBeat), range: 0.1...1, format: .seconds)
                .help("How much of each pause to keep")
        }

        if count > 0 {
            InspectorActionButton(count == 1 ? "Shorten Pause" : "Shorten \(count) Pauses", systemImage: "timer") {
                model.shortenPauses()
            }
            .help("Cut each down to the beat. ⌘Z puts them all back.")
        }

        if !summary.kept.isEmpty {
            InspectorHint(summary.kept.count == 1
                ? "1 pause stays: something happens on screen in it."
                : "\(summary.kept.count) pauses stay: something happens on screen in them.")
        }
    }

    private func pauseLine(_ summary: RecordingStudioModel.PauseSummary) -> String {
        let count = summary.shortenable.count
        if count == 0 {
            return summary.checking.isEmpty ? "No long pauses to shorten" : "Checking the screen…"
        }
        let saved = summary.saved < 10
            ? summary.saved.formatted(.number.precision(.fractionLength(1)))
            : summary.saved.formatted(.number.precision(.fractionLength(0)))
        return "\(count == 1 ? "1 pause" : "\(count) pauses"), \(saved) s"
    }

    private func secondsBinding(_ keyPath: ReferenceWritableKeyPath<RecordingStudioModel, TimeInterval>) -> Binding<CGFloat> {
        Binding(get: { CGFloat(model[keyPath: keyPath]) }, set: { model[keyPath: keyPath] = TimeInterval($0) })
    }
}

extension InspectorValueFormat {
    /// Tenths of a second: "1.0 s".
    static let seconds = InspectorValueFormat(
        multiplier: 1, fractionDigits: 1, suffix: " s", showsPositiveSign: false,
        step: 0.1, acceptedSuffixes: ["seconds", "second", "sec", "s"]
    )
}
