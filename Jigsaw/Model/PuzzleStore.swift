import CloudKit
import Observation
import UIKit

/// All puzzles on this device. Each lives in its own folder under Application Support:
/// `photo.jpg`, `puzzle.json` (piece positions and progress) and `thumbnail.png`.
@MainActor
@Observable
final class PuzzleStore {
    private(set) var puzzles: [PuzzleRecord] = []
    private(set) var thumbnails: [UUID: UIImage] = [:]
    /// Whether every puzzle goes to iCloud while you're signed in, so it follows you to your other devices.
    /// One setting for all your devices, kept in iCloud and remembered here for when it can't be reached.
    private(set) var syncsAll = UserDefaults.standard.object(forKey: PuzzleStore.syncsAllKey) as? Bool ?? true

    @ObservationIgnored private let root: URL
    @ObservationIgnored private let disk = DispatchQueue(label: "PuzzleStore.disk", qos: .utility)
    @ObservationIgnored private var uploading: Set<UUID> = []
    private static let syncsAllKey = "sync.all"

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Puzzles", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    func record(_ id: UUID) -> PuzzleRecord? {
        puzzles.first { $0.id == id }
    }

    func photoURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("photo.jpg") }
    private func recordURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("puzzle.json") }
    private func thumbnailURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("thumbnail.png") }
    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func load() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        puzzles = folders
            .compactMap { folder in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("puzzle.json")) else { return nil }
                return try? decoder.decode(PuzzleRecord.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }

        let wanted = puzzles.map { ($0.id, thumbnailURL($0.id)) }
        disk.async { [weak self] in
            for (id, url) in wanted {
                guard let image = UIImage(contentsOfFile: url.path) else { continue }
                DispatchQueue.main.async {
                    if self?.thumbnails[id] == nil { self?.thumbnails[id] = image }
                }
            }
        }
    }

    /// Cuts a new puzzle from `photo` and saves it. Returns its id.
    func create(photo: UIImage, rows: Int, cols: Int, seed: UInt64, snapToBoard: Bool) async -> UUID? {
        let id = UUID()
        let folder = folder(id), photoURL = photoURL(id), recordURL = recordURL(id), thumbnailURL = thumbnailURL(id)

        let made = await Task.detached(priority: .userInitiated) { () -> (PuzzleRecord, UIImage)? in
            let sized = PhotoPrep.prepare(photo, longSide: PhotoPrep.longSide(forPieces: rows * cols))
            guard let jpeg = sized.jpegData(compressionQuality: 0.92) else { return nil }
            let geometry = PuzzleGeometry(rows: rows, cols: cols, boardSize: sized.size, seed: seed)
            let now = Date()
            let record = PuzzleRecord(id: id, createdAt: now, updatedAt: now, rows: rows, cols: cols, seed: seed,
                                      boardWidth: sized.size.width, boardHeight: sized.size.height,
                                      pieces: geometry.startingPieces(), snapToBoard: snapToBoard)
            let thumbnail = Thumbnail.render(photo: sized, geometry: geometry, finished: record.finishedPieces)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try jpeg.write(to: photoURL, options: .atomic)
                try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
                try thumbnail.pngData()?.write(to: thumbnailURL, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                return nil
            }
            return (record, thumbnail)
        }.value

        guard let (record, thumbnail) = made else { return nil }
        puzzles.insert(record, at: 0)
        thumbnails[id] = thumbnail
        return id
    }

    func save(_ record: PuzzleRecord) {
        guard let index = puzzles.firstIndex(where: { $0.id == record.id }) else { return }
        puzzles[index] = record
        puzzles.sort { $0.updatedAt > $1.updatedAt }
        guard let data = try? JSONEncoder().encode(record) else { return }
        let url = recordURL(record.id)
        // Writing into a folder that was deleted meanwhile simply fails, which is what we want.
        disk.async { try? data.write(to: url, options: .atomic) }
    }

    func saveThumbnail(_ image: UIImage, for id: UUID) {
        guard record(id) != nil else { return }
        thumbnails[id] = image
        let url = thumbnailURL(id)
        disk.async { try? image.pngData()?.write(to: url, options: .atomic) }
    }

    /// Heaps every piece up again and resets the clock (for everyone, if the puzzle is shared).
    func restart(_ id: UUID) {
        guard var record = record(id) else { return }
        let geometry = record.geometry
        let now = Date().timeIntervalSinceReferenceDate
        record.pieces = geometry.startingPieces().map { var piece = $0; piece.t = now; return piece }
        record.playTime = 0
        record.restartedAt = Date()
        record.solvedAt = nil
        record.spreadOut = nil
        record.updatedAt = Date()
        save(record)
        if record.cloud != nil {
            Task { _ = try? await CloudSync.shared.push(record) }
        }

        let photoURL = photoURL(id)
        disk.async { [weak self] in
            guard let photo = UIImage(contentsOfFile: photoURL.path) else { return }
            let thumbnail = Thumbnail.render(photo: photo, geometry: geometry, finished: Array(repeating: false, count: geometry.count))
            DispatchQueue.main.async { self?.saveThumbnail(thumbnail, for: id) }
        }
    }

    /// Deleting a puzzle in iCloud also takes it out for you and anyone you shared it with if it's yours,
    /// or leaves it if it isn't.
    func delete(_ id: UUID) {
        if let link = record(id)?.cloud {
            Task { await CloudSync.shared.remove(link) }
        }
        removeLocally(id)
    }

    private func removeLocally(_ id: UUID) {
        puzzles.removeAll { $0.id == id }
        thumbnails[id] = nil
        let folder = folder(id)
        disk.async { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: - iCloud

    /// Brings everything up to date with iCloud: moves made elsewhere, puzzles from your other devices or shared
    /// with you, and, when you're signed in, any puzzle only on this device so far. Skips the one open on screen,
    /// which keeps itself up to date.
    func catchUp(signedIn: Bool, except openID: UUID?) async {
        if signedIn, let on = await CloudSync.shared.syncsAll() { remember(on) }
        await refreshShared(except: openID)
        if signedIn, syncsAll { await backUpAll() }
    }

    /// Switches syncing every puzzle on or off, for all your devices. Off takes your puzzles out of iCloud to
    /// free up space, keeping the copies on your devices; shared puzzles stay so others can carry on.
    func setSyncsAll(_ on: Bool) async throws {
        try await CloudSync.shared.setSyncsAll(on)
        remember(on)
        guard !on else {
            await backUpAll()
            return
        }
        // First bring over anything that's only on your other devices, so this one keeps a copy of everything.
        await refreshShared(except: nil)
        for record in puzzles {
            guard let link = record.cloud, link.isOwner, !link.isShared else { continue }
            if await CloudSync.shared.takeOut(link) { unlink(record.id) }
        }
    }

    private func remember(_ on: Bool) {
        syncsAll = on
        UserDefaults.standard.set(on, forKey: Self.syncsAllKey)
    }

    /// Puts a puzzle that's only on this device into iCloud.
    func backUp(_ id: UUID) async {
        guard let record = record(id), record.cloud == nil, uploading.insert(id).inserted else { return }
        defer { uploading.remove(id) }
        guard let (link, pieces) = try? await CloudSync.shared.upload(record, photo: photoURL(id)) else { return }
        guard var latest = self.record(id) else {
            // Deleted while it was uploading.
            await CloudSync.shared.remove(link)
            return
        }
        // Sharing it meanwhile put it in iCloud too, and knows it's shared.
        if latest.cloud == nil { latest.cloud = link }
        latest.pieces = PieceState.merge(latest.pieces, pieces)
        save(latest)
    }

    private func backUpAll() async {
        for record in puzzles where record.cloud == nil { await backUp(record.id) }
    }

    private func unlink(_ id: UUID) {
        guard var record = record(id) else { return }
        record.cloud = nil
        save(record)
    }

    /// One of your puzzles is no longer in iCloud. Deleted on another device: delete it here too. Taken out
    /// when sync was switched off, or not in the iCloud account signed in now: keep it here, unlinked.
    private func lost(_ id: UUID, link: CloudLink) async {
        guard let deleted = await CloudSync.shared.wasDeleted(link) else { return }
        if deleted { removeLocally(id) } else { unlink(id) }
    }

    /// Puts the puzzle in iCloud if it isn't yet, and returns the share to invite people with.
    func share(_ id: UUID) async throws -> CKShare {
        guard var record = record(id) else { throw CloudError.incomplete }
        let (share, link) = try await CloudSync.shared.share(record, photo: photoURL(id), thumbnail: thumbnails[id])
        if record.cloud != link {
            record.cloud = link
            save(record)
        }
        return share
    }

    /// Opens an invitation: downloads the puzzle unless it's already here. Returns its id.
    func accept(_ invitation: CKShare.Metadata) async throws -> UUID {
        let zoneName = invitation.share.recordID.zoneID.zoneName
        if let existing = puzzles.first(where: { $0.cloud?.zoneName == zoneName }) { return existing.id }
        let (record, photo) = try await CloudSync.shared.accept(invitation)
        await add(record, photo: photo)
        return record.id
    }

    /// Catches up with puzzles in iCloud: moves made on other devices or by others while you were away,
    /// and puzzles shared with you (or yours from another device) that aren't here yet.
    private func refreshShared(except openID: UUID?) async {
        for record in puzzles where record.cloud != nil && record.id != openID {
            guard let link = record.cloud else { continue }
            let changes: CloudChanges
            do {
                changes = try await CloudSync.shared.changes(in: link)
            } catch {
                if link.isOwner, CloudSync.isGone(error) { await lost(record.id, link: link) }
                continue
            }
            guard var latest = self.record(record.id) else { continue }
            var changed = false
            if (changes.restartedAt ?? .distantPast) > (latest.restartedAt ?? .distantPast) {
                // Started over on another device.
                latest.solvedAt = changes.solvedAt
                latest.spreadOut = nil
                changed = true
            }
            if latest.takeClock(changes.playTime, restartedAt: changes.restartedAt) { changed = true }
            if let theirs = changes.pieces, PieceState.hasNewer(theirs, than: latest.pieces) {
                latest.pieces = PieceState.merge(latest.pieces, theirs)
                changed = true
            }
            if let snaps = changes.snapToBoard, snaps != latest.snapsToBoard {
                latest.snapToBoard = snaps
                changed = true
            }
            if latest.solvedAt == nil, let solved = changes.solvedAt {
                latest.solvedAt = solved
                changed = true
            }
            guard changed else { continue }
            latest.updatedAt = Date()
            save(latest)
            refreshThumbnail(latest)
        }

        let known = Set(puzzles.compactMap { $0.cloud?.zoneName })
        for (record, photo) in await CloudSync.shared.missingPuzzles(known: known) where self.record(record.id) == nil {
            await add(record, photo: photo)
        }
    }

    private func add(_ record: PuzzleRecord, photo: Data) async {
        let folder = folder(record.id), photoURL = photoURL(record.id), recordURL = recordURL(record.id)
        let thumbnailURL = thumbnailURL(record.id)
        let thumbnail = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let image = UIImage(data: photo), let json = try? JSONEncoder().encode(record) else { return nil }
            let thumbnail = Thumbnail.render(photo: image, geometry: record.geometry, finished: record.finishedPieces)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try photo.write(to: photoURL, options: .atomic)
                try json.write(to: recordURL, options: .atomic)
                try thumbnail.pngData()?.write(to: thumbnailURL, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                return nil
            }
            return thumbnail
        }.value
        guard let thumbnail, self.record(record.id) == nil else { return }
        puzzles.insert(record, at: 0)
        thumbnails[record.id] = thumbnail
    }

    private func refreshThumbnail(_ record: PuzzleRecord) {
        let photoURL = photoURL(record.id)
        disk.async { [weak self] in
            guard let photo = UIImage(contentsOfFile: photoURL.path) else { return }
            let thumbnail = Thumbnail.render(photo: photo, geometry: record.geometry, finished: record.finishedPieces)
            DispatchQueue.main.async { self?.saveThumbnail(thumbnail, for: record.id) }
        }
    }
}
