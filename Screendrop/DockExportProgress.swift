//
//  DockExportProgress.swift
//  Screendrop
//
//  A Dock icon progress bar while exporting or uploading.
//

import AppKit
import DockProgress

/// Mirrors every in-flight Studio export onto the single shared Dock icon.
/// Multiple Studio windows can export at once, so progress is averaged
/// across them rather than one export's updates fighting another's.
@MainActor
final class DockExportProgressCoordinator {
    static let shared = DockExportProgressCoordinator()

    private var progressByTask: [UUID: Double] = [:]
    private var pacer = DockProgressPacer()
    private var releaseTimer: Timer?

    private init() {}

    func start() -> UUID {
        let id = UUID()
        progressByTask[id] = 0
        updateDockIcon()
        return id
    }

    func update(_ id: UUID, progress: Double) {
        guard progressByTask[id] != nil else { return }
        progressByTask[id] = min(max(progress, 0), 1)
        updateDockIcon()
    }

    func finish(_ id: UUID) {
        guard progressByTask.removeValue(forKey: id) != nil else { return }
        updateDockIcon()
    }

    private func updateDockIcon() {
        guard !progressByTask.isEmpty else {
            pacer = DockProgressPacer()
            releaseTimer?.invalidate()
            releaseTimer = nil
            DockProgress.resetProgress()
            return
        }
        let average = progressByTask.values.reduce(0, +) / Double(progressByTask.count)
        if let value = pacer.offer(average, shown: DockProgress.displayedProgress, target: DockProgress.progress) {
            DockProgress.progress = value
        } else if releaseTimer == nil {
            // The bar is still easing: hand over the latest value once it has caught up (DockProgressPacer).
            releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseHeldProgress() }
            }
        }
    }

    private func releaseHeldProgress() {
        guard DockProgress.displayedProgress == DockProgress.progress else { return }
        releaseTimer?.invalidate()
        releaseTimer = nil
        if let value = pacer.release(shown: DockProgress.displayedProgress, target: DockProgress.progress) {
            DockProgress.progress = value
        }
    }
}
