import Foundation
import Testing
@testable import ArchTrip

/// Fake Firebase steps that record every call. `MigrationSteps` has no unlink,
/// delete or sign-out operation at all, so no outcome can trigger a rollback.
@MainActor
private final class FakeSteps {
    var user: AuthUserSnapshot?
    var snapshots: [MigrationSnapshot]
    var pendingWritesError: Error?
    var linkError: Error?
    var linkedUser: AuthUserSnapshot?
    var reloaded: AuthUserSnapshot?
    var calls: [String] = []

    init(user: AuthUserSnapshot?, snapshots: [MigrationSnapshot]) {
        self.user = user
        self.snapshots = snapshots
    }

    var steps: MigrationSteps {
        MigrationSteps(
            currentUser: { self.calls.append("currentUser"); return self.user },
            waitForPendingWrites: {
                self.calls.append("waitForPendingWrites")
                if let error = self.pendingWritesError { throw error }
            },
            readServerSnapshot: {
                self.calls.append("readServerSnapshot")
                guard !self.snapshots.isEmpty else { throw URLError(.notConnectedToInternet) }
                return self.snapshots.removeFirst()
            },
            link: { _ in
                self.calls.append("link")
                if let error = self.linkError { throw error }
                return self.linkedUser!
            },
            reloadedUser: { self.calls.append("reloadedUser"); return self.reloaded }
        )
    }
}

@MainActor
struct AccountMigrationTests {
    private let uid = "uid-1"
    private var anonymous: AuthUserSnapshot { AuthUserSnapshot(uid: uid, isAnonymous: true, providerIDs: [], email: nil) }
    private var linked: AuthUserSnapshot { AuthUserSnapshot(uid: uid, isAnonymous: false, providerIDs: ["password"], email: "x@example.com") }
    /// Fake steps never use the values; they are generated so no literal exists.
    private let input = EmailPasswordInput(email: "x@example.com", password: UUID().uuidString)

    private let data = MigrationSnapshot(
        tripIDs: ["t1", "t2"],
        eventIDsByTrip: ["t1": ["e1", "e2"], "t2": []],
        buildingIDs: ["b1"]
    )

    private func fake(snapshots: [MigrationSnapshot]? = nil) -> FakeSteps {
        let fake = FakeSteps(user: anonymous, snapshots: snapshots ?? [data, data])
        fake.linkedUser = linked
        fake.reloaded = linked
        return fake
    }

    // MARK: Snapshot comparison

    @Test func snapshotCountsAndComparison() {
        #expect(data.tripCount == 2 && data.eventCount == 2 && data.buildingCount == 1)
        var report = MigrationReport()
        report.compare(before: data, after: data)
        #expect(report.tripsRetained && report.eventsRetained && report.buildingsRetained)

        var missingEvent = data
        missingEvent.eventIDsByTrip["t1"] = ["e1"]
        report.compare(before: data, after: missingEvent)
        #expect(report.tripsRetained && !report.eventsRetained && report.buildingsRetained)

        var swappedBuilding = data
        swappedBuilding.buildingIDs = ["b2"]
        report.compare(before: data, after: swappedBuilding)
        #expect(!report.buildingsRetained)

        report.compare(before: data, after: nil)
        #expect(!report.tripsRetained && !report.eventsRetained && !report.buildingsRetained)
    }

    @Test func snapshotDescriptionShowsCountsOnly() {
        let text = "\(data) \(String(reflecting: data))"
        let leaks = ["t1", "t2", "e1", "e2", "b1"].contains { text.contains("\"\($0)\"") || text.contains("\($0),") }
        #expect(!leaks)
        #expect(data.description == "MigrationSnapshot(trips: 2, events: 2, buildings: 1)")
    }

    // MARK: Happy path

    @Test func successfulMigration() async {
        let fake = fake()
        let result = await AccountMigrator.run(input: input, expectedUID: uid, steps: fake.steps)
        guard case .completed(let report) = result else {
            Issue.record("expected completed, got \(result)")
            return
        }
        #expect(report.allPassed)
        #expect(fake.calls.filter { $0 == "link" }.count == 1)
    }

    // MARK: Pre-link guards (nothing changes)

    @Test func noUserIsRefusedBeforeLink() async {
        let fake = fake()
        fake.user = nil
        #expect(await AccountMigrator.run(input: input, expectedUID: uid, steps: fake.steps) == .refused(.noUser))
        #expect(!fake.calls.contains("link"))
    }

    @Test func differentUserIsRefusedBeforeLink() async {
        let fake = fake()
        fake.user = AuthUserSnapshot(uid: "someone-else", isAnonymous: true, providerIDs: [], email: nil)
        #expect(await AccountMigrator.run(input: input, expectedUID: uid, steps: fake.steps) == .refused(.userChanged))
        #expect(!fake.calls.contains("link"))
    }

    @Test func permanentUserIsRefused() async {
        let fake = fake()
        fake.user = linked
        #expect(await AccountMigrator.run(input: input, expectedUID: uid, steps: fake.steps) == .refused(.notAnonymous))
        #expect(!fake.calls.contains("link"))
    }

    @Test func pendingWritesBlockLink() async {
        let fake = fake()
        fake.pendingWritesError = AccountError.timedOut
        #expect(await AccountMigrator.run(input: input, expectedUID: uid, steps: fake.steps) == .refused(.pendingWrites))
        #expect(!fake.calls.contains("link"))
    }

    /// RF-G4B1-01: a pending-writes wait that never completes is cut off at the
    /// deadline; the migration is refused and link is never attempted.
    @Test func neverAcknowledgedPendingWritesRefuseWithinBound() async {
        let fake = fake()
        var steps = fake.steps
        steps.waitForPendingWrites = {
            fake.calls.append("waitForPendingWrites")
            try await BoundedWait.run(timeout: .milliseconds(200)) { _ in /* never acknowledged */ }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let result = await AccountMigrator.run(input: input, expectedUID: uid, steps: steps)
        let bounded = clock.now - start < .seconds(2)
        #expect(result == .refused(.pendingWrites))
        #expect(bounded)
        #expect(!fake.calls.contains("link"))
        #expect(!fake.calls.contains("readServerSnapshot"))
    }

    @Test func serverUnavailableBlocksLink() async {
        let fake = fake(snapshots: [])
        #expect(await AccountMigrator.run(input: input, expectedUID: uid, steps: fake.steps) == .refused(.serverUnavailable))
        #expect(!fake.calls.contains("link"))
    }

    @Test func preflightReportsCountsWithoutChanging() async {
        let fake = fake()
        #expect(await AccountMigrator.preflight(expectedUID: uid, steps: fake.steps) == .ready(data))
        #expect(!fake.calls.contains("link"))
    }

    // MARK: Link failures (nothing changes)

    @Test func linkErrorsAreMapped() async {
        let cases: [(Int, LinkFailure)] = [
            (17007, .emailAlreadyInUse), (17025, .credentialAlreadyInUse), (17026, .weakPassword),
            (17211, .weakPassword), (17020, .network), (17006, .operationNotAllowed), (17008, .invalidEmail),
        ]
        for (code, expected) in cases {
            let fake = fake()
            fake.linkError = NSError(domain: "FIRAuthErrorDomain", code: code)
            #expect(await AccountMigrator.run(input: input, expectedUID: uid, steps: fake.steps) == .linkFailed(expected))
            #expect(!fake.calls.contains("reloadedUser"))
        }
    }

    // MARK: Post-link: BLOCKED, never rolled back

    @Test func uidChangeAfterLinkIsHardFailure() async {
        let fake = fake()
        fake.linkedUser = AuthUserSnapshot(uid: "new-uid", isAnonymous: false, providerIDs: ["password"], email: nil)
        let result = await AccountMigrator.run(input: input, expectedUID: uid, steps: fake.steps)
        guard case .blocked(let report) = result else {
            Issue.record("expected blocked, got \(result)")
            return
        }
        #expect(!report.uidPreserved)
        // Stops immediately: no further verification is attempted after a UID change.
        #expect(fake.calls.last == "link")
    }

    @Test func dataMismatchAfterLinkIsBlockedNotRolledBack() async {
        var after = data
        after.tripIDs.remove("t2")
        let fake = fake(snapshots: [data, after])
        let result = await AccountMigrator.run(input: input, expectedUID: uid, steps: fake.steps)
        guard case .blocked(let report) = result else {
            Issue.record("expected blocked, got \(result)")
            return
        }
        #expect(report.uidPreserved && report.passwordProviderLinked)
        #expect(!report.tripsRetained)
        #expect(fake.calls.filter { $0 == "link" }.count == 1)
    }

    @Test func unreadableServerAfterLinkIsBlocked() async {
        let fake = fake(snapshots: [data])
        let result = await AccountMigrator.run(input: input, expectedUID: uid, steps: fake.steps)
        guard case .blocked(let report) = result else {
            Issue.record("expected blocked, got \(result)")
            return
        }
        #expect(report.uidPreserved)
        #expect(!report.tripsRetained && !report.eventsRetained && !report.buildingsRetained)
    }

    @Test func stillAnonymousOrMissingProviderIsBlocked() async {
        let fake = fake()
        fake.reloaded = AuthUserSnapshot(uid: uid, isAnonymous: true, providerIDs: [], email: nil)
        let result = await AccountMigrator.run(input: input, expectedUID: uid, steps: fake.steps)
        guard case .blocked(let report) = result else {
            Issue.record("expected blocked, got \(result)")
            return
        }
        #expect(!report.noLongerAnonymous && !report.passwordProviderLinked)
    }

    @Test func evidenceContainsBooleansOnly() {
        var report = MigrationReport()
        report.uidPreserved = true
        report.currentUserMatches = true
        report.compare(before: data, after: data)
        let text = report.evidence
        #expect(text.hasPrefix("uid-preserved=true"))
        let leaks = text.contains(uid) || ["t1", "e1", "b1"].contains(where: text.contains)
        #expect(!leaks)
    }
}

struct EmailPasswordInputTests {
    /// Lengths matter here, not values: no password-like literals in tests.
    private let eight = String(repeating: "a", count: EmailPasswordInput.minimumPasswordLength)
    private let seven = String(repeating: "a", count: EmailPasswordInput.minimumPasswordLength - 1)

    @Test func migrationValidation() {
        #expect(EmailPasswordInput(email: " user@example.com ", password: eight).issues(confirmation: eight).isEmpty)
        #expect(EmailPasswordInput(email: "not-an-email", password: eight).issues(confirmation: eight) == [.invalidEmail])
        #expect(EmailPasswordInput(email: "user@example", password: eight).issues(confirmation: eight) == [.invalidEmail])
        #expect(EmailPasswordInput(email: "user@example.com", password: seven).issues(confirmation: seven) == [.passwordTooShort])
        #expect(EmailPasswordInput(email: "user@example.com", password: eight).issues(confirmation: eight + "b") == [.passwordMismatch])
    }

    @Test func signInValidation() {
        #expect(EmailPasswordInput(email: "user@example.com", password: seven).issues(confirmation: nil).isEmpty)
        #expect(EmailPasswordInput(email: "user@example.com", password: "").issues(confirmation: nil) == [.passwordTooShort])
    }

    @Test func emailIsTrimmedButPasswordIsNot() {
        let password = " \(UUID().uuidString) "
        let input = EmailPasswordInput(email: "  user@example.com\n", password: password)
        let emailOK = input.email == "user@example.com"
        let passwordOK = input.password == password
        #expect(emailOK && passwordOK)
    }

    @Test func textualRepresentationsAreRedacted() {
        let email = "owner-\(UUID().uuidString.prefix(8))@example.com"
        let password = UUID().uuidString
        let input = EmailPasswordInput(email: email, password: password)
        var dumped = ""
        dump(input, to: &dumped)
        for text in ["\(input)", String(reflecting: input), dumped] {
            let leaks = text.contains(email) || text.contains(password)
            #expect(!leaks)
        }
    }
}
