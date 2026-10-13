import Foundation
import Observation

/// What the server holds under a Trip, read from the server (never the cache) right
/// before deleting. Every Event document counts, readable or not.
nonisolated struct TripDeletionInventory: Equatable, Sendable {
    /// False when the Trip document is already gone (deleted elsewhere).
    let tripExists: Bool
    /// Every Event document ID under the Trip, including unreadable documents.
    let eventIDs: [String]
    /// IDs among `eventIDs` whose documents cannot be decoded as Events (RF-03: they are
    /// deleted with the Trip, and the user is told how many there are).
    let unreadableEventIDs: [String]

    init(tripExists: Bool, eventIDs: [String], unreadableEventIDs: [String] = []) {
        self.tripExists = tripExists
        self.eventIDs = eventIDs
        self.unreadableEventIDs = unreadableEventIDs
    }
}

/// The three server operations a Trip deletion needs. `TripStore` is the Firestore
/// implementation; tests use a fake.
protocol TripDeleting {
    /// Returns once every locally queued write has reached the server, or throws
    /// (`AccountError.timedOut` while offline).
    func waitForPendingWrites(timeout: Duration) async throws
    /// Lists the Trip and its Events on the server, not in the cache.
    func inventory(uid: String, tripID: String) async throws -> TripDeletionInventory
    /// Deletes the given Events and, when `andTrip`, the Trip itself in one atomic batch,
    /// and returns once the server has acknowledged it.
    func delete(eventIDs: [String], andTrip: Bool, uid: String, tripID: String, timeout: Duration) async throws
}

/// RF-03: deleting a Trip means deleting its Events and then the Trip, never the Trip
/// alone. Pure rules live here; `TripDeletionRun` drives them.
nonisolated enum TripDeletion {
    /// Firestore allows 500 operations per batch; the headroom is deliberate.
    static let eventsPerBatch = 450

    struct Configuration: Sendable {
        var pendingWritesTimeout: Duration = .seconds(15)
        var batchTimeout: Duration = .seconds(20)
        /// Above this the deletion is refused here rather than run for minutes.
        var maxEvents = 2_000
        var eventsPerBatch = TripDeletion.eventsPerBatch
    }

    /// Why a deletion did not start, or stopped. Each has its own wording in the UI.
    enum Problem: Equatable, Sendable {
        /// Queued local writes have not reached the server, or the client is offline (the
        /// wait for pending writes does not finish either way).
        case unsyncedWrites
        /// The server could not be reached for the listing or a batch.
        case offline
        /// The server refused (permission).
        case denied
        /// A batch was sent but no acknowledgement arrived in time. It stays queued and
        /// may still complete once connected.
        case noReply
        case tooManyEvents(Int)
        case other(domain: String, code: Int)
    }

    /// What the confirmation screen lists before the user commits.
    struct Summary: Equatable, Sendable {
        let tripExists: Bool
        let eventCount: Int
        let unreadableEventCount: Int
    }

    struct Batch: Equatable, Sendable {
        let eventIDs: [String]
        let andTrip: Bool
    }

    /// Events first, in batches; the Trip goes with the last batch (alone when there are
    /// no Events), so a failure part-way leaves a Trip with fewer Events, never Events
    /// without their Trip. Nothing to do when neither exists.
    static func batches(eventIDs: [String], tripExists: Bool, perBatch: Int = eventsPerBatch) -> [Batch] {
        let perBatch = max(1, perBatch)
        var batches: [Batch] = stride(from: 0, to: eventIDs.count, by: perBatch).map { start in
            Batch(eventIDs: Array(eventIDs[start..<min(start + perBatch, eventIDs.count)]), andTrip: false)
        }
        if tripExists {
            if let last = batches.last {
                batches[batches.count - 1] = Batch(eventIDs: last.eventIDs, andTrip: true)
            } else {
                batches = [Batch(eventIDs: [], andTrip: true)]
            }
        }
        return batches
    }

    /// Maps a thrown error to a `Problem`, by domain and code only (no message parsing).
    static func problem(for error: Error) -> Problem {
        if let accountError = error as? AccountError, accountError == .timedOut { return .noReply }
        let error = error as NSError
        if error.domain == "FIRFirestoreErrorDomain" {
            switch error.code {
            case 7: return .denied            // permissionDenied
            case 4, 14: return .offline       // deadlineExceeded, unavailable
            default: return .other(domain: error.domain, code: error.code)
            }
        }
        if error.domain == NSURLErrorDomain { return .offline }
        return .other(domain: error.domain, code: error.code)
    }
}

/// One Trip deletion from the confirmation screen: a server-side check first, then the
/// batches, then a sweep for Events added in between. Every reply is applied only when
/// it belongs to the current run (never-reused token), so a cancelled check or an old
/// batch cannot change the state shown.
@Observable
final class TripDeletionRun {
    enum State: Equatable {
        case idle
        case checking
        /// Not started; the reason is shown and "Check again" is offered.
        case blocked(TripDeletion.Problem)
        case ready(TripDeletion.Summary)
        case deleting(done: Int, total: Int)
        /// Stopped part-way: `deletedEvents` are gone, the Trip and the rest remain.
        case failed(TripDeletion.Problem, deletedEvents: Int)
        case done
    }

    private(set) var state: State = .idle
    private let deleter: any TripDeleting
    private let uid: String
    private let tripID: String
    private let configuration: TripDeletion.Configuration
    private var token = 0
    private var task: Task<Void, Never>?

    init(deleter: any TripDeleting, uid: String, tripID: String, configuration: TripDeletion.Configuration = .init()) {
        self.deleter = deleter
        self.uid = uid
        self.tripID = tripID
        self.configuration = configuration
    }

    var isBusy: Bool {
        switch state {
        case .checking, .deleting: true
        default: false
        }
    }

    /// Checks that the deletion can complete: local writes synced, server reachable, the
    /// Trip still there, and not too many Events. Ends in `.ready`, `.blocked`, or `.done`
    /// when nothing is left to delete.
    func check() {
        guard !isBusy else { return }
        let current = begin()
        state = .checking
        task = Task {
            do {
                try await deleter.waitForPendingWrites(timeout: configuration.pendingWritesTimeout)
            } catch {
                apply(.blocked(.unsyncedWrites), token: current)
                return
            }
            do {
                let inventory = try await deleter.inventory(uid: uid, tripID: tripID)
                guard current == token else { return }
                if !inventory.tripExists, inventory.eventIDs.isEmpty {
                    apply(.done, token: current)
                } else if inventory.eventIDs.count > configuration.maxEvents {
                    apply(.blocked(.tooManyEvents(inventory.eventIDs.count)), token: current)
                } else {
                    pendingInventory = inventory
                    apply(.ready(TripDeletion.Summary(
                        tripExists: inventory.tripExists,
                        eventCount: inventory.eventIDs.count,
                        unreadableEventCount: inventory.unreadableEventIDs.count
                    )), token: current)
                }
            } catch {
                apply(.blocked(TripDeletion.problem(for: error)), token: current)
            }
        }
    }

    /// The listing `.ready` was computed from; the batches are built from it, not from
    /// the cache or the screen.
    private var pendingInventory: TripDeletionInventory?

    /// Runs the batches for the checked listing. Only from `.ready`.
    func delete() {
        guard case .ready = state, let inventory = pendingInventory else { return }
        let current = begin()
        let batches = TripDeletion.batches(
            eventIDs: inventory.eventIDs, tripExists: inventory.tripExists, perBatch: configuration.eventsPerBatch
        )
        let total = inventory.eventIDs.count
        state = .deleting(done: 0, total: total)
        task = Task {
            var done = 0
            for batch in batches {
                do {
                    try await deleter.delete(
                        eventIDs: batch.eventIDs, andTrip: batch.andTrip, uid: uid, tripID: tripID,
                        timeout: configuration.batchTimeout
                    )
                } catch {
                    apply(.failed(TripDeletion.problem(for: error), deletedEvents: done), token: current)
                    return
                }
                guard current == token else { return }
                done += batch.eventIDs.count
                state = .deleting(done: done, total: total)
            }
            // Events created between the listing and the Trip's deletion (another device)
            // would be left under a Trip that no longer exists; none can be created after.
            for _ in 0..<3 {
                guard let leftovers = try? await deleter.inventory(uid: uid, tripID: tripID), current == token else { break }
                guard !leftovers.eventIDs.isEmpty else { break }
                do {
                    try await deleter.delete(
                        eventIDs: leftovers.eventIDs, andTrip: leftovers.tripExists, uid: uid, tripID: tripID,
                        timeout: configuration.batchTimeout
                    )
                } catch {
                    apply(.failed(TripDeletion.problem(for: error), deletedEvents: done), token: current)
                    return
                }
                done += leftovers.eventIDs.count
            }
            apply(.done, token: current)
        }
    }

    /// After a failure or a blocker: a fresh check (which lists what remains), then the
    /// user confirms again. Deleting is idempotent: what is gone is not listed.
    func checkAgain() {
        guard !isBusy else { return }
        state = .idle
        check()
    }

    /// Drops any reply still to come. Batches already sent are not undone.
    func cancel() {
        _ = begin()
        if isBusy { state = .idle }
    }

    private func begin() -> Int {
        token += 1
        task?.cancel()
        task = nil
        pendingInventory = nil
        return token
    }

    private func apply(_ newState: State, token: Int) {
        guard token == self.token else { return }
        state = newState
    }
}
