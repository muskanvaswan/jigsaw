import Observation
import UIKit

/// All puzzles on this device. Each lives in its own folder under Application Support:
/// `photo.jpg`, `puzzle.json` (piece positions and progress) and `thumbnail.png`.
@Observable
final class PuzzleStore {
    private(set) var puzzles: [PuzzleRecord] = []
    private(set) var thumbnails: [UUID: UIImage] = [:]

    @ObservationIgnored private let root: URL
    @ObservationIgnored private let disk = DispatchQueue(label: "PuzzleStore.disk", qos: .utility)

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

    /// Scatters every piece again and resets the clock.
    func restart(_ id: UUID) {
        guard var record = record(id) else { return }
        let geometry = record.geometry
        record.pieces = geometry.startingPieces()
        record.playTime = 0
        record.solvedAt = nil
        record.updatedAt = Date()
        save(record)

        let photoURL = photoURL(id)
        disk.async { [weak self] in
            guard let photo = UIImage(contentsOfFile: photoURL.path) else { return }
            let thumbnail = Thumbnail.render(photo: photo, geometry: geometry, finished: Array(repeating: false, count: geometry.count))
            DispatchQueue.main.async { self?.saveThumbnail(thumbnail, for: id) }
        }
    }

    func delete(_ id: UUID) {
        puzzles.removeAll { $0.id == id }
        thumbnails[id] = nil
        let folder = folder(id)
        disk.async { try? FileManager.default.removeItem(at: folder) }
    }
}
