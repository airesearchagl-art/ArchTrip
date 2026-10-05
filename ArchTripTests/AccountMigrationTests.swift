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
    private let input = EmailPasswordInput(email: "x@example.com", password: "irrelevant-in-fakes")

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
    @Test func migrationValidation() {
        #expect(EmailPasswordInput(email: " a@b.co ", password: "longenough").issues(confirmation: "longenough").isEmpty)
        #expect(EmailPasswordInput(email: "not-an-email", password: "longenough").issues(confirmation: "longenough") == [.invalidEmail])
        #expect(EmailPasswordInput(email: "a@b", password: "longenough").issues(confirmation: "longenough") == [.invalidEmail])
        #expect(EmailPasswordInput(email: "a@b.co", password: "short").issues(confirmation: "short") == [.passwordTooShort])
        #expect(EmailPasswordInput(email: "a@b.co", password: "longenough").issues(confirmation: "different!") == [.passwordMismatch])
    }

    @Test func signInValidation() {
        #expect(EmailPasswordInput(email: "a@b.co", password: "x").issues(confirmation: nil).isEmpty)
        #expect(EmailPasswordInput(email: "a@b.co", password: "").issues(confirmation: nil) == [.passwordTooShort])
    }

    @Test func emailIsTrimmedButPasswordIsNot() {
        let input = EmailPasswordInput(email: "  a@b.co\n", password: " pass word ")
        let emailOK = input.email == "a@b.co"
        let passwordOK = input.password == " pass word "
        #expect(emailOK && passwordOK)
    }

    @Test func textualRepresentationsAreRedacted() {
        let input = EmailPasswordInput(email: "owner@example.com", password: "S3cret-Value!")
        var dumped = ""
        dump(input, to: &dumped)
        for text in ["\(input)", String(reflecting: input), dumped] {
            let leaks = text.contains("owner@example.com") || text.contains("S3cret-Value!")
            #expect(!leaks)
        }
    }
}
