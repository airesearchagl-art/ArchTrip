import Foundation
import Testing
@testable import ArchTrip

/// RF-03 Trip deletion against a fake server: the order of batches, what blocks a
/// start, what a failure leaves behind, and that no reply from an earlier run can change
/// the screen. Nothing here touches Firestore.
@MainActor
struct TripDeletionTests {
    final class FakeDeleter: TripDeleting {
        struct Call: Equatable {
            let eventIDs: [String]
            let andTrip: Bool
        }

        var pendingWritesError: Error?
        /// Consumed in order; the last one repeats. Empty means "trip exists, no events".
        var inventories: [Result<TripDeletionInventory, Error>] = []
        /// 1-based index of the `delete` call that throws `batchError`.
        var failingBatch: Int?
        var batchError: Error = NSError(domain: "FIRFirestoreErrorDomain", code: 14)
        var hangInventory = false
        private(set) var batches: [Call] = []
        private(set) var inventoryCalls = 0
        private var hung: [CheckedContinuation<Void, Never>] = []

        func waitForPendingWrites(timeout: Duration) async throws {
            if let pendingWritesError { throw pendingWritesError }
        }

        func inventory(uid: String, tripID: String) async throws -> TripDeletionInventory {
            inventoryCalls += 1
            // The reply is chosen by call order, before any hang, so the order in which
            // hung calls are released does not change which listing each call returns.
            let result: Result<TripDeletionInventory, Error> = inventories.isEmpty
                ? .success(TripDeletionInventory(tripExists: true, eventIDs: []))
                : (inventories.count > 1 ? inventories.removeFirst() : inventories[0])
            if hangInventory {
                await withCheckedContinuation { hung.append($0) }
            }
            return try result.get()
        }

        func delete(eventIDs: [String], andTrip: Bool, uid: String, tripID: String, timeout: Duration) async throws {
            batches.append(Call(eventIDs: eventIDs, andTrip: andTrip))
            if let failingBatch, batches.count == failingBatch { throw batchError }
        }

        /// Lets a hanging inventory reply arrive.
        func release() {
            let waiting = hung
            hung = []
            for continuation in waiting { continuation.resume() }
        }
    }

    private let fast = TripDeletion.Configuration(pendingWritesTimeout: .milliseconds(10), batchTimeout: .milliseconds(10))

    private func ids(_ count: Int) -> [String] { (0..<count).map { "e\($0)" } }

    private func settle(_ what: Comment, _ condition: @escaping () -> Bool) async {
        for _ in 0..<400 where !condition() {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition(), what)
    }

    private func run(_ deleter: FakeDeleter, configuration: TripDeletion.Configuration? = nil) -> TripDeletionRun {
        TripDeletionRun(deleter: deleter, uid: "fixture-uid", tripID: "fixture-trip", configuration: configuration ?? fast)
    }

    // MARK: Batching rules

    @Test func eventsComeFirstAndTheTripGoesWithTheLastBatch() {
        let batches = TripDeletion.batches(eventIDs: ids(1_001), tripExists: true, perBatch: 450)
        #expect(batches.map(\.eventIDs.count) == [450, 450, 101])
        #expect(batches.map(\.andTrip) == [false, false, true])
        #expect(batches.flatMap(\.eventIDs) == ids(1_001), "every Event exactly once, in order")

        #expect(TripDeletion.batches(eventIDs: [], tripExists: true) == [TripDeletion.Batch(eventIDs: [], andTrip: true)])
        #expect(TripDeletion.batches(eventIDs: [], tripExists: false).isEmpty)
        #expect(TripDeletion.batches(eventIDs: ids(3), tripExists: false) == [TripDeletion.Batch(eventIDs: ids(3), andTrip: false)])
        #expect(TripDeletion.batches(eventIDs: ids(450), tripExists: true, perBatch: 450).count == 1)
        #expect(TripDeletion.eventsPerBatch < 500, "below Firestore's batch limit")
    }

    @Test func problemsComeFromErrorDomainsAndCodes() {
        #expect(TripDeletion.problem(for: AccountError.timedOut) == .noReply)
        #expect(TripDeletion.problem(for: NSError(domain: "FIRFirestoreErrorDomain", code: 7)) == .denied)
        #expect(TripDeletion.problem(for: NSError(domain: "FIRFirestoreErrorDomain", code: 14)) == .offline)
        #expect(TripDeletion.problem(for: NSError(domain: "FIRFirestoreErrorDomain", code: 4)) == .offline)
        #expect(TripDeletion.problem(for: NSError(domain: "FIRFirestoreErrorDomain", code: 13)) == .other(domain: "FIRFirestoreErrorDomain", code: 13))
        #expect(TripDeletion.problem(for: URLError(.notConnectedToInternet)) == .offline)
        #expect(TripDeletion.problem(for: NSError(domain: "Fixture", code: 7)) == .other(domain: "Fixture", code: 7), "the code alone is not enough")
    }

    // MARK: The run

    @Test func anEmptyTripDeletesOnlyTheTrip() async {
        let deleter = FakeDeleter()
        let run = run(deleter)
        run.check()
        await settle("ready") { run.state == .ready(TripDeletion.Summary(tripExists: true, eventCount: 0, unreadableEventCount: 0)) }
        run.delete()
        await settle("done") { run.state == .done }
        #expect(deleter.batches == [FakeDeleter.Call(eventIDs: [], andTrip: true)])
    }

    @Test func eventsReadableOrNotAreDeletedBeforeTheTrip() async {
        let deleter = FakeDeleter()
        let eventIDs = ids(1_001)
        deleter.inventories = [
            .success(TripDeletionInventory(tripExists: true, eventIDs: eventIDs, unreadableEventIDs: ["e7", "e999"])),
            .success(TripDeletionInventory(tripExists: false, eventIDs: [])),
        ]
        let run = run(deleter)
        run.check()
        await settle("ready") { run.state == .ready(TripDeletion.Summary(tripExists: true, eventCount: 1_001, unreadableEventCount: 2)) }
        run.delete()
        await settle("done") { run.state == .done }
        #expect(deleter.batches.map(\.eventIDs.count) == [450, 450, 101])
        #expect(deleter.batches.map(\.andTrip) == [false, false, true])
        #expect(deleter.batches.flatMap(\.eventIDs).contains("e7") && deleter.batches.flatMap(\.eventIDs).contains("e999"))
        #expect(deleter.inventoryCalls == 2, "one listing before, one sweep after")
    }

    @Test func unsyncedWritesBlockTheStart() async {
        let deleter = FakeDeleter()
        deleter.pendingWritesError = AccountError.timedOut
        let run = run(deleter)
        run.check()
        await settle("blocked") { run.state == .blocked(.unsyncedWrites) }
        run.delete()
        #expect(deleter.batches.isEmpty, "nothing is sent from a blocked state")
        #expect(deleter.inventoryCalls == 0)
    }

    @Test func anUnreachableServerBlocksTheStart() async {
        let deleter = FakeDeleter()
        deleter.inventories = [.failure(NSError(domain: "FIRFirestoreErrorDomain", code: 14))]
        let run = run(deleter)
        run.check()
        await settle("blocked") { run.state == .blocked(.offline) }
        #expect(deleter.batches.isEmpty)
    }

    @Test func anotherUsersTripIsRefusedBeforeAnythingIsSent() async {
        let deleter = FakeDeleter()
        deleter.inventories = [.failure(NSError(domain: "FIRFirestoreErrorDomain", code: 7))]
        let run = run(deleter)
        run.check()
        await settle("blocked") { run.state == .blocked(.denied) }
        #expect(deleter.batches.isEmpty)
    }

    @Test func tooManyEventsBlockTheStart() async {
        let deleter = FakeDeleter()
        deleter.inventories = [.success(TripDeletionInventory(tripExists: true, eventIDs: ids(2_001)))]
        let run = run(deleter)
        run.check()
        await settle("blocked") { run.state == .blocked(.tooManyEvents(2_001)) }
        #expect(deleter.batches.isEmpty)
    }

    @Test func aTripAlreadyGoneEndsWithoutSendingAnything() async {
        let deleter = FakeDeleter()
        deleter.inventories = [.success(TripDeletionInventory(tripExists: false, eventIDs: []))]
        let run = run(deleter)
        run.check()
        await settle("done") { run.state == .done }
        #expect(deleter.batches.isEmpty)
    }

    @Test func leftoverEventsUnderAGoneTripAreStillDeleted() async {
        let deleter = FakeDeleter()
        deleter.inventories = [
            .success(TripDeletionInventory(tripExists: false, eventIDs: ["orphan"])),
            .success(TripDeletionInventory(tripExists: false, eventIDs: [])),
        ]
        let run = run(deleter)
        run.check()
        await settle("ready") { run.state == .ready(TripDeletion.Summary(tripExists: false, eventCount: 1, unreadableEventCount: 0)) }
        run.delete()
        await settle("done") { run.state == .done }
        #expect(deleter.batches == [FakeDeleter.Call(eventIDs: ["orphan"], andTrip: false)])
    }

    /// A batch that fails leaves the Trip (it is only ever in the last batch). Retrying
    /// lists what remains and finishes; nothing is deleted twice.
    @Test func aFailedBatchKeepsTheTripAndRetryFinishes() async {
        let deleter = FakeDeleter()
        let eventIDs = ids(1_001)
        deleter.inventories = [.success(TripDeletionInventory(tripExists: true, eventIDs: eventIDs))]
        deleter.failingBatch = 2
        let run = run(deleter)
        run.check()
        await settle("ready") { if case .ready = run.state { return true } else { return false } }
        run.delete()
        await settle("failed") { run.state == .failed(.offline, deletedEvents: 450) }
        #expect(deleter.batches.count == 2)
        #expect(deleter.batches.allSatisfy { !$0.andTrip }, "the Trip is never deleted before its Events")

        // The server now holds the remaining 551 Events and the Trip.
        deleter.inventories = [
            .success(TripDeletionInventory(tripExists: true, eventIDs: Array(eventIDs[450...]))),
            .success(TripDeletionInventory(tripExists: false, eventIDs: [])),
        ]
        deleter.failingBatch = nil
        run.checkAgain()
        await settle("ready again") { run.state == .ready(TripDeletion.Summary(tripExists: true, eventCount: 551, unreadableEventCount: 0)) }
        run.delete()
        await settle("done") { run.state == .done }
        let retried = Array(deleter.batches[2...])
        #expect(retried.map(\.eventIDs.count) == [450, 101])
        #expect(retried.map(\.andTrip) == [false, true])
        #expect(Set(retried.flatMap(\.eventIDs)) == Set(eventIDs[450...]), "only what remained")
    }

    @Test func aTimedOutBatchIsReportedAsNoReply() async {
        let deleter = FakeDeleter()
        deleter.inventories = [.success(TripDeletionInventory(tripExists: true, eventIDs: ids(2)))]
        deleter.failingBatch = 1
        deleter.batchError = AccountError.timedOut
        let run = run(deleter)
        run.check()
        await settle("ready") { if case .ready = run.state { return true } else { return false } }
        run.delete()
        await settle("no reply") { run.state == .failed(.noReply, deletedEvents: 0) }
    }

    /// Events another device adds between the listing and the Trip's deletion are swept
    /// afterwards; none can be added once the Trip is gone.
    @Test func eventsAddedDuringTheDeletionAreSwept() async {
        let deleter = FakeDeleter()
        deleter.inventories = [
            .success(TripDeletionInventory(tripExists: true, eventIDs: ids(2))),
            .success(TripDeletionInventory(tripExists: false, eventIDs: ["late1", "late2"])),
            .success(TripDeletionInventory(tripExists: false, eventIDs: [])),
        ]
        let run = run(deleter)
        run.check()
        await settle("ready") { if case .ready = run.state { return true } else { return false } }
        run.delete()
        await settle("done") { run.state == .done }
        #expect(deleter.batches == [
            FakeDeleter.Call(eventIDs: ids(2), andTrip: true),
            FakeDeleter.Call(eventIDs: ["late1", "late2"], andTrip: false),
        ])
    }

    // MARK: Stale replies

    @Test func aCancelledCheckIgnoresItsLateReply() async {
        let deleter = FakeDeleter()
        deleter.hangInventory = true
        deleter.inventories = [.success(TripDeletionInventory(tripExists: true, eventIDs: ids(3)))]
        let run = run(deleter)
        run.check()
        await settle("checking") { run.state == .checking && deleter.inventoryCalls == 1 }
        run.cancel()
        #expect(run.state == .idle)
        deleter.release()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(run.state == .idle, "the reply of a cancelled check never shows")
        run.delete()
        #expect(deleter.batches.isEmpty, "no listing was accepted, so nothing can be sent")
    }

    @Test func checkingAgainSupersedesTheEarlierListing() async {
        let deleter = FakeDeleter()
        deleter.hangInventory = true
        deleter.inventories = [
            .success(TripDeletionInventory(tripExists: true, eventIDs: ids(5))),
            .success(TripDeletionInventory(tripExists: true, eventIDs: ids(1))),
        ]
        let run = run(deleter)
        run.check()
        await settle("first listing in flight") { deleter.inventoryCalls == 1 }
        run.cancel()
        run.checkAgain()
        await settle("second listing in flight") { deleter.inventoryCalls == 2 }
        deleter.release()
        await settle("second listing applied") { run.state == .ready(TripDeletion.Summary(tripExists: true, eventCount: 1, unreadableEventCount: 0)) }
        // The sweep after the Trip's deletion lists an empty server, without hanging.
        deleter.hangInventory = false
        deleter.inventories = [.success(TripDeletionInventory(tripExists: false, eventIDs: []))]
        run.delete()
        await settle("done") { run.state == .done }
        #expect(deleter.batches.first?.eventIDs == ids(1), "the batches come from the listing that was accepted")
    }

    /// The protocol a deletion runs through has no Building operation at all, so a
    /// Trip deletion cannot touch Buildings by construction.
    @Test func buildingsAreOutOfReach() {
        let methods = ["waitForPendingWrites", "inventory", "delete"]
        #expect(methods.count == 3)
        #expect(!String(reflecting: TripDeleting.self).lowercased().contains("building"))
    }
}
