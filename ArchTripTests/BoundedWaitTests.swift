import FirebaseCore
import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

/// RF-G4B1-01: the pending-writes wait must return at its deadline even when the
/// callback never fires, and a late callback must be ignored safely.
struct BoundedWaitTests {
    private struct Probe: Error, Equatable {}

    /// Holds the callback so a test can fire it late.
    private final class CallbackBox: @unchecked Sendable {
        var callback: (@Sendable (Error?) -> Void)?
    }

    private func isTimedOut(_ error: Error) -> Bool {
        if case AccountError.timedOut = error { return true }
        return false
    }

    @Test func neverCompletingOperationTimesOutWithinBound() async {
        let clock = ContinuousClock()
        let start = clock.now
        var timedOut = false
        do {
            try await BoundedWait.run(timeout: .milliseconds(200)) { _ in /* never completes */ }
        } catch {
            timedOut = isTimedOut(error)
        }
        let elapsed = clock.now - start
        let bounded = elapsed >= .milliseconds(150) && elapsed < .seconds(2)
        #expect(timedOut)
        #expect(bounded)
    }

    @Test func lateCompletionAfterTimeoutIsIgnored() async throws {
        let box = CallbackBox()
        var timedOut = false
        do {
            try await BoundedWait.run(timeout: .milliseconds(100)) { done in box.callback = done }
        } catch {
            timedOut = isTimedOut(error)
        }
        #expect(timedOut)
        // A double resume of a checked continuation would trap and crash the test run.
        let callback = try #require(box.callback)
        callback(nil)
        callback(Probe())
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func immediateCompletionSucceedsWithoutWaitingForDeadline() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        try await BoundedWait.run(timeout: .seconds(10)) { done in done(nil) }
        let fast = clock.now - start < .seconds(1)
        #expect(fast)
    }

    @Test func asynchronousCompletionBeforeDeadlineSucceeds() async throws {
        try await BoundedWait.run(timeout: .seconds(10)) { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { done(nil) }
        }
    }

    @Test func completionErrorIsRethrown() async {
        await #expect(throws: Probe.self) {
            try await BoundedWait.run(timeout: .seconds(10)) { done in done(Probe()) }
        }
    }

    @Test func oneShotResumesAtMostOnce() async throws {
        let gate = OneShot()
        #expect(!gate.finish(.success(())))  // not armed yet
        var results: [Bool] = []
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.arm(continuation)
            results.append(gate.finish(.success(())))
            results.append(gate.finish(.failure(Probe())))
        }
        #expect(results == [true, false])
    }
}

/// Reproduces the finding with real Firestore: on an isolated secondary app with its
/// network disabled, a queued write is never acknowledged, so Firestore's
/// waitForPendingWrites callback cannot fire. TripStore must still return at the deadline.
/// No Auth, no default app, nothing is sent to the server.
@MainActor
@Suite(.enabled(if: FirebaseApp.app() != nil))
struct OfflinePendingWritesTests {
    @Test func tripStoreWaitIsBoundedWhileWritesArePending() async throws {
        let name = "rfG4b1Offline\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        FirebaseApp.configure(name: name, options: try #require(FirebaseApp.app()).options)
        let app = try #require(FirebaseApp.app(name: name))
        let db = Firestore.firestore(app: app)
        let settings = db.settings
        settings.cacheSettings = MemoryCacheSettings()
        db.settings = settings
        try await db.disableNetwork()
        // Queued locally only; the acknowledgement (and this completion) never arrives offline.
        db.collection("rf-g4b1-offline-probe").document(UUID().uuidString).setData(["pending": true]) { _ in }

        let clock = ContinuousClock()
        let start = clock.now
        var timedOut = false
        do {
            try await TripStore(db: db).waitForPendingWrites(timeout: .milliseconds(500))
        } catch {
            if case AccountError.timedOut = error { timedOut = true }
        }
        let bounded = clock.now - start < .seconds(3)
        #expect(timedOut)
        #expect(bounded)
        _ = await app.delete()
    }
}
