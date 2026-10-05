import FirebaseAuth
import Foundation

/// Live integration tests need a default-app user. Since G4 the app no longer signs in
/// anonymously by itself, so tests do it explicitly (test simulators only), once,
/// even when several live suites start in parallel.
@MainActor
enum LiveTestAuth {
    private static var pendingSignIn: Task<String, Error>?

    static func defaultUID() async throws -> String {
        if let uid = Auth.auth().currentUser?.uid { return uid }
        if let pendingSignIn { return try await pendingSignIn.value }
        let task = Task { try await Auth.auth().signInAnonymously().user.uid }
        pendingSignIn = task
        return try await task.value
    }
}
