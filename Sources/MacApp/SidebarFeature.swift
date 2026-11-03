import ComposableArchitecture
import Foundation
import TurgaiModels

/// The window's sidebar: the person's spaces, each with its conversations, the one something was
/// last said in first; the one open; and which have something new since they were last open.
@Reducer
struct SidebarFeature {
    /// A conversation, as the sidebar lists it.
    struct Row: Equatable, Identifiable, Sendable {
        let id: ConversationID
        var title: String?
        let spaceID: String
        /// Something was said in it since it was last open.
        var unread = false
    }

    @ObservableState
    struct State: Equatable {
        /// Who the sidebar is for: none until the window has someone signed in.
        var session: Session?
        var spaces: [SpaceSummary] = []
        var conversations: IdentifiedArrayOf<Row> = []
        var selected: ConversationID?
        /// What went wrong reading or starting conversations, when something did.
        var error: String?
    }

    enum Action {
        /// The window is shown for `session`: its spaces and conversations are read.
        case appeared(Session)
        case loaded([SpaceSummary], [Conversation])
        case failed(String)
        case selected(ConversationID)
        /// ✎ in a space's header: a new conversation there.
        case newConversationTapped(spaceID: String)
        case started(Conversation)
        case conversationChanged(Conversation)
        case conversationLeft(ConversationID)
        case delegate(Delegate)

        enum Delegate: Equatable {
            /// The window should show `id`.
            case open(ConversationID)
        }
    }

    @Dependency(\.server) var server

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .appeared(let session):
                state.session = session
                return .run { send in
                    do {
                        await send(.loaded(try await server.spaces(session), try await server.conversations(session)))
                    } catch {
                        await send(.failed("Couldn't read your conversations."))
                    }
                }

            case .loaded(let spaces, let conversations):
                state.spaces = spaces
                state.conversations = IdentifiedArray(
                    uniqueElements: conversations.map { Row(id: $0.id, title: $0.title, spaceID: $0.spaceID) })
                state.error = nil
                if let selected = state.selected, state.conversations[id: selected] != nil { return .none }
                // The latest is shown first; with none, a new one in Turgai's own space.
                if let latest = state.conversations.first {
                    return .send(.selected(latest.id))
                }
                return start(in: nil, as: state.session)

            case .failed(let why):
                state.error = why
                return .none

            case .selected(let id):
                state.selected = id
                state.conversations[id: id]?.unread = false
                return .send(.delegate(.open(id)))

            case .newConversationTapped(let space):
                return start(in: space, as: state.session)

            case .started(let conversation):
                state.conversations.insert(
                    Row(id: conversation.id, title: conversation.title, spaceID: conversation.spaceID), at: 0)
                return .send(.selected(conversation.id))

            case .conversationChanged(let conversation):
                // To the top, as the latest; marked when it isn't the one open.
                let unread = conversation.id != state.selected
                state.conversations.remove(id: conversation.id)
                state.conversations.insert(
                    Row(id: conversation.id, title: conversation.title, spaceID: conversation.spaceID, unread: unread),
                    at: 0)
                return .none

            case .conversationLeft(let id):
                state.conversations.remove(id: id)
                guard state.selected == id else { return .none }
                state.selected = nil
                if let next = state.conversations.first { return .send(.selected(next.id)) }
                return .none

            case .delegate:
                return .none
            }
        }
    }

    /// A new conversation in `space`, or Turgai's own, started for `session`'s person.
    private func start(in space: String?, as session: Session?) -> Effect<Action> {
        guard let session else { return .none }
        return .run { send in
            do {
                await send(.started(try await server.startConversation(session, space)))
            } catch {
                await send(.failed("Couldn't start a conversation."))
            }
        }
    }
}
