#if DEBUG
import SwiftUI

/// Launch arguments for making App Store screenshots with a debug build. Nothing syncs with iCloud meanwhile.
///
/// - `-Screenshot <name>`: after a moment, saves the window to `<tmp>/<name>.png` and quits.
/// - `-OpenPuzzle <id>`: opens that puzzle first.
/// - `-NewPuzzle <painting id>`: opens the new-puzzle sheet on one of the bundled paintings.
/// - `-WindowSize 1440x900`: fixes the Mac window's size.
/// - `-Appearance light` or `dark`: ignores the system's appearance.
enum DebugLaunch {
    /// Launch arguments in the form `-Key value` arrive as user defaults.
    private static let arguments = UserDefaults.standard

    static var screenshot: String? { arguments.string(forKey: "Screenshot") }
    static var openPuzzle: UUID? { arguments.string(forKey: "OpenPuzzle").flatMap(UUID.init(uuidString:)) }
    static var newPuzzle: String? { arguments.string(forKey: "NewPuzzle") }
    static var isScreenshotting: Bool { screenshot != nil }

    static var appearance: ColorScheme? {
        switch arguments.string(forKey: "Appearance") {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    static var windowSize: CGSize? {
        let parts = arguments.string(forKey: "WindowSize")?.split(separator: "x").compactMap { Double($0) } ?? []
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }

    @MainActor
    static func takeScreenshotSoon() {
        guard let name = screenshot else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            let window = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first
            guard let window else { exit(1) }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try? image.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png"))
            exit(0)
        }
    }
}
#endif
