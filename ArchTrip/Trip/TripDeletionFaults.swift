import Foundation

#if DEBUG
/// Simulator-check hook for the stop states of a Trip deletion. Debug builds only, and
/// only when the app is launched with `ARCHTRIP_DEBUG_DELETION_FAULT` set to one of the
/// faults below. It wraps the real store and makes exactly one step fail once, so every
/// server state the screen then reports is real. No UI, not compiled into Release.
final class FaultInjectingTripDeleter: TripDeleting {
    enum Fault: String {
        /// The first listing hides one Event, so it survives the main batches; the sweep
        /// that would delete it fails (unreachable server). The Trip is really gone.
        case sweep
        /// The batch holding the Trip is committed for real but reported as timed out.
        case unconfirmed
        /// The listing after the batches fails once.
        case verification
        /// Every listing after the batches adds a phantom Event, until the sweep limit.
        case leftovers
        /// The first batch never returns (nothing is sent): for a force quit right after
        /// the ledger record was written.
        case stallFirstBatch
        /// The second batch never returns: for a force quit while sending.
        case stallSecondBatch
        /// The listing after the batches never returns: for a force quit after the Trip's
        /// acknowledgement and before verification.
        case stallVerification
    }

    static let environmentKey = "ARCHTRIP_DEBUG_DELETION_FAULT"

    private let base: any TripDeleting
    private let fault: Fault
    private var listings = 0
    private var deletes = 0
    private var fired = false

    init?(wrapping base: any TripDeleting, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let raw = environment[Self.environmentKey], let fault = Fault(rawValue: raw) else { return nil }
        self.base = base
        self.fault = fault
    }

    private var unreachable: Error { NSError(domain: "FIRFirestoreErrorDomain", code: 14) }

    func waitForPendingWrites(timeout: Duration) async throws {
        try await base.waitForPendingWrites(timeout: timeout)
    }

    func inventory(uid: String, tripID: String) async throws -> TripDeletionInventory {
        listings += 1
        // Listings before any batch are the checks (possibly repeated after a blocker);
        // listings after a batch are verifications.
        if fault == .stallVerification, deletes > 0 {
            try await Task.sleep(for: .seconds(3_600))
        }
        let real = try await base.inventory(uid: uid, tripID: tripID)
        switch fault {
        case .sweep where deletes == 0 && real.eventIDs.count > 1:
            return TripDeletionInventory(tripExists: real.tripExists, eventIDs: Array(real.eventIDs.dropFirst()), unreadableEventIDs: real.unreadableEventIDs)
        case .verification where deletes > 0 && !fired:
            fired = true
            throw unreachable
        case .leftovers where deletes > 0:
            return TripDeletionInventory(tripExists: real.tripExists, eventIDs: real.eventIDs + ["phantom-\(listings)"], unreadableEventIDs: real.unreadableEventIDs)
        default:
            return real
        }
    }

    func delete(eventIDs: [String], andTrip: Bool, uid: String, tripID: String, timeout: Duration) async throws {
        deletes += 1
        switch fault {
        case .stallFirstBatch where deletes == 1, .stallSecondBatch where deletes == 2:
            try await Task.sleep(for: .seconds(3_600))
        case .sweep where !andTrip && deletes > 1 && !fired:
            fired = true
            throw unreachable
        case .unconfirmed where andTrip && !fired:
            fired = true
            try await base.delete(eventIDs: eventIDs, andTrip: andTrip, uid: uid, tripID: tripID, timeout: timeout)
            throw AccountError.timedOut
        default:
            try await base.delete(eventIDs: eventIDs, andTrip: andTrip, uid: uid, tripID: tripID, timeout: timeout)
        }
    }
}
#endif
