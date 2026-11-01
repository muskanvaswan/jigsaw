import CoreGraphics
import Foundation

/// Where one piece is. Loose pieces keep their table position and `z` is their stacking order.
/// Joined pieces need no extra bookkeeping: they lie at exactly the same offset from where they belong.
struct PieceState: Codable, Equatable {
    var x: Double
    var y: Double
    var placed: Bool
    var z: Int
    /// When the piece last moved (seconds since 2001), so two people's edits can be merged piece by piece.
    var t: Double?

    /// Two versions of the same puzzle combined: for every piece, whichever moved last wins.
    static func merge(_ mine: [PieceState], _ theirs: [PieceState]) -> [PieceState] {
        guard mine.count == theirs.count else { return theirs.isEmpty ? mine : theirs }
        return zip(mine, theirs).map { ($1.t ?? 0) > ($0.t ?? 0) ? $1 : $0 }
    }

    /// Whether `newer` holds any move that `older` hasn't seen.
    static func hasNewer(_ newer: [PieceState], than older: [PieceState]) -> Bool {
        guard newer.count == older.count else { return !newer.isEmpty }
        return zip(newer, older).contains { ($0.t ?? 0) > ($1.t ?? 0) }
    }
}

/// Everything saved about a puzzle besides its photo.
struct PuzzleRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var rows: Int
    var cols: Int
    var seed: UInt64
    var boardWidth: Double
    var boardHeight: Double
    var pieces: [PieceState]
    var playTime: TimeInterval = 0
    /// When the puzzle was last started over, which resets the clock on every device.
    var restartedAt: Date?
    var solvedAt: Date?
    /// Whether pieces lock into their spot on the board, or only to the pieces beside them.
    /// Puzzles saved before this was a choice have no value and snap to the board.
    var snapToBoard: Bool?
    /// Set once the puzzle is in iCloud.
    var cloud: CloudLink?
    /// Whether loose pieces were last laid out in rows rather than heaped up.
    var spreadOut: Bool?

    var snapsToBoard: Bool { snapToBoard ?? true }
    var pieceCount: Int { rows * cols }
    var isSolved: Bool { solvedAt != nil }

    /// Pieces that are done: locked into the board, or joined to at least one neighbour.
    var finishedPieces: [Bool] {
        let groups = geometry.groups(pieces)
        var sizes: [Int: Int] = [:]
        for group in groups.compactMap({ $0 }) { sizes[group, default: 0] += 1 }
        return pieces.indices.map { pieces[$0].placed || (groups[$0].map { sizes[$0, default: 0] > 1 } ?? false) }
    }

    var progressCount: Int { finishedPieces.reduce(0) { $0 + ($1 ? 1 : 0) } }
    var progress: Double { pieceCount == 0 ? 0 : Double(progressCount) / Double(pieceCount) }

    var geometry: PuzzleGeometry {
        PuzzleGeometry(rows: rows, cols: cols, boardSize: CGSize(width: boardWidth, height: boardHeight), seed: seed)
    }

    /// Folds in another device's clock: starting over anywhere resets it everywhere, and otherwise the
    /// puzzle has been played for as long as whichever device has counted most. Returns whether it changed.
    @discardableResult
    mutating func takeClock(_ playTime: TimeInterval?, restartedAt: Date?) -> Bool {
        guard let playTime else { return false }
        let mine = self.restartedAt ?? .distantPast, theirs = restartedAt ?? .distantPast
        if theirs > mine {
            self.restartedAt = restartedAt
            self.playTime = playTime
            return true
        }
        guard theirs == mine, playTime > self.playTime else { return false }
        self.playTime = playTime
        return true
    }
}
