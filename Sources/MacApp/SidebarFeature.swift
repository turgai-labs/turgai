import ComposableArchitecture
import Foundation
import TurgaiModels

/// The window's sidebar, Slack's way: every space the person is in, on a rail; the one shown, the
/// open conversation's, with its conversations, the one something was last said in first; the one
/// open; and which have something new since they were last open.
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

    /// A space on the rail: whether it's the one shown, and whether something's new in it.
    struct SpaceChoice: Equatable, Identifiable {
        let space: SpaceSummary
        let isShown: Bool
        let unread: Bool

        var id: String { space.id }
        /// What its tile says: the first letter of its name.
        var initial: String { space.name.prefix(1).uppercased() }
        var hue: SpaceHue { SpaceHue(name: space.name) }
    }

    /// A space's color, one of the brand's signals, worked out from its name: the same name has
    /// the same one wherever and whenever it's shown.
    enum SpaceHue: CaseIterable, Equatable {
        case coral
        case yellow
        case blue

        init(name: String) {
            let hash = name.utf16.reduce(Int32(0)) { hash, unit in (hash &<< 5) &- hash &+ Int32(unit) }
            self = Self.allCases[Int(hash.magnitude % UInt32(Self.allCases.count))]
        }
    }

    /// The dialog open over the window, with what's written in it.
    enum Dialog: Equatable {
        /// A conversation's or a space's new name.
        case renaming(Renaming)
        /// A space to make, by its name, or to join, by an invite's link.
        case addingSpace(AddingSpace)
        /// An invite to a space, its link to give someone.
        case inviting(Inviting)

        /// What's written for a name in it: nothing in an invite.
        var name: String {
            get {
                switch self {
                case .renaming(let renaming): renaming.name
                case .addingSpace(let adding): adding.name
                case .inviting: ""
                }
            }
            set {
                switch self {
                case .renaming(var renaming):
                    renaming.name = newValue
                    self = .renaming(renaming)
                case .addingSpace(var adding):
                    adding.name = newValue
                    self = .addingSpace(adding)
                case .inviting:
                    break
                }
            }
        }
    }

    /// An invite to a space being made: its link once it's made, or why it couldn't be.
    struct Inviting: Equatable {
        let spaceName: String
        /// The link to give someone: none while it's made, or when it couldn't be.
        var link: String?
        var problem: String?

        /// What the dialog is called.
        var title: String { "Invite people to \(spaceName)" }
    }

    /// What the shown space's menu offers its admins: renaming it, and inviting people to it.
    struct SpaceMenu: Equatable {
        let rename: String
        let invite: String
    }

    /// A conversation's or a space's new name, being written.
    struct Renaming: Equatable {
        enum Subject: Equatable {
            case conversation(ConversationID)
            case space(String)
        }

        let subject: Subject
        var name: String

        /// What the dialog asks for.
        var title: String {
            switch subject {
            case .conversation: "Rename conversation"
            case .space: "Rename space"
            }
        }
    }

    /// A space being added: made, by the name written, or joined, by the invite's link pasted.
    struct AddingSpace: Equatable {
        var name = ""
        var link = ""
        /// What went wrong making or joining one, when something did.
        var problem: String?

        /// The invite the link is: none while it isn't one.
        var invite: SpaceInviteLink? { SpaceInviteLink(link) }
        var canMake: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var canJoin: Bool { invite != nil }
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
        /// How many people each space has, by its id, once they're counted.
        var peopleCounts: [String: Int] = [:]
        /// The dialog open, while one is.
        var dialog: Dialog?

        var hasDialog: Bool { dialog != nil }
        /// What's written for a name in the dialog.
        var name: String { dialog?.name ?? "" }
        /// What's pasted for a link in the dialog.
        var link: String {
            if case .addingSpace(let adding) = dialog { adding.link } else { "" }
        }

        /// What the open conversation is called.
        var openTitle: String {
            selected.flatMap { conversations[id: $0]?.shownTitle } ?? "New conversation"
        }

        /// The space `id` is in, as it's listed.
        func space(of id: ConversationID) -> SpaceSummary? {
            conversations[id: id].flatMap { row in spaces.first { $0.id == row.spaceID } }
        }

        /// The space shown: the open conversation's, or the first before one is open.
        var shownSpace: SpaceSummary? {
            selected.flatMap(space(of:)) ?? spaces.first
        }

        /// The shown space's conversations, the one something was last said in first.
        var entries: [Entry] {
            conversations.filter { $0.spaceID == shownSpace?.id }.map {
                Entry(id: $0.id, title: $0.shownTitle, unread: $0.unread, isOpen: $0.id == selected)
            }
        }

        /// What the panel is headed: the shown space's name, or Spaces before they're read.
        var shownSpaceName: String { shownSpace?.name ?? "Spaces" }

        /// The shown space's initial, as its tile on the rail has it.
        var shownSpaceInitial: String { shownSpace.map { $0.name.prefix(1).uppercased() } ?? "" }
        /// The shown space's color, as its tile on the rail has it.
        var shownSpaceHue: SpaceHue { SpaceHue(name: shownSpace?.name ?? "") }

        /// What the shown space is, under its name: a space, and how many people are in it once
        /// they're counted.
        var shownSpaceDetail: String {
            switch shownSpace.flatMap({ peopleCounts[$0.id] }) {
            case nil: "Space"
            case 1?: "Space · 1 person"
            case let count?: "Space · \(count) people"
            }
        }

        /// Every space, for the rail.
        var spaceChoices: [SpaceChoice] {
            spaces.map { space in
                SpaceChoice(
                    space: space, isShown: space.id == shownSpace?.id,
                    unread: conversations.contains { $0.spaceID == space.id && $0.unread })
            }
        }

        /// What renaming the shown space says, when its person is one of its admins: none otherwise.
        var shownSpaceMenu: SpaceMenu? {
            shownSpace.flatMap {
                $0.role == .admin ? SpaceMenu(rename: "Rename “\($0.name)”…", invite: "Invite People…") : nil
            }
        }

        /// What New conversation says it does.
        var newConversationHelp: String {
            shownSpace.map { "New conversation in \($0.name)" } ?? "New conversation"
        }
    }

    enum Action {
        /// The window is shown for `session`: its spaces and conversations are read.
        case appeared(Session)
        case loaded([SpaceSummary], [Conversation])
        case failed(String)
        case selected(ConversationID)
        /// `count` people are in the space `spaceID`.
        case peopleCounted(String, Int)
        /// A space picked on the rail: its latest conversation opens, or a new one starts there.
        case spaceSwitched(String)
        /// New conversation, in the shown space.
        case newConversationTapped
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
        /// Rename… on the space shown.
        case renameShownSpaceTapped
        /// Invite People… on the space shown: an invite to it is made.
        case inviteTapped
        case inviteMade(SpaceInviteOffer)
        case inviteFailed
        /// Copy in the invite: its link is copied.
        case copyInviteTapped
        /// + on the rail: a space to make or join.
        case addSpaceTapped
        case nameChanged(String)
        case linkChanged(String)
        /// The dialog: `false` once it's closed.
        case dialogPresented(Bool)
        case renameConfirmed
        case makeSpaceTapped
        case joinTapped
        case renamed(ConversationID, title: String)
        case spaceRenamed(SpaceSummary)
        /// A space made or joined: it's shown.
        case spaceAdded(SpaceSummary)
        /// Making or joining a space failed, and why.
        case addingFailed(String)
        case delegate(Delegate)

        enum Delegate: Equatable {
            /// The window should show `id`.
            case open(ConversationID)
        }
    }

    @Dependency(\.server) var server
    @Dependency(\.pasteboard) var pasteboard

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
                return .merge(.send(.delegate(.open(id))), countPeople(in: state.shownSpace, of: state))

            case .peopleCounted(let space, let count):
                state.peopleCounts[space] = count
                return .none

            case .spaceSwitched(let space):
                guard space != state.shownSpace?.id else { return .none }
                if let latest = state.conversations.first(where: { $0.spaceID == space }) {
                    return .send(.selected(latest.id))
                }
                return start(in: space, as: state.session)

            case .newConversationTapped:
                return start(in: state.shownSpace?.id, as: state.session)

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
                state.dialog = .renaming(
                    Renaming(subject: .conversation(id), name: state.conversations[id: id]?.title ?? ""))
                return .none

            case .renameShownSpaceTapped:
                guard let space = state.shownSpace else { return .none }
                state.dialog = .renaming(Renaming(subject: .space(space.id), name: space.name))
                return .none

            case .inviteTapped:
                guard let space = state.shownSpace, let session = state.session else { return .none }
                state.dialog = .inviting(Inviting(spaceName: space.name))
                return .run { send in
                    do {
                        await send(.inviteMade(try await server.makeInvite(session, space.id)))
                    } catch {
                        await send(.inviteFailed)
                    }
                }

            case .inviteMade(let offer):
                guard case .inviting(var inviting) = state.dialog else { return .none }
                inviting.link = offer.link
                state.dialog = .inviting(inviting)
                return .none

            case .inviteFailed:
                guard case .inviting(var inviting) = state.dialog else { return .none }
                inviting.problem = "Couldn't make an invite. Try again."
                state.dialog = .inviting(inviting)
                return .none

            case .copyInviteTapped:
                guard case .inviting(let inviting) = state.dialog, let link = inviting.link else { return .none }
                return .run { _ in await pasteboard.copy(link) }

            case .addSpaceTapped:
                state.dialog = .addingSpace(AddingSpace())
                return .none

            case .nameChanged(let name):
                state.dialog?.name = name
                return .none

            case .linkChanged(let link):
                guard case .addingSpace(var adding) = state.dialog else { return .none }
                adding.link = link
                adding.problem = nil
                state.dialog = .addingSpace(adding)
                return .none

            case .dialogPresented(let presented):
                if !presented { state.dialog = nil }
                return .none

            case .renameConfirmed:
                guard case .renaming(let renaming) = state.dialog, let session = state.session else { return .none }
                state.dialog = nil
                let name = renaming.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return .none }
                return .run { send in
                    do {
                        switch renaming.subject {
                        case .conversation(let id):
                            try await server.titleConversation(session, id, name)
                            await send(.renamed(id, title: name))
                        case .space(let id):
                            await send(.spaceRenamed(try await server.renameSpace(session, id, name)))
                        }
                    } catch {
                        await send(.failed("Couldn't save the name."))
                    }
                }

            case .makeSpaceTapped:
                guard case .addingSpace(let adding) = state.dialog, adding.canMake, let session = state.session
                else { return .none }
                let name = adding.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return .run { send in
                    do {
                        await send(.spaceAdded(try await server.makeSpace(session, name)))
                    } catch {
                        await send(.addingFailed("Couldn't make the space."))
                    }
                }

            case .joinTapped:
                guard case .addingSpace(let adding) = state.dialog, let invite = adding.invite,
                    let session = state.session
                else { return .none }
                return .run { send in
                    do {
                        await send(.spaceAdded(try await server.joinSpace(session, invite)))
                    } catch {
                        await send(.addingFailed("That link didn't work: it may be used up or out of date."))
                    }
                }

            case .spaceAdded(let space):
                state.dialog = nil
                if !state.spaces.contains(where: { $0.id == space.id }) { state.spaces.append(space) }
                return .send(.spaceSwitched(space.id))

            case .addingFailed(let why):
                guard case .addingSpace(var adding) = state.dialog else { return .none }
                adding.problem = why
                state.dialog = .addingSpace(adding)
                return .none

            case .renamed(let id, let title):
                state.conversations[id: id]?.title = title
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

    /// How many people are in `space`, counted once for `state`'s person.
    private func countPeople(in space: SpaceSummary?, of state: State) -> Effect<Action> {
        guard let space, state.peopleCounts[space.id] == nil, let session = state.session else { return .none }
        return .run { send in
            if let people = try? await server.people(session, space.id) {
                await send(.peopleCounted(space.id, people.count))
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
