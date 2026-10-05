import Foundation

/// What the app needs to know about the signed-in Firebase user.
/// Descriptions are redacted so the UID or email never ends up in logs by accident.
nonisolated struct AuthUserSnapshot: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    static let passwordProviderID = "password"

    let uid: String
    let isAnonymous: Bool
    let providerIDs: [String]
    let email: String?

    var hasPasswordProvider: Bool { providerIDs.contains(Self.passwordProviderID) }

    var description: String { "AuthUserSnapshot(isAnonymous: \(isAnonymous), <redacted>)" }
    var customMirror: Mirror { Mirror(self, children: ["isAnonymous": isAnonymous], displayStyle: .struct) }
}

nonisolated enum AccountKind: Equatable, Sendable {
    /// The original per-device anonymous identity (G1–G3).
    case anonymous
    /// Email/Password account usable on several devices (G4+).
    case permanent
}

/// Where the app goes for a given Auth state. A missing user never leads to an
/// automatic anonymous sign-in: it routes to the Email/Password sign-in screen.
nonisolated enum AuthRoute: Equatable, Sendable {
    case signIn
    case app(AccountKind)

    static func route(for user: AuthUserSnapshot?) -> AuthRoute {
        guard let user else { return .signIn }
        return .app(user.isAnonymous ? .anonymous : .permanent)
    }
}

nonisolated enum AccountDisplay {
    /// "s•••@example.com": enough to recognise the account without showing it in full.
    static func maskedEmail(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@"), at != email.startIndex else { return "•••" }
        return "\(email[email.startIndex])•••\(email[at...])"
    }
}
