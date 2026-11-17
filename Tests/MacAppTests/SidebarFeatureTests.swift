import ComposableArchitecture
import Foundation
import Testing
import TurgaiModels

@testable import MacApp

private let turgaiSpace = SpaceID(rawValue: "turgai")
private let familySpace = SpaceID(rawValue: "family")
private let workSpace = SpaceID(rawValue: "work")
/// What a member may in a space: see its people and use its bots.
private let memberMay = SpacePermissions(
    people: .see, bots: .use, requests: nil, tasks: nil, connections: false, deleteConversations: false,
    configureSpace: false)
/// What an admin may in a space: everything.
private let adminMay = SpacePermissions(
    people: .manage, bots: .configure, requests: .runAny, tasks: .manage, connections: true,
    deleteConversations: true, configureSpace: true)

@MainActor
struct SidebarFeatureTests {
    let session = Session(token: "token", expiresAt: Date(timeIntervalSince1970: 2_000_000))
    let turgai = SpaceSummary(
        id: turgaiSpace, name: "Turgai", permissions: memberMay, status: .active)
    let dinner = Conversation(
        id: ConversationID(rawValue: "dinner"), botID: BotID(rawValue: "conversation"), title: "plan dinner",
        spaceID: turgaiSpace, people: 1)
    let trip = Conversation(
        id: ConversationID(rawValue: "trip"), botID: BotID(rawValue: "conversation"), title: "trip",
        spaceID: turgaiSpace, people: 1)

    /// The latest conversation is opened as the window shows.
    @Test
    func theLatestIsOpenedFirst() async {
        let store = TestStore(initialState: SidebarFeature.State()) {
            SidebarFeature()
        } withDependencies: {
            $0.server.spaces = { _ in [self.turgai] }
            $0.server.conversations = { _ in [self.dinner, self.trip] }
            $0.chat.events = { .finished }
        }
        await store.send(.appeared(session)) { $0.session = self.session }
        await store.receive(\.loaded) {
            $0.spaces = [self.turgai]
            $0.conversations = [
                .init(id: self.dinner.id, title: "plan dinner", spaceID: turgaiSpace, people: 1),
                .init(id: self.trip.id, title: "trip", spaceID: turgaiSpace, people: 1),
            ]
            $0.selected = self.dinner.id
            $0.shownSpaceID = turgaiSpace
        }
        await store.receive(\.delegate, .open(dinner.id))
        await store.finish()
    }

    /// The rail follows the person's spaces as the connection tells of them: one joined is added
    /// last, one listed differently is as it lists itself now, and one left goes, the first shown
    /// in its place.
    @Test
    func theRailFollowsTheirSpaces() async {
        var state = SidebarFeature.State()
        state.spaces = [turgai]
        let store = TestStore(initialState: state) { SidebarFeature() }
        let family = SpaceSummary(id: familySpace, name: "Family", permissions: memberMay, status: .active)
        await store.send(.spaceJoined(family)) { $0.spaces = [self.turgai, family] }
        await store.send(.spaceSwitched(familySpace)) { $0.shownSpaceID = familySpace }
        let home = SpaceSummary(id: familySpace, name: "Home", permissions: memberMay, status: .archived)
        await store.send(.spaceListed(home)) { $0.spaces = [self.turgai, home] }
        await store.send(.spaceLeft(familySpace)) {
            $0.spaces = [self.turgai]
            $0.shownSpaceID = nil
        }
    }

    /// With no conversations yet, one is started in the space shown, and opened.
    @Test
    func withNoneOneIsStarted() async {
        let started = LockIsolated<[SpaceID]>([])
        let store = TestStore(initialState: SidebarFeature.State()) {
            SidebarFeature()
        } withDependencies: {
            $0.server.spaces = { _ in [self.turgai] }
            $0.server.conversations = { _ in [] }
            $0.chat.events = { .finished }
            $0.server.startConversation = { _, space in
                started.withValue { $0.append(space) }
                return self.dinner
            }
        }
        await store.send(.appeared(session)) { $0.session = self.session }
        await store.receive(\.loaded) { $0.spaces = [self.turgai] }
        await store.receive(\.started) {
            $0.conversations = [.init(id: self.dinner.id, title: "plan dinner", spaceID: turgaiSpace, people: 1)]
            $0.selected = self.dinner.id
            $0.shownSpaceID = turgaiSpace
        }
        await store.receive(\.delegate, .open(dinner.id))
        await store.finish()
        #expect(started.value == [turgaiSpace])
    }

    /// While the window's shown, what the connection says about their conversations is heard: one
    /// joined comes first, marked; one deleted goes.
    @Test
    func whatTheConnectionSaysIsHeard() async {
        let (events, heard) = AsyncStream.makeStream(of: ChatEvent.self)
        let store = TestStore(initialState: SidebarFeature.State()) {
            SidebarFeature()
        } withDependencies: {
            $0.server.spaces = { _ in [self.turgai] }
            $0.server.conversations = { _ in [self.dinner] }
            $0.chat.events = { events }
        }
        let shown = await store.send(.appeared(session)) { $0.session = self.session }
        await store.receive(\.loaded) {
            $0.spaces = [self.turgai]
            $0.conversations = [.init(id: self.dinner.id, title: "plan dinner", spaceID: turgaiSpace, people: 1)]
            $0.selected = self.dinner.id
            $0.shownSpaceID = turgaiSpace
        }
        await store.receive(\.delegate, .open(dinner.id))

        heard.yield(ChatEvent(payload: .conversationJoined(conversation: trip)))
        await store.receive(\.conversationJoined) {
            $0.conversations.insert(
                .init(id: self.trip.id, title: "trip", spaceID: turgaiSpace, people: 1, unread: true), at: 0)
        }
        heard.yield(ChatEvent(payload: .conversationDeleted(conversationID: trip.id)))
        await store.receive(\.conversationLeft) { $0.conversations.remove(id: self.trip.id) }
        await shown.cancel()
    }

    /// Something said in another conversation brings it to the top, marked, until it's opened.
    @Test
    func aChangedConversationComesFirstMarked() async {
        var state = SidebarFeature.State()
        state.conversations = [
            .init(id: dinner.id, title: "plan dinner", spaceID: turgaiSpace, people: 1),
            .init(id: trip.id, title: "trip", spaceID: turgaiSpace, people: 1),
        ]
        state.selected = dinner.id
        let store = TestStore(initialState: state) { SidebarFeature() }

        let changed = Conversation(
            id: trip.id, botID: trip.botID, title: "trip to Rome", spaceID: turgaiSpace, people: 1)
        await store.send(.conversationSaid(changed)) {
            $0.conversations = [
                .init(id: self.trip.id, title: "trip to Rome", spaceID: turgaiSpace, people: 1, unread: true),
                .init(id: self.dinner.id, title: "plan dinner", spaceID: turgaiSpace, people: 1),
            ]
        }
        await store.send(.selected(trip.id)) {
            $0.selected = self.trip.id
            $0.shownSpaceID = turgaiSpace
            $0.conversations[id: self.trip.id]?.unread = false
        }
        await store.receive(\.delegate, .open(trip.id))
        await store.finish()
    }

    /// Rename… writes a conversation's new title; a blank name does nothing.
    @Test
    func aConversationIsRenamed() async {
        let titled = LockIsolated<[String]>([])
        var state = SidebarFeature.State()
        state.session = session
        state.spaces = [turgai]
        state.conversations = [.init(id: dinner.id, title: "plan dinner", spaceID: turgaiSpace, people: 1)]
        let store = TestStore(initialState: state) {
            SidebarFeature()
        } withDependencies: {
            $0.server.titleConversation = { _, _, _, title in titled.withValue { $0.append(title) } }
        }

        await store.send(.conversationMenuPicked(dinner.id, .rename)) {
            $0.destination = .renaming(
                .init(subject: .conversation(self.dinner.id, in: turgaiSpace), name: "plan dinner"))
        }
        await store.send(.destination(.presented(.renaming(.binding(.set(\.name, " Dinner ")))))) {
            $0.destination = .renaming(.init(subject: .conversation(self.dinner.id, in: turgaiSpace), name: " Dinner "))
        }
        await store.send(.renameConfirmed) { $0.destination = nil }
        await store.receive(\.renamed) { $0.conversations[id: self.dinner.id]?.title = "Dinner" }
        await store.send(.conversationMenuPicked(dinner.id, .rename)) {
            $0.destination = .renaming(.init(subject: .conversation(self.dinner.id, in: turgaiSpace), name: "Dinner"))
        }
        await store.send(.destination(.presented(.renaming(.binding(.set(\.name, " ")))))) {
            $0.destination = .renaming(.init(subject: .conversation(self.dinner.id, in: turgaiSpace), name: " "))
        }
        await store.send(.renameConfirmed) { $0.destination = nil }
        #expect(titled.value == ["Dinner"])
    }

    /// + makes a space by its name and then its first bot, its model picked from what the provider
    /// offers, or joins one by an invite's link; either is then shown. A link that isn't one can't
    /// be joined, and one that doesn't work says so, the dialog still open.
    @Test
    func aSpaceIsMadeOrJoined() async {
        let family = SpaceSummary(id: familySpace, name: "Family", permissions: adminMay, status: .active)
        let space = "8F3C1E2A-4B5D-4E6F-8A9B-0C1D2E3F4A5B"
        let work = SpaceSummary(
            id: SpaceID(rawValue: space), name: "Work", permissions: memberMay, status: .active)
        let joined = LockIsolated<[SpaceInviteLink]>([])
        let made = LockIsolated<[BotConfiguration]>([])
        var state = SidebarFeature.State()
        state.session = session
        state.spaces = [turgai]
        state.conversations = [.init(id: dinner.id, title: "plan dinner", spaceID: familySpace, people: 1)]
        let store = TestStore(initialState: state) {
            SidebarFeature()
        } withDependencies: {
            $0.server.makeSpace = { _, _, bot in
                made.withValue { $0.append(bot) }
                return family
            }
            $0.server.models = { _, _ in .found(["llama3"]) }
            $0.continuousClock = ImmediateClock()
            $0.server.joinSpace = { _, link in
                joined.withValue { $0.append(link) }
                guard link.token == "good" else { throw URLError(.badServerResponse) }
                return work
            }
            $0.server.startConversation = { _, _ in self.trip }
        }
        let adding = SidebarFeature.AddingSpace.State(session: session)

        await store.send(.addSpaceTapped) { $0.destination = .addingSpace(adding) }
        await store.send(.destination(.presented(.addingSpace(.binding(.set(\.name, "Family")))))) {
            $0.destination = .addingSpace(.init(session: self.session, name: "Family"))
        }
        // Its bot, as the bot step writes it.
        var named = SidebarFeature.AddingSpace.State(session: session, name: "Family")
        named.bot = BotForm.State(session: session, name: "Family")
        await store.send(.destination(.presented(.addingSpace(.nextTapped)))) {
            $0.destination = .addingSpace(named)
        }
        named.bot?.models = .asking
        await store.send(.destination(.presented(.addingSpace(.bot(.shown))))) { $0.destination = .addingSpace(named) }
        named.bot?.models = .found(["llama3"])
        await store.receive(\.destination.presented.addingSpace.bot.modelsAnswered) {
            $0.destination = .addingSpace(named)
        }
        named.bot?.model = "llama3"
        await store.send(.destination(.presented(.addingSpace(.bot(.binding(.set(\.model, "llama3"))))))) {
            $0.destination = .addingSpace(named)
        }
        named.making = true
        await store.send(.destination(.presented(.addingSpace(.makeTapped)))) { $0.destination = .addingSpace(named) }
        await store.receive(\.destination.presented.addingSpace.delegate, .added(family)) {
            $0.destination = nil
            $0.spaces = [self.turgai, family]
            $0.shownSpaceID = familySpace
            $0.selected = self.dinner.id
        }
        await store.receive(\.delegate, .open(dinner.id))

        await store.send(.addSpaceTapped) { $0.destination = .addingSpace(adding) }
        await store.send(.destination(.presented(.addingSpace(.binding(.set(\.link, "turgai://join/family/x")))))) {
            $0.destination = .addingSpace(.init(session: self.session, link: "turgai://join/family/x"))
        }
        await store.send(.destination(.presented(.addingSpace(.joinTapped))))
        let bad = "turgai://join/\(space)/bad"
        await store.send(.destination(.presented(.addingSpace(.binding(.set(\.link, bad)))))) {
            $0.destination = .addingSpace(.init(session: self.session, link: bad))
        }
        await store.send(.destination(.presented(.addingSpace(.joinTapped))))
        await store.receive(\.destination.presented.addingSpace.failed) {
            $0.destination = .addingSpace(
                .init(
                    session: self.session, link: bad,
                    problem: "That link didn't work: it may be used up or out of date."))
        }
        let good = "turgai://join/\(space)/good"
        await store.send(.destination(.presented(.addingSpace(.binding(.set(\.link, good)))))) {
            $0.destination = .addingSpace(.init(session: self.session, link: good))
        }
        await store.send(.destination(.presented(.addingSpace(.joinTapped))))
        await store.receive(\.destination.presented.addingSpace.delegate, .added(work)) {
            $0.destination = nil
            $0.spaces = [self.turgai, family, work]
            $0.shownSpaceID = work.id
        }
        await store.receive(\.started) {
            $0.conversations.insert(.init(id: self.trip.id, title: "trip", spaceID: turgaiSpace, people: 1), at: 0)
            $0.selected = self.trip.id
            $0.shownSpaceID = turgaiSpace
        }
        await store.receive(\.delegate, .open(trip.id))
        await store.finish()
        #expect(joined.value.map(\.token) == ["bad", "good"])
        #expect(
            made.value == [
                BotConfiguration(
                    name: "Family", instructions: "", model: ModelChoice(provider: .ollama, model: "llama3"))
            ])
    }

    /// Bots… lists the shown space's bots; one added, changed, made main or removed is saved, and
    /// they're read again; a refusal says why, the form still open.
    @Test
    func aSpacesBotsAreConfigured() async {
        let family = SpaceSummary(id: familySpace, name: "Family", permissions: adminMay, status: .active)
        let helper = SpaceBot(
            id: BotID(rawValue: "helper"), name: "Helper", instructions: "", provider: .ollama, address: nil,
            hasKey: false, model: "llama3", contextWindow: nil, isMain: true)
        let chef = SpaceBot(
            id: BotID(rawValue: "chef"), name: "Chef", instructions: "Cook.", provider: .openAI, address: nil,
            hasKey: true, model: "gpt-5", contextWindow: nil, isMain: false)
        let saved = LockIsolated<[String]>([])
        let store = TestStore(initialState: SidebarFeature.SpaceBots.State(session: session, space: family)) {
            SidebarFeature.SpaceBots()
        } withDependencies: {
            $0.server.bots = { _, _ in saved.value.isEmpty ? [helper] : [helper, chef] }
            $0.server.addBot = { _, space, bot in
                saved.withValue { $0.append("added \(bot.name) to \(space.rawValue)") }
                return chef
            }
            $0.server.changeBot = { _, _, id, bot in
                guard bot.model.apiKey == nil else { throw ServerRefusal(error: ChatError(code: "x", message: "No.")) }
                saved.withValue { $0.append("changed \(id.rawValue): \(bot.name)") }
                return chef
            }
            $0.server.chooseMainBot = { _, _, id in saved.withValue { $0.append("main \(id.rawValue)") } }
            $0.server.removeBot = { _, _, id in saved.withValue { $0.append("removed \(id.rawValue)") } }
            $0.server.models = { _, _ in .found(["gpt-5"]) }
            $0.continuousClock = ImmediateClock()
        }

        await store.send(.shown)
        await store.receive(\.read) { $0.bots = [helper] }
        await store.send(.addTapped) { $0.form = BotForm.State(session: self.session) }
        await store.send(.form(.binding(.set(\.name, "Chef")))) { $0.form?.name = "Chef" }
        await store.send(.form(.binding(.set(\.model, "gpt-5")))) { $0.form?.model = "gpt-5" }
        await store.send(.saveTapped) { $0.saving = true }
        await store.receive(\.saved) {
            $0.form = nil
            $0.saving = false
        }
        await store.receive(\.read) { $0.bots = [helper, chef] }

        // Changed with a key typed, it's refused, and says why; its saved key is kept when none is.
        await store.send(.changeTapped(chef)) {
            $0.form = BotForm.State(session: self.session, changing: chef, in: familySpace)
        }
        // Past here, a key typed asks the provider for its models again, which isn't what's checked.
        store.exhaustivity = .off
        await store.send(.form(.binding(.set(\.apiKey, "sk-new"))))
        await store.send(.saveTapped)
        await store.receive(\.failed) { $0.problem = "No." }
        await store.send(.form(.binding(.set(\.apiKey, ""))))
        await store.send(.saveTapped)
        await store.receive(\.saved)
        await store.send(.mainTapped(chef))
        await store.receive(\.saved)
        await store.send(.removeTapped(helper))
        await store.receive(\.saved)
        await store.finish()
        #expect(
            saved.value == [
                "added Chef to family", "changed chef: Chef", "main chef", "removed helper",
            ])
    }

    /// Connections… lists the shown space's connections; one added with the chats written, or
    /// changed, is saved and they're read again; chats that aren't ids can't be saved.
    @Test
    func aSpacesConnectionsAreConfigured() async {
        let family = SpaceSummary(id: familySpace, name: "Family", permissions: adminMay, status: .active)
        let kids = SpaceConnection(
            id: "kids", label: "Kids", enabled: true, platform: .telegram(chatIDs: [42]), hasToken: true,
            running: true, stopped: nil)
        let saved = LockIsolated<[ConnectionSettings]>([])
        let store = TestStore(initialState: SidebarFeature.SpaceConnections.State(session: session, space: family)) {
            SidebarFeature.SpaceConnections()
        } withDependencies: {
            $0.server.connections = { _, _ in saved.value.isEmpty ? [] : [kids] }
            $0.server.addConnection = { _, _, settings in saved.withValue { $0.append(settings) } }
            $0.server.changeConnection = { _, _, _, settings in saved.withValue { $0.append(settings) } }
        }

        await store.send(.shown)
        await store.receive(\.read)
        await store.send(.addTapped) { $0.form = SidebarFeature.SpaceConnections.Form() }
        var form = SidebarFeature.SpaceConnections.Form()
        form.label = "Kids"
        form.enabled = true
        form.chatIDs = "42, x"
        await store.send(.binding(.set(\.form, form))) { $0.form = form }
        #expect(!store.state.canSave)
        form.chatIDs = "42"
        form.token = "123:abc"
        await store.send(.binding(.set(\.form, form))) { $0.form = form }
        await store.send(.saveTapped) { $0.saving = true }
        await store.receive(\.saved) {
            $0.form = nil
            $0.saving = false
        }
        await store.receive(\.read) { $0.connections = [kids] }

        await store.send(.changeTapped(kids)) { $0.form = SidebarFeature.SpaceConnections.Form(changing: kids) }
        await store.send(.saveTapped) { $0.saving = true }
        await store.receive(\.saved) {
            $0.form = nil
            $0.saving = false
        }
        await store.receive(\.read)
        #expect(
            saved.value == [
                ConnectionSettings(label: "Kids", enabled: true, platform: .telegram(chatIDs: [42]), token: "123:abc"),
                ConnectionSettings(label: "Kids", enabled: true, platform: .telegram(chatIDs: [42]), token: nil),
            ])
    }

    /// Invite People… makes a link to the shown space, shown to copy; one that can't be made says so.
    @Test
    func anInviteIsMadeAndCopied() async {
        let family = SpaceSummary(id: familySpace, name: "Family", permissions: adminMay, status: .active)
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
        let inviting = SidebarFeature.Inviting.State(session: session, space: family)

        await store.send(.spaceMenuPicked(.invite)) { $0.destination = .inviting(inviting) }
        await store.send(.destination(.presented(.inviting(.appeared))))
        await store.receive(\.destination.presented.inviting.made) {
            $0.destination = .inviting(.init(session: self.session, space: family, invite: .made(link: link)))
        }
        await store.send(.destination(.presented(.inviting(.copyTapped))))
        await store.finish()
        #expect(copied.value == [link])
        await store.send(.destination(.dismiss)) { $0.destination = nil }

        await store.send(.spaceMenuPicked(.invite)) { $0.destination = .inviting(inviting) }
        await store.send(.destination(.presented(.inviting(.appeared))))
        await store.receive(\.destination.presented.inviting.failed) {
            $0.destination = .inviting(.init(session: self.session, space: family, invite: .failed))
        }
    }

    /// A new title renames a conversation where it is, marking nothing; one joined comes first,
    /// marked, unless it's listed already.
    @Test
    func aTitleOrAJoinChangesOnlyWhatItSays() async {
        var state = SidebarFeature.State()
        state.conversations = [
            .init(id: dinner.id, title: "plan dinner", spaceID: turgaiSpace, people: 1),
            .init(id: trip.id, title: "trip", spaceID: turgaiSpace, people: 1),
        ]
        state.selected = dinner.id
        let store = TestStore(initialState: state) { SidebarFeature() }

        let rome = Conversation(id: trip.id, botID: trip.botID, title: "Rome", spaceID: turgaiSpace, people: 1)
        await store.send(.conversationTitled(rome)) { $0.conversations[id: self.trip.id]?.title = "Rome" }
        await store.send(.conversationJoined(rome))
        let lunch = Conversation(
            id: ConversationID(rawValue: "lunch"), botID: trip.botID, spaceID: turgaiSpace, people: 1)
        await store.send(.conversationJoined(lunch)) {
            $0.conversations.insert(
                .init(id: lunch.id, title: nil, spaceID: turgaiSpace, people: 1, unread: true), at: 0)
        }
    }

    /// The sidebar shows the open conversation's space; its rail has every space in use, the one
    /// something was last said in first, dotted where something's new; switching opens a space's
    /// latest conversation, or starts one in a space with none; New conversation starts one in the
    /// space shown.
    @Test
    func theRailShowsOneSpaceAtATime() async {
        let family = SpaceSummary(id: familySpace, name: "Family", permissions: adminMay, status: .active)
        let work = SpaceSummary(id: workSpace, name: "Work", permissions: memberMay, status: .active)
        let started = LockIsolated<[SpaceID]>([])
        var state = SidebarFeature.State()
        state.session = session
        state.spaces = [turgai, family, work]
        state.conversations = [
            .init(id: dinner.id, title: "plan dinner", spaceID: familySpace, people: 1),
            .init(id: trip.id, title: nil, spaceID: turgaiSpace, people: 1, unread: true),
        ]
        state.selected = dinner.id
        state.shownSpaceID = familySpace
        #expect(state.shownSpace == family)
        #expect(
            state.entries == [
                .init(id: dinner.id, title: "plan dinner", unread: false, isOpen: true, menu: [.rename, .delete])
            ])
        #expect(state.spaceChoices.map(\.initial) == ["F", "T", "W"])
        #expect(state.spaceChoices.map(\.unread) == [false, true, false])
        #expect(state.spaceChoices.map(\.isShown) == [true, false, false])
        #expect(state.spaceChoices.map(\.fill) == [.filled, .outlined, .outlined])
        #expect(state.shownSpaceMenu == [.invite, .bots, .connections, .rename, .archive])
        #expect(state.canStartConversation)
        #expect(state.shownSpaceName == "Family")
        #expect(state.spaceChoices.map(\.hue) == [.yellow, .blue, .blue])
        #expect(state.shownSpaceHue == .yellow)
        #expect(state.shownSpacePeople == nil)
        state.peopleCounts[familySpace] = 1
        #expect(state.shownSpacePeople == nil)
        state.peopleCounts[familySpace] = 3
        #expect(state.shownSpacePeople == 3)

        let lunch = Conversation(
            id: ConversationID(rawValue: "lunch"), botID: trip.botID, spaceID: workSpace, people: 1)
        let store = TestStore(initialState: state) {
            SidebarFeature()
        } withDependencies: {
            $0.server.startConversation = { _, space in
                started.withValue { $0.append(space) }
                return lunch
            }
        }
        await store.send(.spaceSwitched(familySpace))
        await store.send(.spaceSwitched(turgaiSpace)) {
            $0.shownSpaceID = turgaiSpace
            $0.selected = self.trip.id
            $0.conversations[id: self.trip.id]?.unread = false
        }
        await store.receive(\.delegate, .open(trip.id))
        await store.send(.spaceSwitched(workSpace)) { $0.shownSpaceID = workSpace }
        await store.receive(\.started) {
            $0.conversations.insert(.init(id: lunch.id, spaceID: workSpace, people: 1), at: 0)
            $0.selected = lunch.id
        }
        await store.receive(\.delegate, .open(lunch.id))
        await store.finish()
        #expect(started.value == [workSpace])
    }

    /// An admin archives the space shown, asked first: it's off the rail, and the rail's first is
    /// shown instead. Still in the Spaces list, it opens read only, its menu offering only to use it
    /// again. With nothing left in it, it shows no conversation.
    @Test
    func anAdminArchivesASpace() async {
        let asks = LockIsolated<[ChatAsk]>([])
        let family = SpaceSummary(id: familySpace, name: "Family", permissions: adminMay, status: .active)
        let archived = SpaceSummary(
            id: familySpace, name: "Family", permissions: adminMay, status: .archived)
        let ours = SpaceSummary(
            id: turgaiSpace, name: "Turgai", permissions: adminMay, status: .active)
        let row = SidebarFeature.Row(id: dinner.id, title: "plan dinner", spaceID: familySpace, people: 1)
        var state = SidebarFeature.State()
        state.session = session
        state.spaces = [ours, family]
        state.conversations = [row, .init(id: trip.id, title: "trip", spaceID: turgaiSpace, people: 1)]
        state.selected = dinner.id
        state.shownSpaceID = familySpace
        state.peopleCounts = [familySpace: 1, turgaiSpace: 1]
        let store = TestStore(initialState: state) {
            SidebarFeature()
        } withDependencies: {
            $0.chat.ask = { ask in
                asks.withValue { $0.append(ask) }
                return .ok
            }
        }

        await store.send(.spaceMenuPicked(.archive)) { $0.destination = .alert(.archive(family)) }
        await store.send(.destination(.presented(.alert(.archiveConfirmed(familySpace))))) { $0.destination = nil }
        await store.receive(\.spaceStatusChanged) {
            $0.spaces = [ours, archived]
            $0.shownSpaceID = turgaiSpace
            $0.selected = self.trip.id
        }
        await store.receive(\.delegate, .spaceChanged(archived))
        await store.receive(\.delegate, .open(trip.id))
        #expect(store.state.spaceChoices.map(\.id) == [turgaiSpace])
        #expect(store.state.spaceSections.map(\.status) == [.active, .archived])

        await store.send(.spaceSwitched(familySpace)) {
            $0.shownSpaceID = familySpace
            $0.selected = self.dinner.id
        }
        await store.receive(\.delegate, .open(dinner.id))
        #expect(store.state.shownSpaceIsArchived)
        #expect(!store.state.canStartConversation)
        #expect(store.state.shownSpaceMenu == [.unarchive])
        #expect(store.state.entries.map(\.menu) == [[.delete]])

        await store.send(.conversationMenuPicked(dinner.id, .delete)) { $0.destination = .alert(.delete(row)) }
        await store.send(.destination(.presented(.alert(.deleteConfirmed(dinner.id))))) { $0.destination = nil }
        await store.receive(\.conversationLeft) {
            $0.conversations.remove(id: self.dinner.id)
            $0.selected = nil
        }
        await store.receive(\.delegate, .close(archived))
        #expect(store.state.openTitle == "")

        await store.send(.spaceMenuPicked(.unarchive))
        await store.receive(\.spaceStatusChanged) { $0.spaces = [ours, family] }
        await store.receive(\.delegate, .spaceChanged(family))
        await store.finish()
        #expect(
            asks.value == [
                .archiveSpace(familySpace), .deleteConversation(dinner.id, of: familySpace),
                .unarchiveSpace(familySpace),
            ])

        var turgais = SidebarFeature.State()
        turgais.spaces = [ours]
        #expect(turgais.shownSpaceMenu == [.invite, .bots, .connections, .rename, .archive])
    }

    /// Leaving or deleting the conversation open opens the next in its space; what's refused says
    /// why. Others in it, a member only leaves it.
    @Test
    func leavingOrDeletingOpensTheNext() async {
        let family = SpaceSummary(id: familySpace, name: "Family", permissions: memberMay, status: .active)
        let lunch = ConversationID(rawValue: "lunch")
        let refused = LockIsolated(true)
        let row = SidebarFeature.Row(id: dinner.id, title: "plan dinner", spaceID: familySpace, people: 1)
        var state = SidebarFeature.State()
        state.session = session
        state.spaces = [family]
        state.conversations = [row, .init(id: lunch, title: "lunch", spaceID: familySpace, people: 3)]
        state.selected = dinner.id
        state.shownSpaceID = familySpace
        state.peopleCounts = [familySpace: 3]
        #expect(state.entries.map(\.menu) == [[.rename, .delete], [.rename, .leave]])
        let store = TestStore(initialState: state) {
            SidebarFeature()
        } withDependencies: {
            $0.chat.ask = { _ in
                refused.value ? .failed(ChatError(code: "refused", message: "Not now.")) : .ok
            }
        }

        await store.send(.conversationMenuPicked(lunch, .leave))
        await store.receive(\.failed) { $0.error = "Not now." }
        refused.setValue(false)
        await store.send(.conversationMenuPicked(dinner.id, .delete)) { $0.destination = .alert(.delete(row)) }
        await store.send(.destination(.presented(.alert(.deleteConfirmed(dinner.id))))) { $0.destination = nil }
        await store.receive(\.conversationLeft) {
            $0.conversations.remove(id: self.dinner.id)
            $0.selected = lunch
            $0.error = nil
        }
        await store.receive(\.delegate, .open(lunch))
        await store.finish()
    }

    /// Spaces, or ⌘K, lists every space, those in use first; what's written finds them by name, and
    /// Return shows the first found.
    @Test
    func theSpacesListFindsASpace() async {
        let work = SpaceSummary(id: workSpace, name: "Work", permissions: memberMay, status: .archived)
        var state = SidebarFeature.State()
        state.session = session
        state.spaces = [turgai, work]
        state.conversations = [
            .init(id: dinner.id, title: "plan dinner", spaceID: turgaiSpace, people: 1),
            .init(id: trip.id, title: "trip", spaceID: workSpace, people: 1),
        ]
        state.selected = dinner.id
        state.shownSpaceID = turgaiSpace
        state.peopleCounts = [turgaiSpace: 1, workSpace: 1]
        let store = TestStore(initialState: state) { SidebarFeature() }

        await store.send(.spacesTapped) { $0.destination = .choosingSpace(.init()) }
        #expect(store.state.spaceSections.map(\.status) == [.active, .archived])
        await store.send(.destination(.presented(.choosingSpace(.binding(.set(\.search, "wo")))))) {
            $0.destination = .choosingSpace(.init(search: "wo"))
        }
        #expect(store.state.spaceSections.map { $0.choices.map(\.id) } == [[workSpace]])
        await store.send(.destination(.presented(.choosingSpace(.binding(.set(\.search, "home")))))) {
            $0.destination = .choosingSpace(.init(search: "home"))
        }
        #expect(store.state.spaceSections.isEmpty)
        await store.send(.spacesSubmitted)
        await store.send(.destination(.presented(.choosingSpace(.binding(.set(\.search, "WO")))))) {
            $0.destination = .choosingSpace(.init(search: "WO"))
        }
        await store.send(.spacesSubmitted) {
            $0.destination = nil
            $0.shownSpaceID = workSpace
            $0.selected = self.trip.id
        }
        await store.receive(\.delegate, .open(trip.id))
        await store.finish()
    }
}

@MainActor
struct ChatOpeningTests {
    /// Opening another conversation shows it instead, asking the connection for it; what's heard of
    /// another conversation then isn't shown.
    @Test
    func openingShowsOnlyThatConversation() async {
        let sent = LockIsolated<[ChatCommand]>([])
        let dinner = ConversationID(rawValue: "dinner")
        let trip = ConversationID(rawValue: "trip")
        var state = ChatFeature.State(connection: .connected(botID: BotID(rawValue: "conversation")))
        state.conversationID = dinner
        state.messages = [Message(id: MessageID(), role: .user, text: "pasta?", at: Date(timeIntervalSince1970: 1))]
        let store = TestStore(initialState: state) {
            ChatFeature()
        } withDependencies: {
            $0.chat.send = { command in sent.withValue { $0.append(command) } }
        }

        let turgai = SpaceSummary(
            id: turgaiSpace, name: "Turgai", permissions: memberMay, status: .active)
        await store.send(.open(trip, in: turgai)) {
            $0.conversationID = trip
            $0.space = turgai
            $0.messages = []
        }
        #expect(sent.value == [.open(spaceID: turgaiSpace, conversationID: trip)])

        let late = Message(id: MessageID(), role: .user, text: "late", at: Date(timeIntervalSince1970: 2))
        await store.send(
            .received(ChatEvent(payload: .messageAccepted(conversationID: dinner, turnID: nil, message: late))))
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
            conversationID: ConversationID(rawValue: "dinner"),
            space: SpaceSummary(id: familySpace, name: "Family", permissions: memberMay, status: .active),
            participants: [bob], you: "account-ann")
        state.spacePeople = [
            SpacePerson(id: "account-ann", name: "ann", groups: []),
            SpacePerson(id: "account-bob", name: "bob", groups: ["members"]),
            SpacePerson(id: "account-cat", name: "cat", groups: ["members"]),
        ]
        #expect(state.participantsLine == "bob")
        state.participants = [
            ParticipantSummary(kind: .agent, id: "agent", name: "Turgai"), bob,
            ParticipantSummary(kind: .person, id: "account-ann", name: "ann"),
        ]
        #expect(state.participantsLine == "You, Turgai, bob")
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
            $0.date = .constant(Date(timeIntervalSince1970: 2))
            $0.server.participants = { _, _, _ in [bob, cat] }
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
        let taken = Message(id: request.id, role: .user, text: "@cat", at: Date(timeIntervalSince1970: 1))
        let accepted = ChatEvent(
            payload: .messageAccepted(conversationID: ConversationID(rawValue: "dinner"), turnID: nil, message: taken))
        await store.send(.received(accepted)) {
            $0.pending = []
            $0.today = Date(timeIntervalSince1970: 2)
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
            id: MessageID(rawValue: UUID(0)), text: "@bob pasta?",
            to: [ParticipantRef(kind: .person, id: "account-bob")])
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
