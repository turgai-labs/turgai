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

        await store.send(.open(trip)) {
            $0.conversationID = trip
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
