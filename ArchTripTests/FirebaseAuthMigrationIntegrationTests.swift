import FirebaseAuth
import FirebaseCore
import Foundation
import Testing
@testable import ArchTrip

/// G4-A disposable Auth migration spike:
/// anonymous → link Email/Password → same UID → sign out → password sign-in → same UID → delete.
///
/// Runs entirely on a uniquely named secondary FirebaseApp, so the default app's real
/// Auth session is never used, linked, signed out or deleted. Credentials are generated
/// at runtime and never printed; UIDs are compared in memory only.
///
/// Opt-in: `TEST_RUNNER_ARCHTRIP_FIREBASE_INTEGRATION=1 xcodebuild test ...`
@MainActor
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ARCHTRIP_FIREBASE_INTEGRATION"] == "1"),
    .timeLimit(.minutes(1))
)
struct FirebaseAuthMigrationIntegrationTests {
    private enum SpikeStop: Error {
        case providerDisabled
        case linkFailed
        case uidChanged
    }

    /// Waits briefly for the app's own automatic sign-in so the default UID is stable.
    private func settledDefaultUID() async -> String? {
        for _ in 0..<30 {
            if let uid = Auth.auth().currentUser?.uid { return uid }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return Auth.auth().currentUser?.uid
    }

    @Test func anonymousLinkKeepsUIDAcrossPasswordSignIn() async throws {
        let defaultApp = try #require(FirebaseApp.app())
        let defaultUIDBefore = await settledDefaultUID()

        let spikeApp = "g4aAuthSpike\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        FirebaseApp.configure(name: spikeApp, options: defaultApp.options)
        let app = try #require(FirebaseApp.app(name: spikeApp))
        let auth = Auth.auth(app: app)
        let isolated = auth !== Auth.auth() && app.name != defaultApp.name
        #expect(isolated)
        try? auth.signOut()
        #expect(auth.currentUser == nil)
        AuthSpikeDiagnostics.evidence("secondary app configured isolated=\(isolated)")

        let credential = DisposableCredential.make()
        var uidBefore: String?
        var stepError: Error?

        do {
            // A. Anonymous sign-in on the secondary Auth.
            let anonymous = try await auth.signInAnonymously()
            uidBefore = anonymous.user.uid
            #expect(anonymous.user.isAnonymous)
            AuthSpikeDiagnostics.evidence("anonymous created isAnonymous=\(anonymous.user.isAnonymous)")

            // B + C. Link a runtime Email/Password credential.
            let emailCredential = EmailAuthProvider.credential(withEmail: credential.email, password: credential.password)
            let linked: AuthDataResult
            do {
                linked = try await anonymous.user.link(with: emailCredential)
            } catch {
                let detail = AuthSpikeDiagnostics.describe(error, redacting: credential)
                AuthSpikeDiagnostics.evidence("link FAILED \(detail)")
                Issue.record("link(with:) failed: \(detail)")
                throw AuthSpikeDiagnostics.isProviderDisabled(error) ? SpikeStop.providerDisabled : SpikeStop.linkFailed
            }
            let linkPreserved = linked.user.uid == uidBefore
            AuthSpikeDiagnostics.evidence("link uid-preserved=\(linkPreserved) isAnonymous=\(linked.user.isAnonymous)")
            #expect(linkPreserved)
            #expect(!linked.user.isAnonymous)
            guard linkPreserved else { throw SpikeStop.uidChanged }

            // D. Sign out the secondary Auth only.
            try auth.signOut()
            let signedOut = auth.currentUser == nil
            #expect(signedOut)
            AuthSpikeDiagnostics.evidence("sign-out secondary=\(signedOut)")

            // E. Email/Password sign-in returns the same UID.
            let passwordSignIn = try await auth.signIn(withEmail: credential.email, password: credential.password)
            let signInPreserved = passwordSignIn.user.uid == uidBefore
            AuthSpikeDiagnostics.evidence("password sign-in uid-preserved=\(signInPreserved)")
            #expect(signInPreserved)
        } catch {
            stepError = error
            if !(error is SpikeStop) {
                let detail = AuthSpikeDiagnostics.describe(error, redacting: credential)
                AuthSpikeDiagnostics.evidence("step FAILED \(detail)")
                Issue.record("spike step failed: \(detail)")
            }
        }

        // F. Cleanup: delete the disposable user (anonymous or linked), sign out, drop the app.
        var cleaned = false
        if let uidBefore {
            if auth.currentUser == nil {
                _ = try? await auth.signIn(withEmail: credential.email, password: credential.password)
            }
            if let user = auth.currentUser, user.uid == uidBefore {
                do {
                    try await user.delete()
                    cleaned = true
                } catch {
                    Issue.record("cleanup delete failed: \(AuthSpikeDiagnostics.describe(error, redacting: credential))")
                }
            } else {
                Issue.record("cleanup could not reach the disposable user")
            }
        }
        try? auth.signOut()
        _ = await app.delete()
        AuthSpikeDiagnostics.evidence("disposable cleanup=\(cleaned)")
        #expect(cleaned)

        // The default app's user must be exactly as before.
        let defaultUIDAfter = Auth.auth().currentUser?.uid
        let defaultUnchanged = defaultUIDAfter == defaultUIDBefore
        AuthSpikeDiagnostics.evidence("default user present=\(defaultUIDBefore != nil) unchanged=\(defaultUnchanged)")
        #expect(defaultUnchanged)

        if let stepError { throw stepError }
    }
}
