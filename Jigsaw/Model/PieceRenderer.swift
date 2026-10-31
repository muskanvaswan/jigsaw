import UIKit

enum PhotoPrep {
    /// Photo resolution worth keeping for a puzzle: more pieces means more zooming in.
    static func longSide(forPieces count: Int) -> CGFloat {
        count <= 100 ? 2048 : count <= 300 ? 2600 : count <= 600 ? 3200 : 3600
    }

    /// An upright copy whose long side is at most `longSide` (and at least 1600) pixels.
    static func prepare(_ image: UIImage, longSide: CGFloat) -> UIImage {
        let pixels = max(image.size.width, image.size.height) * image.scale
        return redraw(image, longSide: min(longSide, max(pixels, 1600)))
    }

    /// Draws `image` into a fresh 8-bit sRGB bitmap with exactly `longSide` pixels on its long side.
    static func redraw(_ image: UIImage, longSide: CGFloat) -> UIImage {
        let factor = longSide / max(image.size.width, image.size.height)
        let size = CGSize(width: (image.size.width * factor).rounded(), height: (image.size.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Loads a saved photo fully decoded, ready to be cut repeatedly.
    static func load(_ url: URL) -> UIImage? {
        guard let file = UIImage(contentsOfFile: url.path) else { return nil }
        return redraw(file, longSide: max(file.size.width, file.size.height) * file.scale)
    }
}

/// Cuts the photo into piece images.
final class PieceRenderer {
    let geometry: PuzzleGeometry
    private let photo: CGImage

    init(geometry: PuzzleGeometry, photo: CGImage) {
        self.geometry = geometry
        self.photo = photo
    }

    private static let format: UIGraphicsImageRendererFormat = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        return format
    }()

    /// Loose pieces carry a soft drop shadow; pieces in place lie flat.
    func image(for index: Int, shadowed: Bool) -> UIImage {
        let frame = geometry.frame(index)
        let outline = geometry.localOutline(index)
        let bevel = min(max(geometry.unit * 0.02, 1), 6)

        return UIGraphicsImageRenderer(size: frame.size, format: Self.format).image { context in
            let cg = context.cgContext

            if shadowed {
                cg.saveGState()
                cg.setShadow(offset: CGSize(width: 0, height: geometry.shadowRadius * 0.4),
                             blur: geometry.shadowRadius,
                             color: UIColor(white: 0, alpha: 0.4).cgColor)
                cg.addPath(outline)
                cg.setFillColor(UIColor.black.cgColor)
                cg.fillPath()
                cg.restoreGState()
            }

            cg.saveGState()
            cg.addPath(outline)
            cg.clip()
            let source = frame.intersection(CGRect(origin: .zero, size: geometry.boardSize)).integral
            if let crop = photo.cropping(to: source) {
                UIImage(cgImage: crop).draw(in: source.offsetBy(dx: -frame.minX, dy: -frame.minY))
            }
            // A little bevel: light catches the top-left edges, shade falls on the bottom-right.
            stroke(outline, in: cg, shift: bevel * 0.5, color: UIColor(white: 1, alpha: 0.3), width: bevel)
            stroke(outline, in: cg, shift: -bevel * 0.5, color: UIColor(white: 0, alpha: 0.25), width: bevel)
            cg.restoreGState()

            cg.addPath(outline)
            cg.setStrokeColor(UIColor(white: 0, alpha: 0.2).cgColor)
            cg.setLineWidth(max(bevel * 0.35, 0.75))
            cg.strokePath()
        }
    }

    private func stroke(_ path: CGPath, in cg: CGContext, shift: CGFloat, color: UIColor, width: CGFloat) {
        cg.saveGState()
        cg.translateBy(x: shift, y: shift)
        cg.addPath(path)
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(width)
        cg.strokePath()
        cg.restoreGState()
    }

    /// Renders every piece in parallel.
    func images(shadowed: [Bool]) -> [UIImage] {
        var images = [UIImage?](repeating: nil, count: geometry.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: geometry.count) { index in
            let image = image(for: index, shadowed: shadowed[index])
            lock.lock()
            images[index] = image
            lock.unlock()
        }
        return images.map { $0! }
    }
}

enum Thumbnail {
    /// The photo faded out, with the pieces already done shown at full strength.
    static func render(photo: UIImage, geometry: PuzzleGeometry, finished: [Bool]) -> UIImage {
        let scale = 640 / max(geometry.boardSize.width, geometry.boardSize.height)
        let size = CGSize(width: (geometry.boardSize.width * scale).rounded(),
                          height: (geometry.boardSize.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: size)
            let done = !finished.contains(false)
            photo.draw(in: rect, blendMode: .normal, alpha: done ? 1 : 0.22)
            guard !done, finished.contains(true) else { return }

            let union = CGMutablePath()
            let shrink = CGAffineTransform(scaleX: scale, y: scale)
            for index in finished.indices where finished[index] {
                union.addPath(geometry.outline(index), transform: shrink)
            }
            context.cgContext.addPath(union)
            context.cgContext.clip()
            photo.draw(in: rect)
        }
    }
}
