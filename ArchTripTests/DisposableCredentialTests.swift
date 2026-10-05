import FirebaseAuth
import Foundation
import Testing
@testable import ArchTrip

/// Assertions compare into Bools first so a failure never prints credential values.
struct DisposableCredentialTests {
    @Test func emailFormat() {
        let credential = DisposableCredential.make()
        let email = credential.email
        let prefixOK = email.hasPrefix(DisposableCredential.emailPrefix)
        let domainOK = email.hasSuffix("@\(DisposableCredential.emailDomain)")
        let local = email.dropFirst(DisposableCredential.emailPrefix.count).prefix { $0 != "@" }
        let tokenOK = local.count == 20 && local.allSatisfy { $0.isLowercase || $0.isNumber }
        #expect(prefixOK)
        #expect(domainOK)
        #expect(tokenOK)
    }

    @Test func passwordStrength() {
        let password = DisposableCredential.make().password
        let lengthOK = password.count == DisposableCredential.passwordLength
        let hasLower = password.contains { $0.isLowercase }
        let hasUpper = password.contains { $0.isUppercase }
        let hasDigit = password.contains { $0.isNumber }
        let hasSymbol = password.contains { !$0.isLetter && !$0.isNumber }
        #expect(lengthOK)
        #expect(hasLower && hasUpper && hasDigit && hasSymbol)
    }

    @Test func credentialsAreUnique() {
        let credentials = (0..<50).map { _ in DisposableCredential.make() }
        let uniqueEmails = Set(credentials.map(\.email)).count == credentials.count
        let uniquePasswords = Set(credentials.map(\.password)).count == credentials.count
        #expect(uniqueEmails)
        #expect(uniquePasswords)
    }

    @Test func textualRepresentationsAreRedacted() {
        let credential = DisposableCredential.make()
        var dumped = ""
        dump(credential, to: &dumped)
        for text in ["\(credential)", String(describing: credential), String(reflecting: credential), dumped] {
            let leaks = text.contains(credential.email) || text.contains(credential.password)
            #expect(!leaks)
        }
    }

    @Test func redactRemovesValues() {
        let credential = DisposableCredential.make()
        let redacted = credential.redact("user \(credential.email) used \(credential.password) twice: \(credential.email)")
        let leaks = redacted.contains(credential.email) || redacted.contains(credential.password)
        let exact = redacted == "user <redacted-email> used <redacted-password> twice: <redacted-email>"
        #expect(!leaks)
        #expect(exact)
    }

    @Test func errorDescriptionExcludesUserInfoAndRedacts() {
        let credential = DisposableCredential.make()
        let error = NSError(
            domain: AuthErrors.domain,
            code: AuthErrorCode.operationNotAllowed.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "Disabled for \(credential.email)",
                AuthErrors.userInfoEmailKey: credential.email,
                "secret": credential.password,
            ]
        )
        let text = AuthSpikeDiagnostics.describe(error, redacting: credential)
        let leaks = text.contains(credential.email) || text.contains(credential.password)
        let hasCode = text.contains("code=17006")
        let hasName = text.contains("name=operationNotAllowed")
        #expect(!leaks)
        #expect(hasCode)
        #expect(hasName)
        #expect(AuthSpikeDiagnostics.isProviderDisabled(error))
    }
}
