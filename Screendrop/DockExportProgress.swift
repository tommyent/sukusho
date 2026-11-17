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
    /// Exports that finished well, kept at 100% until the bar shows it (Astra, 2026-11-17: it reset at 20%).
    private var completed: Set<UUID> = []

    private init() {}

    func start() -> UUID {
        let id = UUID()
        progressByTask[id] = 0
        updateDockIcon()
        return id
    }

    func update(_ id: UUID, progress: Double) {
        guard progressByTask[id] != nil, !completed.contains(id) else { return }
        progressByTask[id] = min(max(progress, 0), 1)
        updateDockIcon()
    }

    /// `completed` for an export that finished well: its bar fills before it goes. Cancelled and failed ones go at once.
    func finish(_ id: UUID, completed succeeded: Bool = false) {
        guard progressByTask[id] != nil, !completed.contains(id) else { return }
        if succeeded {
            progressByTask[id] = 1
            completed.insert(id)
        } else {
            progressByTask.removeValue(forKey: id)
        }
        updateDockIcon()
    }

    private func updateDockIcon() {
        guard !progressByTask.isEmpty else {
            pacer = DockProgressPacer()
            completed = []
            releaseTimer?.invalidate()
            releaseTimer = nil
            DockProgress.resetProgress()
            return
        }
        let average = progressByTask.values.reduce(0, +) / Double(progressByTask.count)
        if let value = pacer.offer(average, shown: DockProgress.displayedProgress, target: DockProgress.progress) {
            DockProgress.progress = value
        }
        if releaseTimer == nil, pacer.held != nil || !completed.isEmpty {
            // The bar is still easing: hand over the latest value once it has caught up (DockProgressPacer).
            releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseHeldProgress() }
            }
        }
    }

    private func releaseHeldProgress() {
        let shown = DockProgress.displayedProgress, target = DockProgress.progress
        if let value = pacer.release(shown: shown, target: target) {
            DockProgress.progress = value
            return
        }
        guard pacer.isSettled(shown: shown, target: target) else { return }
        releaseTimer?.invalidate()
        releaseTimer = nil
        // The finished exports' 100% is on the bar now.
        guard !completed.isEmpty else { return }
        for id in completed { progressByTask.removeValue(forKey: id) }
        completed = []
        updateDockIcon()
    }
}
