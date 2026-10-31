import CoreGraphics
import Foundation

/// Deterministic generator, so a puzzle's piece shapes come out identical every time it's opened.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform value in `-range...range`, computed by hand so it never changes between Swift versions.
    mutating func jitter(_ range: CGFloat) -> CGFloat {
        let unit = CGFloat(next() >> 11) / CGFloat(1 << 53)
        return (unit * 2 - 1) * range
    }
}

/// The cut pattern of one puzzle: where every piece belongs and what its outline looks like.
/// Board coordinates are the pixels of the prepared photo, with the board's top-left corner at the origin.
struct PuzzleGeometry {
    let rows: Int
    let cols: Int
    let boardSize: CGSize
    let cellSize: CGSize
    /// Reference length for knobs, so they stay round even when cells aren't perfectly square.
    let unit: CGFloat
    /// Blur of the soft shadow baked into loose pieces.
    let shadowRadius: CGFloat
    /// Room around each cell for its knobs and shadow.
    let padding: CGFloat

    private let horizontalCuts: [Cut]   // below row r, at column c: r * cols + c
    private let verticalCuts: [Cut]     // right of column c, at row r: r * (cols - 1) + c

    /// One shared edge between two neighbouring pieces. `side` says which way the knob points.
    private struct Cut {
        var side: CGFloat
        var a, b, c, d, e: CGFloat
    }

    private static let knob: CGFloat = 0.1
    private static let jitter: CGFloat = 0.04

    init(rows: Int, cols: Int, boardSize: CGSize, seed: UInt64) {
        self.rows = rows
        self.cols = cols
        self.boardSize = boardSize
        cellSize = CGSize(width: boardSize.width / CGFloat(cols), height: boardSize.height / CGFloat(rows))
        unit = min(cellSize.width, cellSize.height)
        shadowRadius = min(max(unit * 0.04, 2), 10)
        padding = (unit * 0.36 + shadowRadius * 2.5).rounded(.up)

        var rng = SeededGenerator(seed: seed)
        horizontalCuts = Self.makeCuts((rows - 1) * cols, using: &rng)
        verticalCuts = Self.makeCuts(rows * (cols - 1), using: &rng)
    }

    private static func makeCuts(_ count: Int, using rng: inout SeededGenerator) -> [Cut] {
        var cuts: [Cut] = []
        cuts.reserveCapacity(max(count, 0))
        for _ in 0..<max(count, 0) {
            let side: CGFloat = rng.next() & 1 == 0 ? 1 : -1
            cuts.append(Cut(side: side,
                            a: rng.jitter(jitter), b: rng.jitter(jitter), c: rng.jitter(jitter),
                            d: rng.jitter(jitter), e: rng.jitter(jitter)))
        }
        return cuts
    }

    var count: Int { rows * cols }

    func cell(_ index: Int) -> CGRect {
        CGRect(x: CGFloat(index % cols) * cellSize.width,
               y: CGFloat(index / cols) * cellSize.height,
               width: cellSize.width, height: cellSize.height)
    }

    /// Where the centre of a piece sits once it's in place.
    func home(_ index: Int) -> CGPoint {
        let cell = cell(index)
        return CGPoint(x: cell.midX, y: cell.midY)
    }

    /// The padded rectangle a piece's image covers, in board coordinates.
    func frame(_ index: Int) -> CGRect {
        cell(index).insetBy(dx: -padding, dy: -padding)
    }

    /// A piece's outline in board coordinates. Every outline winds clockwise, so they can be unioned.
    func outline(_ index: Int) -> CGPath {
        let r = index / cols, c = index % cols
        let cell = cell(index)
        let tl = CGPoint(x: cell.minX, y: cell.minY), tr = CGPoint(x: cell.maxX, y: cell.minY)
        let br = CGPoint(x: cell.maxX, y: cell.maxY), bl = CGPoint(x: cell.minX, y: cell.maxY)
        let down = CGPoint(x: 0, y: 1), right = CGPoint(x: 1, y: 0)

        let path = CGMutablePath()
        path.move(to: tl)
        append(r > 0 ? horizontalCuts[(r - 1) * cols + c] : nil, from: tl, to: tr, normal: down, reversed: false, to: path)
        append(c < cols - 1 ? verticalCuts[r * (cols - 1) + c] : nil, from: tr, to: br, normal: right, reversed: false, to: path)
        append(r < rows - 1 ? horizontalCuts[r * cols + c] : nil, from: bl, to: br, normal: down, reversed: true, to: path)
        append(c > 0 ? verticalCuts[r * (cols - 1) + c - 1] : nil, from: tl, to: bl, normal: right, reversed: true, to: path)
        path.closeSubpath()
        return path
    }

    /// A piece's outline relative to its padded frame.
    func localOutline(_ index: Int) -> CGPath {
        let frame = frame(index)
        var shift = CGAffineTransform(translationX: -frame.minX, y: -frame.minY)
        return outline(index).copy(using: &shift) ?? outline(index)
    }

    /// Every interior cut drawn once, for previewing the pattern over the photo.
    func cutLines() -> CGPath {
        let path = CGMutablePath()
        let w = cellSize.width, h = cellSize.height
        for r in 0..<max(rows - 1, 0) {
            for c in 0..<cols {
                let start = CGPoint(x: CGFloat(c) * w, y: CGFloat(r + 1) * h)
                path.move(to: start)
                append(horizontalCuts[r * cols + c], from: start, to: CGPoint(x: start.x + w, y: start.y),
                       normal: CGPoint(x: 0, y: 1), reversed: false, to: path)
            }
        }
        for r in 0..<rows {
            for c in 0..<max(cols - 1, 0) {
                let start = CGPoint(x: CGFloat(c + 1) * w, y: CGFloat(r) * h)
                path.move(to: start)
                append(verticalCuts[r * (cols - 1) + c], from: start, to: CGPoint(x: start.x, y: start.y + h),
                       normal: CGPoint(x: 1, y: 0), reversed: false, to: path)
            }
        }
        return path
    }

    private func append(_ cut: Cut?, from p: CGPoint, to q: CGPoint, normal: CGPoint, reversed: Bool, to path: CGMutablePath) {
        guard let cut else {
            path.addLine(to: reversed ? p : q)
            return
        }
        var points = knobPoints(cut, from: p, to: q, normal: normal)
        if reversed { points.reverse() }
        path.addCurve(to: points[3], control1: points[1], control2: points[2])
        path.addCurve(to: points[6], control1: points[4], control2: points[5])
        path.addCurve(to: points[9], control1: points[7], control2: points[8])
    }

    /// The classic knob: three cubic curves, shoulder → bulb → shoulder.
    private func knobPoints(_ cut: Cut, from p: CGPoint, to q: CGPoint, normal n: CGPoint) -> [CGPoint] {
        let length = hypot(q.x - p.x, q.y - p.y)
        let dir = CGPoint(x: (q.x - p.x) / length, y: (q.y - p.y) / length)
        let t = Self.knob, u = unit, mid = length / 2
        func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            let out = across * u * cut.side
            return CGPoint(x: p.x + dir.x * along + n.x * out, y: p.y + dir.y * along + n.y * out)
        }
        return [
            point(0, 0),
            point(length * 0.2, cut.a),
            point(mid + (cut.b + cut.d) * u, -t + cut.c),
            point(mid + (-t + cut.b) * u, t + cut.c),
            point(mid + (-2 * t + cut.b - cut.d) * u, 3 * t + cut.c),
            point(mid + (2 * t + cut.b - cut.d) * u, 3 * t + cut.c),
            point(mid + (t + cut.b) * u, t + cut.c),
            point(mid + (cut.b + cut.d) * u, -t + cut.c),
            point(length * 0.8, cut.e),
            point(length, 0),
        ]
    }
}

// MARK: - Layout

extension PuzzleGeometry {
    /// Rows and columns closest to `target` pieces while keeping each piece close to square.
    static func grid(pieces target: Int, aspect: CGFloat) -> (rows: Int, cols: Int) {
        var best = (rows: 2, cols: 2)
        var bestScore = CGFloat.infinity
        for cols in 2...70 {
            for rows in 2...70 {
                let countError = abs(log(CGFloat(rows * cols) / CGFloat(target)))
                let shapeError = abs(log(aspect * CGFloat(rows) / CGFloat(cols)))
                let score = countError * 3 + shapeError
                if score < bestScore {
                    bestScore = score
                    best = (rows, cols)
                }
            }
        }
        return best
    }

    /// Where the loose pieces start out: a heap below the board, a little wider than it.
    var heap: CGRect {
        let width = boardSize.width * 1.8
        // At least a couple of pieces deep, so even a few big pieces pile up rather than line up.
        let height = max(boardSize.width * boardSize.height * 1.1 / width, cellSize.height * 2.2)
        return CGRect(x: (boardSize.width - width) / 2, y: boardSize.height + unit * 0.5, width: width, height: height)
    }

    /// Big puzzles get a table with no edge: it reaches as far as the pieces are spread.
    var hasOpenTable: Bool { count >= 400 }

    /// The table: the board, the heap below it, and the room beside the board for sorting.
    /// On an open table this is just where things start out.
    var table: CGRect {
        CGRect(origin: .zero, size: boardSize).union(heap).insetBy(dx: -unit * 0.6, dy: -unit * 0.6)
    }

    /// Every piece tossed onto the heap in random order, piled highest in the middle.
    func startingPieces() -> [PieceState] {
        // Keep each piece's body inside the heap; only knobs may poke out.
        let spread = heap.insetBy(dx: cellSize.width / 2, dy: cellSize.height / 2)
        func mound() -> CGFloat { (CGFloat.random(in: 0...1) + CGFloat.random(in: 0...1)) / 2 }
        let stacking = (0..<count).shuffled()
        return (0..<count).map { index in
            PieceState(x: spread.minX + spread.width * mound(),
                       y: spread.minY + spread.height * mound(),
                       placed: false, z: stacking[index])
        }
    }

    /// The pieces directly above, below, left and right of `index` in the finished picture.
    func neighbours(of index: Int) -> [Int] {
        let r = index / cols, c = index % cols
        var result: [Int] = []
        if r > 0 { result.append(index - cols) }
        if r < rows - 1 { result.append(index + cols) }
        if c > 0 { result.append(index - 1) }
        if c < cols - 1 { result.append(index + 1) }
        return result
    }
}
