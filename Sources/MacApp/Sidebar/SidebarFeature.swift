import ComposableArchitecture
import Foundation
import SwiftUI
import TurgaiModels

/// A space's color, one of the brand's signals, worked out from its name: the same name has the
/// same one wherever and whenever it's shown.
enum SpaceHue: CaseIterable, Equatable {
    case coral
    case yellow
    case blue

    init(name: String) {
        let hash = name.utf16.reduce(Int32(0)) { hash, unit in (hash &<< 5) &- hash &+ Int32(unit) }
        self = Self.allCases[Int(hash.magnitude % UInt32(Self.allCases.count))]
    }
}

/// How a stamp is drawn: filled with its color, for what's shown, or only its outline.
enum StampFill: Equatable {
    case filled
    case outlined
}

/// The window's sidebar, Slack's way: the spaces in use the person is in, on a rail, the one
/// something was last said in first, and every space, archived ones too, in a list; the one shown,
/// with its conversations, the one something was last said in first; the one open; and which have
/// something new since they were last open.
@Reducer
struct SidebarFeature {
    /// A conversation, as the sidebar lists it.
    struct Row: Equatable, Identifiable, Sendable {
        let id: ConversationID
        var title: String?
        let spaceID: SpaceID
        /// How many people are in it.
        var people: Int
        /// Something was said in it since it was last open.
        var unread = false

        /// `conversation`, as it's listed.
        init(_ conversation: Conversation, unread: Bool = false) {
            self.init(
                id: conversation.id, title: conversation.title, spaceID: conversation.spaceID,
                people: conversation.people, unread: unread)
        }

        init(id: ConversationID, title: String? = nil, spaceID: SpaceID, people: Int, unread: Bool = false) {
            self.id = id
            self.title = title
            self.spaceID = spaceID
            self.people = people
            self.unread = unread
        }

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
        /// What its menu offers.
        let menu: [ConversationMenuItem]

        /// Whether it stands out of the list: open, or with something new in it. The rest recede.
        var standsOut: Bool { unread || isOpen }

        /// How its stamp leans while it's open.
        var lean: Lean { Lean(seed: id.rawValue) }
    }

    /// A space on the rail: whether it's the one shown, and whether something's new in it.
    struct SpaceChoice: Equatable, Identifiable {
        let space: SpaceSummary
        let isShown: Bool
        let unread: Bool

        var id: SpaceID { space.id }
        /// How its tile is drawn: filled in while it's shown, as the open conversation's row is;
        /// an outline otherwise.
        var fill: StampFill { isShown ? .filled : .outlined }
        /// What its tile says: the first letter of its name.
        var initial: String { space.name.prefix(1).uppercased() }
        var hue: SpaceHue { SpaceHue(name: space.name) }
        /// How its tile leans.
        var lean: Lean { Lean(seed: space.id.rawValue) }
    }

    /// What a conversation's menu offers: renaming it while its space is in use; leaving it while
    /// others are in it; deleting it, for everyone, when they're the only one in it, or an admin of
    /// its space.
    enum ConversationMenuItem: Hashable, Identifiable {
        case rename
        case leave
        case delete

        var id: Self { self }
    }

    /// What the shown space's menu offers: inviting people to it, its bots, renaming it, and
    /// archiving it, while it's in use, each to whoever may; using it again, once it's archived.
    enum SpaceMenuItem: Hashable, Identifiable {
        case invite
        case bots
        case connections
        case rename
        case archive
        case unarchive

        var id: Self { self }
    }

    /// Spaces in the Spaces list under one heading: those in use, or those archived.
    struct SpaceSection: Equatable, Identifiable {
        let status: SpaceSummary.Status
        let choices: [SpaceChoice]

        var id: SpaceSummary.Status { status }
    }

    @ObservableState
    struct State: Equatable {
        /// Who the sidebar is for: none until the window has someone signed in.
        var session: Session?
        var spaces: [SpaceSummary] = []
        var conversations: IdentifiedArrayOf<Row> = []
        var selected: ConversationID?
        /// The space shown: the open conversation's, or the one picked; the first before either.
        var shownSpaceID: SpaceID?
        /// What went wrong reading or starting conversations, when something did.
        var error: String?
        /// How many people each space has, by its id, once they're counted.
        var peopleCounts: [SpaceID: Int] = [:]
        /// The shown space's tasks, under its conversations.
        var tasks = TasksFeature.State()
        /// What's over the window, while something is.
        @Presents var destination: Destination.State?

        /// What the open conversation is called: nothing while none is.
        var openTitle: String {
            selected.map { conversations[id: $0]?.shownTitle ?? "New conversation" } ?? ""
        }

        /// The space `id` is in, as it's listed.
        func space(of id: ConversationID) -> SpaceSummary? {
            conversations[id: id].flatMap { row in spaces.first { $0.id == row.spaceID } }
        }

        /// The space shown: the open conversation's, or the one picked; the first before either.
        var shownSpace: SpaceSummary? {
            shownSpaceID.flatMap { id in spaces.first { $0.id == id } } ?? spaces.first
        }

        /// How many people are in the shown space, once they're counted, when there's more than one.
        var shownSpacePeople: Int? { shownSpace.flatMap { peopleCounts[$0.id] }.flatMap { $0 > 1 ? $0 : nil } }

        /// Whether the shown space is archived.
        var shownSpaceIsArchived: Bool { shownSpace?.status == .archived }

        /// The shown space's conversations, the one something was last said in first.
        var entries: [Entry] {
            let space = shownSpace
            return conversations.filter { $0.spaceID == space?.id }.map { row in
                Entry(
                    id: row.id, title: row.shownTitle, unread: row.unread, isOpen: row.id == selected,
                    menu: Self.menu(of: row, in: space))
            }
        }

        /// What `row`'s menu offers in `space`.
        private static func menu(of row: Row, in space: SpaceSummary?) -> [ConversationMenuItem] {
            (space?.status == .archived ? [] : [.rename]) + (row.people > 1 ? [.leave] : [])
                + (row.people <= 1 || space?.permissions.deleteConversations == true ? [.delete] : [])
        }

        /// What the panel is headed: the shown space's name, or Spaces before they're read.
        var shownSpaceName: String { shownSpace?.name ?? "Spaces" }

        /// The shown space's color, as its tile on the rail has it.
        var shownSpaceHue: SpaceHue { SpaceHue(name: shownSpace?.name ?? "") }

        /// The spaces in use, for the rail, the one something was last said in first.
        var spaceChoices: [SpaceChoice] {
            choices(of: spacesByLatest.filter { $0.status == .active })
        }

        /// What's written to find a space in the Spaces list.
        var search: String { destination?.choosingSpace?.search ?? "" }

        /// The spaces the Spaces list shows: those in use, then those archived, each the one
        /// something was last said in first, and only those whose names have what's written to find
        /// one.
        var spaceSections: [SpaceSection] {
            let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let found = spacesByLatest.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
            return [SpaceSummary.Status.active, .archived].map { status in
                SpaceSection(status: status, choices: choices(of: found.filter { $0.status == status }))
            }
            .filter { !$0.choices.isEmpty }
        }

        /// The spaces, the one something was last said in first; those with nothing in them last,
        /// as they're listed.
        private var spacesByLatest: [SpaceSummary] {
            let latest = Dictionary(
                conversations.enumerated().map { ($1.spaceID, $0) }, uniquingKeysWith: min)
            return spaces.enumerated().sorted {
                (latest[$0.element.id] ?? .max, $0.offset) < (latest[$1.element.id] ?? .max, $1.offset)
            }.map(\.element)
        }

        /// `spaces` as tiles, marked when they're shown, or something's new in them.
        private func choices(of spaces: [SpaceSummary]) -> [SpaceChoice] {
            spaces.map { space in
                SpaceChoice(
                    space: space, isShown: space.id == shownSpace?.id,
                    unread: conversations.contains { $0.spaceID == space.id && $0.unread })
            }
        }

        /// What the shown space's menu offers its person: inviting when they manage its people,
        /// and renaming and archiving when they may configure it.
        var shownSpaceMenu: [SpaceMenuItem] {
            guard let space = shownSpace else { return [] }
            let invites: [SpaceMenuItem] = space.permissions.people == .manage ? [.invite] : []
            let bots: [SpaceMenuItem] = space.permissions.bots == .configure ? [.bots] : []
            let connections: [SpaceMenuItem] = space.permissions.connections ? [.connections] : []
            let configures = space.permissions.configureSpace
            switch space.status {
            case .active: return invites + bots + connections + (configures ? [.rename, .archive] : [])
            case .archived: return configures ? [.unarchive] : []
            }
        }

        /// Whether New conversation is offered: not while the shown space is archived.
        var canStartConversation: Bool { !shownSpaceIsArchived }
    }

    enum Action {
        /// The window is shown for `session`: its spaces and conversations are read, then heard as
        /// they change, while it's shown.
        case appeared(Session)
        case loaded([SpaceSummary], [Conversation])
        case failed(String)
        case selected(ConversationID)
        /// `count` people are in the space `spaceID`.
        case peopleCounted(SpaceID, Int)
        /// A space picked on the rail: its latest conversation opens, or a new one starts there.
        case spaceSwitched(SpaceID)
        /// New conversation, in the shown space.
        case newConversationTapped
        case started(Conversation)
        /// They're in `conversation` now.
        case conversationJoined(Conversation)
        /// Something was said in `conversation`.
        case conversationSaid(Conversation)
        /// `conversation` is called something else.
        case conversationTitled(Conversation)
        /// They're no longer in the conversation: they left it, or it was deleted.
        case conversationLeft(ConversationID)
        /// They're in `space` now.
        case spaceJoined(SpaceSummary)
        /// `space` lists itself differently for them now.
        case spaceListed(SpaceSummary)
        /// They're no longer in the space `id`.
        case spaceLeft(SpaceID)
        /// Something picked from a conversation's menu.
        case conversationMenuPicked(ConversationID, ConversationMenuItem)
        /// Something picked from the shown space's menu.
        case spaceMenuPicked(SpaceMenuItem)
        /// The space `id` is in use, or archived, now.
        case spaceStatusChanged(SpaceID, SpaceSummary.Status)
        /// + on the rail: a space to make or join.
        case addSpaceTapped
        /// Spaces on the rail, or ⌘K: every space, to pick one.
        case spacesTapped
        /// A space picked in the Spaces list: it's shown.
        case spacePicked(SpaceID)
        /// Return in the Spaces list: the first space found is shown.
        case spacesSubmitted
        /// Rename in the renaming dialog.
        case renameConfirmed
        case renamed(ConversationID, title: String)
        case spaceRenamed(SpaceSummary)
        case tasks(TasksFeature.Action)
        case destination(PresentationAction<Destination.Action>)
        case delegate(Delegate)

        enum Delegate: Equatable {
            /// The window should show `id`.
            case open(ConversationID)
            /// The window should show no conversation, in `space`, which has none to show.
            case close(SpaceSummary)
            /// A space is as `space` says now.
            case spaceChanged(SpaceSummary)
        }
    }

    private enum CancelID { case hearing }

    @Dependency(\.server) var server
    @Dependency(\.chat) var chat

    var body: some ReducerOf<Self> {
        Scope(\.tasks, action: \.tasks) {
            TasksFeature()
        }
        Reduce(update)
            .ifLet(\.$destination, action: \.destination)
    }

    /// What `action` does to the sidebar, and what it asks for.
    private func update(_ state: inout State, _ action: Action) -> Effect<Action> {
        switch action {
        case .appeared(let session):
            state.session = session
            return hear(as: session).cancellable(id: CancelID.hearing, cancelInFlight: true)

        case .loaded(let spaces, let conversations):
            state.spaces = spaces
            state.conversations = IdentifiedArray(uniqueElements: conversations.map { Row($0) })
            state.error = nil
            if let selected = state.selected, state.conversations[id: selected] != nil { return .none }
            // The latest is shown first; with none, a new one in the space shown, when there's one.
            if let latest = state.conversations.first {
                return select(latest.id, &state)
            }
            guard let space = state.shownSpace else { return .none }
            return start(in: space.id, as: state.session)

        case .failed(let why):
            state.error = why
            return .none

        case .selected(let id):
            return select(id, &state)

        case .peopleCounted(let space, let count):
            state.peopleCounts[space] = count
            return .none

        case .spaceSwitched(let id):
            return switchSpace(to: id, &state)

        case .newConversationTapped:
            guard state.canStartConversation, let space = state.shownSpace else { return .none }
            return start(in: space.id, as: state.session)

        case .started(let conversation):
            state.conversations.insert(Row(conversation), at: 0)
            return select(conversation.id, &state)

        case .conversationJoined(let conversation):
            // A new one comes first, marked; one listed already is only called as it's called now.
            guard state.conversations[id: conversation.id] == nil else {
                state.conversations[id: conversation.id]?.title = conversation.title
                return .none
            }
            state.conversations.insert(Row(conversation, unread: true), at: 0)
            return .none

        case .conversationSaid(let conversation):
            // To the top, as the latest; marked when it isn't the one open.
            let unread = conversation.id != state.selected
            state.conversations.remove(id: conversation.id)
            state.conversations.insert(Row(conversation, unread: unread), at: 0)
            return .none

        case .conversationTitled(let conversation):
            state.conversations[id: conversation.id]?.title = conversation.title
            return .none

        case .spaceJoined(let space), .spaceListed(let space):
            // A new one comes last, as the latest joined; one listed already is as it lists itself now.
            if let index = state.spaces.firstIndex(where: { $0.id == space.id }) {
                state.spaces[index] = space
            } else {
                state.spaces.append(space)
            }
            return .none

        case .spaceLeft(let id):
            // The rail's first is shown in its place.
            state.spaces.removeAll { $0.id == id }
            if state.shownSpaceID == id { state.shownSpaceID = nil }
            return .none

        case .conversationLeft(let id):
            // The next in its space opens in its place.
            guard let row = state.conversations.remove(id: id), state.selected == id else { return .none }
            state.selected = nil
            if let next = state.conversations.first(where: { $0.spaceID == row.spaceID }) {
                return select(next.id, &state)
            }
            guard let space = state.spaces.first(where: { $0.id == row.spaceID }) else { return .none }
            return openNothing(in: space, &state)

        case .conversationMenuPicked(let id, let item):
            return conversationMenuPicked(id, item, &state)

        case .spaceMenuPicked(let item):
            return spaceMenuPicked(item, &state)

        case .spaceStatusChanged(let id, let status):
            guard let index = state.spaces.firstIndex(where: { $0.id == id }) else { return .none }
            let space = state.spaces[index]
            let changed = SpaceSummary(
                id: id, name: space.name, permissions: space.permissions, status: status)
            state.spaces[index] = changed
            // Archived while it's shown, it's off the rail: the rail's first is shown instead.
            guard status == .archived, id == state.shownSpace?.id, let next = state.spaceChoices.first else {
                return .send(.delegate(.spaceChanged(changed)))
            }
            return .merge(.send(.delegate(.spaceChanged(changed))), switchSpace(to: next.id, &state))

        case .addSpaceTapped:
            guard let session = state.session else { return .none }
            state.destination = .addingSpace(AddingSpace.State(session: session))
            return .none

        case .spacesTapped:
            state.destination = .choosingSpace(ChoosingSpace.State())
            return .none

        case .spacePicked(let id):
            state.destination = nil
            return switchSpace(to: id, &state)

        case .spacesSubmitted:
            guard let first = state.spaceSections.first?.choices.first else { return .none }
            state.destination = nil
            return switchSpace(to: first.id, &state)

        case .renameConfirmed:
            guard let renaming = state.destination?.renaming, let session = state.session else { return .none }
            state.destination = nil
            return rename(renaming, as: session)

        case .renamed(let id, let title):
            state.conversations[id: id]?.title = title
            return .none

        case .spaceRenamed(let space):
            guard let index = state.spaces.firstIndex(where: { $0.id == space.id }) else { return .none }
            state.spaces[index] = space
            return .none

        case .tasks(.delegate(.failed(let why))):
            state.error = why
            return .none

        case .destination(.presented(.addingSpace(.delegate(.added(let space))))):
            state.destination = nil
            if !state.spaces.contains(where: { $0.id == space.id }) { state.spaces.append(space) }
            return switchSpace(to: space.id, &state)

        case .destination(.presented(.alert(.archiveConfirmed(let id)))):
            return perform(
                .archiveSpace(id), then: .spaceStatusChanged(id, .archived), otherwise: "Couldn't archive it.")

        case .destination(.presented(.alert(.deleteConfirmed(let id)))):
            guard let row = state.conversations[id: id] else { return .none }
            return perform(
                .deleteConversation(id, of: row.spaceID), then: .conversationLeft(id), otherwise: "Couldn't delete it.")

        case .tasks, .destination, .delegate:
            return .none
        }
    }

    /// `session`'s spaces and conversations read, then what the connection says about their
    /// conversations heard, until it's cancelled.
    private func hear(as session: Session) -> Effect<Action> {
        .run { send in
            // Listened to before they're read, so nothing said in between goes unheard.
            let heard = await chat.events()
            do {
                let spaces = try await server.spaces(session)
                let conversations = try await server.conversations(session)
                await send(.loaded(spaces, conversations))
            } catch {
                await send(.failed("Couldn't read your conversations."))
            }
            for await event in heard {
                switch event.payload {
                case .conversationJoined(let conversation): await send(.conversationJoined(conversation))
                case .conversationSaid(let conversation): await send(.conversationSaid(conversation))
                case .conversationTitled(let conversation): await send(.conversationTitled(conversation))
                case .conversationLeft(let id), .conversationDeleted(let id): await send(.conversationLeft(id))
                case .spaceJoined(let space): await send(.spaceJoined(space))
                case .spaceListed(let space): await send(.spaceListed(space))
                case .spaceLeft(let id): await send(.spaceLeft(id))
                default: break
                }
            }
        }
    }

    /// `id` open, its space shown, and what's new in it seen.
    private func select(_ id: ConversationID, _ state: inout State) -> Effect<Action> {
        state.selected = id
        state.shownSpaceID = state.conversations[id: id]?.spaceID ?? state.shownSpaceID
        state.conversations[id: id]?.unread = false
        state.error = nil
        return .merge(.send(.delegate(.open(id))), countPeople(in: state.shownSpace, of: state))
    }

    /// The space `id` shown: its latest conversation opens, or a new one starts there.
    private func switchSpace(to id: SpaceID, _ state: inout State) -> Effect<Action> {
        guard id != state.shownSpace?.id, let space = state.spaces.first(where: { $0.id == id }) else {
            return .none
        }
        state.shownSpaceID = id
        if let latest = state.conversations.first(where: { $0.spaceID == id }) {
            return select(latest.id, &state)
        }
        return openNothing(in: space, &state)
    }

    /// What `item` does to the conversation `id`.
    private func conversationMenuPicked(
        _ id: ConversationID, _ item: ConversationMenuItem, _ state: inout State
    ) -> Effect<Action> {
        switch item {
        case .rename:
            guard let row = state.conversations[id: id] else { return .none }
            state.destination = .renaming(
                Renaming.State(subject: .conversation(id, in: row.spaceID), name: row.title ?? ""))
            return .none

        case .leave:
            guard let row = state.conversations[id: id] else { return .none }
            return perform(
                .leaveConversation(id, of: row.spaceID), then: .conversationLeft(id), otherwise: "Couldn't leave it.")

        case .delete:
            guard let row = state.conversations[id: id] else { return .none }
            state.destination = .alert(.delete(row))
            return .none
        }
    }

    /// What `item` does to the shown space.
    private func spaceMenuPicked(_ item: SpaceMenuItem, _ state: inout State) -> Effect<Action> {
        guard let space = state.shownSpace else { return .none }
        switch item {
        case .invite:
            guard let session = state.session else { return .none }
            state.destination = .inviting(Inviting.State(session: session, space: space))
            return .none

        case .bots:
            guard let session = state.session else { return .none }
            state.destination = .bots(SpaceBots.State(session: session, space: space))
            return .none

        case .connections:
            guard let session = state.session else { return .none }
            state.destination = .connections(SpaceConnections.State(session: session, space: space))
            return .none

        case .rename:
            state.destination = .renaming(Renaming.State(subject: .space(space.id), name: space.name))
            return .none

        case .archive:
            state.destination = .alert(.archive(space))
            return .none

        case .unarchive:
            return perform(
                .unarchiveSpace(space.id), then: .spaceStatusChanged(space.id, .active),
                otherwise: "Couldn't unarchive it.")
        }
    }

    /// What's renamed to the name `renaming` has, unless it's none.
    private func rename(_ renaming: Renaming.State, as session: Session) -> Effect<Action> {
        let name = renaming.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .none }
        return .run { send in
            do {
                switch renaming.subject {
                case .conversation(let id, let space):
                    try await server.titleConversation(session, space, id, name)
                    await send(.renamed(id, title: name))
                case .space(let id):
                    await send(.spaceRenamed(try await server.renameSpace(session, id, name)))
                }
            } catch {
                await send(.failed("Couldn't save the name."))
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

    /// What `space`, with no conversation of theirs left in it, shows: a new one while it's in use;
    /// none once it's archived, where nothing new is said.
    private func openNothing(in space: SpaceSummary, _ state: inout State) -> Effect<Action> {
        switch space.status {
        case .active:
            return start(in: space.id, as: state.session)
        case .archived:
            state.selected = nil
            return .send(.delegate(.close(space)))
        }
    }

    /// `ask` pushed on the connection, then `done`; what it was refused for, or `otherwise`, when it
    /// wasn't done.
    private func perform(_ ask: ChatAsk, then done: Action, otherwise: String) -> Effect<Action> {
        .run { send in
            do {
                try await chat.perform(ask)
                await send(done)
            } catch ChatSocketError.failed(let error) {
                await send(.failed(error.message))
            } catch {
                await send(.failed(otherwise))
            }
        }
    }

    /// A new conversation in `space`, started for `session`'s person.
    private func start(in space: SpaceID, as session: Session?) -> Effect<Action> {
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
