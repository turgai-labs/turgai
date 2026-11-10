import ComposableArchitecture
import Foundation
import Testing
import TurgaiModels

@testable import MacApp

@MainActor
struct SidebarFeatureTests {
    let session = Session(token: "token", expiresAt: Date(timeIntervalSince1970: 2_000_000))
    let turgai = SpaceSummary(id: "turgai", name: "Turgai", role: .member, status: .active, kind: .turgaisOwn)
    let dinner = Conversation(
        id: ConversationID(rawValue: "dinner"), botID: BotID(rawValue: "conversation"), title: "plan dinner",
        spaceID: "turgai", people: 1)
    let trip = Conversation(
        id: ConversationID(rawValue: "trip"), botID: BotID(rawValue: "conversation"), title: "trip", spaceID: "turgai",
        people: 1)

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
                .init(id: self.dinner.id, title: "plan dinner", spaceID: "turgai", people: 1),
                .init(id: self.trip.id, title: "trip", spaceID: "turgai", people: 1),
            ]
        }
        await store.receive(\.selected) {
            $0.selected = self.dinner.id
            $0.shownSpaceID = "turgai"
        }
        await store.receive(\.delegate, .open(dinner.id))
        await store.finish()
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
            $0.conversations = [.init(id: self.dinner.id, title: "plan dinner", spaceID: "turgai", people: 1)]
        }
        await store.receive(\.selected) {
            $0.selected = self.dinner.id
            $0.shownSpaceID = "turgai"
        }
        await store.receive(\.delegate, .open(dinner.id))
        await store.finish()
        #expect(started.value == [nil])
    }

    /// Something said in another conversation brings it to the top, marked, until it's opened.
    @Test
    func aChangedConversationComesFirstMarked() async {
        var state = SidebarFeature.State()
        state.conversations = [
            .init(id: dinner.id, title: "plan dinner", spaceID: "turgai", people: 1),
            .init(id: trip.id, title: "trip", spaceID: "turgai", people: 1),
        ]
        state.selected = dinner.id
        let store = TestStore(initialState: state) { SidebarFeature() }

        let changed = Conversation(id: trip.id, botID: trip.botID, title: "trip to Rome", spaceID: "turgai", people: 1)
        await store.send(.conversationSaid(changed)) {
            $0.conversations = [
                .init(id: self.trip.id, title: "trip to Rome", spaceID: "turgai", people: 1, unread: true),
                .init(id: self.dinner.id, title: "plan dinner", spaceID: "turgai", people: 1),
            ]
        }
        await store.send(.selected(trip.id)) {
            $0.selected = self.trip.id
            $0.shownSpaceID = "turgai"
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
        state.conversations = [.init(id: dinner.id, title: "plan dinner", spaceID: "turgai", people: 1)]
        let store = TestStore(initialState: state) {
            SidebarFeature()
        } withDependencies: {
            $0.server.titleConversation = { _, _, title in titled.withValue { $0.append(title) } }
        }

        await store.send(.conversationMenuPicked(dinner.id, .rename)) {
            $0.dialog = .renaming(.init(subject: .conversation(self.dinner.id), name: "plan dinner"))
        }
        await store.send(.nameChanged(" Dinner ")) { $0.dialog?.name = " Dinner " }
        await store.send(.renameConfirmed) { $0.dialog = nil }
        await store.receive(\.renamed) { $0.conversations[id: self.dinner.id]?.title = "Dinner" }
        await store.send(.conversationMenuPicked(dinner.id, .rename)) {
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
        let family = SpaceSummary(id: "family", name: "Family", role: .admin, status: .active, kind: .made)
        let space = "8F3C1E2A-4B5D-4E6F-8A9B-0C1D2E3F4A5B"
        let work = SpaceSummary(id: space, name: "Work", role: .member, status: .active, kind: .made)
        let joined = LockIsolated<[SpaceInviteLink]>([])
        var state = SidebarFeature.State()
        state.session = session
        state.spaces = [turgai]
        state.conversations = [.init(id: dinner.id, title: "plan dinner", spaceID: "family", people: 1)]
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
        await store.receive(\.spaceSwitched) { $0.shownSpaceID = "family" }
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
        await store.receive(\.spaceSwitched) { $0.shownSpaceID = space }
        await store.receive(\.started) {
            $0.conversations.insert(.init(id: self.trip.id, title: "trip", spaceID: "turgai", people: 1), at: 0)
        }
        await store.receive(\.selected) {
            $0.selected = self.trip.id
            $0.shownSpaceID = "turgai"
        }
        await store.receive(\.delegate, .open(trip.id))
        await store.finish()
        #expect(joined.value.map(\.token) == ["bad", "good"])
    }

    /// Invite People… makes a link to the shown space, shown to copy; one that can't be made says so.
    @Test
    func anInviteIsMadeAndCopied() async {
        let family = SpaceSummary(id: "family", name: "Family", role: .admin, status: .active, kind: .made)
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

        await store.send(.spaceMenuPicked(.invite)) { $0.dialog = .inviting(.init(spaceName: "Family")) }
        await store.receive(\.inviteMade) { $0.dialog = .inviting(.init(spaceName: "Family", link: link)) }
        await store.send(.copyInviteTapped)
        #expect(copied.value == [link])
        await store.send(.dialogPresented(false)) { $0.dialog = nil }

        await store.send(.spaceMenuPicked(.invite)) { $0.dialog = .inviting(.init(spaceName: "Family")) }
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
            .init(id: dinner.id, title: "plan dinner", spaceID: "turgai", people: 1),
            .init(id: trip.id, title: "trip", spaceID: "turgai", people: 1),
        ]
        state.selected = dinner.id
        let store = TestStore(initialState: state) { SidebarFeature() }

        let rome = Conversation(id: trip.id, botID: trip.botID, title: "Rome", spaceID: "turgai", people: 1)
        await store.send(.conversationTitled(rome)) { $0.conversations[id: self.trip.id]?.title = "Rome" }
        await store.send(.conversationJoined(rome))
        let lunch = Conversation(id: ConversationID(rawValue: "lunch"), botID: trip.botID, spaceID: "turgai", people: 1)
        await store.send(.conversationJoined(lunch)) {
            $0.conversations.insert(.init(id: lunch.id, title: nil, spaceID: "turgai", people: 1, unread: true), at: 0)
        }
    }

    /// The sidebar shows the open conversation's space; its rail has every space in use, the one
    /// something was last said in first, dotted where something's new; switching opens a space's
    /// latest conversation, or starts one in a space with none; New conversation starts one in the
    /// space shown.
    @Test
    func theRailShowsOneSpaceAtATime() async {
        let family = SpaceSummary(id: "family", name: "Family", role: .admin, status: .active, kind: .made)
        let work = SpaceSummary(id: "work", name: "Work", role: .member, status: .active, kind: .made)
        let started = LockIsolated<[String?]>([])
        var state = SidebarFeature.State()
        state.session = session
        state.spaces = [turgai, family, work]
        state.conversations = [
            .init(id: dinner.id, title: "plan dinner", spaceID: "family", people: 1),
            .init(id: trip.id, title: nil, spaceID: "turgai", people: 1, unread: true),
        ]
        state.selected = dinner.id
        state.shownSpaceID = "family"
        #expect(state.shownSpace == family)
        #expect(
            state.entries == [
                .init(id: dinner.id, title: "plan dinner", unread: false, isOpen: true, menu: [.rename, .delete])
            ])
        #expect(state.spaceChoices.map(\.initial) == ["F", "T", "W"])
        #expect(state.spaceChoices.map(\.unread) == [false, true, false])
        #expect(state.spaceChoices.map(\.isShown) == [true, false, false])
        #expect(state.spaceChoices.map(\.fill) == [.filled, .outlined, .outlined])
        #expect(state.shownSpaceMenu == [.invite, .rename(name: "Family"), .archive(name: "Family")])
        #expect(state.newConversationHelp == "New conversation in Family")
        #expect(state.shownSpaceName == "Family")
        #expect(state.spaceChoices.map(\.hue) == [.yellow, .blue, .blue])
        #expect(state.shownSpaceHue == .yellow)
        #expect(state.shownSpaceDetail == "Space")
        state.peopleCounts["family"] = 1
        #expect(state.shownSpaceDetail == "Space · 1 person")
        state.peopleCounts["family"] = 3
        #expect(state.shownSpaceDetail == "Space · 3 people")

        let lunch = Conversation(id: ConversationID(rawValue: "lunch"), botID: trip.botID, spaceID: "work", people: 1)
        let store = TestStore(initialState: state) {
            SidebarFeature()
        } withDependencies: {
            $0.server.startConversation = { _, space in
                started.withValue { $0.append(space) }
                return lunch
            }
        }
        await store.send(.spaceSwitched("family"))
        await store.send(.spaceSwitched("turgai")) { $0.shownSpaceID = "turgai" }
        await store.receive(\.selected) {
            $0.selected = self.trip.id
            $0.conversations[id: self.trip.id]?.unread = false
        }
        await store.receive(\.delegate, .open(trip.id))
        await store.send(.spaceSwitched("work")) { $0.shownSpaceID = "work" }
        await store.receive(\.started) {
            $0.conversations.insert(.init(id: lunch.id, spaceID: "work", people: 1), at: 0)
        }
        await store.receive(\.selected) { $0.selected = lunch.id }
        await store.receive(\.delegate, .open(lunch.id))
        await store.finish()
        #expect(started.value == ["work"])
    }

    /// An admin archives the space shown, asked first: it's off the rail, and the rail's first is
    /// shown instead. Still in the Spaces list, it opens read only, its menu offering only to use it
    /// again; Turgai's own isn't offered. With nothing left in it, it shows no conversation.
    @Test
    func anAdminArchivesASpace() async {
        let asks = LockIsolated<[ChatAsk]>([])
        let family = SpaceSummary(id: "family", name: "Family", role: .admin, status: .active, kind: .made)
        let archived = SpaceSummary(id: "family", name: "Family", role: .admin, status: .archived, kind: .made)
        let ours = SpaceSummary(id: "turgai", name: "Turgai", role: .admin, status: .active, kind: .turgaisOwn)
        var state = SidebarFeature.State()
        state.session = session
        state.spaces = [ours, family]
        state.conversations = [
            .init(id: dinner.id, title: "plan dinner", spaceID: "family", people: 1),
            .init(id: trip.id, title: "trip", spaceID: "turgai", people: 1),
        ]
        state.selected = dinner.id
        state.shownSpaceID = "family"
        state.peopleCounts = ["family": 1, "turgai": 1]
        let store = TestStore(initialState: state) {
            SidebarFeature()
        } withDependencies: {
            $0.chat.ask = { ask in
                asks.withValue { $0.append(ask) }
                return .ok
            }
        }

        await store.send(.spaceMenuPicked(.archive(name: "Family"))) { $0.alert = .archive(family) }
        await store.send(.alert(.presented(.archiveConfirmed("family")))) { $0.alert = nil }
        await store.receive(\.spaceStatusChanged) { $0.spaces = [ours, archived] }
        await store.receive(\.delegate, .spaceChanged(archived))
        await store.receive(\.spaceSwitched) { $0.shownSpaceID = "turgai" }
        await store.receive(\.selected) { $0.selected = self.trip.id }
        await store.receive(\.delegate, .open(trip.id))
        #expect(asks.value == [.archiveSpace("family")])
        #expect(store.state.spaceChoices.map(\.id) == ["turgai"])
        #expect(store.state.spaceSections.map(\.title) == ["Active", "Archived"])

        await store.send(.spaceSwitched("family")) { $0.shownSpaceID = "family" }
        await store.receive(\.selected) { $0.selected = self.dinner.id }
        await store.receive(\.delegate, .open(dinner.id))
        #expect(store.state.shownSpaceDetail == "Archived · 1 person")
        #expect(store.state.newConversationHelp == nil)
        #expect(store.state.shownSpaceMenu == [.unarchive])
        #expect(store.state.entries.map(\.menu) == [[.delete]])

        await store.send(.conversationMenuPicked(dinner.id, .delete)) {
            $0.alert = .delete(.init(id: self.dinner.id, title: "plan dinner", spaceID: "family", people: 1))
        }
        await store.send(.alert(.presented(.deleteConfirmed(dinner.id)))) { $0.alert = nil }
        await store.receive(\.conversationLeft) {
            $0.conversations.remove(id: self.dinner.id)
            $0.selected = nil
        }
        await store.receive(\.delegate, .close(archived))
        #expect(store.state.openTitle == "")

        await store.send(.spaceMenuPicked(.unarchive))
        await store.receive(\.spaceStatusChanged) { $0.spaces = [ours, family] }
        await store.receive(\.delegate, .spaceChanged(family))
        #expect(asks.value == [.archiveSpace("family"), .deleteConversation(dinner.id), .unarchiveSpace("family")])

        var turgais = SidebarFeature.State()
        turgais.spaces = [ours]
        #expect(turgais.shownSpaceMenu == [.invite, .rename(name: "Turgai")])
    }

    /// Leaving or deleting the conversation open opens the next in its space; what's refused says
    /// why. Others in it, a member only leaves it.
    @Test
    func leavingOrDeletingOpensTheNext() async {
        let family = SpaceSummary(id: "family", name: "Family", role: .member, status: .active, kind: .made)
        let lunch = ConversationID(rawValue: "lunch")
        let refused = LockIsolated(true)
        var state = SidebarFeature.State()
        state.session = session
        state.spaces = [family]
        state.conversations = [
            .init(id: dinner.id, title: "plan dinner", spaceID: "family", people: 1),
            .init(id: lunch, title: "lunch", spaceID: "family", people: 3),
        ]
        state.selected = dinner.id
        state.shownSpaceID = "family"
        state.peopleCounts = ["family": 3]
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
        await store.send(.conversationMenuPicked(dinner.id, .delete)) {
            $0.alert = .delete(.init(id: self.dinner.id, title: "plan dinner", spaceID: "family", people: 1))
        }
        await store.send(.alert(.presented(.deleteConfirmed(dinner.id)))) { $0.alert = nil }
        await store.receive(\.conversationLeft) {
            $0.conversations.remove(id: self.dinner.id)
            $0.selected = nil
        }
        await store.receive(\.selected) {
            $0.selected = lunch
            $0.error = nil
        }
        await store.receive(\.delegate, .open(lunch))
        await store.finish()
    }

    /// Tasks lists the shown space's objects with something due, each with what's due, following
    /// their changes while it's shown; or that there are none, or why they couldn't be read.
    @Test
    func tasksListsWhatWorksOnItsOwn() async {
        let asked = LockIsolated<[ChatAsk]>([])
        let ticker = TaskListing(
            object: ObjectListing(
                id: "ticker", title: "ticker", summary: nil, actions: [], events: [], node: "127.0.0.1:1", made: nil),
            schedules: ["tick": "every 5 minutes"], timers: [:])
        var state = SidebarFeature.State()
        state.spaces = [turgai]
        let store = TestStore(initialState: state) {
            SidebarFeature()
        } withDependencies: {
            $0.chat.ask = { ask in
                asked.withValue { $0.append(ask) }
                switch ask {
                case .join, .leave: return .ok
                default:
                    let reads = asked.value.filter { $0 == .tasks(space: "turgai") }.count
                    guard reads < 3 else { return .failed(ChatError(code: "refused", message: "No.")) }
                    return .tasks(reads == 1 ? [ticker] : [])
                }
            }
        }

        await store.send(.tasks(.tapped)) { $0.dialog = .tasks(.init(spaceID: "turgai", spaceName: "Turgai")) }
        await store.receive(\.tasks.read) {
            $0.dialog = .tasks(.init(spaceID: "turgai", spaceName: "Turgai", listing: .read([ticker])))
        }
        guard case .tasks(let tasks) = store.state.dialog else { return }
        #expect(tasks.title == "Tasks in Turgai")
        #expect(tasks.rows.map(\.lines) == [["tick · every 5 minutes"]])
        #expect(tasks.note == nil)
        let none = SidebarFeature.Tasks(spaceID: "turgai", spaceName: "Turgai", listing: .read([]))
        #expect(none.note == "Nothing here is due.")

        // A change in another space reads nothing; one in this space reads them again.
        await store.send(.tasks(.changed("family")))
        await store.send(.tasks(.changed("turgai")))
        await store.receive(\.tasks.read) {
            $0.dialog = .tasks(.init(spaceID: "turgai", spaceName: "Turgai", listing: .read([])))
        }
        await store.send(.dialogPresented(false)) { $0.dialog = nil }
        await store.send(.tasks(.tapped)) { $0.dialog = .tasks(.init(spaceID: "turgai", spaceName: "Turgai")) }
        await store.receive(\.tasks.failed) {
            $0.dialog = .tasks(.init(spaceID: "turgai", spaceName: "Turgai", listing: .failed("No.")))
        }
        await store.finish()
        #expect(
            asked.value == [
                .join(.tasks(space: "turgai")), .tasks(space: "turgai"), .tasks(space: "turgai"),
                .leave(.tasks(space: "turgai")), .join(.tasks(space: "turgai")), .tasks(space: "turgai"),
            ])
    }

    /// Spaces, or ⌘K, lists every space, those in use first; what's written finds them by name, and
    /// Return shows the first found.
    @Test
    func theSpacesListFindsASpace() async {
        let work = SpaceSummary(id: "work", name: "Work", role: .member, status: .archived, kind: .made)
        var state = SidebarFeature.State()
        state.session = session
        state.spaces = [turgai, work]
        state.conversations = [
            .init(id: dinner.id, title: "plan dinner", spaceID: "turgai", people: 1),
            .init(id: trip.id, title: "trip", spaceID: "work", people: 1),
        ]
        state.selected = dinner.id
        state.shownSpaceID = "turgai"
        state.peopleCounts = ["turgai": 1, "work": 1]
        let store = TestStore(initialState: state) { SidebarFeature() }

        await store.send(.spacesTapped) { $0.dialog = .choosingSpace(.init()) }
        #expect(store.state.spaceSections.map(\.title) == ["Active", "Archived"])
        await store.send(.searchChanged("wo")) { $0.dialog = .choosingSpace(.init(search: "wo")) }
        #expect(store.state.spaceSections.map { $0.choices.map(\.id) } == [["work"]])
        await store.send(.searchChanged("home")) { $0.dialog = .choosingSpace(.init(search: "home")) }
        #expect(store.state.spacesNote == "No space is called “home”.")
        await store.send(.searchSubmitted)
        await store.send(.searchChanged("WO")) { $0.dialog = .choosingSpace(.init(search: "WO")) }
        await store.send(.searchSubmitted)
        await store.receive(\.spacePicked) { $0.dialog = nil }
        await store.receive(\.spaceSwitched) { $0.shownSpaceID = "work" }
        await store.receive(\.selected) { $0.selected = self.trip.id }
        await store.receive(\.delegate, .open(trip.id))
        await store.finish()
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
        state.messages = [Message(id: MessageID(), role: .user, text: "pasta?", at: Date(timeIntervalSince1970: 1))]
        let store = TestStore(initialState: state) {
            ChatFeature()
        } withDependencies: {
            $0.chat.send = { command in sent.withValue { $0.append(command) } }
        }

        let turgai = SpaceSummary(id: "turgai", name: "Turgai", role: .member, status: .active, kind: .turgaisOwn)
        await store.send(.open(trip, in: turgai)) {
            $0.conversationID = trip
            $0.space = turgai
            $0.messages = []
        }
        #expect(sent.value == [.open(conversationID: trip)])

        let late = Message(id: MessageID(), role: .user, text: "late", at: Date(timeIntervalSince1970: 2))
        await store.send(.received(ChatEvent(payload: .messageAccepted(conversationID: dinner, turnID: nil, message: late))))

        let changed = Conversation(id: dinner, botID: BotID(rawValue: "conversation"), spaceID: "turgai", people: 1)
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
