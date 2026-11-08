import ComposableArchitecture
import Foundation
import Testing
import TurgaiModels

@testable import MacApp

@MainActor
struct SidebarFeatureTests {
    let session = Session(token: "token", expiresAt: Date(timeIntervalSince1970: 2_000_000))
    let turgai = SpaceSummary(id: "turgai", name: "Turgai", role: .member)
    let dinner = Conversation(
        id: ConversationID(rawValue: "dinner"), botID: BotID(rawValue: "conversation"), title: "plan dinner",
        spaceID: "turgai")
    let trip = Conversation(
        id: ConversationID(rawValue: "trip"), botID: BotID(rawValue: "conversation"), title: "trip", spaceID: "turgai")

    /// The latest conversation is opened as the window shows.
    @Test
    func theLatestIsOpenedFirst() async {
        let store = TestStore(initialState: SidebarFeature.State()) {
            SidebarFeature()
        } withDependencies: {
            $0.server.spaces = { _ in [self.turgai] }
            $0.server.conversations = { _ in [self.dinner, self.trip] }
        }
        await store.send(.appeared(session)) { $0.session = self.session }
        await store.receive(\.loaded) {
            $0.spaces = [self.turgai]
            $0.conversations = [
                .init(id: self.dinner.id, title: "plan dinner", spaceID: "turgai"),
                .init(id: self.trip.id, title: "trip", spaceID: "turgai"),
            ]
        }
        await store.receive(\.selected) { $0.selected = self.dinner.id }
        await store.receive(\.delegate, .open(dinner.id))
    }

    /// With no conversations yet, one is started in Turgai's own space, and opened.
    @Test
    func withNoneOneIsStarted() async {
        let started = LockIsolated<[String?]>([])
        let store = TestStore(initialState: SidebarFeature.State()) {
            SidebarFeature()
        } withDependencies: {
            $0.server.spaces = { _ in [self.turgai] }
            $0.server.conversations = { _ in [] }
            $0.server.startConversation = { _, space in
                started.withValue { $0.append(space) }
                return self.dinner
            }
        }
        await store.send(.appeared(session)) { $0.session = self.session }
        await store.receive(\.loaded) { $0.spaces = [self.turgai] }
        await store.receive(\.started) {
            $0.conversations = [.init(id: self.dinner.id, title: "plan dinner", spaceID: "turgai")]
        }
        await store.receive(\.selected) { $0.selected = self.dinner.id }
        await store.receive(\.delegate, .open(dinner.id))
        #expect(started.value == [nil])
    }

    /// Something said in another conversation brings it to the top, marked, until it's opened.
    @Test
    func aChangedConversationComesFirstMarked() async {
        var state = SidebarFeature.State()
        state.conversations = [
            .init(id: dinner.id, title: "plan dinner", spaceID: "turgai"),
            .init(id: trip.id, title: "trip", spaceID: "turgai"),
        ]
        state.selected = dinner.id
        let store = TestStore(initialState: state) { SidebarFeature() }

        let changed = Conversation(id: trip.id, botID: trip.botID, title: "trip to Rome", spaceID: "turgai")
        await store.send(.conversationSaid(changed)) {
            $0.conversations = [
                .init(id: self.trip.id, title: "trip to Rome", spaceID: "turgai", unread: true),
                .init(id: self.dinner.id, title: "plan dinner", spaceID: "turgai"),
            ]
        }
        await store.send(.selected(trip.id)) {
            $0.selected = self.trip.id
            $0.conversations[id: self.trip.id]?.unread = false
        }
        await store.receive(\.delegate, .open(trip.id))
    }

    /// Rename… writes a conversation's new title, New space makes one; a blank name does nothing.
    @Test
    func namesAreWrittenAndSaved() async {
        let titled = LockIsolated<[String]>([])
        let family = SpaceSummary(id: "family", name: "Family", role: .admin)
        var state = SidebarFeature.State()
        state.session = session
        state.spaces = [turgai]
        state.conversations = [.init(id: dinner.id, title: "plan dinner", spaceID: "turgai")]
        let store = TestStore(initialState: state) {
            SidebarFeature()
        } withDependencies: {
            $0.server.titleConversation = { _, _, title in titled.withValue { $0.append(title) } }
            $0.server.makeSpace = { _, _ in family }
        }

        await store.send(.renameConversationTapped(dinner.id)) {
            $0.naming = .init(subject: .conversation(self.dinner.id), name: "plan dinner")
        }
        await store.send(.nameChanged(" Dinner ")) { $0.naming?.name = " Dinner " }
        await store.send(.namingConfirmed) { $0.naming = nil }
        await store.receive(\.renamed) { $0.conversations[id: self.dinner.id]?.title = "Dinner" }
        #expect(titled.value == ["Dinner"])

        await store.send(.newSpaceTapped) { $0.naming = .init(subject: .newSpace, name: "") }
        await store.send(.namingConfirmed) { $0.naming = nil }
        await store.send(.newSpaceTapped) { $0.naming = .init(subject: .newSpace, name: "") }
        await store.send(.nameChanged("Family")) { $0.naming?.name = "Family" }
        await store.send(.namingConfirmed) { $0.naming = nil }
        await store.receive(\.spaceMade) { $0.spaces = [self.turgai, family] }
    }

    /// A new title renames a conversation where it is, marking nothing; one joined comes first,
    /// marked, unless it's listed already.
    @Test
    func aTitleOrAJoinChangesOnlyWhatItSays() async {
        var state = SidebarFeature.State()
        state.conversations = [
            .init(id: dinner.id, title: "plan dinner", spaceID: "turgai"),
            .init(id: trip.id, title: "trip", spaceID: "turgai"),
        ]
        state.selected = dinner.id
        let store = TestStore(initialState: state) { SidebarFeature() }

        let rome = Conversation(id: trip.id, botID: trip.botID, title: "Rome", spaceID: "turgai")
        await store.send(.conversationTitled(rome)) { $0.conversations[id: self.trip.id]?.title = "Rome" }
        await store.send(.conversationJoined(rome))
        let lunch = Conversation(id: ConversationID(rawValue: "lunch"), botID: trip.botID, spaceID: "turgai")
        await store.send(.conversationJoined(lunch)) {
            $0.conversations.insert(.init(id: lunch.id, title: nil, spaceID: "turgai", unread: true), at: 0)
        }
    }

    /// The sidebar shows the open conversation's space; its rail has every space, dotted where
    /// something's new; switching opens a space's latest conversation, or starts one in a space
    /// with none; New conversation starts one in the space shown.
    @Test
    func theRailShowsOneSpaceAtATime() async {
        let family = SpaceSummary(id: "family", name: "Family", role: .admin)
        let work = SpaceSummary(id: "work", name: "Work", role: .member)
        let started = LockIsolated<[String?]>([])
        var state = SidebarFeature.State()
        state.session = session
        state.spaces = [turgai, family, work]
        state.conversations = [
            .init(id: dinner.id, title: "plan dinner", spaceID: "family"),
            .init(id: trip.id, title: nil, spaceID: "turgai", unread: true),
        ]
        state.selected = dinner.id
        #expect(state.shownSpace == family)
        #expect(state.entries == [.init(id: dinner.id, title: "plan dinner", unread: false, isOpen: true)])
        #expect(state.spaceChoices.map(\.initial) == ["T", "F", "W"])
        #expect(state.spaceChoices.map(\.unread) == [true, false, false])
        #expect(state.spaceChoices.map(\.isShown) == [false, true, false])
        #expect(state.renameShownSpace == "Rename “Family”…")
        #expect(state.newConversationHelp == "New conversation in Family")
        #expect(state.shownSpaceName == "Family")

        let lunch = Conversation(id: ConversationID(rawValue: "lunch"), botID: trip.botID, spaceID: "work")
        let store = TestStore(initialState: state) {
            SidebarFeature()
        } withDependencies: {
            $0.server.startConversation = { _, space in
                started.withValue { $0.append(space) }
                return lunch
            }
        }
        await store.send(.spaceSwitched("family"))
        await store.send(.spaceSwitched("turgai"))
        await store.receive(\.selected) {
            $0.selected = self.trip.id
            $0.conversations[id: self.trip.id]?.unread = false
        }
        await store.receive(\.delegate, .open(trip.id))
        await store.send(.spaceSwitched("work"))
        await store.receive(\.started) { $0.conversations.insert(.init(id: lunch.id, spaceID: "work"), at: 0) }
        await store.receive(\.selected) { $0.selected = lunch.id }
        await store.receive(\.delegate, .open(lunch.id))
        #expect(started.value == ["work"])
    }
}

@MainActor
struct ChatOpeningTests {
    /// Opening another conversation shows it instead, asking the connection for it; what's heard of
    /// another conversation then isn't shown, and what's said about others is passed on.
    @Test
    func openingShowsOnlyThatConversation() async {
        let sent = LockIsolated<[ChatCommand]>([])
        let dinner = ConversationID(rawValue: "dinner")
        let trip = ConversationID(rawValue: "trip")
        var state = ChatFeature.State(connection: .connected(botID: BotID(rawValue: "conversation")))
        state.conversationID = dinner
        state.messages = [Message(id: MessageID(), role: .user, text: "pasta?")]
        let store = TestStore(initialState: state) {
            ChatFeature()
        } withDependencies: {
            $0.chat.send = { command in sent.withValue { $0.append(command) } }
        }

        let turgai = SpaceSummary(id: "turgai", name: "Turgai", role: .member)
        await store.send(.open(trip, in: turgai)) {
            $0.conversationID = trip
            $0.space = turgai
            $0.messages = []
        }
        #expect(sent.value == [.open(conversationID: trip)])
        #expect(store.state.addingTitle == "Add someone from Turgai")
        #expect(store.state.nobodyToAdd == "Everyone in Turgai is here already.")

        let late = Message(id: MessageID(), role: .user, text: "late")
        await store.send(.received(ChatEvent(payload: .messageAccepted(conversationID: dinner, turnID: nil, message: late))))

        let changed = Conversation(id: dinner, botID: BotID(rawValue: "conversation"), spaceID: "turgai")
        await store.send(.received(ChatEvent(payload: .conversationSaid(conversation: changed))))
        await store.receive(\.delegate, .conversationSaid(changed))
    }
}

@MainActor
struct MentionTests {
    /// Typing `@` suggests the participants, but you, whose name starts with what follows it.
    @Test
    func typingAtSuggestsWhoItCouldBe() {
        var state = ChatFeature.State(
            participants: [
                ParticipantSummary(kind: .person, id: "account-ann", name: "ann"),
                ParticipantSummary(kind: .person, id: "account-bob", name: "Bob"),
                ParticipantSummary(kind: .person, id: "account-bea", name: "bea"),
                ParticipantSummary(kind: .agent, id: "conversation", name: "Turgai"),
            ],
            you: "account-ann")

        state.draft = "pasta? @"
        #expect(state.suggestions.map(\.id) == ["account-bob", "account-bea", "conversation"])
        state.draft = "pasta? @b"
        #expect(state.suggestions.map(\.id) == ["account-bob", "account-bea"])
        state.draft = "pasta? @bo"
        #expect(state.suggestions.map(\.id) == ["account-bob"])
        state.draft = "pasta? @Bob "
        #expect(state.suggestions.isEmpty)
        state.draft = "ann@bob"
        #expect(state.suggestions.isEmpty)
    }

    /// A suggestion picked is who the message is said to, while its name is still in the message.
    @Test
    func aMentionSaysTheMessageToThem() async {
        let sent = LockIsolated<[ChatCommand]>([])
        let bob = ParticipantSummary(kind: .person, id: "account-bob", name: "bob")
        let cat = ParticipantSummary(kind: .person, id: "account-cat", name: "cat")
        let store = TestStore(
            initialState: ChatFeature.State(
                connection: .connected(botID: BotID(rawValue: "conversation")),
                conversationID: ConversationID(rawValue: "dinner"))
        ) {
            ChatFeature()
        } withDependencies: {
            $0.chat.send = { command in sent.withValue { $0.append(command) } }
            $0.uuid = .incrementing
        }

        await store.send(.binding(.set(\.draft, "@b"))) { $0.draft = "@b" }
        await store.send(.mentioned(bob)) {
            $0.draft = "@bob "
            $0.to = [bob]
        }
        await store.send(.binding(.set(\.draft, "@bob @"))) { $0.draft = "@bob @" }
        await store.send(.mentioned(cat)) {
            $0.draft = "@bob @cat "
            $0.to = [bob, cat]
        }
        // Cat's name typed away: the message isn't said to them.
        await store.send(.binding(.set(\.draft, "@bob pasta?"))) { $0.draft = "@bob pasta?" }
        let request = SendMessageRequest(
            id: MessageID(rawValue: UUID(0)), text: "@bob pasta?", to: [ParticipantRef(kind: .person, id: "account-bob")])
        await store.send(.sendTapped) {
            $0.draft = ""
            $0.to = []
            $0.pending = [request]
        }
        #expect(sent.value == [.message(request)])
    }

    /// ↑ and ↓ move the mark round the suggestions; Return picks the one marked while someone is
    /// suggested, and sends otherwise.
    @Test
    func returnPicksTheMarkedSuggestionOrSends() async {
        let sent = LockIsolated<[ChatCommand]>([])
        let bob = ParticipantSummary(kind: .person, id: "account-bob", name: "bob")
        let bea = ParticipantSummary(kind: .person, id: "account-bea", name: "bea")
        let store = TestStore(
            initialState: ChatFeature.State(
                connection: .connected(botID: BotID(rawValue: "conversation")),
                conversationID: ConversationID(rawValue: "dinner"), participants: [bob, bea])
        ) {
            ChatFeature()
        } withDependencies: {
            $0.chat.send = { command in sent.withValue { $0.append(command) } }
            $0.uuid = .incrementing
        }

        await store.send(.binding(.set(\.draft, "@b"))) { $0.draft = "@b" }
        #expect(store.state.picked == bob)
        await store.send(.markMoved(by: 1)) { $0.marked = bea }
        await store.send(.markMoved(by: 1)) { $0.marked = bob }
        await store.send(.markMoved(by: -1)) { $0.marked = bea }
        await store.send(.submitted) {
            $0.draft = "@bea "
            $0.to = [bea]
            $0.marked = nil
        }
        #expect(sent.value.isEmpty)

        let request = SendMessageRequest(
            id: MessageID(rawValue: UUID(0)), text: "@bea", to: [ParticipantRef(kind: .person, id: "account-bea")])
        await store.send(.submitted) {
            $0.draft = ""
            $0.to = []
            $0.pending = [request]
        }
        #expect(sent.value == [.message(request)])
    }
}
