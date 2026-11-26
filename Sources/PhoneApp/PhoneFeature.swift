import ComposableArchitecture
import TurgaiClient
import TurgaiModels

/// Turgai on a phone: the app, arranged as on a Mac: the spaces and the shown one's conversations
/// or pages, and beside them what's open. Where the two don't fit side by side, what's open comes
/// over the spaces once something's opened. Only that is kept here: what's open, the app keeps.
@Reducer
struct PhoneFeature {
    @ObservableState
    struct State: Equatable {
        var app: AppFeature.State
        /// Whether what's open is over the spaces, where the two don't fit side by side.
        var showsOpen = false
        /// Whether the account is shown, over everything.
        var accountShown = false
    }

    enum Action {
        case app(AppFeature.Action)
        case conversationTapped(ConversationID)
        case pageTapped(PageAddress)
        /// Back to the spaces from what's open over them.
        case openClosed
        case accountTapped
        case accountClosed
    }

    var body: some ReducerOf<Self> {
        Scope(\.app, action: \.app) {
            AppFeature()
        }
        Reduce { state, action in
            switch action {
            case .conversationTapped(let id):
                state.showsOpen = true
                return .send(.app(.sidebar(.selected(id))))

            case .pageTapped(let address):
                state.showsOpen = true
                return .send(.app(.pageOpened(address)))

            case .openClosed:
                // Back to the spaces: an open page is closed; the conversation stays the one open.
                state.showsOpen = false
                return state.app.openPage == nil ? .none : .send(.app(.pageClosed))

            case .accountTapped:
                state.accountShown = true
                return .send(.app(.profile(.shown)))

            case .accountClosed:
                state.accountShown = false
                return .send(.app(.profile(.hidden)))

            // A conversation just started opens.
            case .app(.sidebar(.started)):
                state.showsOpen = true
                return .none

            // Another space: its spaces' side first.
            case .app(.sidebar(.spaceSwitched)):
                state.showsOpen = false
                return .none

            // Signed out: the phone's as it was.
            case .app(.profile(.signOutTapped)), .app(.sessionExpired):
                state.showsOpen = false
                state.accountShown = false
                return .none

            case .app:
                return .none
            }
        }
    }
}

extension PhoneFeature {
    /// The phone's store, from its first state: the server chosen before, when one was, read before
    /// anything's shown; none until one's chosen.
    @MainActor
    static func store() -> StoreOf<PhoneFeature> {
        let chosen = ServerChoice.liveValue.load().map(AppFeature.Server.elsewhere)
        return Store(initialState: State(app: AppFeature.State(server: chosen))) {
            PhoneFeature()
        } withDependencies: {
            AppFeature.prepare(&$0)
        }
    }
}
