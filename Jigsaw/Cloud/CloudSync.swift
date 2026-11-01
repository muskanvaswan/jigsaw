import CloudKit
import UIKit

/// Where a puzzle lives in iCloud.
struct CloudLink: Codable, Equatable {
    var zoneName: String
    var ownerName: String
    /// The person who made the puzzle keeps it in their private database; everyone they shared
    /// it with reaches it through their shared database.
    var isOwner: Bool
    /// Whether anyone else has been invited. Puzzles only went to iCloud when shared before
    /// every puzzle did, so older links leave this out.
    var shared: Bool?

    var isShared: Bool { !isOwner || shared != false }
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
    /// The most time any device has counted on the puzzle since it was last started over.
    var playTime: TimeInterval?
    var restartedAt: Date?
    var collaborators: [Collaborator] = []
}

enum CloudError: LocalizedError {
    case unavailable
    case incomplete

    var errorDescription: String? {
        switch self {
        case .unavailable: "Sign in to iCloud in the Settings app first."
        case .incomplete: "This puzzle couldn't be fully downloaded. Try again in a moment."
        }
    }
}

/// Keeps puzzles in iCloud. Each one is a record zone (shared as a whole with everyone invited, if anyone is)
/// holding the photo and cut ("Puzzle"), where every piece is ("Board"), and one "Player" record per person.
/// The private database's default zone holds your settings ("Preferences": whether to sync every puzzle, and
/// your name for solving together), and a "Deleted"
/// note for each puzzle deleted, so your other devices can tell that apart from sync being switched off.
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

    // MARK: - Keeping puzzles in iCloud

    /// Puts a puzzle in iCloud, unshared. Safe to repeat: if another device already put the same puzzle
    /// there, the pieces are merged. Returns where it lives and the merged pieces.
    func upload(_ puzzle: PuzzleRecord, photo: URL) async throws -> (CloudLink, [PieceState]) {
        guard await isAvailable else { throw CloudError.unavailable }
        let db = container.privateCloudDatabase
        let zone = CKRecordZone(zoneName: Self.zonePrefix + puzzle.id.uuidString)
        _ = try await db.modifyRecordZones(saving: [zone], deleting: [])

        let cut = CKRecord(recordType: "Puzzle", recordID: CKRecord.ID(recordName: "puzzle", zoneID: zone.zoneID))
        cut["rows"] = puzzle.rows
        cut["cols"] = puzzle.cols
        cut["seed"] = Int64(bitPattern: puzzle.seed)
        cut["boardWidth"] = puzzle.boardWidth
        cut["boardHeight"] = puzzle.boardHeight
        cut["createdAt"] = puzzle.createdAt
        cut["photo"] = CKAsset(fileURL: photo)
        let saved = try await db.modifyRecords(saving: [cut], deleting: [], savePolicy: .allKeys).saveResults[cut.recordID]
        if case .failure(let error) = saved { throw error }

        var linked = puzzle
        linked.cloud = CloudLink(zoneName: zone.zoneID.zoneName, ownerName: zone.zoneID.ownerName, isOwner: true, shared: false)
        // Anything remembered about the zone may be from before it was last taken out.
        forget(linked.cloud!)
        let pieces = try await push(linked)
        return (linked.cloud!, pieces)
    }

    /// Returns the share to invite people to, putting the puzzle in iCloud first if it isn't yet.
    func share(_ puzzle: PuzzleRecord, photo: URL, thumbnail: UIImage?) async throws -> (CKShare, CloudLink) {
        guard await isAvailable else { throw CloudError.unavailable }
        var link: CloudLink
        if let existing = puzzle.cloud { link = existing } else { link = try await upload(puzzle, photo: photo).0 }
        link.shared = true

        let db = database(for: link)
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: link.zoneID)
        if let share = try? await db.record(for: shareID) as? CKShare { return (share, link) }
        let share = makeShare(link.zoneID, thumbnail: thumbnail?.jpegData(compressionQuality: 0.7))
        let saved = try await db.modifyRecords(saving: [share], deleting: []).saveResults[share.recordID]
        guard case .success(let record as CKShare) = saved else { throw CloudError.incomplete }
        return (record, link)
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

    /// Puzzles in iCloud with no copy on this device yet: ones others shared with us,
    /// and our own from another device or from before reinstalling.
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

        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let shared = isOwner ? (try? await db.record(for: shareID)) != nil : true
        let link = CloudLink(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName, isOwner: isOwner, shared: shared)
        boards[link.zoneName] = board
        let id = UUID(uuidString: String(zoneID.zoneName.dropFirst(Self.zonePrefix.count))) ?? UUID()
        var puzzle = PuzzleRecord(id: id, createdAt: cut["createdAt"] as? Date ?? Date(), updatedAt: Date(),
                                  rows: rows, cols: cols, seed: UInt64(bitPattern: seed),
                                  boardWidth: width, boardHeight: height, pieces: [],
                                  solvedAt: board["solvedAt"] as? Date,
                                  snapToBoard: (board["snapToBoard"] as? Int).map { $0 != 0 },
                                  cloud: link)
        puzzle.pieces = Self.pieces(of: board) ?? puzzle.geometry.startingPieces()
        puzzle.playTime = board["playTime"] as? Double ?? 0
        puzzle.restartedAt = board["restartedAt"] as? Date
        return (puzzle, photo)
    }

    /// A deleted puzzle: owners take it out of iCloud for everyone, and leave a note so their other
    /// devices delete it too; anyone else just leaves it.
    func remove(_ link: CloudLink) async {
        if link.isOwner {
            let note = CKRecord(recordType: "Deleted", recordID: Self.deletedID(link.zoneName))
            _ = try? await container.privateCloudDatabase.modifyRecords(saving: [note], deleting: [], savePolicy: .allKeys)
            await takeOut(link)
        } else {
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: link.zoneID)
            _ = try? await container.sharedCloudDatabase.modifyRecords(saving: [], deleting: [shareID])
            forget(link)
        }
    }

    /// Takes one of your puzzles out of iCloud, leaving the copies on your devices alone.
    @discardableResult
    func takeOut(_ link: CloudLink) async -> Bool {
        guard link.isOwner else { return false }
        do {
            _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [link.zoneID])
        } catch {
            guard Self.isGone(error) else { return false }
        }
        forget(link)
        return true
    }

    /// Whether one of your puzzles missing from iCloud was deleted on another device, rather than
    /// taken out when sync was switched off. Nil when iCloud can't say.
    func wasDeleted(_ link: CloudLink) async -> Bool? {
        do {
            _ = try await container.privateCloudDatabase.record(for: Self.deletedID(link.zoneName))
            return true
        } catch let error as CKError where error.code == .unknownItem {
            return false
        } catch {
            return nil
        }
    }

    /// The puzzle's zone no longer exists: deleted, or taken out of iCloud.
    static func isGone(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        if [.zoneNotFound, .userDeletedZone].contains(error.code) { return true }
        return error.partialErrorsByItemID?.values.contains { isGone($0) } ?? false
    }

    private func forget(_ link: CloudLink) {
        boards[link.zoneName] = nil
        tokens[link.zoneName] = nil
        players[link.zoneName] = nil
    }

    private static func deletedID(_ zoneName: String) -> CKRecord.ID { CKRecord.ID(recordName: "deleted-" + zoneName) }

    // MARK: - Preferences

    /// One record for all your devices. Each setting is saved on its own, leaving the others as they are.
    private static let preferencesID = CKRecord.ID(recordName: "preferences")

    /// Whether every puzzle should go to iCloud. One setting for all your devices. Nil when iCloud can't say.
    func syncsAll() async -> Bool? {
        do {
            let record = try await container.privateCloudDatabase.record(for: Self.preferencesID)
            return (record["syncAll"] as? Int).map { $0 != 0 } ?? true
        } catch let error as CKError where error.code == .unknownItem {
            return true
        } catch {
            return nil
        }
    }

    func setSyncsAll(_ on: Bool) async throws {
        guard await isAvailable else { throw CloudError.unavailable }
        let record = CKRecord(recordType: "Preferences", recordID: Self.preferencesID)
        record["syncAll"] = on ? 1 : 0
        let saved = try await container.privateCloudDatabase.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
            .saveResults[record.recordID]
        if case .failure(let error) = saved { throw error }
    }

    /// The name you go by when solving together, as last saved from any of your devices. Nil if none was.
    func savedName() async throws -> String? {
        do {
            let record = try await container.privateCloudDatabase.record(for: Self.preferencesID)
            return (record["name"] as? String)?.nilIfEmpty
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    func saveName(_ name: String) async {
        let record = CKRecord(recordType: "Preferences", recordID: Self.preferencesID)
        record["name"] = name
        _ = try? await container.privateCloudDatabase.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
    }

    // MARK: - Syncing

    /// Saves where every piece is, folding in whatever someone else saved meanwhile.
    /// Returns the merged pieces, which may include their moves.
    func push(_ puzzle: PuzzleRecord) async throws -> [PieceState] {
        guard let link = puzzle.cloud else { return puzzle.pieces }
        let db = database(for: link)
        let id = CKRecord.ID(recordName: "board", zoneID: link.zoneID)
        var record: CKRecord
        if let known = boards[link.zoneName] {
            record = known
        } else {
            do {
                record = try await db.record(for: id)
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: "Board", recordID: id)
            }
        }

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

    /// Everything that changed in a puzzle since the last look, plus who has been here.
    func changes(in link: CloudLink) async throws -> CloudChanges {
        let db = database(for: link)
        var changes = CloudChanges()
        var token = tokens[link.zoneName]
        var moreComing = true
        while moreComing {
            let result: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                         deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                result = try await db.recordZoneChanges(inZoneWith: link.zoneID, since: token,
                                                        desiredKeys: ["pieces", "snapToBoard", "solvedAt", "playTime", "restartedAt", "name", "seenAt"])
            } catch let error as CKError where error.code == .changeTokenExpired && token != nil {
                // The zone was taken out of iCloud and put back since the last look: read it all again.
                token = nil
                continue
            }
            for case .success(let modification) in result.modificationResultsByID.values {
                let record = modification.record
                switch record.recordType {
                case "Board":
                    boards[link.zoneName] = record
                    changes.pieces = Self.pieces(of: record)
                    changes.snapToBoard = (record["snapToBoard"] as? Int).map { $0 != 0 }
                    changes.solvedAt = record["solvedAt"] as? Date
                    changes.playTime = record["playTime"] as? Double
                    changes.restartedAt = record["restartedAt"] as? Date
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
        var clock = puzzle
        clock.takeClock(record["playTime"] as? Double, restartedAt: record["restartedAt"] as? Date)
        record["playTime"] = clock.playTime
        record["restartedAt"] = clock.restartedAt
    }

    private static func pieces(of record: CKRecord) -> [PieceState]? {
        guard let packed = record["pieces"] as? Data,
              let json = try? (packed as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? JSONDecoder().decode([PieceState].self, from: json)
    }
}
