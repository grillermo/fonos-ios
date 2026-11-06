// Pending recordings retry by themselves, oldest first, while the app is open.
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/PendingRecordingAutoRetrierTests

import Testing
import Foundation
@testable import FonosApp

/// Records each wait and holds it until the test calls `fire()`.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    private var fires = 0

    var delays: [TimeInterval] { lock.withLock { recorded } }
    func fire() { lock.withLock { fires += 1 } }

    func sleep(_ delay: TimeInterval) async throws {
        lock.withLock { recorded.append(delay) }
        while true {
            try Task.checkCancellation()
            let fired: Bool = lock.withLock {
                guard fires > 0 else { return false }
                fires -= 1
                return true
            }
            if fired { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

@MainActor
private func waitFor(_ condition: () -> Bool) async throws {
    let start = Date()
    while !condition() {
        guard Date().timeIntervalSince(start) < 5 else {
            Issue.record("Timed out waiting")
            return
        }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}

@MainActor
private final class Harness {
    let store = PendingRecordingStore(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-\(UUID().uuidString)", isDirectory: true)
    )
    let clock = FakeClock()
    let retrier: PendingRecordingAutoRetrier
    var retried: [UUID] = []
    /// Errors thrown per recording. Anything not listed succeeds.
    var failures: [UUID: any Error] = [:]

    init() {
        let clock = clock
        retrier = PendingRecordingAutoRetrier(store: store, sleep: { try await clock.sleep($0) })
        retrier.retry = { [unowned self] recording in
            self.retried.append(recording.id)
            if let error = self.failures[recording.id] {
                self.store.recordAttempt(id: recording.id, failure: error)
                throw error
            }
            self.store.discard(id: recording.id)
        }
    }

    @discardableResult
    func add(age: TimeInterval) throws -> PendingRecording {
        try store.save(
            wav: Data(count: 44), surface: .dictate, workflowID: "w", error: "e",
            now: Date(timeIntervalSinceNow: -age)
        )
    }

    deinit { try? FileManager.default.removeItem(at: store.directory) }
}

@MainActor
struct PendingRecordingAutoRetrierTests {

    @Test("becoming active retries everything, oldest first")
    func oldestFirst() async throws {
        let h = Harness()
        let newer = try h.add(age: 10)
        let older = try h.add(age: 100)

        h.retrier.setActive(true)

        try await waitFor { h.store.all().isEmpty }
        #expect(h.retried == [older.id, newer.id])
        #expect(h.clock.delays.isEmpty)
    }

    @Test("a temporary failure ends the pass and waits 1, 2, 5, then 15 minutes")
    func temporaryBacksOff() async throws {
        let h = Harness()
        let first = try h.add(age: 100)
        let second = try h.add(age: 10)
        h.failures[first.id] = STTError.networkUnavailable

        h.retrier.setActive(true)

        for (index, expected) in [60.0, 120, 300, 900, 900].enumerated() {
            try await waitFor { h.clock.delays.count == index + 1 }
            #expect(h.clock.delays[index] == expected)
            #expect(!h.retried.contains(second.id))
            h.clock.fire()
        }
    }

    @Test("a success after failures resets the wait")
    func successResetsWait() async throws {
        let h = Harness()
        let first = try h.add(age: 100)
        h.failures[first.id] = STTError.networkUnavailable
        h.retrier.setActive(true)
        try await waitFor { h.clock.delays.count == 1 }
        h.clock.fire()
        try await waitFor { h.clock.delays.count == 2 }
        h.failures[first.id] = nil
        h.clock.fire()
        try await waitFor { h.store.all().isEmpty }

        let next = try h.add(age: 1)
        h.failures[next.id] = STTError.networkUnavailable
        h.retrier.networkBecameAvailable()

        try await waitFor { h.clock.delays.count == 3 }
        #expect(h.clock.delays[2] == 60)
    }

    @Test("a permanent failure is skipped and never auto-retried again")
    func permanentContinues() async throws {
        let h = Harness()
        let bad = try h.add(age: 100)
        let good = try h.add(age: 10)
        h.failures[bad.id] = STTError.http(status: 415, body: "")

        h.retrier.setActive(true)

        try await waitFor { h.retried == [bad.id, good.id] }
        try await waitFor { h.store.all().count == 1 }

        h.retrier.networkBecameAvailable()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(h.retried == [bad.id, good.id])
        #expect(h.clock.delays.isEmpty)
    }

    @Test("nothing runs while the app is busy; the timer tries again")
    func busyWaits() async throws {
        let h = Harness()
        try h.add(age: 10)
        var busy = true
        h.retrier.isBusy = { busy }

        h.retrier.setActive(true)
        try await waitFor { h.clock.delays.count == 1 }
        #expect(h.retried.isEmpty)

        busy = false
        h.clock.fire()
        try await waitFor { h.store.all().isEmpty }
    }

    @Test("an inactive app does not retry")
    func inactiveDoesNothing() async throws {
        let h = Harness()
        try h.add(age: 10)

        h.retrier.networkBecameAvailable()
        h.retrier.recordingsChanged()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(h.retried.isEmpty)
        #expect(h.clock.delays.isEmpty)
    }

    @Test("a newly kept recording arms the timer instead of retrying at once")
    func newRecordingArmsTimer() async throws {
        let h = Harness()
        h.retrier.setActive(true)
        let recording = try h.add(age: 1)

        h.retrier.recordingsChanged()

        try await waitFor { h.clock.delays == [60] }
        #expect(h.retried.isEmpty)
        h.clock.fire()
        try await waitFor { h.retried == [recording.id] }
    }

    @Test("Retry All includes stopped items and stops at a temporary failure")
    func retryAll() async throws {
        let h = Harness()
        let stopped = try h.add(age: 100)
        h.store.recordAttempt(id: stopped.id, error: "e", permanent: true)
        let down = try h.add(age: 50)
        let last = try h.add(age: 10)
        h.failures[down.id] = STTError.networkUnavailable

        await h.retrier.retryAll()

        #expect(h.retried == [stopped.id, down.id])
        #expect(h.store.recording(id: last.id) != nil)
        #expect(h.retrier.isRetryingAll == false)
    }
}
