import CloudKit
import UIKit

/// Where a shared puzzle lives in iCloud.
struct CloudLink: Codable, Equatable {
    var zoneName: String
    var ownerName: String
    /// The person who shared the puzzle keeps it in their private database; everyone else
    /// reaches it through their shared database.
    var isOwner: Bool

    var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName) }
}

/// Someone else solving a shared puzzle.
struct Collaborator: Identifiable, Equatable {
    let id: String
    let name: String
    let seenAt: Date

    /// Had the puzzle open within the last minute.
    var isHere: Bool { seenAt.timeIntervalSinceNow > -60 }
}

/// What changed in a shared puzzle since this device last looked.
struct CloudChanges {
    var pieces: [PieceState]?
    var snapToBoard: Bool?
    var solvedAt: Date?
    var collaborators: [Collaborator] = []
}

enum CloudError: LocalizedError {
    case unavailable
    case incomplete

    var errorDescription: String? {
        switch self {
        case .unavailable: "Sign in to iCloud in Settings to share puzzles."
        case .incomplete: "This puzzle couldn't be fully downloaded. Try again in a moment."
        }
    }
}

/// Keeps shared puzzles in iCloud. Each one is a record zone shared as a whole with everyone invited,
/// holding the photo and cut ("Puzzle"), where every piece is ("Board"), and one "Player" record per person.
@MainActor
final class CloudSync {
    static let shared = CloudSync()

    let container = CKContainer(identifier: "iCloud.com.vaswan.jigsaw")

    /// The newest known copy of each puzzle's board, so saves don't trip over our own earlier saves.
    private var boards: [String: CKRecord] = [:]
    /// How far each puzzle's changes have been read.
    private var tokens: [String: CKServerChangeToken] = [:]
    private var players: [String: [String: Collaborator]] = [:]
    private var myRecordName: String?

    private static let zonePrefix = "puzzle-"

    func database(for link: CloudLink) -> CKDatabase {
        link.isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    var isAvailable: Bool {
        get async { (try? await container.accountStatus()) == .available }
    }

    // MARK: - Sharing

    /// Puts a puzzle in iCloud the first time it's shared, and returns the share to invite people to.
    func share(_ puzzle: PuzzleRecord, photo: URL, thumbnail: UIImage?) async throws -> (CKShare, CloudLink) {
        guard await isAvailable else { throw CloudError.unavailable }
        let thumbnailData = thumbnail?.jpegData(compressionQuality: 0.7)

        if let link = puzzle.cloud {
            let db = database(for: link)
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: link.zoneID)
            if let share = try? await db.record(for: shareID) as? CKShare { return (share, link) }
            // The owner stopped sharing earlier; share the same puzzle again.
            let share = makeShare(link.zoneID, thumbnail: thumbnailData)
            let saved = try await db.modifyRecords(saving: [share], deleting: []).saveResults[share.recordID]
            guard case .success(let record as CKShare) = saved else { throw CloudError.incomplete }
            return (record, link)
        }

        let db = container.privateCloudDatabase
        let zone = CKRecordZone(zoneName: Self.zonePrefix + puzzle.id.uuidString)
        _ = try await db.modifyRecordZones(saving: [zone], deleting: [])
        let link = CloudLink(zoneName: zone.zoneID.zoneName, ownerName: zone.zoneID.ownerName, isOwner: true)

        let cut = CKRecord(recordType: "Puzzle", recordID: CKRecord.ID(recordName: "puzzle", zoneID: zone.zoneID))
        cut["rows"] = puzzle.rows
        cut["cols"] = puzzle.cols
        cut["seed"] = Int64(bitPattern: puzzle.seed)
        cut["boardWidth"] = puzzle.boardWidth
        cut["boardHeight"] = puzzle.boardHeight
        cut["createdAt"] = puzzle.createdAt
        cut["photo"] = CKAsset(fileURL: photo)

        let board = CKRecord(recordType: "Board", recordID: CKRecord.ID(recordName: "board", zoneID: zone.zoneID))
        fill(board, pieces: puzzle.pieces, from: puzzle)

        let share = makeShare(zone.zoneID, thumbnail: thumbnailData)
        let results = try await db.modifyRecords(saving: [cut, board, share], deleting: []).saveResults
        for result in results.values { if case .failure(let error) = result { throw error } }
        if case .success(let saved) = results[board.recordID] { boards[link.zoneName] = saved }
        guard case .success(let saved as CKShare) = results[share.recordID] else { throw CloudError.incomplete }
        return (saved, link)
    }

    private func makeShare(_ zoneID: CKRecordZone.ID, thumbnail: Data?) -> CKShare {
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = "Jigsaw puzzle" as CKRecordValue
        if let thumbnail { share[CKShare.SystemFieldKey.thumbnailImageData] = thumbnail as CKRecordValue }
        share.publicPermission = .none
        return share
    }

    /// Joins a puzzle someone shared, and downloads it.
    func accept(_ metadata: CKShare.Metadata) async throws -> (PuzzleRecord, Data) {
        let zoneID = metadata.share.recordID.zoneID
        if metadata.participantRole == .owner {
            return try await download(zoneID, isOwner: true)
        }
        _ = try await container.accept(metadata)
        return try await download(zoneID, isOwner: false)
    }

    /// Shared puzzles in iCloud with no copy on this device yet: ones others shared with us,
    /// and our own after reinstalling or on another iPad.
    func missingPuzzles(known: Set<String>) async -> [(PuzzleRecord, Data)] {
        guard await isAvailable else { return [] }
        var found: [(PuzzleRecord, Data)] = []
        for (db, isOwner) in [(container.sharedCloudDatabase, false), (container.privateCloudDatabase, true)] {
            guard let zones = try? await db.allRecordZones() else { continue }
            for zone in zones where zone.zoneID.zoneName.hasPrefix(Self.zonePrefix) && !known.contains(zone.zoneID.zoneName) {
                if let puzzle = try? await download(zone.zoneID, isOwner: isOwner) { found.append(puzzle) }
            }
        }
        return found
    }

    private func download(_ zoneID: CKRecordZone.ID, isOwner: Bool) async throws -> (PuzzleRecord, Data) {
        let db = isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase
        let cutID = CKRecord.ID(recordName: "puzzle", zoneID: zoneID)
        let boardID = CKRecord.ID(recordName: "board", zoneID: zoneID)
        let results = try await db.records(for: [cutID, boardID])
        guard case .success(let cut) = results[cutID], case .success(let board) = results[boardID],
              let rows = cut["rows"] as? Int, let cols = cut["cols"] as? Int, let seed = cut["seed"] as? Int64,
              let width = cut["boardWidth"] as? Double, let height = cut["boardHeight"] as? Double,
              let photoURL = (cut["photo"] as? CKAsset)?.fileURL,
              let photo = try? Data(contentsOf: photoURL)
        else { throw CloudError.incomplete }

        let link = CloudLink(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName, isOwner: isOwner)
        boards[link.zoneName] = board
        let id = UUID(uuidString: String(zoneID.zoneName.dropFirst(Self.zonePrefix.count))) ?? UUID()
        var puzzle = PuzzleRecord(id: id, createdAt: cut["createdAt"] as? Date ?? Date(), updatedAt: Date(),
                                  rows: rows, cols: cols, seed: UInt64(bitPattern: seed),
                                  boardWidth: width, boardHeight: height, pieces: [],
                                  solvedAt: board["solvedAt"] as? Date,
                                  snapToBoard: (board["snapToBoard"] as? Int).map { $0 != 0 },
                                  cloud: link)
        puzzle.pieces = Self.pieces(of: board) ?? puzzle.geometry.startingPieces()
        return (puzzle, photo)
    }

    /// Owners take the puzzle out of iCloud for everyone; anyone else just leaves it.
    func remove(_ link: CloudLink) async {
        if link.isOwner {
            _ = try? await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [link.zoneID])
        } else {
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: link.zoneID)
            _ = try? await container.sharedCloudDatabase.modifyRecords(saving: [], deleting: [shareID])
        }
        boards[link.zoneName] = nil
        tokens[link.zoneName] = nil
    }

    // MARK: - Syncing

    /// Saves where every piece is, folding in whatever someone else saved meanwhile.
    /// Returns the merged pieces, which may include their moves.
    func push(_ puzzle: PuzzleRecord) async throws -> [PieceState] {
        guard let link = puzzle.cloud else { return puzzle.pieces }
        let db = database(for: link)
        let id = CKRecord.ID(recordName: "board", zoneID: link.zoneID)
        var record: CKRecord
        if let known = boards[link.zoneName] { record = known } else { record = try await db.record(for: id) }

        var pieces = puzzle.pieces
        for _ in 0..<4 {
            pieces = PieceState.merge(pieces, Self.pieces(of: record) ?? [])
            fill(record, pieces: pieces, from: puzzle)
            let result = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged).saveResults[id]
            switch result {
            case .success(let saved):
                boards[link.zoneName] = saved
                return pieces
            case .failure(let error as CKError) where error.code == .serverRecordChanged:
                guard let newer = error.serverRecord else { throw error }
                record = newer
            case .failure(let error):
                throw error
            case nil:
                return pieces
            }
        }
        return pieces
    }

    /// Everything that changed in a shared puzzle since the last look, plus who has been here.
    func changes(in link: CloudLink) async throws -> CloudChanges {
        let db = database(for: link)
        var changes = CloudChanges()
        var token = tokens[link.zoneName]
        var moreComing = true
        while moreComing {
            let result = try await db.recordZoneChanges(inZoneWith: link.zoneID, since: token,
                                                        desiredKeys: ["pieces", "snapToBoard", "solvedAt", "name", "seenAt"])
            for case .success(let modification) in result.modificationResultsByID.values {
                let record = modification.record
                switch record.recordType {
                case "Board":
                    boards[link.zoneName] = record
                    changes.pieces = Self.pieces(of: record)
                    changes.snapToBoard = (record["snapToBoard"] as? Int).map { $0 != 0 }
                    changes.solvedAt = record["solvedAt"] as? Date
                case "Player":
                    let person = Collaborator(id: record.recordID.recordName, name: record["name"] as? String ?? "Someone",
                                              seenAt: record["seenAt"] as? Date ?? .distantPast)
                    players[link.zoneName, default: [:]][person.id] = person
                default:
                    break
                }
            }
            token = result.changeToken
            moreComing = result.moreComing
        }
        tokens[link.zoneName] = token
        let me = await myPlayerID()
        changes.collaborators = players[link.zoneName, default: [:]].values
            .filter { $0.id != me }
            .sorted { $0.seenAt > $1.seenAt }
        return changes
    }

    /// Lets the others know you have the puzzle open, and under what name.
    func checkIn(_ link: CloudLink, name: String) async {
        guard let me = await myPlayerID() else { return }
        let record = CKRecord(recordType: "Player", recordID: CKRecord.ID(recordName: me, zoneID: link.zoneID))
        record["name"] = name
        record["seenAt"] = Date()
        _ = try? await database(for: link).modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    private func myPlayerID() async -> String? {
        if myRecordName == nil { myRecordName = try? await container.userRecordID().recordName }
        return myRecordName.map { "player-" + $0 }
    }

    private func fill(_ record: CKRecord, pieces: [PieceState], from puzzle: PuzzleRecord) {
        if let json = try? JSONEncoder().encode(pieces), let packed = try? (json as NSData).compressed(using: .lzfse) {
            record["pieces"] = packed as Data
        }
        record["snapToBoard"] = puzzle.snapsToBoard ? 1 : 0
        record["solvedAt"] = puzzle.solvedAt
    }

    private static func pieces(of record: CKRecord) -> [PieceState]? {
        guard let packed = record["pieces"] as? Data,
              let json = try? (packed as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? JSONDecoder().decode([PieceState].self, from: json)
    }
}
