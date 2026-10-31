import CloudKit
import Observation
import UIKit

/// One open puzzle: its cut pieces, the clock, saving progress, and keeping a shared puzzle in step
/// with everyone else solving it.
@MainActor
@Observable
final class BoardSession {
    private(set) var record: PuzzleRecord
    /// Pieces locked into the board, or joined to a neighbour when the puzzle doesn't snap to the board.
    private(set) var progressCount: Int
    private(set) var isSolved: Bool
    /// Other people who have opened this puzzle, most recent first.
    private(set) var collaborators: [Collaborator] = []

    @ObservationIgnored let renderer: PieceRenderer
    @ObservationIgnored let photo: UIImage
    /// Handed to the board once, then dropped so pieces can swap images without keeping old ones alive.
    @ObservationIgnored private(set) var initialImages: [UIImage]?
    @ObservationIgnored weak var board: BoardView?
    @ObservationIgnored private weak var store: PuzzleStore?
    @ObservationIgnored private var playingSince: Date?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var syncing: Task<Void, Never>?
    @ObservationIgnored private var isPushing = false
    @ObservationIgnored private var pushAgain = false

    private init(record: PuzzleRecord, photo: UIImage, renderer: PieceRenderer, images: [UIImage], store: PuzzleStore) {
        self.record = record
        self.photo = photo
        self.renderer = renderer
        self.initialImages = images
        self.store = store
        progressCount = record.progressCount
        isSolved = record.isSolved
    }

    /// Loads the photo and cuts every piece off the main thread.
    static func open(_ record: PuzzleRecord, store: PuzzleStore) async -> BoardSession? {
        let url = store.photoURL(record.id)
        let loaded = await Task.detached(priority: .userInitiated) { () -> (UIImage, PieceRenderer, [UIImage])? in
            guard let photo = PhotoPrep.load(url), let cgImage = photo.cgImage else { return nil }
            let renderer = PieceRenderer(geometry: record.geometry, photo: cgImage)
            let images = renderer.images(shadowed: record.finishedPieces.map { !$0 })
            return (photo, renderer, images)
        }.value
        guard let (photo, renderer, images) = loaded else { return nil }
        return BoardSession(record: record, photo: photo, renderer: renderer, images: images, store: store)
    }

    func makeBoard() -> BoardView {
        let board = BoardView(renderer: renderer, photo: photo,
                              images: initialImages ?? renderer.images(shadowed: record.finishedPieces.map { !$0 }),
                              states: record.pieces, snapsToBoard: record.snapsToBoard, solved: isSolved)
        initialImages = nil
        board.delegate = self
        self.board = board
        return board
    }

    var isSpreadOut: Bool { record.spreadOut ?? false }

    /// Lays loose pieces out in rows, or sweeps them back into a heap.
    func setSpreadOut(_ spread: Bool) {
        record.spreadOut = spread
        if spread { board?.spreadOut() } else { board?.heapUp() }
        save()
    }

    func setSnapsToBoard(_ snaps: Bool) {
        record.snapToBoard = snaps
        board?.setSnapsToBoard(snaps)
        save()
    }

    // MARK: - Clock

    func resume() {
        if playingSince == nil, !isSolved { playingSince = Date() }
    }

    func pause() {
        bankPlayTime()
        playingSince = nil
    }

    /// Time spent solving so far, including the stretch in progress.
    func elapsed(at date: Date) -> TimeInterval {
        record.playTime + (playingSince.map { date.timeIntervalSince($0) } ?? 0)
    }

    private func bankPlayTime() {
        guard let since = playingSince else { return }
        let now = Date()
        record.playTime += now.timeIntervalSince(since)
        playingSince = now
    }

    // MARK: - Saving

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        save(sharing: true)
    }

    private func save(sharing: Bool) {
        pendingSave?.cancel()
        pendingSave = nil
        guard let board, let store else { return }
        bankPlayTime()
        record.pieces = board.pieceStates()
        record.updatedAt = Date()
        store.save(record)

        let finished = record.finishedPieces, geometry = renderer.geometry, photo = photo, id = record.id
        Task {
            let thumbnail = await Task.detached(priority: .utility) {
                Thumbnail.render(photo: photo, geometry: geometry, finished: finished)
            }.value
            store.saveThumbnail(thumbnail, for: id)
        }
        if sharing { push() }
    }

    // MARK: - Solving together

    var isShared: Bool { record.cloud != nil }

    /// Shares the puzzle (putting it in iCloud the first time) and returns the share to invite people with.
    func share() async throws -> CKShare {
        guard let store else { throw CloudError.incomplete }
        save(sharing: false)
        let share = try await store.share(record.id)
        record.cloud = store.record(record.id)?.cloud
        return share
    }

    /// While a shared puzzle is open: say you're here, and look for everyone else's moves every few seconds.
    func startSyncing(as name: String) {
        guard let link = record.cloud, syncing == nil else { return }
        syncing = Task { [weak self] in
            var round = 0
            while !Task.isCancelled {
                if round % 5 == 0 { await CloudSync.shared.checkIn(link, name: name) }
                await self?.pull()
                round += 1
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopSyncing() {
        syncing?.cancel()
        syncing = nil
    }

    private func pull() async {
        guard let link = record.cloud, let changes = try? await CloudSync.shared.changes(in: link) else { return }
        collaborators = changes.collaborators
        if let snaps = changes.snapToBoard, snaps != record.snapsToBoard {
            record.snapToBoard = snaps
            board?.setSnapsToBoard(snaps)
        }
        if let theirs = changes.pieces { take(theirs) }
    }

    /// Folds someone else's moves into the board, and sends ours if they haven't seen them yet.
    private func take(_ theirs: [PieceState]) {
        guard let board else { return }
        let mine = board.pieceStates()
        if PieceState.hasNewer(theirs, than: mine) {
            board.apply(PieceState.merge(mine, theirs))
            save(sharing: false)
        }
        if PieceState.hasNewer(mine, than: theirs) { push() }
    }

    private func push() {
        guard record.cloud != nil else { return }
        guard !isPushing else {
            pushAgain = true
            return
        }
        isPushing = true
        let snapshot = record
        Task {
            let merged = try? await CloudSync.shared.push(snapshot)
            isPushing = false
            if let merged { take(merged) }
            if pushAgain {
                pushAgain = false
                push()
            }
        }
    }
}

extension BoardSession: BoardViewDelegate {
    func boardDidChange(_ board: BoardView) {
        scheduleSave()
    }

    func board(_ board: BoardView, didProgress count: Int) {
        progressCount = count
    }

    func boardDidFinish(_ board: BoardView) {
        bankPlayTime()
        playingSince = nil
        if record.solvedAt == nil { record.solvedAt = Date() }
        isSolved = true
        save()
    }
}
