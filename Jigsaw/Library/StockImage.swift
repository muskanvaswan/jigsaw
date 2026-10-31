import ImageIO
import UIKit

/// Public-domain paintings that ship with the app, so there is always something to solve.
/// Sourced from Wikimedia Commons.
struct StockImage: Identifiable {
    let id: String
    let title: String
    let artist: String

    static let all = [
        StockImage(id: "starry-night", title: "The Starry Night", artist: "Van Gogh, 1889"),
        StockImage(id: "great-wave", title: "The Great Wave", artist: "Hokusai, c. 1831"),
        StockImage(id: "water-lilies", title: "Water Lilies", artist: "Monet, 1906"),
    ]

    private var url: URL? { Bundle.main.url(forResource: id, withExtension: "jpg") }

    /// The full painting, ready to be cut.
    func photo() -> UIImage? {
        url.flatMap { UIImage(contentsOfFile: $0.path) }.map { PhotoPrep.prepare($0, longSide: 3200) }
    }

    /// A small copy for the picker, decoded without loading the whole painting.
    func thumbnail(maxPixels: Int = 480) -> UIImage? {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}
