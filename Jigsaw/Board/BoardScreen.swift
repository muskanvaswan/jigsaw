import SwiftUI

/// The full-screen puzzle: the table, a way out, how long you've been at it, a peek at the picture,
/// and who else is solving it, live or in their own time.
struct BoardScreen: View {
    let puzzleID: UUID
    let close: () -> Void

    @Environment(PuzzleStore.self) private var store
    @Environment(Account.self) private var account
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: BoardSession?
    @State private var peeking = false
    /// A brief line under the buttons saying what just changed.
    @State private var note: String?
    @State private var showingAccount = false
    @State private var isSharing = false
    @State private var failure: String?
    @State private var tip: BoardTip?
    @AppStorage("seenBoardTips") private var seenTips = false

    var body: some View {
        ZStack {
            Color.table.ignoresSafeArea()
            if let session {
                BoardCanvas(session: session, peeking: peeking)
                    .ignoresSafeArea()
                    .transition(.opacity)
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 12) {
                chrome
                if let note {
                    Text(note)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .chromeBackground(Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let session, session.isSolved { solvedBadge(session.record) }
        }
        .overlayPreferenceValue(TipAnchors.self) { anchors in
            if let tip {
                TipOverlay(tip: tip, anchors: anchors) { nextTip() }
                    .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.5), value: session?.isSolved)
        .animation(.spring(duration: 0.4), value: session?.collaborators)
        .animation(.spring(duration: 0.4), value: Live.shared.people)
        // Handed over explicitly: on a Mac, sheets don't always inherit them.
        .sheet(isPresented: $showingAccount) { AccountSheet().environment(store).environment(account) }
        .alert("Couldn't share", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .task { await open() }
        // Also when another puzzle replaces this one, say to join someone solving live.
        .onDisappear { session?.close() }
        .onChange(of: scenePhase) { _, phase in
            guard let session else { return }
            if phase == .active {
                session.resume()
                session.startSyncing(as: account.displayName)
            } else {
                session.pause()
                session.save()
                session.stopSyncing()
            }
        }
    }

    private var chrome: some View {
        HStack(spacing: 10) {
            ChromeButton(systemImage: "chevron.left", label: "Back to puzzles") { leave() }
                .keyboardShortcut(.escape, modifiers: [])
            Spacer(minLength: 8)
            if let session, !session.isSolved {
                // Narrow screens drop the faces and fold the clock into the counter.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        if session.isLive {
                            LiveFaces(people: Live.shared.people)
                        } else if !session.collaborators.isEmpty {
                            Faces(people: session.collaborators)
                        }
                        chip { Clock(session: session) }
                        chip { Text("\(session.progressCount) / \(session.record.pieceCount)") }
                            .accessibilityLabel("\(session.progressCount) of \(session.record.pieceCount) pieces in place")
                        buttons(session)
                    }
                    HStack(spacing: 8) {
                        chip {
                            HStack(spacing: 6) {
                                Text("\(session.progressCount)/\(session.record.pieceCount)")
                                Text("·")
                                Clock(session: session)
                            }
                        }
                        buttons(session)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.footnote.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 46)
            .chromeBackground(Capsule())
    }

    private func buttons(_ session: BoardSession) -> some View {
        HStack(spacing: 10) {
            ChromeButton(systemImage: peeking ? "eye.fill" : "eye", label: "Show picture", isActive: peeking) {
                peeking.toggle()
            }
            .tipAnchor(.peek)
            tools(session)
                .tipAnchor(.more)
        }
    }

    /// Things you reach for now and then, kept out of the way.
    private func tools(_ session: BoardSession) -> some View {
        Menu {
            Toggle(isOn: Binding(get: { session.isSpreadOut }, set: { session.setSpreadOut($0) })) {
                Label("Spread Out Pieces", systemImage: "square.grid.3x3.square")
            }
            Toggle(isOn: Binding(get: { session.record.snapsToBoard }, set: { snaps in
                session.setSnapsToBoard(snaps)
                show(snaps ? "Pieces snap to the board" : "Pieces only snap to each other")
            })) {
                Label("Snap to Board", systemImage: "square.grid.3x3")
            }
            Divider()
            Button(session.isShared ? "People…" : "Solve Together…", systemImage: "person.2") { share(session) }
                .disabled(isSharing)
            if session.isLive {
                Button("Stop Solving Live", systemImage: "shareplay.slash") { Live.shared.leave() }
            } else if session.isShared {
                Button("Solve Live with SharePlay", systemImage: "shareplay") { solveLive() }
            }
            Button("Show Tips", systemImage: "lightbulb") { showTips() }
        } label: {
            Group {
                if isSharing {
                    ProgressView()
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.primary)
                }
            }
            .frame(width: 46, height: 46)
            .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .chromeBackground(Circle())
        .accessibilityLabel("More")
    }

    private func share(_ session: BoardSession) {
        guard account.isSignedIn else {
            showingAccount = true
            return
        }
        isSharing = true
        Task {
            defer { isSharing = false }
            do {
                let share = try await session.share()
                Sharing.present(share, container: CloudSync.shared.container, thumbnail: store.thumbnails[puzzleID])
                session.startSyncing(as: account.displayName)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// Starts solving live, bringing the iCloud share along so anyone invited who hasn't opened the puzzle yet can get in.
    private func solveLive() {
        Task {
            let share = try? await store.share(puzzleID)
            await Live.shared.start(SolveLive(puzzleID: puzzleID, shareURL: share?.url))
        }
    }

    private func showTips() {
        withAnimation(.easeOut(duration: 0.3)) { tip = BoardTip.allCases.first }
    }

    private func nextTip() {
        withAnimation(.spring(duration: 0.45)) { tip = tip?.next }
        if tip == nil { seenTips = true }
    }

    private func show(_ text: String) {
        withAnimation(.spring(duration: 0.35)) { note = text }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard note == text else { return }
            withAnimation(.easeIn(duration: 0.3)) { note = nil }
        }
    }

    private func solvedBadge(_ record: PuzzleRecord) -> some View {
        VStack(spacing: 3) {
            Text("Solved")
                .font(.headline)
            Text("\(record.pieceCount) pieces · \(Duration.seconds(record.playTime).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .chromeBackground(Capsule())
        .padding(.bottom, 28)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func open() async {
        guard session == nil, let record = store.record(puzzleID) else { return }
        guard let opened = await BoardSession.open(record, store: store) else {
            close()
            return
        }
        withAnimation(.easeOut(duration: 0.35)) { session = opened }
        opened.resume()
        opened.startSyncing(as: account.displayName)
        Live.shared.attach(opened)
        #if DEBUG
        if DebugLaunch.livePartner { opened.pretendPartner() }
        #endif

        // The first time, once the board has settled in, point out what people miss.
        #if DEBUG
        guard !DebugLaunch.isScreenshotting else { return }
        #endif
        guard !seenTips, !opened.isSolved else { return }
        try? await Task.sleep(for: .seconds(0.8))
        if !Task.isCancelled { showTips() }
    }

    private func leave() {
        session?.close()
        close()
    }
}

/// Time spent on this puzzle, ticking while you play.
private struct Clock: View {
    let session: BoardSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = Duration.seconds(session.elapsed(at: context.date).rounded(.down))
            Text(elapsed.formatted(.time(pattern: elapsed >= .seconds(3600) ? .hourMinuteSecond : .minuteSecond)))
                .accessibilityLabel("Time: \(elapsed.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))")
        }
    }
}

/// Initials of the people solving with you; faded if they haven't been here in the last minute.
private struct Faces: View {
    let people: [Collaborator]

    var body: some View {
        HStack(spacing: -10) {
            ForEach(people.prefix(3)) { person in
                Text(person.name.initials)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(person.isHere ? 1 : 0.4), in: Circle())
                    .overlay(Circle().stroke(Color.table, lineWidth: 2))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Solving with " + people.map(\.name).joined(separator: ", "))
    }
}

/// Everyone solving live with you, in the colours their initials take on the board.
private struct LiveFaces: View {
    let people: [LivePerson]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shareplay")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color("AccentColor"))
            if people.isEmpty {
                Text("Live")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: -8) {
                    ForEach(people.prefix(3)) { person in
                        Text(person.name.initials)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color(uiColor: person.color), in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, people.isEmpty ? 14 : 7)
        .frame(height: 46)
        .chromeBackground(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(people.isEmpty ? "Solving live" : "Solving live with " + people.map(\.name).joined(separator: ", "))
    }
}

private struct BoardCanvas: UIViewRepresentable {
    let session: BoardSession
    let peeking: Bool

    func makeUIView(context: Context) -> BoardView {
        session.makeBoard()
    }

    func updateUIView(_ board: BoardView, context: Context) {
        board.setPeeking(peeking)
    }
}
