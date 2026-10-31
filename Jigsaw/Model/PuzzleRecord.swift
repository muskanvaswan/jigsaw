import CoreGraphics
import Foundation

/// Where one piece is. Loose pieces keep their table position; `z` is their stacking order,
/// and loose pieces that share a `z` have been joined into one group.
struct PieceState: Codable, Equatable {
    var x: Double
    var y: Double
    var placed: Bool
    var z: Int
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
    var solvedAt: Date?
    /// Whether pieces lock into their spot on the board, or only to the pieces beside them.
    /// Puzzles saved before this was a choice have no value and snap to the board.
    var snapToBoard: Bool?

    var snapsToBoard: Bool { snapToBoard ?? true }
    var pieceCount: Int { rows * cols }
    var isSolved: Bool { solvedAt != nil }

    /// Pieces that are done: locked into the board, or joined to at least one neighbour.
    var finishedPieces: [Bool] {
        zip(pieces, Self.joined(pieces)).map { $0.placed || $1 }
    }

    var progressCount: Int { finishedPieces.reduce(0) { $0 + ($1 ? 1 : 0) } }
    var progress: Double { pieceCount == 0 ? 0 : Double(progressCount) / Double(pieceCount) }

    var geometry: PuzzleGeometry {
        PuzzleGeometry(rows: rows, cols: cols, boardSize: CGSize(width: boardWidth, height: boardHeight), seed: seed)
    }

    /// Loose pieces that are part of a group of two or more.
    static func joined(_ pieces: [PieceState]) -> [Bool] {
        var sizes: [Int: Int] = [:]
        for piece in pieces where !piece.placed { sizes[piece.z, default: 0] += 1 }
        return pieces.map { !$0.placed && sizes[$0.z, default: 0] > 1 }
    }
}
