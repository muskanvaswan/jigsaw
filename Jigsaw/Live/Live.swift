import Combine
import GroupActivities
import Observation
import UIKit

/// Solving one puzzle at the same time as everyone on a FaceTime call or in a Messages chat, with each
/// other's hands on the table. The puzzle still lives in iCloud, so when the call ends everyone simply
/// carries on solving whenever suits them.
struct SolveLive: GroupActivity {
    /// The same on every device that has the puzzle.
    let puzzleID: UUID
    /// Lets in anyone invited to the puzzle who hasn't opened it yet.
    let shareURL: URL?

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = "Jigsaw puzzle"
        metadata.subtitle = "Solve it together, live"
        metadata.type = .generic
        return metadata
    }
}

/// What one board tells the others while solving live. Positions are in board pixels, the same on every device.
enum LiveMessage: Codable {
    /// Your name, for the others to put beside what you pick up.
    case hello(name: String)
    /// Holding the pieces joined to `piece`, which lie `at` this far from where they belong. Sent on picking
    /// them up, then over and over while carrying them.
    case hold(piece: Int, at: CGPoint)
    case letGo(piece: Int)
    /// Where pieces ended up: dropped, snapped in, or spread out.
    case moved([Int: PieceState])
    case snapToBoard(Bool)
}

/// Someone else solving live.
struct LivePerson: Identifiable, Equatable {
    let id: UUID
    var name: String

    /// Worked out from who they are rather than when they joined, so everyone sees them in the same colour.
    var color: UIColor {
        let palette: [UIColor] = [
            UIColor(red: 0.17, green: 0.53, blue: 0.55, alpha: 1),
            UIColor(red: 0.55, green: 0.34, blue: 0.62, alpha: 1),
            UIColor(red: 0.80, green: 0.58, blue: 0.13, alpha: 1),
            UIColor(red: 0.25, green: 0.44, blue: 0.76, alpha: 1),
            UIColor(red: 0.33, green: 0.58, blue: 0.33, alpha: 1),
            UIColor(red: 0.78, green: 0.33, blue: 0.47, alpha: 1),
        ]
        let sum = id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}

/// The live session, if there is one. It talks to the board only while that puzzle is open; the rest of the
/// time iCloud keeps everyone's copy up to date as usual.
@MainActor
@Observable
final class Live {
    static let shared = Live()

    /// The puzzle being solved live.
    private(set) var puzzleID: UUID?
    /// Everyone else in the session.
    private(set) var people: [LivePerson] = []
    /// What the others call you.
    @ObservationIgnored var name = "Someone"

    @ObservationIgnored private var session: GroupSession<SolveLive>?
    @ObservationIgnored private var messenger: GroupSessionMessenger?
    /// For where a carried piece is right now: the next one is never far behind, so a lost one doesn't matter.
    @ObservationIgnored private var quickMessenger: GroupSessionMessenger?
    @ObservationIgnored private var listening: [Task<Void, Never>] = []
    @ObservationIgnored private var names: [UUID: String] = [:]
    @ObservationIgnored private weak var board: BoardSession?

    func isLive(_ puzzleID: UUID) -> Bool { self.puzzleID == puzzleID }

    /// Starts solving this puzzle live: straight away on a FaceTime call, otherwise by inviting people in Messages.
    func start(_ activity: SolveLive) async {
        if GroupStateObserver().isEligibleForGroupSession {
            guard await activity.prepareForActivation() == .activationPreferred else { return }
            _ = try? await activity.activate()
        } else if let controller = try? GroupActivitySharingController(activity) {
            Sharing.topViewController()?.present(controller, animated: true)
        }
    }

    /// Takes part in a session, whether you started it or someone else did.
    func join(_ session: GroupSession<SolveLive>) {
        end()
        let messenger = GroupSessionMessenger(session: session)
        let quickMessenger = GroupSessionMessenger(session: session, deliveryMode: .unreliable)
        self.session = session
        self.messenger = messenger
        self.quickMessenger = quickMessenger
        puzzleID = session.activity.puzzleID
        listening = [
            Task {
                for await state in session.$state.values {
                    if case .invalidated = state { self.end() }
                }
            },
            Task {
                for await participants in session.$activeParticipants.values { self.update(participants) }
            },
            Task {
                for await (message, context) in messenger.messages(of: LiveMessage.self) { self.receive(message, from: context.source.id) }
            },
            Task {
                for await (message, context) in quickMessenger.messages(of: LiveMessage.self) { self.receive(message, from: context.source.id) }
            },
        ]
        session.join()
    }

    /// Stops solving live here; everyone else carries on.
    func leave() {
        session?.leave()
        end()
    }

    /// Tells the others, in the order things happened. `quickly` is for a carried piece's latest position.
    func send(_ message: LiveMessage, quickly: Bool = false) {
        guard let messenger = quickly ? quickMessenger : messenger else { return }
        messenger.send(message) { _ in }
    }

    /// The open puzzle, which hears from the others while it's the one being solved live.
    func attach(_ board: BoardSession) {
        self.board = board
    }

    func detach(_ board: BoardSession) {
        if self.board === board { self.board = nil }
    }

    private var liveBoard: BoardSession? {
        guard let board, board.record.id == puzzleID else { return nil }
        return board
    }

    private func end() {
        listening.forEach { $0.cancel() }
        listening = []
        session = nil
        messenger = nil
        quickMessenger = nil
        names = [:]
        puzzleID = nil
        people = []
        board?.livePeopleChanged([])
    }

    private func update(_ participants: Set<Participant>) {
        guard let session else { return }
        people = participants
            .filter { $0 != session.localParticipant }
            .map { LivePerson(id: $0.id, name: names[$0.id] ?? "Someone") }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        // Anyone just arrived needs to hear everyone's name.
        send(.hello(name: name))
        liveBoard?.livePeopleChanged(Set(people.map(\.id)))
    }

    private func receive(_ message: LiveMessage, from id: UUID) {
        if case .hello(let name) = message {
            names[id] = name
            if let index = people.firstIndex(where: { $0.id == id }) { people[index].name = name }
            return
        }
        let person = people.first { $0.id == id } ?? LivePerson(id: id, name: names[id] ?? "Someone")
        liveBoard?.receive(message, from: person)
    }

    #if DEBUG
    /// Acts as though a session is on, for trying it in the simulator, where there's no FaceTime.
    func pretend(_ person: LivePerson, on puzzleID: UUID) {
        self.puzzleID = puzzleID
        people = [person]
    }
    #endif
}
