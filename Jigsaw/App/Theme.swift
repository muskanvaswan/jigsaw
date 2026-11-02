import SwiftUI
import UIKit

extension UIColor {
    /// The surface everything sits on: warm paper by day, near-black by night.
    static let table = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.095, green: 0.094, blue: 0.10, alpha: 1)
            : UIColor(red: 0.929, green: 0.918, blue: 0.898, alpha: 1)
    }

    /// The recessed area where the picture comes together.
    static let tray = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.145, green: 0.143, blue: 0.152, alpha: 1)
            : UIColor(red: 0.878, green: 0.863, blue: 0.835, alpha: 1)
    }
}

extension Color {
    static let table = Color(uiColor: .table)
    static let tray = Color(uiColor: .tray)
}

extension View {
    /// Liquid Glass where available, frosted material before that. Interactive glass answers a touch,
    /// which suits a button more than a card.
    @ViewBuilder
    func chromeBackground<S: Shape>(_ shape: S, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}

/// A small round floating button.
struct ChromeButton: View {
    let systemImage: String
    var label: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isActive ? Color("AccentColor") : Color.primary)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .chromeBackground(Circle())
        .accessibilityLabel(label)
    }
}
