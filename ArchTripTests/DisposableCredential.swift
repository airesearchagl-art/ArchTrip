import FirebaseAuth
import Foundation

/// A throwaway Email/Password credential generated at runtime for the G4-A Auth spike.
/// Values exist only in memory; every textual representation is redacted so that
/// string interpolation, `dump`, or test-failure output cannot leak them.
struct DisposableCredential: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let emailPrefix = "archtrip-g4a-"
    /// RFC 2606 reserved domain: no real mailbox can receive mail for it.
    static let emailDomain = "example.com"
    static let passwordLength = 32

    let email: String
    let password: String

    static func make() -> DisposableCredential {
        var generator = SystemRandomNumberGenerator()
        return DisposableCredential(
            email: "\(emailPrefix)\(randomString(length: 20, from: lowercase + digits, using: &generator))@\(emailDomain)",
            password: randomPassword(using: &generator)
        )
    }

    var description: String { "DisposableCredential(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    /// Replaces any occurrence of the credential values in `text`.
    func redact(_ text: String) -> String {
        text.replacingOccurrences(of: email, with: "<redacted-email>")
            .replacingOccurrences(of: password, with: "<redacted-password>")
    }

    private static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    private static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let digits = Array("0123456789")
    private static let symbols = Array("!#$%&*+-=?@^_~")

    private static func randomString(length: Int, from alphabet: [Character], using generator: inout SystemRandomNumberGenerator) -> String {
        String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// At least one character from each class so any project password policy is met.
    private static func randomPassword(using generator: inout SystemRandomNumberGenerator) -> String {
        let all = lowercase + uppercase + digits + symbols
        var characters: [Character] = [
            lowercase.randomElement(using: &generator)!,
            uppercase.randomElement(using: &generator)!,
            digits.randomElement(using: &generator)!,
            symbols.randomElement(using: &generator)!,
        ]
        characters += (0..<(passwordLength - characters.count)).map { _ in all.randomElement(using: &generator)! }
        characters.shuffle(using: &generator)
        return String(characters)
    }
}

enum AuthSpikeDiagnostics {
    /// Domain, code, code name and message only. `userInfo` is never included because
    /// Firebase can place the email there (`AuthErrors.userInfoEmailKey`).
    static func describe(_ error: Error, redacting credential: DisposableCredential?) -> String {
        let nsError = error as NSError
        let name = nsError.domain == AuthErrors.domain ? authCodeNames[nsError.code] ?? "other" : "-"
        let text = "domain=\(nsError.domain) code=\(nsError.code) name=\(name) message=\(nsError.localizedDescription)"
        return credential?.redact(text) ?? text
    }

    /// `AuthErrorCode` is an @objc enum, so case names are not available by reflection.
    private static let authCodeNames: [Int: String] = [
        AuthErrorCode.invalidCredential.rawValue: "invalidCredential",
        AuthErrorCode.operationNotAllowed.rawValue: "operationNotAllowed",
        AuthErrorCode.emailAlreadyInUse.rawValue: "emailAlreadyInUse",
        AuthErrorCode.invalidEmail.rawValue: "invalidEmail",
        AuthErrorCode.wrongPassword.rawValue: "wrongPassword",
        AuthErrorCode.tooManyRequests.rawValue: "tooManyRequests",
        AuthErrorCode.userNotFound.rawValue: "userNotFound",
        AuthErrorCode.requiresRecentLogin.rawValue: "requiresRecentLogin",
        AuthErrorCode.providerAlreadyLinked.rawValue: "providerAlreadyLinked",
        AuthErrorCode.networkError.rawValue: "networkError",
        AuthErrorCode.credentialAlreadyInUse.rawValue: "credentialAlreadyInUse",
        AuthErrorCode.weakPassword.rawValue: "weakPassword",
        AuthErrorCode.adminRestrictedOperation.rawValue: "adminRestrictedOperation",
        AuthErrorCode.passwordDoesNotMeetRequirements.rawValue: "passwordDoesNotMeetRequirements",
    ]

    static func isProviderDisabled(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == AuthErrors.domain && nsError.code == AuthErrorCode.operationNotAllowed.rawValue
    }

    /// Evidence lines go to stderr, which xcodebuild shows in its console output.
    /// Callers must never pass credential values or full UIDs.
    static func evidence(_ line: String) {
        FileHandle.standardError.write(Data("G4A-EVIDENCE \(line)\n".utf8))
    }
}
