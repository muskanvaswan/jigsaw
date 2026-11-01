import AuthenticationServices
import SwiftUI

/// Signing in, the name other people see when you solve together, and whether puzzles sync through iCloud.
struct AccountSheet: View {
    @Environment(Account.self) private var account
    @Environment(PuzzleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var name = ""
    @State private var failure: String?
    @State private var isSwitchingSync = false
    @State private var confirmingSyncOff = false
    @State private var syncFailure: String?

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
            }

            Image(systemName: "person.2.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.accentColor)

            if account.isSignedIn {
                VStack(spacing: 6) {
                    Text("Signed in")
                        .font(.title2.weight(.semibold))
                    Text("This is the name people you solve with will see.")
                        .foregroundStyle(.secondary)
                }
                TextField("Your name", text: $name)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .padding(.vertical, 12)
                    .background(Color.tray, in: Capsule())
                    .frame(maxWidth: 320)
                    .onSubmit { account.rename(name) }
                syncToggle
                Button("Sign Out", role: .destructive) { account.signOut() }
                    .padding(.top, 8)
            } else {
                VStack(spacing: 6) {
                    Text("Sign in")
                        .font(.title2.weight(.semibold))
                    Text("Your puzzles follow you to your other devices, and you can solve them with friends and family, at the same time or whenever suits you.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 380)
                }
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    switch result {
                    case .success(let authorization):
                        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
                            account.signedIn(with: credential)
                            name = account.name ?? ""
                        }
                    case .failure(let error):
                        if (error as? ASAuthorizationError)?.code != .canceled { failure = error.localizedDescription }
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(width: 280, height: 50)
                if let failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(32)
        .background(Color.table)
        .onAppear { name = account.name ?? "" }
        // The name can arrive from iCloud a moment after signing in.
        .onChange(of: account.name) { _, saved in
            if name.isEmpty { name = saved ?? "" }
        }
        .onDisappear { if account.isSignedIn, name != (account.name ?? "") { account.rename(name) } }
        .alert("Turn off iCloud sync?", isPresented: $confirmingSyncOff) {
            Button("Turn Off", role: .destructive) { setSync(false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your puzzles will be removed from iCloud to free up space, and kept on each of your devices. Puzzles you've shared stay so others can keep solving.")
        }
    }

    private var syncToggle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { store.syncsAll }, set: { on in
                if on { setSync(true) } else { confirmingSyncOff = true }
            })) {
                HStack(spacing: 10) {
                    Text("Sync with iCloud")
                    if isSwitchingSync { ProgressView() }
                }
            }
            .disabled(isSwitchingSync)
            Text(syncFailure ?? (store.syncsAll ? "Your puzzles and progress follow you to your other devices."
                                 : "Puzzles stay on the device they're on. Shared puzzles still sync."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.tray, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: 380)
    }

    private func setSync(_ on: Bool) {
        isSwitchingSync = true
        syncFailure = nil
        Task {
            do {
                try await store.setSyncsAll(on)
            } catch {
                syncFailure = error.localizedDescription
            }
            isSwitchingSync = false
        }
    }
}

/// The round button in the library header: your initials once signed in.
struct AccountButton: View {
    @Environment(Account.self) private var account
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if account.isSignedIn {
                    Text(account.displayName.initials)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                } else {
                    Image(systemName: "person")
                        .font(.system(size: 18, weight: .medium))
                }
            }
            .foregroundStyle(Color.primary)
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .chromeBackground(Circle())
        .accessibilityLabel(account.isSignedIn ? "Account, signed in as \(account.displayName)" : "Sign in")
    }
}
