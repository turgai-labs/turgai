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

    /// Rename… writes a conversation's new title; a blank name does nothing.
    @Test
    func aConversationIsRenamed() async {
        let titled = LockIsolated<[String]>([])
        var state = SidebarFeature.State()
        state.session = session
        state.spaces = [turgai]
        state.conversations = [.init(id: dinner.id, title: "plan dinner", spaceID: "turgai")]
        let store = TestStore(initialState: state) {
            SidebarFeature()
        } withDependencies: {
            $0.server.titleConversation = { _, _, title in titled.withValue { $0.append(title) } }
        }

        await store.send(.renameConversationTapped(dinner.id)) {
            $0.dialog = .renaming(.init(subject: .conversation(self.dinner.id), name: "plan dinner"))
        }
        await store.send(.nameChanged(" Dinner ")) { $0.dialog?.name = " Dinner " }
        await store.send(.renameConfirmed) { $0.dialog = nil }
        await store.receive(\.renamed) { $0.conversations[id: self.dinner.id]?.title = "Dinner" }
        await store.send(.renameConversationTapped(dinner.id)) {
            $0.dialog = .renaming(.init(subject: .conversation(self.dinner.id), name: "Dinner"))
        }
        await store.send(.nameChanged(" ")) { $0.dialog?.name = " " }
        await store.send(.renameConfirmed) { $0.dialog = nil }
        #expect(titled.value == ["Dinner"])
    }

    /// + makes a space by its name, or joins one by an invite's link; either is then shown. A link
    /// that isn't one can't be joined, and one that doesn't work says so, the dialog still open.
    @Test
    func aSpaceIsMadeOrJoined() async {
        let family = SpaceSummary(id: "family", name: "Family", role: .admin)
        let space = "8F3C1E2A-4B5D-4E6F-8A9B-0C1D2E3F4A5B"
        let work = SpaceSummary(id: space, name: "Work", role: .member)
        let joined = LockIsolated<[SpaceInviteLink]>([])
        var state = SidebarFeature.State()
        state.session = session
        state.spaces = [turgai]
        state.conversations = [.init(id: dinner.id, title: "plan dinner", spaceID: "family")]
        let store = TestStore(initialState: state) {
            SidebarFeature()
        } withDependencies: {
            $0.server.makeSpace = { _, _ in family }
            $0.server.joinSpace = { _, link in
                joined.withValue { $0.append(link) }
                guard link.token == "good" else { throw URLError(.badServerResponse) }
                return work
            }
            $0.server.startConversation = { _, _ in self.trip }
        }

        await store.send(.addSpaceTapped) { $0.dialog = .addingSpace(.init()) }
        await store.send(.nameChanged("Family")) { $0.dialog = .addingSpace(.init(name: "Family")) }
        await store.send(.makeSpaceTapped)
        await store.receive(\.spaceAdded) {
            $0.dialog = nil
            $0.spaces = [self.turgai, family]
        }
        await store.receive(\.spaceSwitched)
        await store.receive(\.selected) { $0.selected = self.dinner.id }
        await store.receive(\.delegate, .open(dinner.id))

        await store.send(.addSpaceTapped) { $0.dialog = .addingSpace(.init()) }
        await store.send(.linkChanged("turgai://join/family/x")) {
            $0.dialog = .addingSpace(.init(link: "turgai://join/family/x"))
        }
        #expect(store.state.dialog == .addingSpace(.init(link: "turgai://join/family/x")))
        await store.send(.joinTapped)
        await store.send(.linkChanged("turgai://join/\(space)/bad")) {
            $0.dialog = .addingSpace(.init(link: "turgai://join/\(space)/bad"))
        }
        await store.send(.joinTapped)
        await store.receive(\.addingFailed) {
            $0.dialog = .addingSpace(
                .init(
                    link: "turgai://join/\(space)/bad",
                    problem: "That link didn't work: it may be used up or out of date."))
        }
        await store.send(.linkChanged("turgai://join/\(space)/good")) {
            $0.dialog = .addingSpace(.init(link: "turgai://join/\(space)/good"))
        }
        await store.send(.joinTapped)
        await store.receive(\.spaceAdded) {
            $0.dialog = nil
            $0.spaces = [self.turgai, family, work]
        }
        await store.receive(\.spaceSwitched)
        await store.receive(\.started) {
            $0.conversations.insert(.init(id: self.trip.id, title: "trip", spaceID: "turgai"), at: 0)
        }
        await store.receive(\.selected) { $0.selected = self.trip.id }
        await store.receive(\.delegate, .open(trip.id))
        #expect(joined.value.map(\.token) == ["bad", "good"])
    }

    /// Invite People… makes a link to the shown space, shown to copy; one that can't be made says so.
    @Test
    func anInviteIsMadeAndCopied() async {
        let family = SpaceSummary(id: "family", name: "Family", role: .admin)
        let link = "turgai://join/8F3C1E2A-4B5D-4E6F-8A9B-0C1D2E3F4A5B/abc"
        let copied = LockIsolated<[String]>([])
        let makes = LockIsolated(0)
        var state = SidebarFeature.State()
        state.session = session
        state.spaces = [family]
        let store = TestStore(initialState: state) {
            SidebarFeature()
        } withDependencies: {
            $0.server.makeInvite = { _, space in
                makes.withValue { $0 += 1 }
                guard makes.value == 1 else { throw URLError(.badServerResponse) }
                return SpaceInviteOffer(id: "invite", token: "abc", link: link, expiresAt: nil)
            }
            $0.pasteboard.copy = { text in copied.withValue { $0.append(text) } }
        }

        await store.send(.inviteTapped) { $0.dialog = .inviting(.init(spaceName: "Family")) }
        await store.receive(\.inviteMade) { $0.dialog = .inviting(.init(spaceName: "Family", link: link)) }
        await store.send(.copyInviteTapped)
        #expect(copied.value == [link])
        await store.send(.dialogPresented(false)) { $0.dialog = nil }

        await store.send(.inviteTapped) { $0.dialog = .inviting(.init(spaceName: "Family")) }
        await store.receive(\.inviteFailed) {
            $0.dialog = .inviting(.init(spaceName: "Family", problem: "Couldn't make an invite. Try again."))
        }
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
        #expect(state.shownSpaceMenu == .init(rename: "Rename “Family”…", invite: "Invite People…"))
        #expect(state.newConversationHelp == "New conversation in Family")
        #expect(state.shownSpaceName == "Family")
        #expect(state.shownSpaceInitial == "F")
        #expect(state.spaceChoices.map(\.hue) == [.blue, .yellow, .blue])
        #expect(state.shownSpaceHue == .yellow)
        #expect(state.shownSpaceDetail == "Space")
        state.peopleCounts["family"] = 1
        #expect(state.shownSpaceDetail == "Space · 1 person")
        state.peopleCounts["family"] = 3
        #expect(state.shownSpaceDetail == "Space · 3 people")

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

    /// `@` also suggests the people in the space who aren't in it, marked as joining by it; once a
    /// message mentioning one is taken, who's in it is read again.
    @Test
    func mentioningSomeoneFromTheSpaceBringsThemIn() async {
        let bob = ParticipantSummary(kind: .person, id: "account-bob", name: "bob")
        let cat = ParticipantSummary(kind: .person, id: "account-cat", name: "cat")
        let session = Session(token: "token", expiresAt: Date(timeIntervalSince1970: 2_000_000))
        var state = ChatFeature.State(
            connection: .connected(botID: BotID(rawValue: "conversation")), session: session,
            conversationID: ConversationID(rawValue: "dinner"), participants: [bob], you: "account-ann")
        state.spacePeople = [
            SpacePerson(id: "account-ann", name: "ann", role: .admin),
            SpacePerson(id: "account-bob", name: "bob", role: .member),
            SpacePerson(id: "account-cat", name: "cat", role: .member),
        ]
        #expect(state.participantsLine == "bob")
        state.participants = [ParticipantSummary(kind: .person, id: "account-ann", name: "ann"), bob]
        #expect(state.participantsLine == "You, bob")
        state.participants = [bob]
        #expect(state.connectionNotice == nil)
        state.connection = .disconnected(why: "gone")
        #expect(state.connectionNotice == "Reconnecting…")
        state.connection = .connected(botID: BotID(rawValue: "conversation"))
        state.draft = "@"
        #expect(state.suggestions == [bob, cat])
        #expect(
            state.shownSuggestions == [
                ShownSuggestion(participant: bob, isPicked: true, joins: false),
                ShownSuggestion(participant: cat, isPicked: false, joins: true),
            ])

        let store = TestStore(initialState: state) {
            ChatFeature()
        } withDependencies: {
            $0.chat.send = { _ in }
            $0.uuid = .incrementing
            $0.server.participants = { _, _ in [bob, cat] }
        }
        await store.send(.mentioned(cat)) {
            $0.draft = "@cat "
            $0.to = [cat]
        }
        let request = SendMessageRequest(
            id: MessageID(rawValue: UUID(0)), text: "@cat", to: [ParticipantRef(kind: .person, id: "account-cat")])
        await store.send(.submitted) {
            $0.draft = ""
            $0.to = []
            $0.pending = [request]
        }
        let taken = Message(id: request.id, role: .user, text: "@cat")
        let accepted = ChatEvent(
            payload: .messageAccepted(conversationID: ConversationID(rawValue: "dinner"), turnID: nil, message: taken))
        await store.send(.received(accepted)) {
            $0.pending = []
            $0.messages = [taken]
        }
        await store.receive(\.participantsLoaded) { $0.participants = [bob, cat] }
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
