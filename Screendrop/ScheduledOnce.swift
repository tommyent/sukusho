//
//  ScheduledOnce.swift
//  Screendrop
//
//  Work that is due a little later, once for each key, and that someone may
//  want sooner. Whoever asks gets the one run: it is never done a second time
//  for them. A new capture's optimizing is the case: due two seconds after
//  the capture, and wanted at once by the copy that follows it.
//

import Foundation

@MainActor
final class ScheduledOnce<Key: Hashable & Sendable, Value: Sendable> {
    private var entries: [Key: (wait: Task<Void, Never>, work: Task<Value, Never>)] = [:]

    /// Runs `work` for `key` after `delay`, unless work for that key is already waiting or running.
    func schedule(_ key: Key, after delay: Duration, priority: TaskPriority = .utility, _ work: @escaping () async -> Value) {
        guard entries[key] == nil else { return }
        let wait = Task { _ = try? await Task.sleep(for: delay) }
        let run = Task(priority: priority) { [weak self] in
            await wait.value
            let value = await work()
            self?.entries[key] = nil
            return value
        }
        entries[key] = (wait, run)
    }

    /// What the work scheduled for `key` gives, started now if it was still waiting. Nil when nothing is
    /// scheduled for it, or its work has already finished.
    func now(_ key: Key) async -> Value? {
        guard let entry = entries[key] else { return nil }
        entry.wait.cancel()
        return await entry.work.value
    }
}
