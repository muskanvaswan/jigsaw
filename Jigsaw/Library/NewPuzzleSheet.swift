import PhotosUI
import SwiftUI

/// Making a puzzle: choose a picture, then how many pieces.
struct NewPuzzleSheet: View {
    let start: (_ photo: UIImage, _ rows: Int, _ cols: Int, _ seed: UInt64, _ snapToBoard: Bool) -> Void
    @State private var photo: UIImage?
    @Environment(\.dismiss) private var dismiss

    init(photo: UIImage? = nil, start: @escaping (_ photo: UIImage, _ rows: Int, _ cols: Int, _ seed: UInt64, _ snapToBoard: Bool) -> Void) {
        _photo = State(initialValue: photo)
        self.start = start
    }

    var body: some View {
        Group {
            if let photo {
                CutStep(photo: photo, back: { self.photo = nil }) { rows, cols, seed, snaps in
                    start(photo, rows, cols, seed, snaps)
                }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Button("Cancel") { dismiss() }
                        Spacer()
                    }
                    Text("New Puzzle")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    PhotoSources { self.photo = $0 }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(32)
        .background(Color.table)
        .animation(.easeInOut(duration: 0.25), value: photo == nil)
    }
}

/// Your own photos, or one of the paintings that ship with the app.
struct PhotoSources: View {
    let pick: (UIImage) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var pickedItem: PhotosPickerItem?
    @State private var isLoading = false

    var body: some View {
        // Four across on iPad, two by two on a phone.
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: sizeClass == .compact ? 2 : 4)
        LazyVGrid(columns: columns, spacing: 20) {
            PhotosPicker(selection: $pickedItem, matching: .images) {
                tile(title: "Your Photos", subtitle: "Any picture") {
                    ZStack {
                        Color.tray
                        if isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(Color.primary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isLoading)

            ForEach(StockImage.all) { stock in
                Button {
                    load { stock.photo() }
                } label: {
                    tile(title: stock.title, subtitle: stock.artist) {
                        StockThumbnail(stock: stock)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
            }
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                load { UIImage(data: data).map { PhotoPrep.prepare($0, longSide: 3200) } }
            }
        }
    }

    private func load(_ make: @escaping () -> UIImage?) {
        isLoading = true
        Task {
            let photo = await Task.detached(priority: .userInitiated) { make() }.value
            isLoading = false
            if let photo { pick(photo) }
        }
    }

    private func tile<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { content() }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct StockThumbnail: View {
    let stock: StockImage
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.tray
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task {
            image = await Task.detached(priority: .userInitiated) { stock.thumbnail() }.value
        }
    }
}

/// Pick how many pieces, seeing exactly how the photo will be cut.
private struct CutStep: View {
    let photo: UIImage
    let back: () -> Void
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
                Button { back() } label: {
                    Label("Pictures", systemImage: "chevron.left")
                }
                Spacer()
                Button("Cancel") { dismiss() }
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

            // One row where it fits (iPad); wrapped onto more rows on a phone.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { sizes }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) { sizes }
            }

            Toggle(isOn: $snapToBoard) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snap to board")
                        .font(.body.weight(.medium))
                    Text(snapToBoard ? "Pieces lock into their spot, and to each other." : "Pieces only lock to the pieces beside them.")
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
    }
}

extension CutStep {
    private var sizes: some View {
        ForEach(Self.targets, id: \.self) { option in
            let cut = grid(option)
            let count = cut.rows * cut.cols
            Button { target = option } label: {
                Text("\(count)")
                    .font(.callout.weight(.medium).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(option == target ? Color(uiColor: .systemBackground) : Color.primary)
                    .frame(minWidth: 50, minHeight: 44)
                    .padding(.horizontal, 2)
                    .background(option == target ? Color.primary : Color.primary.opacity(0.07), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(count) pieces")
            .accessibilityAddTraits(option == target ? .isSelected : [])
        }
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
