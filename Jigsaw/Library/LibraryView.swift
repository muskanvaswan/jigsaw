import SwiftUI

/// Home: every puzzle on this device, most recently played first.
struct LibraryView: View {
    let open: (UUID) -> Void

    @Environment(PuzzleStore.self) private var store
    @Environment(Account.self) private var account
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var draft: Draft?
    @State private var isCreating = false
    @State private var pendingDelete: PuzzleRecord?
    @State private var showingAccount = false
    @State private var failure: String?

    /// Room at the sides: generous on iPad, tighter on iPhone.
    private var gutter: CGFloat { sizeClass == .compact ? 20 : 44 }

    /// A new puzzle being set up, maybe with its picture already chosen.
    private struct Draft: Identifiable {
        let id = UUID()
        let photo: UIImage?
    }

    var body: some View {
        ZStack {
            Color.table.ignoresSafeArea()
            if store.puzzles.isEmpty {
                emptyState
            } else {
                library
            }
            if isCreating {
                ProgressView()
                    .padding(22)
                    .chromeBackground(Circle())
            }
        }
        // Signing in is how puzzles from your other devices arrive, so it's there before there are any here.
        .overlay(alignment: .top) {
            if store.puzzles.isEmpty { header }
        }
        .sheet(item: $draft) { draft in
            NewPuzzleSheet(photo: draft.photo) { photo, rows, cols, seed, snapToBoard in
                start(photo, rows: rows, cols: cols, seed: seed, snapToBoard: snapToBoard)
            }
        }
        // Handed over explicitly: on a Mac, sheets don't always inherit them.
        .sheet(isPresented: $showingAccount) { AccountSheet().environment(store).environment(account) }
        // A picture dragged in (from Finder, or another app beside this one) starts a new puzzle.
        .dropDestination(for: Data.self) { items, _ in
            guard let data = items.first, draft == nil else { return false }
            Task {
                let photo = await Task.detached(priority: .userInitiated) {
                    UIImage(data: data).map { PhotoPrep.prepare($0, longSide: 3200) }
                }.value
                if let photo { draft = Draft(photo: photo) }
            }
            return true
        }
        .alert("Delete this puzzle?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { puzzle in
            Button("Delete", role: .destructive) { store.delete(puzzle.id) }
        } message: { puzzle in
            Text(puzzle.cloud.map { !$0.isOwner ? "You'll leave this shared puzzle."
                                     : $0.isShared ? "It will be removed for everyone you shared it with, and from your other devices."
                                     : "It will be removed from all your devices." } ?? "Its progress will be lost.")
        }
        .alert("Couldn't share", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func share(_ puzzle: PuzzleRecord) {
        guard account.isSignedIn else {
            showingAccount = true
            return
        }
        Task {
            do {
                let share = try await store.share(puzzle.id)
                Sharing.present(share, container: CloudSync.shared.container, thumbnail: store.thumbnails[puzzle.id])
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: gutter * 0.6)], spacing: 34) {
                    ForEach(store.puzzles) { puzzle in
                        Button { open(puzzle.id) } label: {
                            PuzzleCard(puzzle: puzzle, thumbnail: store.thumbnails[puzzle.id])
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(puzzle.cloud?.isShared == true ? "People…" : "Solve Together…", systemImage: "person.2") { share(puzzle) }
                            Button("Start Over", systemImage: "arrow.counterclockwise") { store.restart(puzzle.id) }
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = puzzle }
                        }
                    }
                }
                .padding(.horizontal, gutter)
            }
            .padding(.bottom, 60)
        }
    }

    /// Your account, and a new puzzle once there's a library to add it to.
    private var header: some View {
        HStack {
            Spacer()
            AccountButton { showingAccount = true }
            if !store.puzzles.isEmpty {
                Button { draft = Draft(photo: nil) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .chromeBackground(Circle())
                .keyboardShortcut("n")
                .accessibilityLabel("New puzzle")
            }
        }
        .padding(.horizontal, gutter)
        .padding(.top, 36)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Start a puzzle")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Any picture becomes a puzzle.")
                    .foregroundStyle(.secondary)
            }
            PhotoSources { draft = Draft(photo: $0) }
        }
        .frame(maxWidth: 680)
        .padding(.horizontal, gutter)
    }

    private func start(_ photo: UIImage, rows: Int, cols: Int, seed: UInt64, snapToBoard: Bool) {
        draft = nil
        isCreating = true
        Task {
            let id = await store.create(photo: photo, rows: rows, cols: cols, seed: seed, snapToBoard: snapToBoard)
            isCreating = false
            guard let id else { return }
            open(id)
            if account.isSignedIn, store.syncsAll { await store.backUp(id) }
        }
    }
}

private struct PuzzleCard: View {
    let puzzle: PuzzleRecord
    let thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.tray)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .padding(20)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            HStack(spacing: 6) {
                if puzzle.cloud?.isShared == true {
                    Image(systemName: "person.2.fill")
                        .accessibilityLabel("Shared")
                }
                Text("\(puzzle.pieceCount) pieces")
                Spacer()
                if puzzle.isSolved {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .accessibilityLabel("Solved")
                } else if puzzle.progressCount > 0 {
                    Text(puzzle.progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
        }
    }
}
