import Foundation
import Observation

/// What the server holds under a Trip, read from the server (never the cache) right
/// before deleting and again afterwards. Every Event document counts, readable or not.
nonisolated struct TripDeletionInventory: Equatable, Sendable {
    /// False when the Trip document is gone.
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

    /// Nothing left on the server: the only state that counts as "deleted".
    var isEmpty: Bool { !tripExists && eventIDs.isEmpty }
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
/// alone, and reporting "deleted" only once the server confirms nothing is left. Pure
/// rules live here; `TripDeletionRun` drives them.
nonisolated enum TripDeletion {
    /// Firestore allows 500 operations per batch; the headroom is deliberate.
    static let eventsPerBatch = 450

    struct Configuration: Sendable {
        var pendingWritesTimeout: Duration = .seconds(15)
        var batchTimeout: Duration = .seconds(20)
        /// Above this the deletion is refused here rather than run for minutes.
        var maxEvents = 2_000
        var eventsPerBatch = TripDeletion.eventsPerBatch
        /// How many times Events found by the verification listing (added meanwhile) are
        /// deleted before the run stops and reports what is left.
        var maxSweeps = 3
    }

    /// Why a deletion did not start, or why a step failed. Each has its own wording.
    enum Problem: Equatable, Sendable {
        /// Queued local writes have not reached the server, or the client is offline (the
        /// wait for pending writes does not finish either way).
        case unsyncedWrites
        /// The server could not be reached.
        case offline
        /// The server refused (permission).
        case denied
        /// A request was sent but no acknowledgement arrived in time.
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

    /// Why a run stopped short of a confirmed deletion, and what the server did
    /// acknowledge. Only an acknowledged batch counts; a batch sent without an
    /// acknowledgement may still apply later, so it is reported as unconfirmed.
    struct Stop: Equatable, Sendable {
        enum Reason: Equatable, Sendable {
            /// A batch was refused or could not be sent; nothing of it was applied.
            case batchFailed(Problem)
            /// A batch was sent but not acknowledged in time (`events` and whether the
            /// Trip was in it). It stays queued and may still apply once connected.
            case batchUnconfirmed(events: Int, includesTrip: Bool)
            /// The server could not be read after the batches; what remains is unknown.
            case verificationFailed(Problem)
            /// The server still listed something after the sweep limit.
            case leftovers(events: Int, tripExists: Bool)
        }

        let reason: Reason
        /// Events in batches the server acknowledged.
        let acknowledgedEvents: Int
        /// Whether a batch holding the Trip was acknowledged.
        let tripAcknowledged: Bool
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
/// batches, then a server-side verification that sweeps Events added in between. The
/// run ends in `.done` only when a listing shows the Trip and its Events gone; anything
/// else is `.stopped` with what was acknowledged. Every reply is applied only when it
/// belongs to the current run (never-reused token).
@Observable
final class TripDeletionRun {
    enum State: Equatable {
        case idle
        case checking
        /// Not started; the reason is shown and "Check again" is offered.
        case blocked(TripDeletion.Problem)
        case ready(TripDeletion.Summary)
        case deleting(acknowledged: Int, total: Int)
        /// Stopped before the server confirmed everything is gone (see `Stop`).
        case stopped(TripDeletion.Stop)
        /// The server listed neither the Trip nor any Event.
        case done
    }

    private(set) var state: State = .idle
    private let deleter: any TripDeleting
    private let uid: String
    private let tripID: String
    private let configuration: TripDeletion.Configuration
    private var token = 0
    private var task: Task<Void, Never>?
    /// The listing `.ready` was computed from; the batches are built from it, not from
    /// the cache or the screen.
    private var pendingInventory: TripDeletionInventory?

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

    /// Checks that the deletion can complete: local writes synced, server reachable, and
    /// not too many Events. Ends in `.ready`, `.blocked`, or `.done` when the server
    /// already holds nothing.
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
                if inventory.isEmpty {
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

    /// Runs the batches for the checked listing, then verifies on the server. Only from `.ready`.
    func delete() {
        guard case .ready = state, let inventory = pendingInventory else { return }
        let current = begin()
        let total = inventory.eventIDs.count
        state = .deleting(acknowledged: 0, total: total)
        task = Task {
            var acknowledged = 0
            var tripAcknowledged = false

            func stop(_ reason: TripDeletion.Stop.Reason) {
                apply(.stopped(TripDeletion.Stop(reason: reason, acknowledgedEvents: acknowledged, tripAcknowledged: tripAcknowledged)), token: current)
            }

            /// Sends the batches in order; false when one failed (the stop is already applied).
            func send(_ batches: [TripDeletion.Batch]) async -> Bool {
                for batch in batches {
                    do {
                        try await deleter.delete(
                            eventIDs: batch.eventIDs, andTrip: batch.andTrip, uid: uid, tripID: tripID,
                            timeout: configuration.batchTimeout
                        )
                    } catch {
                        guard current == token else { return false }
                        let problem = TripDeletion.problem(for: error)
                        if problem == .noReply {
                            stop(.batchUnconfirmed(events: batch.eventIDs.count, includesTrip: batch.andTrip))
                        } else {
                            stop(.batchFailed(problem))
                        }
                        return false
                    }
                    guard current == token else { return false }
                    acknowledged += batch.eventIDs.count
                    if batch.andTrip { tripAcknowledged = true }
                    state = .deleting(acknowledged: acknowledged, total: total)
                }
                return true
            }

            let batches = TripDeletion.batches(
                eventIDs: inventory.eventIDs, tripExists: inventory.tripExists, perBatch: configuration.eventsPerBatch
            )
            guard await send(batches) else { return }

            // Verification: the server must list nothing. Events another device added
            // between the listing and the Trip's deletion are swept, in batches, a bounded
            // number of times; none can be created once the Trip is gone.
            var sweeps = 0
            while true {
                let listing: TripDeletionInventory
                do {
                    listing = try await deleter.inventory(uid: uid, tripID: tripID)
                } catch {
                    guard current == token else { return }
                    stop(.verificationFailed(TripDeletion.problem(for: error)))
                    return
                }
                guard current == token else { return }
                if listing.isEmpty {
                    apply(.done, token: current)
                    return
                }
                if sweeps == configuration.maxSweeps {
                    stop(.leftovers(events: listing.eventIDs.count, tripExists: listing.tripExists))
                    return
                }
                sweeps += 1
                let sweep = TripDeletion.batches(
                    eventIDs: listing.eventIDs, tripExists: listing.tripExists, perBatch: configuration.eventsPerBatch
                )
                guard await send(sweep) else { return }
            }
        }
    }

    /// After a stop or a blocker: waits for queued writes (an unconfirmed batch included),
    /// lists the server again and offers to delete what remains, or ends in `.done` when
    /// nothing is left. Deleting is idempotent: what is gone is not listed.
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
