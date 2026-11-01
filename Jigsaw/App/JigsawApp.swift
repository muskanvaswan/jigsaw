import SwiftUI

@main
struct JigsawApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = PuzzleStore()
    @State private var account = Account()

    init() {
        Click.prepare()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(account)
                .tint(Color("AccentColor"))
        }
    }
}

/// The library, with the open puzzle laid over it. No navigation stack, so no system
/// swipe-back gesture can fight with dragging pieces.
struct RootView: View {
    @Environment(PuzzleStore.self) private var store
    @Environment(Account.self) private var account
    @Environment(\.scenePhase) private var scenePhase
    @State private var openPuzzle: UUID?
    @State private var invitations = Invitations.shared
    @State private var failure: String?

    var body: some View {
        ZStack {
            LibraryView { id in
                withAnimation(.easeInOut(duration: 0.3)) { openPuzzle = id }
            }
            if let id = openPuzzle {
                BoardScreen(puzzleID: id) {
                    withAnimation(.easeInOut(duration: 0.3)) { openPuzzle = nil }
                }
                .id(id)
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .statusBarHidden(openPuzzle != nil)
        .persistentSystemOverlays(openPuzzle == nil ? .automatic : .hidden)
        .onAppear {
            acceptInvitation()
            catchUp()
        }
        .onChange(of: invitations.pending.count) { _, _ in acceptInvitation() }
        .onChange(of: account.isSignedIn) { _, _ in catchUp() }
        .onChange(of: openPuzzle) { _, open in
            if open == nil { catchUp() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { catchUp() }
        }
        .alert("Couldn't open the puzzle", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    /// Opens a puzzle someone shared, downloading it first if it's new here.
    private func acceptInvitation() {
        guard let invitation = invitations.pending.first else { return }
        invitations.pending.removeFirst()
        Task {
            do {
                let id = try await store.accept(invitation)
                withAnimation(.easeInOut(duration: 0.3)) { openPuzzle = id }
            } catch {
                failure = error.localizedDescription
            }
            acceptInvitation()
        }
    }

    /// Brings the library up to date with iCloud, and puts new puzzles there when signed in.
    /// Only bothers iCloud for people who sign in or share.
    private func catchUp() {
        guard account.isSignedIn || store.puzzles.contains(where: { $0.cloud != nil }) else { return }
        let open = openPuzzle, signedIn = account.isSignedIn
        Task { await store.catchUp(signedIn: signedIn, except: open) }
    }
}
