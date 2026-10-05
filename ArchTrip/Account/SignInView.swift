import SwiftUI

/// Email/Password sign-in for an install without a Firebase user (e.g. a second
/// device). There is no account creation and no anonymous fallback here.
struct SignInView: View {
    @Environment(AppSession.self) private var session
    @State private var email = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var failure: SignInFailure?

    private var input: EmailPasswordInput { EmailPasswordInput(email: email, password: password) }

    var body: some View {
        Form {
            Section {
                Label("Sign in with your sync account", systemImage: "person.badge.key")
                    .font(.headline)
                Text("Use the email and password set up on your other iPhone. Your data is shared through this account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            } footer: {
                if let failure {
                    Text(failure.message).foregroundStyle(.red)
                }
            }
            Section {
                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        Text("Sign In")
                        if isSigningIn {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isSigningIn || !input.issues(confirmation: nil).isEmpty)
            }
        }
    }

    private func signIn() async {
        isSigningIn = true
        failure = nil
        let attempt = input
        password = ""
        failure = await session.signIn(attempt)
        isSigningIn = false
    }
}

extension SignInFailure {
    var message: LocalizedStringKey {
        switch self {
        case .wrongCredentials: "The email or password is incorrect."
        case .network: "Check your network connection and try again."
        case .tooManyRequests: "Too many attempts. Wait a while and try again."
        case .disabled: "This account can't be used to sign in."
        case .other: "Couldn't sign in. Try again later."
        }
    }
}
