import ComposableArchitecture
import Foundation
import TurgaiModels

/// The signed-in person's profile: who they are, what's remembered about them, forgetting all of it
/// once they say so again, and signing out.
@Reducer
struct ProfileFeature {
    /// What's remembered about them, as it's read.
    enum Memory: Equatable {
        case reading
        case read(MemorySummary)
        /// It couldn't be read or forgotten, and why.
        case failed(String)
    }

    /// A remembered name, as a line of the profile shows it: how far under the person it is, and
    /// what was said for it, when anything was.
    struct MemoryLine: Equatable, Identifiable {
        /// The names down to it.
        let path: [String]
        let said: String?

        var id: [String] { path }
        var name: String { path.last ?? "" }
        /// How many names it's under.
        var depth: Int { path.count - 1 }
    }

    /// What the memory section shows.
    enum MemoryShown: Equatable {
        case reading
        case lines([MemoryLine])
        /// Words instead: that nothing's remembered, or why it couldn't be read.
        case note(String)
    }

    @ObservableState
    struct State: Equatable {
        /// Who it's for: none until someone's signed in.
        var session: Session?
        /// Who's signed in, once it's read.
        var me: Me?
        var memory = Memory.reading
        /// Asking whether to forget everything, while it asks.
        @Presents var alert: AlertState<Action.Alert>?

        /// What the account button and the profile show: the first letter of the name, once it's read.
        var initial: String { me.map { $0.name.prefix(1).uppercased() } ?? "" }
        var name: String { me?.name ?? "" }
        /// Someone's signed in: the profile is theirs.
        var isSignedIn: Bool { session != nil }

        var memoryShown: MemoryShown {
            switch memory {
            case .reading: .reading
            case .read(let summary) where summary.nodes.isEmpty: .note("Nothing is remembered about you yet.")
            case .read(let summary): .lines(Self.lines(of: summary.nodes, under: []))
            case .failed(let why): .note(why)
            }
        }

        /// There's something remembered to forget.
        var canForget: Bool {
            if case .lines = memoryShown { true } else { false }
        }

        private static func lines(of nodes: [MemorySummary.Node], under path: [String]) -> [MemoryLine] {
            nodes.flatMap { node in
                let here = path + [node.name]
                return [MemoryLine(path: here, said: node.said)] + lines(of: node.children, under: here)
            }
        }
    }

    enum Action {
        /// Someone's signed in as `session`: who they are is read.
        case appeared(Session)
        case meLoaded(Me)
        /// The profile is shown: what's remembered is read again.
        case shown
        case memoryLoaded(MemorySummary)
        case memoryFailed(String)
        /// Forget Everything…: it's asked again.
        case forgetTapped
        case alert(PresentationAction<Alert>)
        case forgotten
        /// Sign Out: the app signs them out.
        case signOutTapped

        enum Alert: Equatable {
            case forgetConfirmed
        }
    }

    @Dependency(\.server) var server

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .appeared(let session):
                state.session = session
                return .run { send in
                    if let me = try? await server.me(session) { await send(.meLoaded(me)) }
                }

            case .meLoaded(let me):
                state.me = me
                return .none

            case .shown:
                guard let session = state.session else { return .none }
                state.memory = .reading
                return .run { send in
                    do {
                        await send(.memoryLoaded(try await server.memory(session)))
                    } catch {
                        await send(.memoryFailed("Couldn't read what's remembered."))
                    }
                }

            case .memoryLoaded(let summary):
                state.memory = .read(summary)
                return .none

            case .memoryFailed(let why):
                state.memory = .failed(why)
                return .none

            case .forgetTapped:
                state.alert = .forgetEverything
                return .none

            case .alert(.presented(.forgetConfirmed)):
                guard let session = state.session else { return .none }
                return .run { send in
                    do {
                        try await server.forgetMemory(session)
                        await send(.forgotten)
                    } catch {
                        await send(.memoryFailed("Couldn't forget it. Try again."))
                    }
                }

            case .alert:
                return .none

            case .forgotten:
                state.memory = .read(MemorySummary(nodes: []))
                return .none

            case .signOutTapped:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }
}

extension AlertState where Action == ProfileFeature.Action.Alert {
    static let forgetEverything = AlertState {
        TextState("Forget everything remembered about you?")
    } actions: {
        ButtonState(role: .destructive, action: .forgetConfirmed) { TextState("Forget Everything") }
        ButtonState(role: .cancel) { TextState("Cancel") }
    } message: {
        TextState("Your conversations stay; only what was remembered from them goes.")
    }
}
