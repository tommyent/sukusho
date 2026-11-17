//
//  RecordingBarToggles.swift
//  Screendrop
//
//  The recording bar's toggles, direction B "Lit when on" (owner's pick 2026-11-17, from Fable's
//  pass 4): off is a dark-grey icon, slashed for the three inputs; on is a filled capsule with
//  something inside it - the input's own colour with proof that it works, or a soft blue for a
//  helper; a control that can't be used is light grey and says why on hover. It reads without
//  colour too: off is slashed, on is a filled capsule with content.
//

import AppKit
import AVFoundation
import SwiftUI

/// How a toggle lights up when it's on.
enum BarToggleLook {
    /// Goes into the recording: filled with its own colour, white icon, proof beside it.
    case input(Color)
    /// Only helps: a soft blue tint with an outline and icon in a blue of its own per appearance.
    case helper

    fileprivate var foreground: Color {
        switch self {
        case .input: .white
        case .helper: BarMetrics.helperForeground
        }
    }

    fileprivate var fill: Color {
        switch self {
        case .input(let color): color
        case .helper: BarMetrics.helperFill
        }
    }

    fileprivate var stroke: Color {
        switch self {
        case .input: .clear
        case .helper: BarMetrics.helperForeground.opacity(0.6)
        }
    }
}

struct BarToggleLabel<Proof: View>: View {
    let id: BarTooltipID
    let state: BarToggleState
    let hover: BarHover
    /// Drawn off and when it can't be used: slashed for the inputs.
    let offSymbol: String
    let onSymbol: String
    let look: BarToggleLook
    @ViewBuilder var proof: () -> Proof

    var body: some View {
        BarControlChrome(id: id, hover: hover, showsPuck: !state.isOn) {
            switch state {
            case .on:
                lit
            case .off:
                icon(BarMetrics.activeTint)
            case .unavailable(let reason):
                icon(BarMetrics.unavailableTint)
                    .overlay(alignment: .topTrailing) {
                        if reason == .blocked { blockedBadge }
                    }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: state)
    }

    private func icon(_ tint: Color) -> some View {
        Image(systemName: offSymbol)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: BarMetrics.controlSize, height: BarMetrics.controlSize)
            .transition(.opacity)
    }

    private var lit: some View {
        HStack(spacing: 5) {
            Image(systemName: onSymbol)
                .font(.system(size: 14, weight: .semibold))
            proof()
        }
        .foregroundStyle(look.foreground)
        .padding(.horizontal, Proof.self == EmptyView.self ? 0 : 9)
        .frame(minWidth: BarMetrics.chipHeight, minHeight: BarMetrics.chipHeight)
        .background(Capsule().fill(look.fill))
        .overlay(Capsule().strokeBorder(look.stroke, lineWidth: 1))
        .padding(.horizontal, 4)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    /// An amber "!": the input is blocked in System Settings, and a click opens them.
    private var blockedBadge: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 11, weight: .bold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(BarMetrics.onCaution, BarMetrics.caution)
            .offset(x: -6, y: 7)
            .accessibilityHidden(true)
    }
}

extension BarToggleLabel where Proof == EmptyView {
    init(id: BarTooltipID, state: BarToggleState, hover: BarHover, offSymbol: String, onSymbol: String,
         look: BarToggleLook) {
        self.init(id: id, state: state, hover: hover, offSymbol: offSymbol, onSymbol: onSymbol, look: look) {
            EmptyView()
        }
    }
}

// MARK: - Proof

/// The camera's live picture in a small circle, from the session the floating bubble already
/// runs; plain green when that session isn't up.
struct BarCameraThumbnail: NSViewRepresentable {
    static let diameter: CGFloat = 20

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        view.wantsLayer = true
        view.layer?.cornerRadius = Self.diameter / 2
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
        let preview = CameraRecordingManager.shared.makeThumbnailLayer()
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(preview)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: Self.diameter, height: Self.diameter)
    }
}

/// An audio input's level as four bars, during a take only. Before it nothing opens the
/// microphone or system audio (it would light macOS's indicators), so the picker and the countdown
/// show those chips without a meter rather than one that doesn't move (Fable on m1).
struct BarLevelMeter: View {
    let level: Double
    var isClipping = false
    var accessibilityName = "Microphone level"

    private static let heights: [CGFloat] = [0.45, 0.8, 1, 0.65]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Self.heights.indices, id: \.self) { index in
                Capsule()
                    .frame(width: 2.5, height: max(3, 14 * Self.heights[index] * CGFloat(min(1, level * 1.6))))
            }
        }
        .frame(height: 14)
        // Amber, not red, when it clips: red means recording and nothing else (Astra's note).
        .foregroundStyle(isClipping ? BarMetrics.caution : .white)
        .animation(.linear(duration: 0.05), value: level)
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(isClipping ? "Too loud" : "\(Int((level * 100).rounded())) percent")
    }
}
