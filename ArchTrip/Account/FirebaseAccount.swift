import FirebaseAuth
import Foundation

extension AuthUserSnapshot {
    init(_ user: User) {
        self.init(
            uid: user.uid,
            isAnonymous: user.isAnonymous,
            providerIDs: user.providerData.map(\.providerID),
            email: user.email
        )
    }
}

extension MigrationSteps {
    /// Real Firebase operations for `auth` and its Firestore `store`.
    /// The app uses the default instances; disposable live tests pass a secondary app.
    static func firebase(auth: Auth, store: TripStore, uid: String) -> MigrationSteps {
        MigrationSteps(
            currentUser: { auth.currentUser.map(AuthUserSnapshot.init) },
            waitForPendingWrites: { try await store.waitForPendingWrites(timeout: .seconds(15)) },
            readServerSnapshot: { try await store.serverSnapshot(uid: uid) },
            link: { input in
                guard let user = auth.currentUser else { throw AccountError.noCurrentUser }
                let credential = EmailAuthProvider.credential(withEmail: input.email, password: input.password)
                return AuthUserSnapshot(try await user.link(with: credential).user)
            },
            reloadedUser: {
                try await auth.currentUser?.reload()
                return auth.currentUser.map(AuthUserSnapshot.init)
            }
        )
    }
}

enum AccountError: Error {
    case noCurrentUser
    case timedOut
}

nonisolated enum SignInFailure: Equatable, Sendable {
    case wrongCredentials
    case network
    case tooManyRequests
    case disabled
    case other(code: Int)

    /// `userInfo` is never read, because Firebase may put the email there.
    init(error: Error) {
        let error = error as NSError
        switch (error.domain, error.code) {
        case ("FIRAuthErrorDomain", 17004), ("FIRAuthErrorDomain", 17009), ("FIRAuthErrorDomain", 17011),
             ("FIRAuthErrorDomain", 17008):
            self = .wrongCredentials
        case ("FIRAuthErrorDomain", 17020): self = .network
        case ("FIRAuthErrorDomain", 17010): self = .tooManyRequests
        case ("FIRAuthErrorDomain", 17005), ("FIRAuthErrorDomain", 17006): self = .disabled
        default: self = .other(code: error.code)
        }
    }
}
