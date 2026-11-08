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
        await store.send(.conversationChanged(changed)) {
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

    /// Each space lists its own conversations, the open one marked; New conversation starts in the
    /// one space there is, or offers each, the open conversation's first.
    @Test
    func spacesListTheirConversationsAndWhereANewOneStarts() {
        let family = SpaceSummary(id: "family", name: "Family", role: .admin)
        var state = SidebarFeature.State()
        #expect(state.newConversation == nil)
        state.spaces = [turgai]
        state.conversations = [
            .init(id: dinner.id, title: "plan dinner", spaceID: "family"),
            .init(id: trip.id, title: nil, spaceID: "turgai", unread: true),
        ]
        #expect(state.newConversation == .inSpace("turgai"))

        state.spaces = [turgai, family]
        state.selected = dinner.id
        #expect(
            state.sections == [
                .init(
                    space: turgai,
                    entries: [.init(id: trip.id, title: "New conversation", unread: true, isOpen: false)]),
                .init(
                    space: family,
                    entries: [.init(id: dinner.id, title: "plan dinner", unread: false, isOpen: true)]),
            ])
        #expect(state.newConversation == .pick([family, turgai]))
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

        await store.send(.open(trip, inSpace: "turgai")) {
            $0.conversationID = trip
            $0.spaceID = "turgai"
            $0.messages = []
        }
        #expect(sent.value == [.open(conversationID: trip)])

        let late = Message(id: MessageID(), role: .user, text: "late")
        await store.send(.received(ChatEvent(payload: .messageAccepted(conversationID: dinner, turnID: nil, message: late))))

        let changed = Conversation(id: dinner, botID: BotID(rawValue: "conversation"), spaceID: "turgai")
        await store.send(.received(ChatEvent(payload: .conversationChanged(conversation: changed))))
        await store.receive(\.delegate, .conversationChanged(changed))
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
