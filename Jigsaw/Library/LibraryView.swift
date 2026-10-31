import PhotosUI
import SwiftUI

/// Home: every puzzle on this device, most recently played first.
struct LibraryView: View {
    let open: (UUID) -> Void

    @Environment(PuzzleStore.self) private var store
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var draft: Draft?
    @State private var isLoadingPhoto = false
    @State private var pendingDelete: PuzzleRecord?

    private struct Draft: Identifiable {
        let id = UUID()
        let photo: UIImage
    }

    var body: some View {
        ZStack {
            Color.table.ignoresSafeArea()
            if store.puzzles.isEmpty {
                emptyState
            } else {
                library
            }
            if isLoadingPhoto {
                ProgressView()
                    .padding(22)
                    .chromeBackground(Circle())
            }
        }
        .onChange(of: pickedPhoto) { _, item in load(item) }
        .sheet(item: $draft) { draft in
            NewPuzzleSheet(photo: draft.photo) { rows, cols, seed, snapToBoard in
                start(draft.photo, rows: rows, cols: cols, seed: seed, snapToBoard: snapToBoard)
            }
        }
        .alert("Delete this puzzle?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { puzzle in
            Button("Delete", role: .destructive) { store.delete(puzzle.id) }
        } message: { _ in
            Text("Its progress will be lost.")
        }
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack {
                    Text("Puzzles")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                    Spacer()
                    PhotosPicker(selection: $pickedPhoto, matching: .images) {
                        Image(systemName: "plus")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(Color.primary)
                            .frame(width: 48, height: 48)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .chromeBackground(Circle())
                    .accessibilityLabel("New puzzle")
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 28)], spacing: 34) {
                    ForEach(store.puzzles) { puzzle in
                        Button { open(puzzle.id) } label: {
                            PuzzleCard(puzzle: puzzle, thumbnail: store.thumbnails[puzzle.id])
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Start Over", systemImage: "arrow.counterclockwise") { store.restart(puzzle.id) }
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = puzzle }
                        }
                    }
                }
            }
            .padding(.horizontal, 44)
            .padding(.top, 36)
            .padding(.bottom, 60)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            PhotosPicker(selection: $pickedPhoto, matching: .images) {
                VStack(spacing: 16) {
                    Image(systemName: "puzzlepiece")
                        .font(.system(size: 42, weight: .light))
                    Text("Choose a photo")
                        .font(.title3.weight(.medium))
                }
                .foregroundStyle(Color.primary)
                .frame(width: 300, height: 220)
                .background(Color.tray, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
            .buttonStyle(.plain)
            Text("Any picture becomes a puzzle.")
                .foregroundStyle(.secondary)
        }
    }

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        isLoadingPhoto = true
        Task {
            defer {
                isLoadingPhoto = false
                pickedPhoto = nil
            }
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            let photo = await Task.detached(priority: .userInitiated) {
                UIImage(data: data).map { PhotoPrep.prepare($0, longSide: 3200) }
            }.value
            if let photo { draft = Draft(photo: photo) }
        }
    }

    private func start(_ photo: UIImage, rows: Int, cols: Int, seed: UInt64, snapToBoard: Bool) {
        draft = nil
        isLoadingPhoto = true
        Task {
            let id = await store.create(photo: photo, rows: rows, cols: cols, seed: seed, snapToBoard: snapToBoard)
            isLoadingPhoto = false
            if let id { open(id) }
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

            HStack {
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
