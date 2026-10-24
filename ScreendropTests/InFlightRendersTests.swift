import Foundation
import Synchronization
import Testing

@MainActor
struct InFlightRendersTests {
    struct Failed: Error {}

    /// A render held open until the test lets it finish.
    final class Hold {
        private var continuation: CheckedContinuation<Void, Never>?
        var isHolding: Bool { continuation != nil }

        func wait() async { await withCheckedContinuation { continuation = $0 } }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    nonisolated final class Seen: Sendable {
        let values = Mutex<[Double]>([])
        func record(_ value: Double) { values.withLock { $0.append(value) } }
        var all: [Double] { values.withLock { $0 } }
    }

    let renders = InFlightRenders<String, Int>()

    /// Starts a render of `key` owned by a new task, held until `hold` is released.
    func own(_ key: String, hold: Hold, failing: Bool = false) -> Task<Int, Error> {
        let renders = renders
        return Task {
            try await renders.value(for: key, onProgress: nil) { progress in
                await hold.wait()
                try Task.checkCancellation()
                progress(0.5)
                if failing { throw Failed() }
                return 1
            }
        }
    }

    func join(_ key: String, counting starts: Counter, seen: Seen? = nil) -> Task<Int, Error> {
        let renders = renders
        return Task {
            try await renders.value(for: key, onProgress: seen.map { seen in { @Sendable in seen.record($0) } }) { _ in
                starts.count += 1
                return 2
            }
        }
    }

    /// How many times a joiner rendered on its own.
    final class Counter { var count = 0 }

    /// Lets queued main-actor tasks run up to their first suspension.
    func settle() async { for _ in 0..<10 { await Task.yield() } }

    @Test func sameKeyJoinsTheRunningRenderAndSeesItsProgress() async throws {
        let hold = Hold(), joined = Counter(), seen = Seen()
        let owner = own("a", hold: hold)
        await settle()
        let joiner = join("a", counting: joined, seen: seen)
        await settle()
        hold.release()
        #expect(try await owner.value == 1)
        #expect(try await joiner.value == 1)
        #expect(joined.count == 0)
        #expect(seen.all == [0.5])
    }

    @Test func cancellingAJoinerOnlyEndsItsWait() async throws {
        let hold = Hold(), joined = Counter(), seen = Seen()
        let owner = own("a", hold: hold)
        await settle()
        let joiner = join("a", counting: joined, seen: seen)
        await settle()
        joiner.cancel()
        await #expect(throws: CancellationError.self) { try await joiner.value }
        #expect(hold.isHolding)
        hold.release()
        #expect(try await owner.value == 1)
        #expect(joined.count == 0)
        #expect(seen.all.isEmpty)
    }

    @Test func aJoinerRendersOnceItselfWhenTheSharedRenderFails() async throws {
        let hold = Hold(), joined = Counter()
        let owner = own("a", hold: hold, failing: true)
        await settle()
        let joiner = join("a", counting: joined)
        await settle()
        hold.release()
        await #expect(throws: Failed.self) { try await owner.value }
        #expect(try await joiner.value == 2)
        #expect(joined.count == 1)
    }

    @Test func cancellingTheOwnerCancelsTheRenderAndTheJoinerRendersItself() async throws {
        let hold = Hold(), joined = Counter()
        let owner = own("a", hold: hold)
        await settle()
        let joiner = join("a", counting: joined)
        await settle()
        owner.cancel()
        hold.release()
        await #expect(throws: CancellationError.self) { try await owner.value }
        #expect(try await joiner.value == 2)
        #expect(joined.count == 1)
    }

    @Test func aDifferentKeyRendersAsBefore() async throws {
        let hold = Hold(), joined = Counter()
        let owner = own("a", hold: hold)
        await settle()
        #expect(try await join("b", counting: joined).value == 2)
        #expect(joined.count == 1)
        hold.release()
        #expect(try await owner.value == 1)
        #expect(try await join("a", counting: joined).value == 2) // Finished renders are not reused here.
        #expect(joined.count == 2)
    }
}
