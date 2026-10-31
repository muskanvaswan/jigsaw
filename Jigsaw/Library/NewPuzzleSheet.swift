import SwiftUI

/// Pick how many pieces, seeing exactly how the photo will be cut.
struct NewPuzzleSheet: View {
    let photo: UIImage
    let start: (_ rows: Int, _ cols: Int, _ seed: UInt64, _ snapToBoard: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("pieceTarget") private var target = 48
    @AppStorage("snapToBoard") private var snapToBoard = true
    @State private var seed = UInt64.random(in: 1...UInt64(UInt32.max))

    private static let targets = [12, 24, 48, 100, 200, 300, 500, 1000, 2000]

    private var aspect: CGFloat { photo.size.width / photo.size.height }

    private func grid(_ target: Int) -> (rows: Int, cols: Int) {
        PuzzleGeometry.grid(pieces: target, aspect: aspect)
    }

    var body: some View {
        let chosen = grid(target)
        VStack(spacing: 28) {
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
            }

            Image(uiImage: photo)
                .resizable()
                .scaledToFit()
                .overlay {
                    CutLines(geometry: PuzzleGeometry(rows: chosen.rows, cols: chosen.cols, boardSize: photo.size, seed: seed))
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.2), value: target)

            HStack(spacing: 6) {
                ForEach(Self.targets, id: \.self) { option in
                    let cut = grid(option)
                    let count = cut.rows * cut.cols
                    Button { target = option } label: {
                        Text("\(count)")
                            .font(.callout.weight(.medium).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(option == target ? Color(uiColor: .systemBackground) : Color.primary)
                            .frame(maxWidth: 64, minHeight: 44)
                            .background(option == target ? Color.primary : Color.primary.opacity(0.07), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(count) pieces")
                    .accessibilityAddTraits(option == target ? .isSelected : [])
                }
            }

            Toggle(isOn: $snapToBoard) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snap to board")
                        .font(.body.weight(.medium))
                    Text(snapToBoard ? "Pieces lock into their spot on the board." : "Pieces only lock to the pieces beside them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.accentColor)
            .frame(maxWidth: 420)

            Button {
                start(chosen.rows, chosen.cols, seed, snapToBoard)
            } label: {
                Text("Start")
                    .font(.headline)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(width: 240, height: 54)
                    .background(Color.primary, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(32)
        .background(Color.table)
    }
}

/// The cut pattern drawn over the photo.
private struct CutLines: View {
    let geometry: PuzzleGeometry

    var body: some View {
        Canvas { context, size in
            let scale = size.width / geometry.boardSize.width
            let path = Path(geometry.cutLines()).applying(CGAffineTransform(scaleX: scale, y: scale))
            context.stroke(path, with: .color(.black.opacity(0.28)), lineWidth: 2.4)
            context.stroke(path, with: .color(.white.opacity(0.92)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
