import Foundation
import Testing
@testable import ArchTrip

@MainActor
struct AccountStateTests {
    private let anonymous = AuthUserSnapshot(uid: "uid-anon", isAnonymous: true, providerIDs: [], email: nil)
    private let permanent = AuthUserSnapshot(uid: "uid-anon", isAnonymous: false, providerIDs: ["password"], email: "owner@example.com")

    @Test func routing() {
        #expect(AuthRoute.route(for: nil) == .signIn)
        #expect(AuthRoute.route(for: anonymous) == .app(.anonymous))
        #expect(AuthRoute.route(for: permanent) == .app(.permanent))
        #expect(permanent.hasPasswordProvider)
        #expect(!anonymous.hasPasswordProvider)
    }

    /// No user must lead to the sign-in screen, never to a new anonymous account.
    @Test func noUserRoutesToSignInWithoutCreatingAccount() {
        let session = AppSession()
        session.apply(authUser: nil)
        #expect(session.state == .signedOut)
        #expect(session.uid == nil)
        #expect(session.accountKind == nil)
        #expect(session.migrationSteps() == nil)
    }

    @Test func anonymousUserRoutesToAppWithMigrationOption() {
        let session = AppSession()
        session.apply(authUser: anonymous)
        #expect(session.state == .ready(uid: "uid-anon"))
        #expect(session.accountKind == .anonymous)
        #expect(session.maskedEmail == nil)
    }

    @Test func permanentUserRoutesToNormalApp() {
        let session = AppSession()
        session.apply(authUser: permanent)
        #expect(session.state == .ready(uid: "uid-anon"))
        #expect(session.accountKind == .permanent)
        #expect(session.maskedEmail == "o•••@example.com")
    }

    @Test func linkingKeepsSessionAndUpdatesKind() {
        let session = AppSession()
        session.apply(authUser: anonymous)
        session.apply(authUser: permanent)
        #expect(session.state == .ready(uid: "uid-anon"))
        #expect(session.accountKind == .permanent)
    }

    @Test func signingOutClearsAccount() {
        let session = AppSession()
        session.apply(authUser: permanent)
        session.apply(authUser: nil)
        #expect(session.state == .signedOut)
        #expect(session.accountKind == nil)
        #expect(session.maskedEmail == nil)
    }

    @Test func maskedEmail() {
        #expect(AccountDisplay.maskedEmail("someone@example.com") == "s•••@example.com")
        #expect(AccountDisplay.maskedEmail("@example.com") == "•••")
        #expect(AccountDisplay.maskedEmail("no-at-sign") == "•••")
    }

    @Test func snapshotDescriptionIsRedacted() {
        var dumped = ""
        dump(permanent, to: &dumped)
        for text in ["\(permanent)", String(reflecting: permanent), dumped] {
            let leaks = text.contains("uid-anon") || text.contains("owner@example.com")
            #expect(!leaks)
        }
    }
}
