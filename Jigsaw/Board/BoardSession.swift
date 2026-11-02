import CloudKit
import Observation
import UIKit

/// One open puzzle: its cut pieces, the clock, saving progress, and keeping a puzzle in iCloud in step
/// with your other devices and everyone else solving it.
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
    @ObservationIgnored private var checkedInAt: Date?
    @ObservationIgnored private var isPushing = false
    @ObservationIgnored private var pushAgain = false
    @ObservationIgnored private var isClosed = false
    /// When each piece had last moved as of the last change, so each move is told live just once.
    @ObservationIgnored private var toldLive: [Double]
    @ObservationIgnored private var lastCarry = Date.distantPast

    private init(record: PuzzleRecord, photo: UIImage, renderer: PieceRenderer, images: [UIImage], store: PuzzleStore) {
        self.record = record
        self.photo = photo
        self.renderer = renderer
        self.initialImages = images
        self.store = store
        progressCount = record.progressCount
        isSolved = record.isSolved
        toldLive = record.pieces.map { $0.t ?? 0 }
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
        if isLive { Live.shared.send(.snapToBoard(snaps)) }
        board?.setSnapsToBoard(snaps)
        save()
    }

    /// Done with the puzzle for now: the clock stops, everything is saved, and syncing stops. Safe to call twice.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        pause()
        save()
        stopSyncing()
        Live.shared.detach(self)
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
        adoptLink()
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

    // MARK: - Syncing and solving together

    var isShared: Bool { record.cloud?.isShared == true }

    /// Shares the puzzle (putting it in iCloud the first time) and returns the share to invite people with.
    func share() async throws -> CKShare {
        guard let store else { throw CloudError.incomplete }
        save(sharing: false)
        let share = try await store.share(record.id)
        record.cloud = store.record(record.id)?.cloud
        return share
    }

    /// While the puzzle is open: look for moves made on your other devices, or by everyone else if it's shared
    /// (and say you're here).
    func startSyncing(as name: String) {
        guard syncing == nil else { return }
        syncing = Task { [weak self] in
            while !Task.isCancelled {
                guard let pause = await self?.sync(as: name) else { return }
                try? await Task.sleep(for: .seconds(pause))
            }
        }
    }

    func stopSyncing() {
        syncing?.cancel()
        syncing = nil
        checkedInAt = nil
    }

    /// One look at iCloud. Returns how long to wait before the next: not long when others may be solving too.
    private func sync(as name: String) async -> Double {
        adoptLink()
        guard let link = record.cloud else { return 5 }
        if link.isShared, checkedInAt.map({ $0.timeIntervalSinceNow < -15 }) ?? true {
            checkedInAt = Date()
            await CloudSync.shared.checkIn(link, name: name)
        }
        await pull()
        return link.isShared ? 3 : 10
    }

    /// The puzzle can go into iCloud (or come out) while it's open; the store knows where it lives.
    private func adoptLink() {
        if let stored = store?.record(record.id) { record.cloud = stored.cloud }
    }

    private func pull() async {
        guard let link = record.cloud, let changes = try? await CloudSync.shared.changes(in: link) else { return }
        collaborators = changes.collaborators
        bankPlayTime()
        record.takeClock(changes.playTime, restartedAt: changes.restartedAt)
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
        // Finishes even if the app is put away meanwhile, so the last moves reach your other devices (and
        // everyone else) without waiting for it to be opened again.
        let background = BackgroundTime(named: "Saving to iCloud")
        Task {
            let merged = try? await CloudSync.shared.push(snapshot)
            background.end()
            isPushing = false
            if let merged { take(merged) }
            if pushAgain {
                pushAgain = false
                push()
            }
        }
    }
}

// MARK: - Solving live

extension BoardSession {
    var isLive: Bool { Live.shared.isLive(record.id) }

    /// What someone else did, solving live.
    func receive(_ message: LiveMessage, from person: LivePerson) {
        guard let board else { return }
        switch message {
        case .hold(let piece, let offset):
            board.showHand(of: person, holding: piece, at: offset)
        case .letGo(let piece):
            board.removeHand(of: person.id, holding: piece)
        case .moved(let theirs):
            let mine = board.pieceStates()
            var merged = mine
            for (index, state) in theirs where merged.indices.contains(index) && (state.t ?? 0) > (merged[index].t ?? 0) {
                merged[index] = state
            }
            guard merged != mine else { return }
            board.apply(merged)
            save(sharing: false)
        case .snapToBoard(let snaps):
            guard snaps != record.snapsToBoard else { return }
            record.snapToBoard = snaps
            board.setSnapsToBoard(snaps)
        case .hello:
            break
        }
    }

    func livePeopleChanged(_ people: Set<UUID>) {
        board?.removeHands(except: people)
    }

    /// Tells everyone live where pieces went since last time.
    private func tellLive(_ board: BoardView) {
        let states = board.pieceStates()
        var moved: [Int: PieceState] = [:]
        for (index, state) in states.enumerated() where toldLive.indices.contains(index) && (state.t ?? 0) != toldLive[index] {
            moved[index] = state
        }
        toldLive = states.map { $0.t ?? 0 }
        if isLive, !moved.isEmpty { Live.shared.send(.moved(moved)) }
    }

    #if DEBUG
    /// Someone to solve with in the simulator, where there's no FaceTime: every so often they pick up a loose
    /// piece, carry it over and put it where it belongs, through the same messages a real partner sends.
    func pretendPartner() {
        let sam = LivePerson(id: UUID(uuidString: "5A3E0000-0000-4000-8000-000000000001")!, name: "Sam Rivera")
        Live.shared.pretend(sam, on: record.id)
        let geometry = renderer.geometry
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, let board = self.board, self.isLive, !self.isSolved else { return }
                let states = board.pieceStates()
                let groups = geometry.groups(states)
                var sizes: [Int: Int] = [:]
                for group in groups.compactMap({ $0 }) { sizes[group, default: 0] += 1 }
                let loners = states.indices.filter { !states[$0].placed && (groups[$0].map { sizes[$0] == 1 } ?? true) }
                guard let piece = loners.randomElement() else { return }
                let home = geometry.home(piece)
                let from = CGPoint(x: states[piece].x - home.x, y: states[piece].y - home.y)
                for step in 0...40 {
                    let t = Double(step) / 40, eased = t * t * (3 - 2 * t)
                    self.receive(.hold(piece: piece, at: CGPoint(x: from.x * (1 - eased), y: from.y * (1 - eased))), from: sam)
                    try? await Task.sleep(for: .milliseconds(33))
                }
                let now = Date().timeIntervalSinceReferenceDate
                let placed = PieceState(x: home.x, y: home.y, placed: self.record.snapsToBoard, z: 0, t: now)
                self.receive(.moved([piece: placed]), from: sam)
                self.receive(.letGo(piece: piece), from: sam)
            }
        }
    }
    #endif
}

extension BoardSession: BoardViewDelegate {
    func boardDidChange(_ board: BoardView) {
        scheduleSave()
        tellLive(board)
    }

    func board(_ board: BoardView, didLift piece: Int, at offset: CGPoint) {
        guard isLive else { return }
        lastCarry = Date()
        Live.shared.send(.hold(piece: piece, at: offset))
    }

    func board(_ board: BoardView, didCarry piece: Int, to offset: CGPoint) {
        // Often enough to look smooth to the others, without flooding the call.
        guard isLive, lastCarry.timeIntervalSinceNow < -1.0 / 30 else { return }
        lastCarry = Date()
        Live.shared.send(.hold(piece: piece, at: offset), quickly: true)
    }

    func board(_ board: BoardView, didLetGo piece: Int) {
        guard isLive else { return }
        Live.shared.send(.letGo(piece: piece))
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

/// A little time to finish something should the app go to the background meanwhile.
@MainActor
private final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(named name: String) {
        // When the time runs out, giving it back is all that's left to do.
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
