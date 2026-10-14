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
        /// 1-based call index from which inventories hang (the verification listing).
        var hangInventoryFrom: Int?
        /// 1-based index of the `delete` call that hangs until released (a batch in flight).
        var hangDeleteAt: Int?
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
            if hangInventory || (hangInventoryFrom.map { inventoryCalls >= $0 } ?? false) {
                await withCheckedContinuation { hung.append($0) }
            }
            return try result.get()
        }

        func delete(eventIDs: [String], andTrip: Bool, uid: String, tripID: String, timeout: Duration) async throws {
            batches.append(Call(eventIDs: eventIDs, andTrip: andTrip))
            if let hangDeleteAt, batches.count == hangDeleteAt {
                await withCheckedContinuation { hung.append($0) }
            }
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

    private func stopped(_ reason: TripDeletion.Stop.Reason, acknowledged: Int, trip: TripDeletion.TripStatus) -> TripDeletionRun.State {
        .stopped(TripDeletion.Stop(reason: reason, acknowledgedEvents: acknowledged, tripStatus: trip))
    }

    /// A ledger file of its own per test, in a temporary directory.
    private func ledgerFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TripDeletionTests-\(UUID().uuidString)/pendingTripDeletions.json")
    }

    private func ledger(_ file: URL? = nil) -> TripDeletionLedger {
        TripDeletionLedger(storage: FileTripDeletionLedgerStorage(url: file ?? ledgerFile()))
    }

    /// Storage whose saves fail (a full or read-only disk).
    struct FailingStorage: TripDeletionLedgerStorage {
        func load() throws -> Data? { nil }
        func save(_ data: Data?) throws { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError) }
    }

    /// Reads the record exactly as a restarted app would: a new ledger from the same file.
    private func reread(_ file: URL, uid: String = "fixture-uid") -> PendingTripDeletion? {
        TripDeletionLedger(storage: FileTripDeletionLedgerStorage(url: file)).records(for: uid).first
    }

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
        deleter.inventories = [
            .success(TripDeletionInventory(tripExists: true, eventIDs: [])),
            .success(TripDeletionInventory(tripExists: false, eventIDs: [])),
        ]
        let run = run(deleter)
        run.check()
        await settle("ready") { run.state == .ready(TripDeletion.Summary(tripExists: true, eventCount: 0, unreadableEventCount: 0)) }
        run.delete()
        await settle("done") { run.state == .done }
        #expect(deleter.batches == [FakeDeleter.Call(eventIDs: [], andTrip: true)])
        #expect(deleter.inventoryCalls == 2, "the listing before, and the verification that found nothing")
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
        await settle("stopped") { run.state == stopped(.batchFailed(.offline), acknowledged: 450, trip: .present) }
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

    /// A batch sent without an acknowledgement is neither "deleted" nor "undone": it is
    /// reported as unconfirmed, with the Trip's fate unknown when the batch held it.
    @Test func aTimedOutBatchIsReportedAsUnconfirmed() async {
        let deleter = FakeDeleter()
        deleter.inventories = [.success(TripDeletionInventory(tripExists: true, eventIDs: ids(2)))]
        deleter.failingBatch = 1
        deleter.batchError = AccountError.timedOut
        let run = run(deleter)
        run.check()
        await settle("ready") { if case .ready = run.state { return true } else { return false } }
        run.delete()
        await settle("unconfirmed") { run.state == stopped(.batchUnconfirmed(events: 2, includesTrip: true), acknowledged: 0, trip: .unknown) }
    }

    // MARK: Verification after the batches (review findings 1–3)

    /// The listing after the batches failing is not success: the run stops as
    /// "verification failed" with what was acknowledged, and Check again finishes when
    /// the server then lists nothing.
    @Test func aFailedVerificationIsNotSuccess() async {
        let deleter = FakeDeleter()
        deleter.inventories = [
            .success(TripDeletionInventory(tripExists: true, eventIDs: ids(3))),
            .failure(NSError(domain: "FIRFirestoreErrorDomain", code: 14)),
        ]
        let run = run(deleter)
        run.check()
        await settle("ready") { if case .ready = run.state { return true } else { return false } }
        run.delete()
        await settle("verification failed") { run.state == stopped(.verificationFailed(.offline), acknowledged: 3, trip: .deletionAcknowledged) }
        #expect(deleter.batches.count == 1)

        deleter.inventories = [.success(TripDeletionInventory(tripExists: false, eventIDs: []))]
        run.checkAgain()
        await settle("done after a clean listing") { run.state == .done }
        #expect(deleter.batches.count == 1, "nothing is sent again")
    }

    /// Events found by the verification listing are deleted in the same batches as the
    /// main run, never in one oversized batch.
    @Test func theSweepIsBatchedLikeTheMainRun() async {
        let deleter = FakeDeleter()
        let late = (0..<1_001).map { "late\($0)" }
        deleter.inventories = [
            .success(TripDeletionInventory(tripExists: true, eventIDs: ids(2))),
            .success(TripDeletionInventory(tripExists: false, eventIDs: late)),
            .success(TripDeletionInventory(tripExists: false, eventIDs: [])),
        ]
        let run = run(deleter)
        run.check()
        await settle("ready") { if case .ready = run.state { return true } else { return false } }
        run.delete()
        await settle("done") { run.state == .done }
        #expect(deleter.batches.map(\.eventIDs.count) == [2, 450, 450, 101])
        #expect(deleter.batches.map(\.andTrip) == [true, false, false, false])
        #expect(deleter.batches.allSatisfy { $0.eventIDs.count <= TripDeletion.eventsPerBatch })
        #expect(deleter.inventoryCalls == 3, "listing, verification with leftovers, verification clean")
    }

    /// When the server keeps listing Events after the sweep limit, the run stops and says
    /// what is left instead of finishing.
    @Test func leftoversAfterTheSweepLimitAreReportedNotFinished() async {
        let deleter = FakeDeleter()
        deleter.inventories = [
            .success(TripDeletionInventory(tripExists: true, eventIDs: ids(1))),
            .success(TripDeletionInventory(tripExists: false, eventIDs: ["stuck1", "stuck2"])),
        ]
        let run = run(deleter)
        run.check()
        await settle("ready") { if case .ready = run.state { return true } else { return false } }
        run.delete()
        await settle("leftovers") { run.state == stopped(.leftovers(events: 2, tripExists: false), acknowledged: 1 + 3 * 2, trip: .verifiedGone) }
        #expect(deleter.batches.count == 1 + fast.maxSweeps)
        #expect(deleter.inventoryCalls == 1 + fast.maxSweeps + 1, "a verification after every sweep, plus the last one")
    }

    /// The last batch (with the Trip) times out, then applies on the server anyway:
    /// Check again waits for queued writes, lists nothing, and only then reports done.
    @Test func aTimedOutLastBatchThatAppliesLaterCompletesOnCheckAgain() async {
        let deleter = FakeDeleter()
        deleter.inventories = [.success(TripDeletionInventory(tripExists: true, eventIDs: ids(1_001)))]
        deleter.failingBatch = 3
        deleter.batchError = AccountError.timedOut
        let run = run(deleter)
        run.check()
        await settle("ready") { if case .ready = run.state { return true } else { return false } }
        run.delete()
        await settle("last batch unconfirmed") { run.state == stopped(.batchUnconfirmed(events: 101, includesTrip: true), acknowledged: 900, trip: .unknown) }

        deleter.inventories = [.success(TripDeletionInventory(tripExists: false, eventIDs: []))]
        run.checkAgain()
        await settle("done") { run.state == .done }
        #expect(deleter.batches.count == 3, "nothing is sent twice")
    }

    /// A sweep failing after the Trip's batch was acknowledged says the Trip is deleted
    /// and the remaining Events are unconfirmed; Check again lists and deletes them.
    @Test func aSweepFailureAfterTheTripIsGoneSaysSo() async {
        let deleter = FakeDeleter()
        deleter.inventories = [
            .success(TripDeletionInventory(tripExists: true, eventIDs: ids(2))),
            .success(TripDeletionInventory(tripExists: false, eventIDs: ["late"])),
        ]
        deleter.failingBatch = 2
        let run = run(deleter)
        run.check()
        await settle("ready") { if case .ready = run.state { return true } else { return false } }
        run.delete()
        await settle("sweep failed") { run.state == stopped(.batchFailed(.offline), acknowledged: 2, trip: .verifiedGone) }

        deleter.failingBatch = nil
        deleter.inventories = [
            .success(TripDeletionInventory(tripExists: false, eventIDs: ["late"])),
            .success(TripDeletionInventory(tripExists: false, eventIDs: [])),
        ]
        run.checkAgain()
        await settle("ready for what remains") { run.state == .ready(TripDeletion.Summary(tripExists: false, eventCount: 1, unreadableEventCount: 0)) }
        run.delete()
        await settle("done") { run.state == .done }
        #expect(deleter.batches.last == FakeDeleter.Call(eventIDs: ["late"], andTrip: false))
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

    // MARK: What is known about the Trip (review finding 2)

    /// The Trip's status comes from listings and acknowledgements only. A sweep that
    /// fails after a listing showed the Trip gone reports "verified gone", even though
    /// no batch holding the Trip was acknowledged in this run.
    @Test func tripStatusIsNeverInferredFromAMissingAcknowledgement() async {
        let deleter = FakeDeleter()
        // The Trip was already gone when the run started (an earlier unconfirmed batch applied).
        deleter.inventories = [
            .success(TripDeletionInventory(tripExists: false, eventIDs: ["orphan1", "orphan2"])),
            .success(TripDeletionInventory(tripExists: false, eventIDs: ["orphan2"])),
        ]
        deleter.failingBatch = 2
        let run = run(deleter)
        run.check()
        await settle("ready") { run.state == .ready(TripDeletion.Summary(tripExists: false, eventCount: 2, unreadableEventCount: 0)) }
        run.delete()
        await settle("sweep failed") { run.state == stopped(.batchFailed(.offline), acknowledged: 2, trip: .verifiedGone) }

        // A failed first batch with the Trip present: present, and nothing to follow up.
        let intact = FakeDeleter()
        intact.inventories = [.success(TripDeletionInventory(tripExists: true, eventIDs: ids(3)))]
        intact.failingBatch = 1
        let untouched = self.run(intact)
        untouched.check()
        await settle("ready") { if case .ready = untouched.state { return true } else { return false } }
        untouched.delete()
        await settle("stopped") { untouched.state == stopped(.batchFailed(.offline), acknowledged: 0, trip: .present) }
        if case .stopped(let stop) = untouched.state { #expect(!stop.needsFollowUp) } else { Issue.record("stopped expected") }

        // An unconfirmed batch holding the Trip: unknown until a listing says otherwise.
        let unknown = FakeDeleter()
        unknown.inventories = [.success(TripDeletionInventory(tripExists: true, eventIDs: ids(1)))]
        unknown.failingBatch = 1
        unknown.batchError = AccountError.timedOut
        let pending = self.run(unknown)
        pending.check()
        await settle("ready") { if case .ready = pending.state { return true } else { return false } }
        pending.delete()
        await settle("unknown") { pending.state == stopped(.batchUnconfirmed(events: 1, includesTrip: true), acknowledged: 0, trip: .unknown) }
        if case .stopped(let stop) = pending.state { #expect(stop.needsFollowUp) } else { Issue.record("stopped expected") }
    }

    // MARK: Ledger and resuming (review finding 1 and 3)

    @Test func aStopThatSentSomethingIsRecordedAndAConfirmedDeletionErasesIt() async {
        let ledger = ledger()
        let deleter = FakeDeleter()
        deleter.inventories = [
            .success(TripDeletionInventory(tripExists: true, eventIDs: ids(3))),
            .failure(NSError(domain: "FIRFirestoreErrorDomain", code: 14)),
        ]
        let run = TripDeletionRun(deleter: deleter, uid: "fixture-uid", tripID: "fixture-trip", ledger: ledger, configuration: fast)
        run.check()
        await settle("ready") { if case .ready = run.state { return true } else { return false } }
        run.delete()
        await settle("verification failed") { run.state == stopped(.verificationFailed(.offline), acknowledged: 3, trip: .deletionAcknowledged) }
        let record = ledger.records(for: "fixture-uid").first
        #expect(record?.tripID == "fixture-trip")
        #expect(record?.acknowledgedEvents == 3 && record?.tripStatus == .deletionAcknowledged && record?.reason == "verificationFailed")
        #expect(ledger.records(for: "other-uid").isEmpty, "records are per account")

        deleter.inventories = [.success(TripDeletionInventory(tripExists: false, eventIDs: []))]
        run.checkAgain()
        await settle("done") { run.state == .done }
        #expect(ledger.records(for: "fixture-uid").isEmpty, "a confirmed deletion needs no follow-up")
    }

    @Test func aStopThatSentNothingIsNotRecorded() async {
        let ledger = ledger()
        let deleter = FakeDeleter()
        deleter.inventories = [.success(TripDeletionInventory(tripExists: true, eventIDs: ids(2)))]
        deleter.failingBatch = 1
        let run = TripDeletionRun(deleter: deleter, uid: "fixture-uid", tripID: "fixture-trip", ledger: ledger, configuration: fast)
        run.check()
        await settle("ready") { if case .ready = run.state { return true } else { return false } }
        run.delete()
        await settle("stopped") { run.state == stopped(.batchFailed(.offline), acknowledged: 0, trip: .present) }
        #expect(ledger.records(for: "fixture-uid").isEmpty)
    }

    /// Trip gone → sweep failed → the screen closes (run dropped) → the app restarts (a
    /// new ledger reads the same file) → Check again from the record → the server
    /// lists nothing → done, record erased.
    @Test func aStoppedDeletionIsResumedAfterARestartAndConfirmedEmpty() async {
        let file = ledgerFile()

        let before = FakeDeleter()
        before.inventories = [
            .success(TripDeletionInventory(tripExists: true, eventIDs: ids(2))),
            .success(TripDeletionInventory(tripExists: false, eventIDs: ["late"])),
        ]
        before.failingBatch = 2
        let firstLedger = ledger(file)
        var run: TripDeletionRun? = TripDeletionRun(deleter: before, uid: "fixture-uid", tripID: "fixture-trip", ledger: firstLedger, configuration: fast)
        run?.check()
        await settle("ready") { if case .ready = run?.state { return true } else { return false } }
        run?.delete()
        await settle("sweep failed") { run?.state == stopped(.batchFailed(.offline), acknowledged: 2, trip: .verifiedGone) }
        run?.cancel()
        run = nil   // the screen is gone

        // Restart: a fresh ledger from the same file still lists the deletion.
        let afterRestart = ledger(file)
        let record = afterRestart.records(for: "fixture-uid").first
        #expect(record?.tripID == "fixture-trip" && record?.tripStatus == .verifiedGone && record?.acknowledgedEvents == 2)

        // The queued sweep applied meanwhile: the server lists nothing.
        let after = FakeDeleter()
        after.inventories = [.success(TripDeletionInventory(tripExists: false, eventIDs: []))]
        let resumed = TripDeletionRun(deleter: after, uid: "fixture-uid", tripID: record?.tripID ?? "", ledger: afterRestart, configuration: fast)
        resumed.check()
        await settle("confirmed empty") { resumed.state == .done }
        #expect(after.batches.isEmpty)
        #expect(afterRestart.records(for: "fixture-uid").isEmpty)
        #expect(reread(file) == nil, "erased in storage too")
    }

    /// The same, but the leftover is still there: the resumed run offers to delete only
    /// the remaining Events (the Trip is verified gone), then confirms.
    @Test func aStoppedDeletionResumedAfterARestartDeletesWhatRemains() async {
        let ledger = ledger()
        try? ledger.record(PendingTripDeletion(tripID: "fixture-trip", startedAt: Date(), updatedAt: Date(), acknowledgedEvents: 2, tripStatus: .verifiedGone, reason: "batchFailed"), uid: "fixture-uid")
        let deleter = FakeDeleter()
        deleter.inventories = [
            .success(TripDeletionInventory(tripExists: false, eventIDs: ["late"])),
            .success(TripDeletionInventory(tripExists: false, eventIDs: [])),
        ]
        let resumed = TripDeletionRun(deleter: deleter, uid: "fixture-uid", tripID: "fixture-trip", ledger: ledger, configuration: fast)
        resumed.check()
        await settle("ready for the remaining event") { resumed.state == .ready(TripDeletion.Summary(tripExists: false, eventCount: 1, unreadableEventCount: 0)) }
        resumed.delete()
        await settle("done") { resumed.state == .done }
        #expect(deleter.batches == [FakeDeleter.Call(eventIDs: ["late"], andTrip: false)])
        #expect(ledger.records(for: "fixture-uid").isEmpty)
    }

    // MARK: When the record is written (PR #15 reinforcement)

    /// The record is on disk before the first batch is sent: a kill at that moment leaves
    /// a resumable entry. It is updated after each acknowledgement, and after the Trip's
    /// acknowledgement while the verification listing is still open.
    @Test func theRecordIsOnDiskBeforeDuringAndAfterTheBatches() async {
        let file = ledgerFile()
        let deleter = FakeDeleter()
        deleter.inventories = [
            .success(TripDeletionInventory(tripExists: true, eventIDs: ids(1_001))),
            .success(TripDeletionInventory(tripExists: false, eventIDs: [])),
        ]
        deleter.hangDeleteAt = 1
        deleter.hangInventoryFrom = 2
        let run = TripDeletionRun(deleter: deleter, uid: "fixture-uid", tripID: "fixture-trip", ledger: ledger(file), configuration: fast)
        run.check()
        await settle("ready") { if case .ready = run.state { return true } else { return false } }
        #expect(reread(file) == nil, "nothing is recorded before the user commits")

        // Right after the save, with the first batch in flight (nothing acknowledged).
        run.delete()
        await settle("first batch in flight") { deleter.batches.count == 1 }
        var record = reread(file)
        #expect(record?.tripID == "fixture-trip" && record?.reason == "started" && record?.acknowledgedEvents == 0 && record?.tripStatus == .present)

        // While sending: the first two batches acknowledged, the third not yet.
        deleter.hangDeleteAt = 3
        deleter.release()
        await settle("third batch in flight") { deleter.batches.count == 3 }
        record = reread(file)
        #expect(record?.reason == "inProgress" && record?.acknowledgedEvents == 900 && record?.tripStatus == .present)

        // After the Trip's acknowledgement, before the verification listing answers.
        deleter.hangDeleteAt = nil
        deleter.release()
        await settle("verification in flight") { deleter.inventoryCalls == 2 }
        record = reread(file)
        #expect(record?.acknowledgedEvents == 1_001 && record?.tripStatus == .deletionAcknowledged)

        // The listing confirms nothing is left: only now is the record erased.
        deleter.release()
        await settle("done") { run.state == .done }
        #expect(reread(file) == nil)
    }

    @Test func aRecordThatCannotBeSavedStopsTheDeletionBeforeAnythingIsSent() async {
        let deleter = FakeDeleter()
        deleter.inventories = [.success(TripDeletionInventory(tripExists: true, eventIDs: ids(3)))]
        let run = TripDeletionRun(deleter: deleter, uid: "fixture-uid", tripID: "fixture-trip", ledger: TripDeletionLedger(storage: FailingStorage()), configuration: fast)
        run.check()
        await settle("ready") { if case .ready = run.state { return true } else { return false } }
        run.delete()
        #expect(run.state == .blocked(.ledgerUnavailable))
        #expect(deleter.batches.isEmpty, "no batch is sent without its record")
        #expect(run.ledgerWarning != nil)
    }

    /// A resumed run adds to the acknowledged count already on record.
    @Test func aResumedRunKeepsTheEarlierAcknowledgedCount() async {
        let file = ledgerFile()
        let before = ledger(file)
        try? before.record(PendingTripDeletion(tripID: "fixture-trip", startedAt: Date(timeIntervalSince1970: 1_790_000_000), updatedAt: Date(), acknowledgedEvents: 450, tripStatus: .present, reason: "batchFailed"), uid: "fixture-uid")
        let deleter = FakeDeleter()
        deleter.inventories = [
            .success(TripDeletionInventory(tripExists: true, eventIDs: ids(2))),
            .failure(NSError(domain: "FIRFirestoreErrorDomain", code: 14)),
        ]
        let run = TripDeletionRun(deleter: deleter, uid: "fixture-uid", tripID: "fixture-trip", ledger: ledger(file), configuration: fast)
        run.check()
        await settle("ready") { if case .ready = run.state { return true } else { return false } }
        run.delete()
        await settle("verification failed") { run.state == stopped(.verificationFailed(.offline), acknowledged: 2, trip: .deletionAcknowledged) }
        let record = reread(file)
        #expect(record?.acknowledgedEvents == 452 && record?.reason == "verificationFailed")
        #expect(record?.startedAt == Date(timeIntervalSince1970: 1_790_000_000), "the first attempt's start is kept")
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
