import Foundation

// MARK: - Credential input

/// Email/Password typed by the user. Never persisted or logged; every textual
/// representation is redacted.
nonisolated struct EmailPasswordInput: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let minimumPasswordLength = 8

    enum Issue: Hashable, Sendable {
        case invalidEmail
        case passwordTooShort
        case passwordMismatch
    }

    let email: String
    let password: String

    init(email: String, password: String) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
    }

    /// Issues for the migration form (with confirmation) or sign-in form (`confirmation == nil`).
    func issues(confirmation: String?) -> [Issue] {
        var issues: [Issue] = []
        if !Self.looksLikeEmail(email) { issues.append(.invalidEmail) }
        if let confirmation {
            if password.count < Self.minimumPasswordLength { issues.append(.passwordTooShort) }
            if password != confirmation { issues.append(.passwordMismatch) }
        } else if password.isEmpty {
            issues.append(.passwordTooShort)
        }
        return issues
    }

    private static func looksLikeEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !email.contains(" ") else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    var description: String { "EmailPasswordInput(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

// MARK: - Snapshot / report

/// Document IDs owned by the user, read from the server. Held in memory only;
/// only counts are ever shown.
nonisolated struct MigrationSnapshot: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    var tripIDs: Set<String>
    var eventIDsByTrip: [String: Set<String>]
    var buildingIDs: Set<String>

    var tripCount: Int { tripIDs.count }
    var eventCount: Int { eventIDsByTrip.values.reduce(0) { $0 + $1.count } }
    var buildingCount: Int { buildingIDs.count }

    var description: String { "MigrationSnapshot(trips: \(tripCount), events: \(eventCount), buildings: \(buildingCount))" }
    var customMirror: Mirror {
        Mirror(self, children: ["trips": tripCount, "events": eventCount, "buildings": buildingCount], displayStyle: .struct)
    }
}

nonisolated struct MigrationReport: Equatable, Sendable {
    var uidPreserved = false
    var currentUserMatches = false
    var noLongerAnonymous = false
    var passwordProviderLinked = false
    var tripsRetained = false
    var eventsRetained = false
    var buildingsRetained = false

    var allPassed: Bool {
        uidPreserved && currentUserMatches && noLongerAnonymous && passwordProviderLinked
            && tripsRetained && eventsRetained && buildingsRetained
    }

    /// Safe evidence: booleans only.
    var evidence: String {
        "uid-preserved=\(uidPreserved && currentUserMatches) provider-linked=\(passwordProviderLinked) "
            + "anonymous=\(!noLongerAnonymous) trip-ids-preserved=\(tripsRetained) "
            + "event-ids-preserved=\(eventsRetained) building-ids-preserved=\(buildingsRetained)"
    }

    mutating func compare(before: MigrationSnapshot, after: MigrationSnapshot?) {
        tripsRetained = after?.tripIDs == before.tripIDs
        eventsRetained = after?.eventIDsByTrip == before.eventIDsByTrip
        buildingsRetained = after?.buildingIDs == before.buildingIDs
    }
}

// MARK: - Outcomes

nonisolated enum PreflightFailure: Equatable, Sendable {
    case noUser
    case notAnonymous
    case userChanged
    case pendingWrites
    case serverUnavailable
}

nonisolated enum LinkFailure: Equatable, Sendable {
    case emailAlreadyInUse
    case credentialAlreadyInUse
    case weakPassword
    case invalidEmail
    case network
    case operationNotAllowed
    case requiresRecentLogin
    case tooManyRequests
    case other(code: Int)

    /// Maps Firebase Auth error codes (FIRAuthErrorDomain). `userInfo` is never read,
    /// because Firebase may put the email there.
    init(error: Error) {
        let error = error as NSError
        switch (error.domain, error.code) {
        case ("FIRAuthErrorDomain", 17007): self = .emailAlreadyInUse
        case ("FIRAuthErrorDomain", 17025), ("FIRAuthErrorDomain", 17015): self = .credentialAlreadyInUse
        case ("FIRAuthErrorDomain", 17026), ("FIRAuthErrorDomain", 17211): self = .weakPassword
        case ("FIRAuthErrorDomain", 17008): self = .invalidEmail
        case ("FIRAuthErrorDomain", 17020): self = .network
        case ("FIRAuthErrorDomain", 17006): self = .operationNotAllowed
        case ("FIRAuthErrorDomain", 17014): self = .requiresRecentLogin
        case ("FIRAuthErrorDomain", 17010): self = .tooManyRequests
        default: self = .other(code: error.code)
        }
    }
}

nonisolated enum MigrationResult: Equatable, Sendable {
    /// A pre-link guard failed. Nothing was changed.
    case refused(PreflightFailure)
    /// Firebase rejected the link. Nothing was changed.
    case linkFailed(LinkFailure)
    /// Linked and every post-link check passed.
    case completed(MigrationReport)
    /// Linked, but a post-link check failed. Deliberately left as is for human
    /// review: no unlink, delete, sign-out or data copy is attempted.
    case blocked(MigrationReport)
}

nonisolated enum PreflightResult: Equatable, Sendable {
    case ready(MigrationSnapshot)
    case failed(PreflightFailure)
}

// MARK: - Orchestration

/// The Firebase operations migration needs. There is intentionally no unlink,
/// delete or sign-out capability here, so no code path can roll back automatically.
struct MigrationSteps {
    var currentUser: () -> AuthUserSnapshot?
    var waitForPendingWrites: () async throws -> Void
    var readServerSnapshot: () async throws -> MigrationSnapshot
    var link: (EmailPasswordInput) async throws -> AuthUserSnapshot
    var reloadedUser: () async throws -> AuthUserSnapshot?
}

enum AccountMigrator {
    /// Checks that the expected anonymous user is signed in, local writes are
    /// acknowledged and the server is readable. Nothing is changed.
    static func preflight(expectedUID: String, steps: MigrationSteps) async -> PreflightResult {
        if let failure = guardUser(expectedUID: expectedUID, steps: steps) { return .failed(failure) }
        do {
            try await steps.waitForPendingWrites()
        } catch {
            return .failed(.pendingWrites)
        }
        do {
            return .ready(try await steps.readServerSnapshot())
        } catch {
            return .failed(.serverUnavailable)
        }
    }

    /// Links the Email/Password credential to the current anonymous user, then
    /// verifies UID, provider and server data against a snapshot taken just before.
    static func run(input: EmailPasswordInput, expectedUID: String, steps: MigrationSteps) async -> MigrationResult {
        let before: MigrationSnapshot
        switch await preflight(expectedUID: expectedUID, steps: steps) {
        case .failed(let failure): return .refused(failure)
        case .ready(let snapshot): before = snapshot
        }
        // Re-check right before linking in case the session changed during the reads.
        if let failure = guardUser(expectedUID: expectedUID, steps: steps) { return .refused(failure) }

        let linked: AuthUserSnapshot
        do {
            linked = try await steps.link(input)
        } catch {
            return .linkFailed(LinkFailure(error: error))
        }

        // From here the credential is linked. Failures become `.blocked`, never a rollback.
        var report = MigrationReport()
        report.uidPreserved = linked.uid == expectedUID
        guard report.uidPreserved else { return .blocked(report) }

        let current = try? await steps.reloadedUser()
        report.currentUserMatches = current?.uid == expectedUID
        report.noLongerAnonymous = current?.isAnonymous == false
        report.passwordProviderLinked = current?.hasPasswordProvider == true
        report.compare(before: before, after: try? await steps.readServerSnapshot())
        return report.allPassed ? .completed(report) : .blocked(report)
    }

    private static func guardUser(expectedUID: String, steps: MigrationSteps) -> PreflightFailure? {
        guard let user = steps.currentUser() else { return .noUser }
        guard user.uid == expectedUID else { return .userChanged }
        guard user.isAnonymous else { return .notAnonymous }
        return nil
    }
}
