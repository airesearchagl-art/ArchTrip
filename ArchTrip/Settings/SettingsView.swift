import SwiftUI

struct SettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.default
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Language", selection: $language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(verbatim: language.nativeName).tag(language)
                        }
                    }
                }
                accountSection
                Section("Developer") {
                    NavigationLink("Developer Diagnostics") {
                        SyncDiagnosticsView()
                    }
                }
                Section {
                    LabeledContent("Version") {
                        Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        switch session.accountKind {
        case .anonymous:
            Section {
                LabeledContent("Account") {
                    Text("This iPhone only")
                }
                NavigationLink("Set Up Device Sync") {
                    AccountMigrationView()
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Add an email and password to use the same data on another iPhone.")
            }
        case .permanent:
            Section("Account") {
                LabeledContent("Account") {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                        Text("Device sync set up")
                    }
                    .foregroundStyle(.green)
                }
                if let maskedEmail = session.maskedEmail {
                    LabeledContent("Email") {
                        Text(verbatim: maskedEmail)
                    }
                }
            }
        case nil:
            EmptyView()
        }
    }
}
