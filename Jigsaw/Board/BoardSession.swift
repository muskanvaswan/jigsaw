import Observation
import UIKit

/// One open puzzle: its cut pieces, the clock, and saving progress back to the store.
@Observable
final class BoardSession {
    private(set) var record: PuzzleRecord
    /// Pieces locked into the board, or joined to a neighbour when the puzzle doesn't snap to the board.
    private(set) var progressCount: Int
    private(set) var isSolved: Bool

    @ObservationIgnored let renderer: PieceRenderer
    @ObservationIgnored let photo: UIImage
    /// Handed to the board once, then dropped so pieces can swap images without keeping old ones alive.
    @ObservationIgnored private(set) var initialImages: [UIImage]?
    @ObservationIgnored weak var board: BoardView?
    @ObservationIgnored private weak var store: PuzzleStore?
    @ObservationIgnored private var playingSince: Date?
    @ObservationIgnored private var pendingSave: DispatchWorkItem?

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

    private func bankPlayTime() {
        guard let since = playingSince else { return }
        let now = Date()
        record.playTime += now.timeIntervalSince(since)
        playingSince = now
    }

    // MARK: - Saving

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let board, let store else { return }
        bankPlayTime()
        record.pieces = board.pieceStates()
        record.updatedAt = Date()
        store.save(record)

        let finished = record.finishedPieces, geometry = renderer.geometry, photo = photo, id = record.id
        DispatchQueue.global(qos: .utility).async {
            let thumbnail = Thumbnail.render(photo: photo, geometry: geometry, finished: finished)
            DispatchQueue.main.async { store.saveThumbnail(thumbnail, for: id) }
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
        record.solvedAt = Date()
        isSolved = true
        save()
    }
}
