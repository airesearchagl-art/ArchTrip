import SwiftUI

/// Adds an Email/Password credential to the current anonymous account so the same
/// UID (and all data under users/{uid}) can be used on another iPhone.
struct AccountMigrationView: View {
    @Environment(AppSession.self) private var session
    @State private var preflight: PreflightResult?
    @State private var isChecking = false
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var confirming = false
    @State private var isLinking = false
    @State private var result: MigrationResult?

    private var input: EmailPasswordInput { EmailPasswordInput(email: email, password: password) }
    private var inputIssues: [EmailPasswordInput.Issue] { input.issues(confirmation: confirmation) }

    private var canLink: Bool {
        if case .ready = preflight, session.accountKind == .anonymous, inputIssues.isEmpty, !isLinking, !isChecking, result == nil {
            return true
        }
        return false
    }

    var body: some View {
        Form {
            Section {
                Text("Add an email and password to this account so you can sign in on your company iPhone later. Your trips, events and buildings stay in place.")
                Label("Use an email address you control.", systemImage: "envelope")
                Label("Use a unique, strong password (a password manager is recommended).", systemImage: "key")
                Label("You will use this account on your company iPhone.", systemImage: "iphone.gen3")
            }
            .font(.subheadline)

            if let result {
                resultSection(result)
            } else {
                preflightSection
                credentialSection
            }
        }
        .navigationTitle("Set Up Device Sync")
        .navigationBarTitleDisplayMode(.inline)
        .task { await runPreflight() }
        .confirmationDialog("Set up this account?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Set Up Account", role: .destructive) {
                Task { await link() }
            }
        } message: {
            Text("This changes this anonymous account into an account for syncing between devices. Your current data is kept; only sign-in details are added.")
        }
    }

    private var preflightSection: some View {
        Section {
            switch preflight {
            case nil:
                HStack {
                    Text("Checking…")
                    Spacer()
                    ProgressView()
                }
            case .failed(let failure):
                Label(failure.message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Button("Check Again") { Task { await runPreflight() } }
                    .disabled(isChecking)
            case .ready(let snapshot):
                Label("Ready", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                LabeledContent("Trips") { Text(verbatim: "\(snapshot.tripCount)") }
                LabeledContent("Events") { Text(verbatim: "\(snapshot.eventCount)") }
                LabeledContent("Buildings") { Text(verbatim: "\(snapshot.buildingCount)") }
                Button("Check Again") { Task { await runPreflight() } }
                    .disabled(isChecking)
            }
        } header: {
            Text("Pre-check")
        } footer: {
            Text("Confirms with the server that all changes are saved before setting up the account.")
        }
    }

    private var credentialSection: some View {
        Section {
            TextField("Email", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .textContentType(.newPassword)
            SecureField("Confirm Password", text: $confirmation)
                .textContentType(.newPassword)
            Button {
                confirming = true
            } label: {
                HStack {
                    Text("Set Up Account")
                    if isLinking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!canLink)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(inputIssues.filter { _ in !email.isEmpty || !password.isEmpty }, id: \.self) { issue in
                    Text(issue.message).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func resultSection(_ result: MigrationResult) -> some View {
        switch result {
        case .refused(let failure):
            Section {
                Label(failure.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text("Nothing was changed.").foregroundStyle(.secondary)
                Button("Back") { reset() }
            }
        case .linkFailed(let failure):
            Section {
                Label(failure.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text("Nothing was changed.").foregroundStyle(.secondary)
                Button("Back") { reset() }
            }
        case .completed(let report):
            Section {
                Label("Account set up", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                reportRows(report)
            } footer: {
                Text("You can now sign in on another iPhone with this email and password.")
            }
        case .blocked(let report):
            Section {
                Label("Needs review", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("The sign-in details were added, but a check did not pass. Nothing was undone automatically. Do not retry; report this state for review.")
                    .font(.subheadline)
                reportRows(report)
            }
        }
    }

    @ViewBuilder
    private func reportRows(_ report: MigrationReport) -> some View {
        checkRow("UID maintained", report.uidPreserved && report.currentUserMatches)
        checkRow("Email/Password linked", report.passwordProviderLinked && report.noLongerAnonymous)
        checkRow("Trips retained", report.tripsRetained)
        checkRow("Events retained", report.eventsRetained)
        checkRow("Buildings retained", report.buildingsRetained)
    }

    private func checkRow(_ title: LocalizedStringKey, _ passed: Bool) -> some View {
        LabeledContent(title) {
            Text(verbatim: passed ? "PASS" : "FAIL")
                .font(.body.monospaced().weight(.semibold))
                .foregroundStyle(passed ? .green : .red)
        }
    }

    private func runPreflight() async {
        guard let uid = session.uid, let steps = session.migrationSteps(), !isChecking else {
            preflight = .failed(.noUser)
            return
        }
        isChecking = true
        preflight = nil
        preflight = await AccountMigrator.preflight(expectedUID: uid, steps: steps)
        isChecking = false
    }

    private func link() async {
        guard let uid = session.uid, let steps = session.migrationSteps() else { return }
        isLinking = true
        let attempt = input
        password = ""
        confirmation = ""
        let outcome = await AccountMigrator.run(input: attempt, expectedUID: uid, steps: steps)
        switch outcome {
        case .completed(let report), .blocked(let report):
            session.logMigrationEvidence(report.evidence)
            session.refreshAccount()
        case .refused(let failure):
            session.logMigrationEvidence("refused \(failure)")
        case .linkFailed(let failure):
            session.logMigrationEvidence("link-failed \(failure)")
        }
        result = outcome
        isLinking = false
    }

    private func reset() {
        result = nil
        Task { await runPreflight() }
    }
}

extension PreflightFailure {
    var message: LocalizedStringKey {
        switch self {
        case .noUser: "No account is signed in."
        case .notAnonymous: "This account is already set up."
        case .userChanged: "The signed-in account changed. Reopen this screen."
        case .pendingWrites: "Some changes have not reached the server yet. Connect to the network and try again."
        case .serverUnavailable: "Couldn't reach the server. Connect to the network and try again."
        }
    }
}

extension LinkFailure {
    var message: LocalizedStringKey {
        switch self {
        case .emailAlreadyInUse, .credentialAlreadyInUse: "This email address is already used by another account."
        case .weakPassword: "The password is too weak. Use a longer, more complex password."
        case .invalidEmail: "Enter a valid email address."
        case .network: "Check your network connection and try again."
        case .operationNotAllowed: "Email sign-in is not enabled for this app."
        case .requiresRecentLogin: "Couldn't set up the account. Try again later."
        case .tooManyRequests: "Too many attempts. Wait a while and try again."
        case .other: "Couldn't set up the account. Try again later."
        }
    }
}

extension EmailPasswordInput.Issue {
    var message: LocalizedStringKey {
        switch self {
        case .invalidEmail: "Enter a valid email address."
        case .passwordTooShort: "Use at least 8 characters for the password."
        case .passwordMismatch: "The passwords don't match."
        }
    }
}
