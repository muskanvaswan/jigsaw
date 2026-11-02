import GroupActivities
import SwiftUI

@main
struct JigsawApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = PuzzleStore()
    @State private var account = Account()

    init() {
        Click.prepare()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SeedCloudKitSchema") {
            Task { @MainActor in
                let result: String
                do {
                    try await CloudSync.shared.seedSchema()
                    result = "Seeded the CloudKit schema."
                } catch {
                    result = "Couldn't seed the CloudKit schema: \(error)"
                }
                let log = FileManager.default.temporaryDirectory.appendingPathComponent("seed-result.txt")
                try? result.write(to: log, atomically: true, encoding: .utf8)
                exit(0)
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(account)
                .tint(Color("AccentColor"))
                #if DEBUG
                .preferredColorScheme(DebugLaunch.appearance)
                #endif
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
            #if DEBUG
            if let id = DebugLaunch.openPuzzle { openPuzzle = id }
            DebugLaunch.takeScreenshotSoon()
            #endif
        }
        .onChange(of: invitations.pending.count) { _, _ in acceptInvitation() }
        .task {
            for await session in SolveLive.sessions() { joinLive(session) }
        }
        .onChange(of: account.isSignedIn) { _, _ in catchUp() }
        .onChange(of: openPuzzle) { _, open in
            if open == nil { catchUp() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { catchUp() }
        }
        // iCloud doesn't tell a running app about moves made on other devices or by everyone else,
        // so the library looks again every little while it's on screen.
        .task(id: openPuzzle == nil && scenePhase != .background) {
            guard openPuzzle == nil, scenePhase != .background else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if !Task.isCancelled { catchUp() }
            }
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

    /// Joins someone solving live, and opens the puzzle: the copy here, or through the iCloud invitation if it
    /// hasn't been opened on this device yet.
    private func joinLive(_ session: GroupSession<SolveLive>) {
        Live.shared.name = account.displayName
        Live.shared.join(session)
        let puzzleID = session.activity.puzzleID, shareURL = session.activity.shareURL
        Task {
            if store.record(puzzleID) == nil, let url = shareURL,
               let metadata = try? await CloudSync.shared.container.shareMetadatas(for: [url])[url]?.get() {
                _ = try? await store.accept(metadata)
            }
            guard store.record(puzzleID) != nil else {
                Live.shared.leave()
                failure = "This puzzle hasn't been shared with you yet. Ask whoever started it to invite you from Solve Together, then join again."
                return
            }
            if openPuzzle != puzzleID { withAnimation(.easeInOut(duration: 0.3)) { openPuzzle = puzzleID } }
        }
    }

    /// Brings the library up to date with iCloud, and puts new puzzles there when signed in.
    /// Only bothers iCloud for people who sign in or share.
    private func catchUp() {
        #if DEBUG
        guard !DebugLaunch.isScreenshotting else { return }
        #endif
        guard account.isSignedIn || store.puzzles.contains(where: { $0.cloud != nil }) else { return }
        let open = openPuzzle, signedIn = account.isSignedIn
        Task { await store.catchUp(signedIn: signedIn, except: open) }
    }
}
