import SwiftUI

@main
struct JigsawApp: App {
    @State private var store = PuzzleStore()

    init() {
        Click.prepare()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(Color("AccentColor"))
        }
    }
}

/// The library, with the open puzzle laid over it. No navigation stack, so no system
/// swipe-back gesture can fight with dragging pieces.
struct RootView: View {
    @State private var openPuzzle: UUID?

    var body: some View {
        ZStack {
            LibraryView { id in
                withAnimation(.easeInOut(duration: 0.3)) { openPuzzle = id }
            }
            if let id = openPuzzle {
                BoardScreen(puzzleID: id) {
                    withAnimation(.easeInOut(duration: 0.3)) { openPuzzle = nil }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .statusBarHidden(openPuzzle != nil)
        .persistentSystemOverlays(openPuzzle == nil ? .automatic : .hidden)
    }
}
