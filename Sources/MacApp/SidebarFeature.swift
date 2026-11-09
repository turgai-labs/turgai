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
        let spaceID: String
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

        init(id: ConversationID, title: String? = nil, spaceID: String, people: Int, unread: Bool = false) {
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

        /// How its stamp leans while it's open.
        var lean: Lean { Lean(seed: id.rawValue) }
    }

    /// A space on the rail: whether it's the one shown, and whether something's new in it.
    struct SpaceChoice: Equatable, Identifiable {
        let space: SpaceSummary
        let isShown: Bool
        let unread: Bool

        var id: String { space.id }
        /// How its tile is drawn: filled in while it's shown, as the open conversation's row is;
        /// an outline otherwise.
        var fill: StampFill { isShown ? .filled : .outlined }
        /// What its tile says: the first letter of its name.
        var initial: String { space.name.prefix(1).uppercased() }
        var hue: SpaceHue { SpaceHue(name: space.name) }
        /// How its tile leans.
        var lean: Lean { Lean(seed: space.id) }
    }

    /// What a conversation's menu offers: renaming it while its space is in use; leaving it while
    /// others are in it; deleting it, for everyone, when they're the only one in it, or an admin of
    /// its space.
    enum ConversationMenuItem: Hashable, Identifiable {
        case rename
        case leave
        case delete

        var id: Self { self }

        var title: String {
            switch self {
            case .rename: "Rename…"
            case .leave: "Leave"
            case .delete: "Delete…"
            }
        }

        var role: ButtonRole? { self == .delete ? .destructive : nil }
    }

    /// What the shown space's menu offers its admins: inviting people to it, renaming it, and
    /// archiving it, while it's in use, Turgai's own staying in use; using it again, once it's
    /// archived.
    enum SpaceMenuItem: Hashable, Identifiable {
        case invite
        /// Renaming it, called `name` now.
        case rename(name: String)
        case archive(name: String)
        case unarchive

        var id: Self { self }

        var title: String {
            switch self {
            case .invite: "Invite People…"
            case .rename(let name): "Rename “\(name)”…"
            case .archive(let name): "Archive “\(name)”…"
            case .unarchive: "Unarchive"
            }
        }
    }

    /// Spaces in the Spaces list under one heading: those in use, or those archived.
    struct SpaceSection: Equatable, Identifiable {
        let title: String
        let choices: [SpaceChoice]

        var id: String { title }
    }

    /// The Spaces list, with what's written to find one.
    struct ChoosingSpace: Equatable {
        var search = ""
    }

    /// The dialog open over the window, with what's written in it.
    enum Dialog: Equatable {
        /// A conversation's or a space's new name.
        case renaming(Renaming)
        /// A space to make, by its name, or to join, by an invite's link.
        case addingSpace(AddingSpace)
        /// An invite to a space, its link to give someone.
        case inviting(Inviting)
        /// Every space, to pick one.
        case choosingSpace(ChoosingSpace)

        /// What's written for a name in it: nothing in an invite or the Spaces list.
        var name: String {
            get {
                switch self {
                case .renaming(let renaming): renaming.name
                case .addingSpace(let adding): adding.name
                case .inviting, .choosingSpace: ""
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
                case .inviting, .choosingSpace:
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
        /// The space shown: the open conversation's, or the one picked; the first before either.
        var shownSpaceID: String?
        /// What went wrong reading or starting conversations, when something did.
        var error: String?
        /// How many people each space has, by its id, once they're counted.
        var peopleCounts: [String: Int] = [:]
        /// The dialog open, while one is.
        var dialog: Dialog?
        /// Asking whether to archive a space or delete a conversation, while it asks.
        @Presents var alert: AlertState<Action.Alert>?

        var hasDialog: Bool { dialog != nil }
        /// What's written for a name in the dialog.
        var name: String { dialog?.name ?? "" }
        /// What's pasted for a link in the dialog.
        var link: String {
            if case .addingSpace(let adding) = dialog { adding.link } else { "" }
        }
        /// What's written to find a space in the Spaces list.
        var search: String {
            if case .choosingSpace(let choosing) = dialog { choosing.search } else { "" }
        }

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
                + (row.people <= 1 || space?.role == .admin ? [.delete] : [])
        }

        /// What the panel is headed: the shown space's name, or Spaces before they're read.
        var shownSpaceName: String { shownSpace?.name ?? "Spaces" }

        /// The shown space's color, as its tile on the rail has it.
        var shownSpaceHue: SpaceHue { SpaceHue(name: shownSpace?.name ?? "") }

        /// What the shown space is, under its name: a space, or an archived one, and how many
        /// people are in it once they're counted.
        var shownSpaceDetail: String {
            let kind = shownSpace?.status == .archived ? "Archived" : "Space"
            switch shownSpace.flatMap({ peopleCounts[$0.id] }) {
            case nil: return kind
            case 1?: return "\(kind) · 1 person"
            case let count?: return "\(kind) · \(count) people"
            }
        }

        /// The spaces in use, for the rail, the one something was last said in first.
        var spaceChoices: [SpaceChoice] {
            choices(of: spacesByLatest.filter { $0.status == .active })
        }

        /// The spaces the Spaces list shows: those in use, then those archived, each the one
        /// something was last said in first, and only those whose names have what's written to find
        /// one.
        var spaceSections: [SpaceSection] {
            let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let found = spacesByLatest.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
            return [
                SpaceSection(title: "Active", choices: choices(of: found.filter { $0.status == .active })),
                SpaceSection(title: "Archived", choices: choices(of: found.filter { $0.status == .archived })),
            ].filter { !$0.choices.isEmpty }
        }

        /// What the Spaces list says when no space has what's written: none while some do.
        var spacesNote: String? {
            spaceSections.isEmpty ? "No space is called “\(search)”." : nil
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

        /// What the shown space's menu offers, when its person is one of its admins: nothing
        /// otherwise.
        var shownSpaceMenu: [SpaceMenuItem] {
            guard let space = shownSpace, space.role == .admin else { return [] }
            switch (space.status, space.kind) {
            case (.active, .made): return [.invite, .rename(name: space.name), .archive(name: space.name)]
            case (.active, .turgaisOwn): return [.invite, .rename(name: space.name)]
            case (.archived, _): return [.unarchive]
            }
        }

        /// What New conversation says it does: none while the shown space is archived, where it
        /// isn't offered.
        var newConversationHelp: String? {
            switch shownSpace {
            case nil: "New conversation"
            case let space? where space.status == .archived: nil
            case let space?: "New conversation in \(space.name)"
            }
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
        /// They're no longer in the conversation: they left it, or it was deleted.
        case conversationLeft(ConversationID)
        /// Something picked from a conversation's menu.
        case conversationMenuPicked(ConversationID, ConversationMenuItem)
        /// Something picked from the shown space's menu.
        case spaceMenuPicked(SpaceMenuItem)
        /// The space `id` is in use, or archived, now.
        case spaceStatusChanged(String, SpaceSummary.Status)
        case alert(PresentationAction<Alert>)
        /// Spaces on the rail, or ⌘K: every space, to pick one.
        case spacesTapped
        case searchChanged(String)
        /// A space picked in the Spaces list: it's shown.
        case spacePicked(String)
        /// Return in the Spaces list: the first space found is shown.
        case searchSubmitted
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

        enum Alert: Equatable {
            case archiveConfirmed(String)
            case deleteConfirmed(ConversationID)
        }

        enum Delegate: Equatable {
            /// The window should show `id`.
            case open(ConversationID)
            /// The window should show no conversation, in `space`, which has none to show.
            case close(SpaceSummary)
            /// A space is as `space` says now.
            case spaceChanged(SpaceSummary)
        }
    }

    @Dependency(\.server) var server
    @Dependency(\.chat) var chat
    @Dependency(\.pasteboard) var pasteboard

    var body: some ReducerOf<Self> {
        Reduce(update)
            .ifLet(\.$alert, action: \.alert)
    }

    /// What `action` does to the sidebar, and what it asks for.
    private func update(_ state: inout State, _ action: Action) -> Effect<Action> {
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
            state.conversations = IdentifiedArray(uniqueElements: conversations.map { Row($0) })
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
            state.shownSpaceID = state.conversations[id: id]?.spaceID ?? state.shownSpaceID
            state.conversations[id: id]?.unread = false
            state.error = nil
            return .merge(.send(.delegate(.open(id))), countPeople(in: state.shownSpace, of: state))

        case .peopleCounted(let space, let count):
            state.peopleCounts[space] = count
            return .none

        case .spaceSwitched(let id):
            guard id != state.shownSpace?.id, let space = state.spaces.first(where: { $0.id == id }) else {
                return .none
            }
            state.shownSpaceID = id
            if let latest = state.conversations.first(where: { $0.spaceID == id }) {
                return .send(.selected(latest.id))
            }
            return openNothing(in: space, &state)

        case .newConversationTapped:
            guard state.shownSpace?.status != .archived else { return .none }
            return start(in: state.shownSpace?.id, as: state.session)

        case .started(let conversation):
            state.conversations.insert(Row(conversation), at: 0)
            return .send(.selected(conversation.id))

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

        case .conversationLeft(let id):
            // The next in its space opens in its place.
            guard let row = state.conversations.remove(id: id), state.selected == id else { return .none }
            state.selected = nil
            if let next = state.conversations.first(where: { $0.spaceID == row.spaceID }) {
                return .send(.selected(next.id))
            }
            guard let space = state.spaces.first(where: { $0.id == row.spaceID }) else { return .none }
            return openNothing(in: space, &state)

        case .conversationMenuPicked(let id, .rename):
            state.dialog = .renaming(
                Renaming(subject: .conversation(id), name: state.conversations[id: id]?.title ?? ""))
            return .none

        case .conversationMenuPicked(let id, .leave):
            return perform(.leaveConversation(id), then: .conversationLeft(id), otherwise: "Couldn't leave it.")

        case .conversationMenuPicked(let id, .delete):
            guard let row = state.conversations[id: id] else { return .none }
            state.alert = .delete(row)
            return .none

        case .spaceMenuPicked(.invite):
            guard let space = state.shownSpace, let session = state.session else { return .none }
            state.dialog = .inviting(Inviting(spaceName: space.name))
            return .run { send in
                do {
                    await send(.inviteMade(try await server.makeInvite(session, space.id)))
                } catch {
                    await send(.inviteFailed)
                }
            }

        case .spaceMenuPicked(.rename):
            guard let space = state.shownSpace else { return .none }
            state.dialog = .renaming(Renaming(subject: .space(space.id), name: space.name))
            return .none

        case .spaceMenuPicked(.archive):
            guard let space = state.shownSpace else { return .none }
            state.alert = .archive(space)
            return .none

        case .spaceMenuPicked(.unarchive):
            guard let space = state.shownSpace else { return .none }
            return perform(
                .unarchiveSpace(space.id), then: .spaceStatusChanged(space.id, .active),
                otherwise: "Couldn't unarchive it.")

        case .alert(.presented(.archiveConfirmed(let id))):
            return perform(
                .archiveSpace(id), then: .spaceStatusChanged(id, .archived), otherwise: "Couldn't archive it.")

        case .alert(.presented(.deleteConfirmed(let id))):
            return perform(.deleteConversation(id), then: .conversationLeft(id), otherwise: "Couldn't delete it.")

        case .alert:
            return .none

        case .spaceStatusChanged(let id, let status):
            guard let index = state.spaces.firstIndex(where: { $0.id == id }) else { return .none }
            let space = state.spaces[index]
            let changed = SpaceSummary(id: id, name: space.name, role: space.role, status: status, kind: space.kind)
            state.spaces[index] = changed
            // Archived while it's shown, it's off the rail: the rail's first is shown instead.
            guard status == .archived, id == state.shownSpace?.id, let next = state.spaceChoices.first else {
                return .send(.delegate(.spaceChanged(changed)))
            }
            return .concatenate(.send(.delegate(.spaceChanged(changed))), .send(.spaceSwitched(next.id)))

        case .spacesTapped:
            state.dialog = .choosingSpace(ChoosingSpace())
            return .none

        case .searchChanged(let search):
            guard case .choosingSpace = state.dialog else { return .none }
            state.dialog = .choosingSpace(ChoosingSpace(search: search))
            return .none

        case .spacePicked(let id):
            state.dialog = nil
            return .send(.spaceSwitched(id))

        case .searchSubmitted:
            guard let first = state.spaceSections.first?.choices.first else { return .none }
            return .send(.spacePicked(first.id))

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

extension AlertState where Action == SidebarFeature.Action.Alert {
    static func archive(_ space: SpaceSummary) -> Self {
        AlertState {
            TextState("Archive “\(space.name)”?")
        } actions: {
            ButtonState(role: .destructive, action: .archiveConfirmed(space.id)) { TextState("Archive") }
            ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
            TextState(
                "Its conversations can still be read, and nothing new is said in them. Its admins can unarchive it.")
        }
    }

    static func delete(_ row: SidebarFeature.Row) -> Self {
        AlertState {
            TextState("Delete “\(row.shownTitle)”?")
        } actions: {
            ButtonState(role: .destructive, action: .deleteConfirmed(row.id)) { TextState("Delete") }
            ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
            TextState("It's deleted for everyone in it, and can't be brought back.")
        }
    }
}
