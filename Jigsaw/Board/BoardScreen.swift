import SwiftUI

/// The full-screen puzzle: just the table, a way out, how pieces snap, and a peek at the picture.
struct BoardScreen: View {
    let puzzleID: UUID
    let close: () -> Void

    @Environment(PuzzleStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: BoardSession?
    @State private var peeking = false
    /// A brief line under the buttons saying what just changed.
    @State private var note: String?

    var body: some View {
        ZStack {
            Color.table.ignoresSafeArea()
            if let session {
                BoardCanvas(session: session, peeking: peeking)
                    .ignoresSafeArea()
                    .transition(.opacity)
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 12) {
                chrome
                if let note {
                    Text(note)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .chromeBackground(Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let session, session.isSolved { solvedBadge(session.record) }
        }
        .animation(.spring(duration: 0.5), value: session?.isSolved)
        .task { await open() }
        .onChange(of: scenePhase) { _, phase in
            guard let session else { return }
            if phase == .active {
                session.resume()
            } else {
                session.pause()
                session.save()
            }
        }
    }

    private var chrome: some View {
        HStack(spacing: 10) {
            ChromeButton(systemImage: "chevron.left", label: "Back to puzzles") { leave() }
            Spacer()
            if let session, !session.isSolved {
                Text("\(session.progressCount) / \(session.record.pieceCount)")
                    .font(.footnote.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                    .chromeBackground(Capsule())
                    .accessibilityLabel("\(session.progressCount) of \(session.record.pieceCount) pieces in place")
                let snaps = session.record.snapsToBoard
                ChromeButton(systemImage: snaps ? "square.grid.3x3.fill" : "square.grid.3x3",
                             label: "Snap to board", isActive: snaps) {
                    session.setSnapsToBoard(!snaps)
                    show(snaps ? "Pieces only snap to each other" : "Pieces snap to the board")
                }
                .accessibilityValue(snaps ? "On" : "Off")
                ChromeButton(systemImage: peeking ? "eye.fill" : "eye", label: "Show picture", isActive: peeking) {
                    peeking.toggle()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private func show(_ text: String) {
        withAnimation(.spring(duration: 0.35)) { note = text }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard note == text else { return }
            withAnimation(.easeIn(duration: 0.3)) { note = nil }
        }
    }

    private func solvedBadge(_ record: PuzzleRecord) -> some View {
        VStack(spacing: 3) {
            Text("Solved")
                .font(.headline)
            Text("\(record.pieceCount) pieces · \(Duration.seconds(record.playTime).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .chromeBackground(Capsule())
        .padding(.bottom, 28)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func open() async {
        guard session == nil, let record = store.record(puzzleID) else { return }
        guard let opened = await BoardSession.open(record, store: store) else {
            close()
            return
        }
        withAnimation(.easeOut(duration: 0.35)) { session = opened }
        opened.resume()
    }

    private func leave() {
        session?.pause()
        session?.save()
        close()
    }
}

private struct BoardCanvas: UIViewRepresentable {
    let session: BoardSession
    let peeking: Bool

    func makeUIView(context: Context) -> BoardView {
        session.makeBoard()
    }

    func updateUIView(_ board: BoardView, context: Context) {
        board.setPeeking(peeking)
    }
}
