import SwiftUI

/// Settings › Epic Games: sign in through Epic's website with a one-time code, then the library shows up.
struct EpicSettingsSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var code = ""

    var body: some View {
        Section {
            switch store.epicState {
            case .ready(let account):
                LabeledContent("Account") { Text(verbatim: account) }
                LabeledContent("Games") { Text(verbatim: "\(store.epicTitles.count)") }
                HStack {
                    Button("Refresh Library") { Task { await store.refreshEpic(refresh: true) } }
                    Button("Sign Out", role: .destructive) { Task { await store.signOutEpic() } }
                }
            case .working(let step):
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(verbatim: step) }
            case .signedOut, .failed:
                if case .failed(let message) = store.epicState {
                    Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .foregroundStyle(.orange).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Sign in on Epic's website. The page then shows a short text containing “authorizationCode”.")
                    Link(destination: Legendary.loginURL) { Label("Open Epic Sign-In", systemImage: "arrow.up.right.square") }
                    Text("2. Copy that code (or the whole text) and paste it here within a few minutes:")
                    HStack {
                        TextField("Authorization code", text: $code).textFieldStyle(.roundedBorder)
                        Button("Connect") {
                            let pasted = code
                            code = ""
                            Task { await store.signInEpic(code: pasted) }
                        }
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        } header: {
            Text("Epic Games")
        } footer: {
            Text("MacHub uses Legendary, an open-source Epic launcher (GPLv3), downloaded once from its GitHub releases and checked by SHA-256. Your Epic password stays on Epic's website; Legendary keeps a sign-in token in MacHub's folder. Epic games install into their own Windows environment and start with MacHub's engine. Games with Epic's anti-cheat or Epic Online Services may not run.")
        }
    }
}
