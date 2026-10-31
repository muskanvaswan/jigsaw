import AuthenticationServices
import SwiftUI

/// Signing in, and the name other people see when you solve together.
struct AccountSheet: View {
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var name = ""
    @State private var failure: String?

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
                Button("Sign Out", role: .destructive) { account.signOut() }
                    .padding(.top, 8)
            } else {
                VStack(spacing: 6) {
                    Text("Solve together")
                        .font(.title2.weight(.semibold))
                    Text("Sign in to share puzzles and solve them with friends and family, at the same time or whenever suits you.")
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
        .onDisappear { if account.isSignedIn, name != (account.name ?? "") { account.rename(name) } }
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
