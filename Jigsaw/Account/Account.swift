import AuthenticationServices
import Observation

/// Who is playing, from Sign in with Apple. Collaborators see this name in shared puzzles. Apple only shares
/// the name the very first time someone signs in to the app, so it's also kept in iCloud for every other
/// device (and every later sign-in) to pick up.
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
        syncName()
    }

    /// Signs out if this Apple ID has been disconnected from the app in Settings.
    func verify() {
        guard let userID else { return }
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
            guard state == .revoked || state == .notFound else { return }
            DispatchQueue.main.async { self.signOut() }
        }
    }

    func signedIn(with credential: ASAuthorizationAppleIDCredential) {
        userID = credential.user
        if let parts = credential.fullName, let given = PersonNameComponentsFormatter.localizedString(from: parts, style: .default).nilIfEmpty {
            name = given
        }
        save()
        syncName()
    }

    func rename(_ newName: String) {
        name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
        if let name = name?.nilIfEmpty { Task { await CloudSync.shared.saveName(name) } }
    }

    /// Fills in the name from iCloud when this device doesn't know it, or puts this device's in iCloud
    /// when nobody has yet.
    private func syncName() {
        guard isSignedIn else { return }
        Task { @MainActor in
            let saved: String?
            do { saved = try await CloudSync.shared.savedName() } catch { return }
            if let mine = name?.nilIfEmpty {
                if saved == nil { await CloudSync.shared.saveName(mine) }
            } else if let saved, isSignedIn {
                name = saved
                save()
            }
        }
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
