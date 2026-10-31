import AuthenticationServices
import Observation

/// Who is playing, from Sign in with Apple. Collaborators see this name in shared puzzles.
@Observable
final class Account {
    private(set) var userID: String?
    private(set) var name: String?

    var isSignedIn: Bool { userID != nil }
    var displayName: String { name?.isEmpty == false ? name! : "Player" }

    private static let userIDKey = "account.userID"
    private static let nameKey = "account.name"

    init() {
        userID = UserDefaults.standard.string(forKey: Self.userIDKey)
        name = UserDefaults.standard.string(forKey: Self.nameKey)
        verify()
    }

    /// Signs out if this Apple ID has been disconnected from the app in Settings.
    func verify() {
        guard let userID else { return }
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
            guard state == .revoked || state == .notFound else { return }
            DispatchQueue.main.async { self.signOut() }
        }
    }

    /// Apple only shares the person's name the first time they sign in, so keep the one we have after that.
    func signedIn(with credential: ASAuthorizationAppleIDCredential) {
        userID = credential.user
        if let parts = credential.fullName, let given = PersonNameComponentsFormatter.localizedString(from: parts, style: .default).nilIfEmpty {
            name = given
        }
        save()
    }

    func rename(_ newName: String) {
        name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func signOut() {
        userID = nil
        name = nil
        save()
    }

    private func save() {
        UserDefaults.standard.set(userID, forKey: Self.userIDKey)
        UserDefaults.standard.set(name, forKey: Self.nameKey)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    /// Up to two letters standing for a name, for small avatars.
    var initials: String {
        let letters = split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
