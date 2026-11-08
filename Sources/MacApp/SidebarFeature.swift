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

        /// What it's called where it's shown: its title, or else that it's new.
        var shownTitle: String { title ?? "New conversation" }
    }

    /// A conversation as a line in the sidebar: what it's called, whether something's new in it,
    /// and whether it's the one open.
    struct Entry: Equatable, Identifiable {
        let id: ConversationID
        let title: String
        let unread: Bool
        let isOpen: Bool
    }

    /// A space, with its conversations, as the sidebar shows it.
    struct Section: Equatable, Identifiable {
        let space: SpaceSummary
        let entries: [Entry]

        var id: String { space.id }
        /// Its admins rename it.
        var canRename: Bool { space.role == .admin }
    }

    /// A name being written: a conversation's or a space's new one, or a new space's.
    struct Naming: Equatable {
        enum Subject: Equatable {
            case conversation(ConversationID)
            case space(String)
            case newSpace
        }

        let subject: Subject
        var name: String

        /// What the dialog asks for.
        var title: String {
            switch subject {
            case .conversation: "Rename conversation"
            case .space: "Rename space"
            case .newSpace: "New space"
            }
        }

        /// What its button says.
        var confirmation: String {
            switch subject {
            case .conversation, .space: "Rename"
            case .newSpace: "Make"
            }
        }
    }

    /// Where a new conversation starts: in the one space there is, or in one picked.
    enum NewConversation: Equatable {
        case inSpace(String)
        /// The spaces to pick from, the open conversation's first.
        case pick([SpaceSummary])
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
        /// The name being written, while one is: none otherwise.
        var naming: Naming?

        var isNaming: Bool { naming != nil }
        /// What's written for the name, while one is.
        var name: String { naming?.name ?? "" }

        /// What the open conversation is called.
        var openTitle: String {
            selected.flatMap { conversations[id: $0]?.shownTitle } ?? "New conversation"
        }

        /// The space `id` is in, as it's listed.
        func space(of id: ConversationID) -> SpaceSummary? {
            conversations[id: id].flatMap { row in spaces.first { $0.id == row.spaceID } }
        }

        /// Each space, with its conversations, the one something was last said in first.
        var sections: [Section] {
            spaces.map { space in
                Section(
                    space: space,
                    entries: conversations.filter { $0.spaceID == space.id }.map {
                        Entry(id: $0.id, title: $0.shownTitle, unread: $0.unread, isOpen: $0.id == selected)
                    })
            }
        }

        /// Where New conversation starts one: none until the spaces are read.
        var newConversation: NewConversation? {
            guard let only = spaces.first else { return nil }
            guard spaces.count > 1 else { return .inSpace(only.id) }
            let open = selected.flatMap { conversations[id: $0]?.spaceID }
            return .pick(spaces.filter { $0.id == open } + spaces.filter { $0.id != open })
        }
    }

    enum Action {
        /// The window is shown for `session`: its spaces and conversations are read.
        case appeared(Session)
        case loaded([SpaceSummary], [Conversation])
        case failed(String)
        case selected(ConversationID)
        /// New conversation, in `spaceID`.
        case newConversationTapped(spaceID: String)
        case started(Conversation)
        /// They're in `conversation` now.
        case conversationJoined(Conversation)
        /// Something was said in `conversation`.
        case conversationSaid(Conversation)
        /// `conversation` is called something else.
        case conversationTitled(Conversation)
        case conversationLeft(ConversationID)
        /// Rename… on a conversation.
        case renameConversationTapped(ConversationID)
        /// Rename… on a space.
        case renameSpaceTapped(String)
        case newSpaceTapped
        case nameChanged(String)
        /// The naming dialog: `false` once it's closed.
        case namingPresented(Bool)
        case namingConfirmed
        case renamed(ConversationID, title: String)
        case spaceMade(SpaceSummary)
        case spaceRenamed(SpaceSummary)
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

            case .conversationJoined(let conversation):
                // A new one comes first, marked; one listed already is only called as it's called now.
                guard state.conversations[id: conversation.id] == nil else {
                    state.conversations[id: conversation.id]?.title = conversation.title
                    return .none
                }
                state.conversations.insert(
                    Row(id: conversation.id, title: conversation.title, spaceID: conversation.spaceID, unread: true),
                    at: 0)
                return .none

            case .conversationSaid(let conversation):
                // To the top, as the latest; marked when it isn't the one open.
                let unread = conversation.id != state.selected
                state.conversations.remove(id: conversation.id)
                state.conversations.insert(
                    Row(id: conversation.id, title: conversation.title, spaceID: conversation.spaceID, unread: unread),
                    at: 0)
                return .none

            case .conversationTitled(let conversation):
                state.conversations[id: conversation.id]?.title = conversation.title
                return .none

            case .conversationLeft(let id):
                state.conversations.remove(id: id)
                guard state.selected == id else { return .none }
                state.selected = nil
                if let next = state.conversations.first { return .send(.selected(next.id)) }
                return .none

            case .renameConversationTapped(let id):
                state.naming = Naming(subject: .conversation(id), name: state.conversations[id: id]?.title ?? "")
                return .none

            case .renameSpaceTapped(let id):
                state.naming = Naming(subject: .space(id), name: state.spaces.first { $0.id == id }?.name ?? "")
                return .none

            case .newSpaceTapped:
                state.naming = Naming(subject: .newSpace, name: "")
                return .none

            case .nameChanged(let name):
                state.naming?.name = name
                return .none

            case .namingPresented(let presented):
                if !presented { state.naming = nil }
                return .none

            case .namingConfirmed:
                guard let naming = state.naming, let session = state.session else { return .none }
                state.naming = nil
                let name = naming.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return .none }
                return .run { send in
                    do {
                        switch naming.subject {
                        case .conversation(let id):
                            try await server.titleConversation(session, id, name)
                            await send(.renamed(id, title: name))
                        case .space(let id):
                            await send(.spaceRenamed(try await server.renameSpace(session, id, name)))
                        case .newSpace:
                            await send(.spaceMade(try await server.makeSpace(session, name)))
                        }
                    } catch {
                        await send(.failed("Couldn't save the name."))
                    }
                }

            case .renamed(let id, let title):
                state.conversations[id: id]?.title = title
                return .none

            case .spaceMade(let space):
                state.spaces.append(space)
                return .none

            case .spaceRenamed(let space):
                guard let index = state.spaces.firstIndex(where: { $0.id == space.id }) else { return .none }
                state.spaces[index] = space
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
