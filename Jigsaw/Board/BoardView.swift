import UIKit

protocol BoardViewDelegate: AnyObject {
    func boardDidChange(_ board: BoardView)
    /// Pieces locked into the board, or joined to a neighbour when the puzzle doesn't snap to the board.
    func board(_ board: BoardView, didProgress count: Int)
    func boardDidFinish(_ board: BoardView)
}

/// Holds pieces that can be anywhere, so it ignores its own bounds when hit-testing.
private class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for sub in subviews.reversed() where sub.isUserInteractionEnabled && !sub.isHidden {
            if let hit = sub.hitTest(convert(point, to: sub), with: event) { return hit }
        }
        return nil
    }
}

final class PieceView: UIImageView {
    let index: Int
    let shape: CGPath
    var isPlaced = false
    /// Drawn without the baked-in shadow, because it lies in the board or in a group.
    var isFlat: Bool

    init(index: Int, image: UIImage, shape: CGPath, size: CGSize, isFlat: Bool) {
        self.index = index
        self.shape = shape
        self.isFlat = isFlat
        super.init(frame: CGRect(origin: .zero, size: size))
        self.image = image
        isUserInteractionEnabled = true
        layer.minificationFilter = .trilinear
        layer.shadowPath = shape
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Only the piece itself is touchable, not the transparent corners around its knobs.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point) && shape.contains(point)
    }
}

/// Loose pieces that move as one; a lone piece is a group of one. Each piece sits at its home
/// position inside the group, so the group's `center` is how far all of them are from where they belong.
private final class GroupView: PassthroughView {
    private let shadow = CALayer()

    var members: [PieceView] { subviews.compactMap { $0 as? PieceView } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        shadow.shadowColor = UIColor.black.cgColor
        layer.insertSublayer(shadow, at: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Two or more pieces cast one shadow together; a lone piece has its own baked into its image.
    func updateShadow(_ geometry: PuzzleGeometry) {
        let pieces = members
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if pieces.count > 1 {
            // A layer with empty bounds may not be drawn at all, so give the shadow the board's size.
            shadow.frame = CGRect(origin: .zero, size: geometry.boardSize)
            let outline = CGMutablePath()
            for piece in pieces { outline.addPath(geometry.outline(piece.index)) }
            shadow.shadowPath = outline
            setLifted(false, geometry)
        } else {
            shadow.shadowPath = nil
            shadow.shadowOpacity = 0
        }
        CATransaction.commit()
    }

    func setLifted(_ lifted: Bool, _ geometry: PuzzleGeometry) {
        guard shadow.shadowPath != nil else { return }
        shadow.shadowOpacity = lifted ? 0.28 : 0.4
        shadow.shadowRadius = lifted ? geometry.unit * 0.07 : geometry.shadowRadius * 0.6
        shadow.shadowOffset = CGSize(width: 0, height: lifted ? geometry.unit * 0.06 : geometry.shadowRadius * 0.4)
    }
}

/// The table. Pieces live in world coordinates (board pixels, board at the origin);
/// the camera maps them to the screen with a scale and an offset.
final class BoardView: UIView, UIGestureRecognizerDelegate {
    weak var delegate: BoardViewDelegate?

    private let geometry: PuzzleGeometry
    private let renderer: PieceRenderer
    private let table: CGRect
    /// Pieces lock into their spot on the board; otherwise they only lock to the pieces beside them.
    private(set) var snapsToBoard: Bool

    private let world = PassthroughView()
    private let tray = UIView()
    private let ghost = UIImageView()
    private let placedLayer = PassthroughView()
    private let finished = UIImageView()
    private let looseLayer = PassthroughView()
    private var pieces: [PieceView] = []

    private var scale: CGFloat = 1
    private var offset: CGPoint = .zero
    private var laidOutSize: CGSize = .zero
    private let margin: CGFloat = 20

    private var cameraGestures = 0
    private var throwVelocity: CGPoint = .zero
    private var zoomFocus: CGPoint?

    private struct Drag {
        let group: GroupView
        let touch: UIGestureRecognizer
        let grab: CGPoint
        /// Where the finger came down on screen; auto-scroll waits until the piece has been carried away from it.
        let start: CGPoint
    }
    private var drags: [ObjectIdentifier: Drag] = [:]
    private var autoScroll: CADisplayLink?
    private var isPeeking = false

    /// How close a piece has to be dropped to where it fits before it snaps.
    private var reach: CGFloat { geometry.unit * 0.3 }

    init(renderer: PieceRenderer, photo: UIImage, images: [UIImage], states: [PieceState], snapsToBoard: Bool, solved: Bool) {
        self.renderer = renderer
        self.geometry = renderer.geometry
        self.table = renderer.geometry.table
        self.snapsToBoard = snapsToBoard
        super.init(frame: .zero)

        backgroundColor = .table
        isMultipleTouchEnabled = true
        clipsToBounds = true
        addSubview(world)

        let board = CGRect(origin: .zero, size: geometry.boardSize)
        let rim = max(geometry.boardSize.width, geometry.boardSize.height) * 0.006
        tray.frame = board.insetBy(dx: -rim, dy: -rim)
        tray.backgroundColor = .tray
        tray.layer.cornerRadius = rim * 1.5
        tray.layer.cornerCurve = .continuous
        ghost.frame = board
        ghost.image = photo
        ghost.alpha = 0
        finished.frame = board
        finished.image = photo
        finished.alpha = solved ? 1 : 0
        for layer in [tray, ghost, finished] {
            layer.isUserInteractionEnabled = false
            (layer as? UIImageView)?.layer.minificationFilter = .trilinear
        }
        [tray, ghost, placedLayer, finished, looseLayer].forEach(world.addSubview)

        let joined = PuzzleRecord.joined(states)
        for index in 0..<geometry.count {
            let piece = PieceView(index: index, image: images[index], shape: geometry.localOutline(index),
                                  size: geometry.frame(index).size, isFlat: states[index].placed || joined[index])
            piece.center = geometry.home(index)
            let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePiece(_:)))
            press.minimumPressDuration = 0
            press.allowableMovement = .greatestFiniteMagnitude
            press.delegate = self
            piece.addGestureRecognizer(press)
            pieces.append(piece)

            if states[index].placed {
                piece.isPlaced = true
                piece.isUserInteractionEnabled = false
                placedLayer.addSubview(piece)
            }
        }

        // Loose pieces sharing a `z` form one group, stacked in `z` order.
        let loose = Dictionary(grouping: states.indices.filter { !states[$0].placed }) { states[$0].z }
        for (_, members) in loose.sorted(by: { $0.key < $1.key }) {
            let group = GroupView()
            let first = members[0], home = geometry.home(first)
            group.center = CGPoint(x: states[first].x - home.x, y: states[first].y - home.y)
            for index in members { group.addSubview(pieces[index]) }
            group.updateShadow(geometry)
            looseLayer.addSubview(group)
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        pan.allowedScrollTypesMask = .all
        pan.delegate = self
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - State

    /// Current position of every piece. Loose groups are numbered bottom to top, and every piece
    /// in a group shares its number.
    func pieceStates() -> [PieceState] {
        var states = pieces.map { piece -> PieceState in
            let home = geometry.home(piece.index)
            return PieceState(x: home.x, y: home.y, placed: true, z: 0)
        }
        for (z, view) in looseLayer.subviews.enumerated() {
            guard let group = view as? GroupView else { continue }
            for piece in group.members {
                let home = geometry.home(piece.index)
                states[piece.index] = PieceState(x: home.x + group.center.x, y: home.y + group.center.y, placed: false, z: z)
            }
        }
        return states
    }

    private var progressCount: Int {
        var count = placedLayer.subviews.count
        for case let group as GroupView in looseLayer.subviews {
            let size = group.members.count
            if size > 1 { count += size }
        }
        return count
    }

    /// Switches how pieces snap without losing any work: pieces locked into the board come loose
    /// (still joined to their neighbours), and groups already where they belong drop into the board.
    func setSnapsToBoard(_ snaps: Bool) {
        guard snaps != snapsToBoard else { return }
        snapsToBoard = snaps
        if snaps {
            for case let group as GroupView in looseLayer.subviews
            where !isDragging(group) && hypot(group.center.x, group.center.y) < reach {
                place(group)
            }
        } else {
            loosenPlacedPieces()
        }
        contentDidChange()
        delegate?.board(self, didProgress: progressCount)
        delegate?.boardDidChange(self)
    }

    /// Turns pieces locked into the board into loose groups lying exactly where they are, one group
    /// per run of touching pieces, beneath everything else on the table.
    private func loosenPlacedPieces() {
        var seen = Set<Int>()
        for piece in pieces where piece.isPlaced && !seen.contains(piece.index) {
            var run: [PieceView] = []
            var next = [piece.index]
            seen.insert(piece.index)
            while let index = next.popLast() {
                run.append(pieces[index])
                for neighbour in geometry.neighbours(of: index) where pieces[neighbour].isPlaced && !seen.contains(neighbour) {
                    seen.insert(neighbour)
                    next.append(neighbour)
                }
            }
            let group = GroupView()
            for member in run {
                member.isPlaced = false
                member.isUserInteractionEnabled = true
                group.addSubview(member)
            }
            group.updateShadow(geometry)
            looseLayer.insertSubview(group, at: 0)
            restyle(run, flat: run.count > 1)
        }
    }

    func setPeeking(_ peeking: Bool) {
        guard peeking != isPeeking else { return }
        isPeeking = peeking
        UIView.animate(withDuration: 0.25) { self.ghost.alpha = peeking ? 0.4 : 0 }
    }

    // MARK: - Camera

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, bounds.size != laidOutSize else { return }
        let previous = laidOutSize
        laidOutSize = bounds.size

        if previous == .zero || scale <= fitScale(in: previous) * 1.02 {
            scale = fitScale(in: bounds.size)
            offset = centered(on: contentRect, scale: scale)
        } else {
            // Keep whatever was in the middle of the screen in the middle.
            let middle = CGPoint(x: (previous.width / 2 - offset.x) / scale, y: (previous.height / 2 - offset.y) / scale)
            scale = min(max(scale, minScale), maxScale)
            offset = clampedOffset(CGPoint(x: bounds.midX - middle.x * scale, y: bounds.midY - middle.y * scale), scale: scale)
        }
        applyCamera()
    }

    private func applyCamera() {
        world.transform = CGAffineTransform(scaleX: scale, y: scale)
        world.center = offset
        for drag in drags.values { follow(drag) }
    }

    /// Everything on the table: where it all started plus wherever pieces have been put since.
    /// On a closed table the piece in hand doesn't count, so carrying it to the edge can't stretch
    /// the table; on an open table it does, which is what lets the table grow without end.
    private var contentRect: CGRect {
        if let cached = contentCache { return cached }
        var rect = table
        for case let group as GroupView in looseLayer.subviews where geometry.hasOpenTable || !isDragging(group) {
            rect = rect.union(extent(of: group))
        }
        contentCache = rect
        return rect
    }
    private var contentCache: CGRect?

    private func contentDidChange() {
        contentCache = nil
    }

    /// Where a group's pieces cover the table, in world coordinates.
    private func extent(of group: GroupView) -> CGRect {
        group.members.reduce(CGRect.null) { $0.union($1.frame) }.offsetBy(dx: group.center.x, dy: group.center.y)
    }

    private func fitScale(in size: CGSize) -> CGFloat {
        let content = contentRect
        return min(max(size.width - 2 * margin, 1) / content.width, max(size.height - 2 * margin, 1) / content.height)
    }

    /// The offset that puts the middle of `rect` in the middle of the screen.
    private func centered(on rect: CGRect, scale s: CGFloat) -> CGPoint {
        CGPoint(x: bounds.midX - rect.midX * s, y: bounds.midY - rect.midY * s)
    }

    /// Everything fits on screen; an open table lets you pull back further still.
    private var minScale: CGFloat {
        fitScale(in: bounds.size) * (geometry.hasOpenTable ? 0.5 : 1)
    }

    /// Close enough that one piece spans almost half the screen.
    private var maxScale: CGFloat {
        max(fitScale(in: bounds.size) * 3, min(bounds.width, bounds.height) * 0.45 / geometry.unit)
    }

    private func clampedOffset(_ proposed: CGPoint, scale s: CGFloat) -> CGPoint {
        var content = contentRect
        if geometry.hasOpenTable {
            // Room to pan well past the pieces in any direction, keeping a quarter screen of them in view.
            content = content.insetBy(dx: -bounds.width * 0.75 / s, dy: -bounds.height * 0.75 / s)
        }
        func axis(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat, _ length: CGFloat) -> CGFloat {
            let span = (high - low) * s
            if span + 2 * margin <= length { return (length - span) / 2 - low * s }
            return min(max(value, length - margin - high * s), margin - low * s)
        }
        return CGPoint(x: axis(proposed.x, content.minX, content.maxX, bounds.width),
                       y: axis(proposed.y, content.minY, content.maxY, bounds.height))
    }

    /// Stops a camera animation in flight, keeping the camera where it currently is on screen.
    private func haltCamera() {
        guard world.layer.animationKeys()?.isEmpty == false, let shown = world.layer.presentation() else { return }
        offset = shown.position
        scale = shown.transform.m11
        world.layer.removeAllAnimations()
        applyCamera()
    }

    private func animateCamera(to newScale: CGFloat, offset newOffset: CGPoint, velocity: CGFloat = 0) {
        guard newScale != scale || newOffset != offset else { return }
        scale = newScale
        offset = newOffset
        UIView.animate(withDuration: 0.55, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: velocity,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.applyCamera()
        }
    }

    /// After a pinch or pan: come back inside the limits, coasting a little in the direction of a throw.
    private func settle(throwing velocity: CGPoint) {
        let target = min(max(scale, minScale), maxScale)
        let focus = zoomFocus ?? CGPoint(x: bounds.midX, y: bounds.midY)
        var next = offset
        if target != scale {
            next = CGPoint(x: focus.x - (focus.x - next.x) * target / scale, y: focus.y - (focus.y - next.y) * target / scale)
        }
        next.x += velocity.x * 0.2
        next.y += velocity.y * 0.2
        next = clampedOffset(next, scale: target)
        let distance = hypot(next.x - offset.x, next.y - offset.y)
        animateCamera(to: target, offset: next, velocity: distance > 1 ? hypot(velocity.x, velocity.y) / distance : 0)
    }

    private func beginCameraGesture() {
        if cameraGestures == 0 { haltCamera() }
        cameraGestures += 1
    }

    private func endCameraGesture() {
        cameraGestures = max(cameraGestures - 1, 0)
        guard cameraGestures == 0 else { return }
        settle(throwing: throwVelocity)
        throwVelocity = .zero
        zoomFocus = nil
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            beginCameraGesture()
        case .changed:
            let move = pan.translation(in: self)
            pan.setTranslation(.zero, in: self)
            // Resist being dragged past the edge.
            let limit = clampedOffset(offset, scale: scale)
            offset.x += (offset.x - limit.x) * move.x > 0 ? move.x * 0.35 : move.x
            offset.y += (offset.y - limit.y) * move.y > 0 ? move.y * 0.35 : move.y
            applyCamera()
        case .ended:
            throwVelocity = pan.velocity(in: self)
            endCameraGesture()
        case .cancelled, .failed:
            endCameraGesture()
        default:
            break
        }
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            beginCameraGesture()
        case .changed:
            let focus = pinch.location(in: self)
            let next = min(max(scale * pinch.scale, minScale * 0.8), maxScale * 1.25)
            offset = CGPoint(x: focus.x - (focus.x - offset.x) * next / scale, y: focus.y - (focus.y - offset.y) * next / scale)
            scale = next
            zoomFocus = focus
            pinch.scale = 1
            applyCamera()
        case .ended, .cancelled, .failed:
            endCameraGesture()
        default:
            break
        }
    }

    /// Zooms in on the tapped spot, or back out to everything on the table.
    @objc private func handleDoubleTap(_ tap: UITapGestureRecognizer) {
        haltCamera()
        let fit = fitScale(in: bounds.size)
        if scale > fit * 1.3 || scale < fit * 0.95 {
            animateCamera(to: fit, offset: clampedOffset(centered(on: contentRect, scale: fit), scale: fit))
        } else {
            let point = tap.location(in: self)
            let target = min(max(fit * 2.5, 64 / geometry.unit), maxScale)
            let next = CGPoint(x: point.x - (point.x - offset.x) * target / scale, y: point.y - (point.y - offset.y) * target / scale)
            animateCamera(to: target, offset: clampedOffset(next, scale: target))
        }
    }

    // MARK: - Dragging

    private func isDragging(_ group: GroupView) -> Bool {
        drags.values.contains { $0.group === group }
    }

    @objc private func handlePiece(_ press: UILongPressGestureRecognizer) {
        let key = ObjectIdentifier(press)
        switch press.state {
        case .began:
            guard let piece = press.view as? PieceView, let group = piece.superview as? GroupView,
                  !isDragging(group) else { return }
            haltCamera()
            looseLayer.bringSubviewToFront(group)
            let finger = press.location(in: looseLayer)
            drags[key] = Drag(group: group, touch: press,
                              grab: CGPoint(x: group.center.x - finger.x, y: group.center.y - finger.y),
                              start: press.location(in: self))
            lift(group)
            contentDidChange()
            updateAutoScroll()
        case .changed:
            if let drag = drags[key] { follow(drag) }
        case .ended, .cancelled, .failed:
            guard let drag = drags.removeValue(forKey: key) else { return }
            // The finger can lift a little past the last reported move.
            follow(drag)
            updateAutoScroll()
            drop(drag.group)
        default:
            break
        }
    }

    private func follow(_ drag: Drag) {
        let finger = drag.touch.location(in: looseLayer)
        drag.group.center = CGPoint(x: finger.x + drag.grab.x, y: finger.y + drag.grab.y)
        contentDidChange()
    }

    private func lift(_ group: GroupView) {
        let members = group.members
        guard members.count == 1, let piece = members.first else {
            group.setLifted(true, geometry)
            return
        }
        piece.layer.shadowRadius = geometry.unit * 0.07
        piece.layer.shadowOffset = CGSize(width: 0, height: geometry.unit * 0.06)
        piece.layer.shadowOpacity = 0.22
        UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            piece.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
        }
    }

    private func setDown(_ group: GroupView) {
        group.setLifted(false, geometry)
        for piece in group.members {
            piece.layer.shadowOpacity = 0
            UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                piece.transform = .identity
            }
        }
    }

    private func drop(_ group: GroupView) {
        setDown(group)
        if snapsToBoard {
            if hypot(group.center.x, group.center.y) < reach {
                place(group)
            } else {
                keepOnTable(group)
            }
        } else if !join(group) {
            keepOnTable(group)
        }
        contentDidChange()
        delegate?.boardDidChange(self)
    }

    /// Don't let pieces wander off too far from a closed table.
    private func keepOnTable(_ group: GroupView) {
        guard !geometry.hasOpenTable else { return }
        let area = table.insetBy(dx: -table.width * 0.1, dy: -table.height * 0.1)
        let middle = CGPoint(x: extent(of: group).midX, y: extent(of: group).midY)
        let shift = CGPoint(x: min(max(middle.x, area.minX), area.maxX) - middle.x,
                            y: min(max(middle.y, area.minY), area.maxY) - middle.y)
        guard shift != .zero else { return }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            group.center = CGPoint(x: group.center.x + shift.x, y: group.center.y + shift.y)
        }
    }

    // MARK: - Snapping into the board

    /// Locks a group (usually a single piece) into its spot on the board.
    private func place(_ group: GroupView) {
        let members = group.members
        for piece in members {
            piece.isPlaced = true
            piece.isUserInteractionEnabled = false
            placedLayer.addSubview(piece)
            piece.center = CGPoint(x: piece.center.x + group.center.x, y: piece.center.y + group.center.y)
        }
        group.removeFromSuperview()
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState]) {
            for piece in members {
                piece.center = self.geometry.home(piece.index)
                piece.transform = .identity
            }
        }
        Click.play()
        restyle(members, flat: true)

        let count = progressCount
        delegate?.board(self, didProgress: count)
        if count == pieces.count { finish() }
    }

    // MARK: - Snapping to each other

    /// Snaps a dropped group onto a neighbour that lines up with it, then joins any other group
    /// that now lines up too, always moving the smaller of the two. Returns whether anything joined.
    private func join(_ dropped: GroupView) -> Bool {
        guard var target = match(for: dropped) else { return false }
        absorb(dropped, into: target)
        while let other = match(for: target) {
            let (moving, staying) = other.members.count > target.members.count ? (target, other) : (other, target)
            absorb(moving, into: staying)
            target = staying
        }
        Click.play()

        let count = progressCount
        delegate?.board(self, didProgress: count)
        if target.members.count == pieces.count { assemble(target) }
        return true
    }

    /// The closest group, not in someone's hand, holding a neighbour of one of `group`'s pieces at the right offset.
    private func match(for group: GroupView) -> GroupView? {
        var best: GroupView?
        var bestDistance = reach
        for piece in group.members {
            for neighbour in geometry.neighbours(of: piece.index) {
                guard let other = pieces[neighbour].superview as? GroupView, other !== group, !isDragging(other) else { continue }
                let distance = hypot(other.center.x - group.center.x, other.center.y - group.center.y)
                if distance < bestDistance {
                    best = other
                    bestDistance = distance
                }
            }
        }
        return best
    }

    /// Moves every piece of `moving` into `target`, sliding them the last little way into line.
    private func absorb(_ moving: GroupView, into target: GroupView) {
        let shift = CGPoint(x: moving.center.x - target.center.x, y: moving.center.y - target.center.y)
        let arriving = moving.members
        for piece in arriving {
            target.addSubview(piece)
            piece.center.x += shift.x
            piece.center.y += shift.y
        }
        moving.removeFromSuperview()
        looseLayer.bringSubviewToFront(target)
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            for piece in arriving {
                piece.center = self.geometry.home(piece.index)
                piece.transform = .identity
            }
        } completion: { _ in
            target.updateShadow(self.geometry)
        }
        restyle(target.members, flat: true)
    }

    /// The last join: the finished picture glides into the frame.
    private func assemble(_ group: GroupView) {
        group.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.9, delay: 0.3, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: []) {
            group.center = .zero
        } completion: { _ in
            for piece in group.members {
                piece.isPlaced = true
                piece.isUserInteractionEnabled = false
                self.placedLayer.addSubview(piece)
            }
            group.removeFromSuperview()
            self.contentDidChange()
            self.finish()
        }
    }

    /// Pieces lying in the board or in a group are drawn flat; a lone loose piece carries its own shadow.
    private func restyle(_ list: [PieceView], flat: Bool) {
        for piece in list where piece.isFlat != flat {
            piece.isFlat = flat
            let index = piece.index
            DispatchQueue.global(qos: .userInitiated).async { [renderer] in
                let image = renderer.image(for: index, shadowed: !flat)
                DispatchQueue.main.async {
                    if piece.isFlat == flat { piece.image = image }
                }
            }
        }
    }

    private func finish() {
        UIView.animate(withDuration: 1.2, delay: 0.35, options: [.curveEaseInOut]) {
            self.finished.alpha = 1
            self.ghost.alpha = 0
        }
        let board = CGRect(origin: .zero, size: geometry.boardSize)
        let fit = min((bounds.width - 160) / board.width, (bounds.height - 200) / board.height)
        let target = min(max(fit, fitScale(in: bounds.size)), maxScale)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.animateCamera(to: target, offset: self.clampedOffset(self.centered(on: board, scale: target), scale: target))
        }
        delegate?.boardDidFinish(self)
    }

    // MARK: - Auto-scroll while dragging near an edge

    private func updateAutoScroll() {
        if drags.isEmpty {
            autoScroll?.invalidate()
            autoScroll = nil
        } else if autoScroll == nil {
            let link = CADisplayLink(target: self, selector: #selector(autoScrollTick(_:)))
            link.add(to: .main, forMode: .common)
            autoScroll = link
        }
    }

    @objc private func autoScrollTick(_ link: CADisplayLink) {
        let zone: CGFloat = 44
        var push = CGPoint.zero
        for drag in drags.values {
            let p = drag.touch.location(in: self)
            guard hypot(p.x - drag.start.x, p.y - drag.start.y) > 24 else { continue }
            push.x += max(0, zone - p.x) / zone - max(0, p.x - (bounds.width - zone)) / zone
            push.y += max(0, zone - p.y) / zone - max(0, p.y - (bounds.height - zone)) / zone
        }
        guard push != .zero else { return }
        let step = CGFloat(link.targetTimestamp - link.timestamp) * 700
        let next = clampedOffset(CGPoint(x: offset.x + push.x * step, y: offset.y + push.y * step), scale: scale)
        guard next != offset else { return }
        offset = next
        applyCamera()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            autoScroll?.invalidate()
            autoScroll = nil
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Touches that land on a loose piece belong to that piece, not to the camera.
        recognizer.view is PieceView || !(touch.view is PieceView)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
