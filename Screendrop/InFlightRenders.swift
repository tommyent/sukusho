//
//  InFlightRenders.swift
//  Screendrop
//
//  The renders running now, so a second request for the same movie joins
//  the first instead of encoding it again beside it (sd-5oxt).
//

import Foundation
import Synchronization

/// The caller that starts a render owns it: cancelling that caller cancels
/// the render, as before. A joiner only waits: cancelling it ends the wait
/// and leaves the render running, and if the shared render fails the joiner
/// renders once on its own.
@MainActor
final class InFlightRenders<Key: Equatable, Value: Sendable> {
    private var running: [(key: Key, task: Task<Value, Error>, listeners: ProgressListeners)] = []

    func value(
        for key: Key,
        onProgress: (@Sendable (Double) -> Void)?,
        render: @escaping @MainActor (@escaping @Sendable (Double) -> Void) async throws -> Value
    ) async throws -> Value {
        if let shared = running.first(where: { $0.key == key }) {
            let listener = shared.listeners.add(onProgress)
            defer { shared.listeners.remove(listener) }
            do { return try await Self.wait(for: shared.task) } catch { try Task.checkCancellation() }
            return try await render { onProgress?($0) }
        }
        let listeners = ProgressListeners()
        _ = listeners.add(onProgress)
        let task = Task { try await render { listeners.report($0) } }
        running.append((key, task, listeners))
        defer { running.removeAll { $0.task == task } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Waits for `task` without owning it: cancelling the caller ends the
    /// wait, never the task.
    private static func wait(for task: Task<Value, Error>) async throws -> Value {
        let waiter = Waiter<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.set(continuation)
                Task { waiter.resume(with: await task.result) }
                if Task.isCancelled { waiter.resume(with: .failure(CancellationError())) }
            }
        } onCancel: {
            waiter.resume(with: .failure(CancellationError()))
        }
    }
}

/// One render's progress, for its owner and everyone waiting on it.
nonisolated private final class ProgressListeners: Sendable {
    private let listeners = Mutex<[UUID: @Sendable (Double) -> Void]>([:])

    func add(_ listener: (@Sendable (Double) -> Void)?) -> UUID {
        let id = UUID()
        if let listener { listeners.withLock { $0[id] = listener } }
        return id
    }

    func remove(_ id: UUID) {
        _ = listeners.withLock { $0.removeValue(forKey: id) }
    }

    func report(_ progress: Double) {
        for listener in listeners.withLock({ Array($0.values) }) { listener(progress) }
    }
}

/// Resumes a continuation once, from whichever comes first: the result or a cancel.
nonisolated private final class Waiter<Value: Sendable>: Sendable {
    private let continuation = Mutex<CheckedContinuation<Value, Error>?>(nil)

    func set(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resume(with result: Result<Value, Error>) {
        continuation.withLock { $0.take() }?.resume(with: result)
    }
}
