import Foundation
import MapKit
import Observation

/// What an Apple Maps Place ID resolves to, for display only (v0.2). It is never
/// encoded, stored or logged: it lives in `PlaceDirectory`'s memory, at most 24 hours,
/// and only ever enters it through a fetch.
nonisolated struct ResolvedPlace: Equatable {
    /// The place's current ID as returned by MapKit (may differ from the stored one).
    let identifier: String
    /// Other IDs MapKit says refer to the same place.
    let alternateIdentifiers: Set<String>
    let name: String?
    /// One-line address, or nil when MapKit gives none.
    let address: String?
    let latitude: Double
    let longitude: Double
    /// MapKit's item, for opening Apple Maps. Nil in tests.
    let mapItem: MKMapItem?

    init(identifier: String, alternateIdentifiers: Set<String> = [], name: String?, address: String?, latitude: Double, longitude: Double, mapItem: MKMapItem? = nil) {
        self.identifier = identifier
        self.alternateIdentifiers = alternateIdentifiers
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.mapItem = mapItem
    }

    static func == (lhs: ResolvedPlace, rhs: ResolvedPlace) -> Bool {
        lhs.identifier == rhs.identifier && lhs.alternateIdentifiers == rhs.alternateIdentifiers
            && lhs.name == rhs.name && lhs.address == rhs.address
            && lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}

/// How a fetch failed, as far as the directory needs to know to retry and the UI to
/// explain. See `MapKitPlaceFetcher.classify` for the mapping from error codes.
nonisolated enum PlaceFetchFailure: Error, Hashable, Sendable, CaseIterable {
    /// No connectivity (explicit "not connected" codes only).
    case offline
    /// The network is there but the request timed out.
    case timeout
    /// A transport problem: TLS or certificate failure, DNS or connection failure.
    case transport
    /// MapKit is rate-limiting this app.
    case throttled
    /// Apple's server failed or answered something unreadable.
    case server
    /// Apple Maps no longer resolves the ID. Never retried automatically.
    case notFound
}

/// Resolves a Place ID. Throws `PlaceFetchFailure` (or `CancellationError`); should stop
/// when its task is cancelled, but the directory does not depend on it: a result that
/// arrives after its request was superseded is ignored.
protocol PlaceFetching {
    func fetch(_ identifier: String) async throws -> ResolvedPlace
}

/// In-memory place lookups for linked Buildings. Two things are tracked separately:
///
/// - **Screen interest** (`hold` / `retain` / `release`): which visible views need an ID.
///   It drives network work only: at zero, the in-flight request, the retry wait and the
///   queue slot are cancelled. Each claim is a `HoldToken`, unique for the directory's
///   lifetime, so a release from an old screen, after a clear or after the same ID was
///   discarded and re-created, is a no-op and never decrements a newer claim.
/// - **Document references** (`updateDocumentReferences`): which IDs the user's stored
///   Buildings carry. They drive retention: a resolved value stays (until its limits) while
///   a document still refers to it, and is discarded when neither a document nor a view does.
///
/// Every request and retry wait carries a work token from the same never-reused sequence:
/// a completion that arrives late, after a cancel, a clear or a re-creation, changes nothing.
///
/// Values are fetched on demand, never prefetched and never injected from elsewhere. Each
/// has a freshness window (refetched when shown again after it) and a hard retention limit
/// (discarded regardless), checked on access, on foreground and by a sweep timer. Nothing
/// here is written to disk.
@Observable
final class PlaceDirectory {
    struct Configuration {
        /// After this, a shown value is refetched; the old value stays visible meanwhile.
        var freshness: TimeInterval = 60 * 60
        /// After this, a value is discarded whatever happened to its refetch.
        var maxRetention: TimeInterval = 24 * 60 * 60
        var maxEntries = 100
        var concurrency = 2
        var minManualRetryInterval: TimeInterval = 5
        /// Automatic retry delays per failure, in order; past the end, manual only.
        var retryDelays: [PlaceFetchFailure: [TimeInterval]] = [
            .offline: [5, 20, 60, 180],
            .timeout: [10, 30, 90],
            .transport: [30, 90],
            .throttled: [60, 180],
            .server: [20, 60],
            .notFound: [],
        ]

        static let `default` = Configuration()
    }

    enum State: Equatable {
        case idle
        case loading
        /// `stale`: past the freshness window; a refetch is pending, waiting or failed.
        case resolved(ResolvedPlace, fetchedAt: Date, stale: Bool)
        /// `nextRetryAt` nil: automatic retries exhausted (or none for this kind), manual only.
        case failed(PlaceFetchFailure, attempts: Int, nextRetryAt: Date?)
    }

    /// A screen's claim on a place. Release it with the token you were given; a token
    /// that was already released, cleared away or belongs to a re-created entry does nothing.
    struct HoldToken: Hashable, Sendable {
        fileprivate let value: Int
        fileprivate let identifier: String
    }

    private struct Entry {
        var state: State = .idle
        /// Live hold tokens; screen interest is their count.
        var holders: Set<Int> = []
        var lastAccess: Date
        var attempts = 0
        var lastAttemptAt: Date?
        /// The in-flight fetch or the retry wait, and its token. A task whose token no longer
        /// matches (cancelled, cleared, superseded) touches nothing when it resumes.
        var work: Task<Void, Never>?
        var workToken: Int?
        var queued = false

        var interest: Int { holders.count }
    }

    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var documentReferences: Set<String> = []
    @ObservationIgnored private var pending: [String] = []
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    /// One sequence for hold and work tokens, never reset (not even by `clear`).
    @ObservationIgnored private var lastToken = 0
    @ObservationIgnored private let fetcher: any PlaceFetching
    @ObservationIgnored let configuration: Configuration
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: (TimeInterval) async throws -> Void
    /// Fetches started, for tests (no prefetch means this only moves on demand).
    @ObservationIgnored private(set) var fetchCount = 0

    init(
        fetcher: any PlaceFetching,
        configuration: Configuration = .default,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.fetcher = fetcher
        self.configuration = configuration
        self.now = now
        self.sleep = sleep
    }

    // MARK: Reading

    func state(for identifier: String) -> State {
        entries[identifier]?.state ?? .idle
    }

    func place(for identifier: String) -> ResolvedPlace? {
        if case .resolved(let place, _, _) = state(for: identifier) { return place }
        return nil
    }

    func interest(in identifier: String) -> Int {
        entries[identifier]?.interest ?? 0
    }

    var isIdle: Bool { pending.isEmpty && running.isEmpty }

    // MARK: Screen interest

    /// Keeps `identifier` wanted until the calling task is cancelled (`.task(id:)`). The
    /// claim is released with the token taken at the start, never by identifier.
    func hold(_ identifier: String) async {
        let token = retain(identifier)
        defer { release(token) }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    func hold(_ identifiers: Set<String>) async {
        let tokens = identifiers.map(retain)
        defer { for token in tokens { release(token) } }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    func retain(_ identifier: String) -> HoldToken {
        let token = HoldToken(value: nextToken(), identifier: identifier)
        var entry = entries[identifier] ?? Entry(lastAccess: now())
        entry.holders.insert(token.value)
        entry.lastAccess = now()
        entries[identifier] = entry
        scheduleIfNeeded(identifier)
        enforceLimit()
        return token
    }

    func release(_ token: HoldToken) {
        guard var entry = entries[token.identifier], entry.holders.remove(token.value) != nil else { return }
        entries[token.identifier] = entry
        if entry.interest == 0 {
            cancelWork(token.identifier)
            discardIfUnreferenced(token.identifier)
        }
    }

    // MARK: Document references

    /// The Place IDs the user's stored Buildings carry. Values nobody refers to are dropped.
    func updateDocumentReferences(_ identifiers: Set<String>) {
        documentReferences = identifiers
        for identifier in entries.keys where !identifiers.contains(identifier) {
            discardIfUnreferenced(identifier)
        }
    }

    // MARK: Actions

    /// Manual retry: resets the automatic attempts, at most once per `minManualRetryInterval`.
    func retry(_ identifier: String) {
        guard var entry = entries[identifier] else { return }
        if let last = entry.lastAttemptAt, now().timeIntervalSince(last) < configuration.minManualRetryInterval { return }
        entry.attempts = 0
        entries[identifier] = entry
        cancelWork(identifier)
        if case .failed = entries[identifier]?.state { entries[identifier]?.state = .idle }
        enqueue(identifier)
    }

    /// Back in the foreground: apply the limits, then retry each shown failure once
    /// (not "not found") and refresh shown stale values.
    func handleForeground() {
        sweep()
        for (identifier, entry) in entries where entry.interest > 0 {
            switch entry.state {
            case .failed(let failure, _, _) where failure != .notFound:
                cancelWork(identifier)
                entries[identifier]?.state = .idle
                enqueue(identifier)
            case .resolved(_, _, stale: true) where entry.work == nil && !entry.queued:
                enqueue(identifier)
            default:
                break
            }
        }
    }

    /// Memory pressure: drop everything no view is showing.
    func discardUndisplayed() {
        for (identifier, entry) in entries where entry.interest == 0 {
            cancelWork(identifier)
            entries.removeValue(forKey: identifier)
        }
        scheduleSweep()
    }

    /// Signed out or switched user: cancel everything and forget it all. Tokens handed out
    /// before this point stay invalid forever; the sequence is not reset.
    func clear() {
        for identifier in entries.keys { cancelWork(identifier) }
        sweepTask?.cancel()
        sweepTask = nil
        entries = [:]
        pending = []
        running = []
        documentReferences = []
    }

    // MARK: Limits

    /// Applies freshness and retention to every value, then reschedules the next sweep.
    func sweep() {
        let now = now()
        for (identifier, entry) in entries {
            guard case .resolved(let place, let fetchedAt, let stale) = entry.state else { continue }
            if now.timeIntervalSince(fetchedAt) >= configuration.maxRetention {
                cancelWork(identifier)
                entries[identifier]?.state = .idle
                entries[identifier]?.attempts = 0
                if entry.interest > 0 { enqueue(identifier) } else { discardIfUnreferenced(identifier) }
            } else if !stale, now.timeIntervalSince(fetchedAt) >= configuration.freshness {
                entries[identifier]?.state = .resolved(place, fetchedAt: fetchedAt, stale: true)
                if entry.interest > 0 { enqueue(identifier) }
            }
        }
        scheduleSweep()
    }

    // MARK: Private

    private func nextToken() -> Int {
        lastToken += 1
        return lastToken
    }

    private func scheduleIfNeeded(_ identifier: String) {
        guard let entry = entries[identifier] else { return }
        switch entry.state {
        case .idle:
            enqueue(identifier)
        case .loading:
            break
        case .resolved(let place, let fetchedAt, let stale):
            let age = now().timeIntervalSince(fetchedAt)
            if age >= configuration.maxRetention {
                entries[identifier]?.state = .idle
                entries[identifier]?.attempts = 0
                enqueue(identifier)
            } else if age >= configuration.freshness {
                if !stale { entries[identifier]?.state = .resolved(place, fetchedAt: fetchedAt, stale: true) }
                if entry.work == nil { enqueue(identifier) }
            }
        case .failed(_, _, let nextRetryAt):
            if entry.work == nil, !entry.queued, let nextRetryAt {
                waitThenRetry(identifier, until: nextRetryAt)
            }
        }
    }

    private func enqueue(_ identifier: String) {
        guard var entry = entries[identifier], !entry.queued, !running.contains(identifier) else { return }
        entry.queued = true
        // Waiting for a slot already looks like loading to the user.
        if case .idle = entry.state { entry.state = .loading }
        entries[identifier] = entry
        pending.append(identifier)
        pump()
    }

    private func pump() {
        while running.count < configuration.concurrency, !pending.isEmpty {
            let identifier = pending.removeFirst()
            guard var entry = entries[identifier] else { continue }
            entry.queued = false
            guard entry.interest > 0 else {
                entries[identifier] = entry
                continue
            }
            if case .resolved = entry.state {
                // A refresh: keep showing the old value.
            } else {
                entry.state = .loading
            }
            entry.work?.cancel()
            let token = nextToken()
            entry.workToken = token
            entry.lastAttemptAt = now()
            entry.attempts += 1
            running.insert(identifier)
            entries[identifier] = entry
            fetchCount += 1
            entries[identifier]?.work = Task { [weak self] in
                await self?.perform(identifier, token: token)
            }
        }
    }

    private func perform(_ identifier: String, token: Int) async {
        var outcome: Result<ResolvedPlace, PlaceFetchFailure>?
        do {
            let place = try await fetcher.fetch(identifier)
            outcome = .success(place)
        } catch is CancellationError {
            outcome = nil
        } catch let failure as PlaceFetchFailure {
            outcome = .failure(failure)
        } catch {
            outcome = .failure(.server)
        }
        // Superseded (cancelled, cleared, re-created or restarted): `cancelWork` already did
        // the bookkeeping, and this result belongs to nobody.
        guard let entry = entries[identifier], entry.workToken == token else { return }
        running.remove(identifier)
        entries[identifier]?.work = nil
        entries[identifier]?.workToken = nil
        switch outcome {
        case .success(let place):
            entries[identifier]?.state = .resolved(place, fetchedAt: now(), stale: false)
            entries[identifier]?.attempts = 0
        case .failure(let failure):
            applyFailure(failure, to: identifier)
        case nil:
            if case .loading = entry.state { entries[identifier]?.state = .idle }
        }
        pump()
        scheduleSweep()
    }

    private func applyFailure(_ failure: PlaceFetchFailure, to identifier: String) {
        guard let entry = entries[identifier] else { return }
        let delays = configuration.retryDelays[failure] ?? []
        let delay = entry.attempts - 1 < delays.count ? delays[entry.attempts - 1] : nil
        let nextRetryAt = delay.map { now().addingTimeInterval($0) }
        if case .resolved(let place, let fetchedAt, _) = entry.state {
            // Refresh failed: the old value stays visible until the retention limit.
            entries[identifier]?.state = .resolved(place, fetchedAt: fetchedAt, stale: true)
        } else {
            entries[identifier]?.state = .failed(failure, attempts: entry.attempts, nextRetryAt: nextRetryAt)
        }
        if let nextRetryAt, entry.interest > 0 {
            waitThenRetry(identifier, until: nextRetryAt)
        }
    }

    private func waitThenRetry(_ identifier: String, until deadline: Date) {
        guard var entry = entries[identifier] else { return }
        entry.work?.cancel()
        let token = nextToken()
        entry.workToken = token
        entries[identifier] = entry
        let delay = max(0, deadline.timeIntervalSince(now()))
        entries[identifier]?.work = Task { [weak self] in
            guard let self else { return }
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let entry = entries[identifier], entry.workToken == token else { return }
            entries[identifier]?.work = nil
            entries[identifier]?.workToken = nil
            enqueue(identifier)
        }
    }

    /// Stops all network work for `identifier`: the request, the retry wait, the queue slot.
    /// The work token is dropped, so a late completion of that work is ignored.
    private func cancelWork(_ identifier: String) {
        guard var entry = entries[identifier] else { return }
        entry.work?.cancel()
        entry.work = nil
        entry.workToken = nil
        entry.queued = false
        pending.removeAll { $0 == identifier }
        let wasRunning = running.remove(identifier) != nil
        if case .loading = entry.state { entry.state = .idle }
        entries[identifier] = entry
        if wasRunning { pump() }
    }

    private func discardIfUnreferenced(_ identifier: String) {
        guard let entry = entries[identifier], entry.interest == 0, !documentReferences.contains(identifier) else { return }
        cancelWork(identifier)
        entries.removeValue(forKey: identifier)
    }

    private func enforceLimit() {
        guard entries.count > configuration.maxEntries else { return }
        let evictable = entries.filter { $0.value.interest == 0 }.sorted { $0.value.lastAccess < $1.value.lastAccess }
        var excess = entries.count - configuration.maxEntries
        for (identifier, _) in evictable where excess > 0 {
            cancelWork(identifier)
            entries.removeValue(forKey: identifier)
            excess -= 1
        }
    }

    /// One timer for the earliest freshness or retention deadline among resolved values.
    private func scheduleSweep() {
        sweepTask?.cancel()
        sweepTask = nil
        var deadline: Date?
        for entry in entries.values {
            guard case .resolved(_, let fetchedAt, let stale) = entry.state else { continue }
            let candidates = [fetchedAt.addingTimeInterval(configuration.maxRetention)]
                + (stale ? [] : [fetchedAt.addingTimeInterval(configuration.freshness)])
            for candidate in candidates where deadline == nil || candidate < deadline! {
                deadline = candidate
            }
        }
        guard let deadline else { return }
        let delay = max(0, deadline.timeIntervalSince(now()))
        sweepTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            sweep()
        }
    }
}

/// MapKit-backed lookup by Place ID. Cancelling the task cancels the request.
struct MapKitPlaceFetcher: PlaceFetching {
    func fetch(_ identifier: String) async throws -> ResolvedPlace {
        guard let placeID = MKMapItem.Identifier(rawValue: identifier) else { throw PlaceFetchFailure.notFound }
        let request = RequestBox(MKMapItemRequest(mapItemIdentifier: placeID))
        do {
            let item = try await withTaskCancellationHandler {
                try await request.request.mapItem
            } onCancel: {
                request.cancel()
            }
            return ResolvedPlace(item, requestedIdentifier: identifier)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Self.classify(error)
        }
    }

    /// Classifies by error code, following `NSUnderlyingErrorKey` so a MapKit wrapper around
    /// a URL or POSIX error is read by its cause:
    ///
    /// | Source | Codes | Failure |
    /// |---|---|---|
    /// | MKErrorDomain | loadingThrottled | throttled |
    /// | MKErrorDomain | placemarkNotFound, directionsNotFound (travel search) | notFound |
    /// | MKErrorDomain | serverFailure, decodingFailed, unknown (no cause) | server |
    /// | NSURLErrorDomain | notConnectedToInternet, networkConnectionLost, dataNotAllowed, internationalRoamingOff, callIsActive | offline |
    /// | NSURLErrorDomain | timedOut | timeout |
    /// | NSURLErrorDomain | TLS / certificate codes, DNS, cannotFindHost, cannotConnectToHost, other URL errors | transport |
    /// | NSPOSIXErrorDomain | ENETDOWN, ENETUNREACH, EHOSTUNREACH, EHOSTDOWN | offline |
    /// | NSPOSIXErrorDomain | ETIMEDOUT | timeout |
    /// | NSPOSIXErrorDomain | other | transport |
    /// | anything else | | server |
    static func classify(_ error: Error) -> PlaceFetchFailure {
        var current: NSError? = error as NSError
        var mapKitVerdict: PlaceFetchFailure?
        while let error = current {
            switch error.domain {
            case MKErrorDomain:
                switch MKError.Code(rawValue: UInt(error.code)) {
                case .loadingThrottled: return .throttled
                case .placemarkNotFound, .directionsNotFound: return .notFound
                default: mapKitVerdict = mapKitVerdict ?? .server
                }
            case NSURLErrorDomain:
                return classifyURLError(error.code)
            case NSPOSIXErrorDomain:
                return classifyPOSIXError(error.code)
            default:
                break
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return mapKitVerdict ?? .server
    }

    private static func classifyURLError(_ code: Int) -> PlaceFetchFailure {
        switch URLError.Code(rawValue: code) {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return .offline
        case .timedOut:
            return .timeout
        default:
            // TLS and certificate failures, DNS lookup failures, cannotFindHost,
            // cannotConnectToHost, bad server responses and every other URL error.
            return .transport
        }
    }

    private static func classifyPOSIXError(_ code: Int) -> PlaceFetchFailure {
        switch Int32(code) {
        case ENETDOWN, ENETUNREACH, EHOSTUNREACH, EHOSTDOWN: .offline
        case ETIMEDOUT: .timeout
        default: .transport
        }
    }

    /// Lets the cancellation handler (a nonisolated, Sendable context) reach the request.
    private nonisolated final class RequestBox: @unchecked Sendable {
        let request: MKMapItemRequest
        init(_ request: MKMapItemRequest) { self.request = request }
        func cancel() { request.cancel() }
    }
}

extension ResolvedPlace {
    /// From a MapKit item: the item's own ID when it has one, else the one requested.
    init(_ item: MKMapItem, requestedIdentifier: String? = nil) {
        let coordinate: CLLocationCoordinate2D
        let address: String?
        if #available(iOS 26.0, *) {
            coordinate = item.location.coordinate
            address = item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
                ?? item.address?.fullAddress
        } else {
            coordinate = item.placemark.coordinate
            address = item.placemark.title
        }
        self.init(
            identifier: item.identifier?.rawValue ?? requestedIdentifier ?? "",
            alternateIdentifiers: Set(item.alternateIdentifiers.map(\.rawValue)),
            name: item.name,
            address: address,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            mapItem: item
        )
    }
}
