import SwiftUI

/// The things on the board people miss: the peek at the picture, and the menu holding Spread Out and
/// Snap to Board. Shown the first time a puzzle opens, pointing at the real buttons; Show Tips in that
/// menu brings them back.
enum BoardTip: Int, CaseIterable {
    case peek, more

    var next: BoardTip? { BoardTip(rawValue: rawValue + 1) }
}

/// Where the button each tip is about sits on screen.
struct TipAnchors: PreferenceKey {
    static let defaultValue: [BoardTip: Anchor<CGRect>] = [:]

    static func reduce(value: inout [BoardTip: Anchor<CGRect>], nextValue: () -> [BoardTip: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Marks the button a tip is about.
    func tipAnchor(_ tip: BoardTip) -> some View {
        anchorPreference(key: TipAnchors.self, value: .bounds) { [tip: $0] }
    }
}

/// Dims everything but the button a tip is about, and explains it in a card just below. The button
/// still works, so you can try it; tapping anywhere else moves on.
struct TipOverlay: View {
    let tip: BoardTip
    let anchors: [BoardTip: Anchor<CGRect>]
    let next: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            if let anchor = anchors[tip] {
                let button = proxy[anchor]
                let hole = button.insetBy(dx: -7, dy: -7)
                let width = min(340, proxy.size.width - 24)
                // Hanging from the button, as far right as the screen allows.
                let x = min(max(button.midX + 44 - width, 12), proxy.size.width - 12 - width)
                ZStack(alignment: .topLeading) {
                    Spotlight(hole: hole)
                        .fill(.black.opacity(colorScheme == .dark ? 0.5 : 0.3), style: FillStyle(eoFill: true))
                        .contentShape(Spotlight(hole: hole), eoFill: true)
                        .onTapGesture(perform: next)
                        .accessibilityHidden(true)
                    Beacon()
                        .frame(width: hole.width, height: hole.height)
                        .offset(x: hole.minX, y: hole.minY)
                    TipCard(tip: tip, point: button.midX - x, next: next)
                        .frame(width: width)
                        .offset(x: x, y: hole.maxY + 4)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Everything but a round hole.
private struct Spotlight: Shape {
    var hole: CGRect

    var animatableData: CGRect.AnimatableData {
        get { hole.animatableData }
        set { hole.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addEllipse(in: hole)
        return path
    }
}

/// A ring round the button, with a ripple going out from it every so often.
private struct Beacon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .stroke(Color("AccentColor"), lineWidth: 2)
                    .keyframeAnimator(initialValue: 0.0) { ring, t in
                        ring.scaleEffect(1 + t * 0.4).opacity(1 - t)
                    } keyframes: { _ in
                        KeyframeTrack {
                            CubicKeyframe(1, duration: 1.1)
                            LinearKeyframe(1, duration: 0.7)
                        }
                    }
            }
            Circle()
                .stroke(Color("AccentColor"), lineWidth: 2.5)
        }
        .allowsHitTesting(false)
    }
}

private struct TipCard: View {
    let tip: BoardTip
    /// Where the button is, from the card's left edge.
    let point: CGFloat
    let next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch tip {
            case .peek:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Peek at the picture")
                        .font(.headline)
                    Text("The eye shows the finished picture faintly on the board, so you can see where pieces go. Try it.")
                        .foregroundStyle(.secondary)
                }
            case .more:
                Text("More in this menu")
                    .font(.headline)
                row("square.grid.3x3.square", "Spread Out Pieces", "Lays the loose pieces out in rows, so none hide under others.")
                row("square.grid.3x3", "Snap to Board", "Turn it off and pieces only join each other, not the board. A little harder.")
                row("lightbulb", "Show Tips", "Brings these back.")
            }
            HStack {
                HStack(spacing: 6) {
                    ForEach(BoardTip.allCases, id: \.self) { step in
                        Circle()
                            .fill(Color.primary.opacity(step == tip ? 0.8 : 0.2))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Tip \(tip.rawValue + 1) of \(BoardTip.allCases.count)")
                Spacer()
                Button(action: next) {
                    Text(tip.next == nil ? "Got It" : "Next")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 38)
                        .background(Color("AccentColor"), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 20)
        .padding(.top, 18 + Callout.pointHeight)
        .padding(.bottom, 16)
        .chromeBackground(Callout(point: point), interactive: false)
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color("AccentColor"))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.semibold)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A rounded card with a point on top, `point` from its left edge, toward the button it's about.
private struct Callout: Shape {
    static let pointHeight: CGFloat = 10
    var point: CGFloat

    var animatableData: CGFloat {
        get { point }
        set { point = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + Self.pointHeight, width: rect.width, height: rect.height - Self.pointHeight)
        let x = rect.minX + min(max(point, 32), rect.width - 26)
        var tip = Path()
        tip.move(to: CGPoint(x: x - 12, y: body.minY + 2))
        tip.addLine(to: CGPoint(x: x - 2.5, y: rect.minY + 1))
        tip.addQuadCurve(to: CGPoint(x: x + 2.5, y: rect.minY + 1), control: CGPoint(x: x, y: rect.minY - 0.5))
        tip.addLine(to: CGPoint(x: x + 12, y: body.minY + 2))
        tip.closeSubpath()
        return Path(roundedRect: body, cornerRadius: 22, style: .continuous).union(tip)
    }
}
