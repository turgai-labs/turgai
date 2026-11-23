import Foundation
import Testing
import TurgaiCalls
import TurgaiDomain
import TurgaiSpaces
import VirtualActors

@testable import TurgaiObjects

/// A space: its admins, who may everything; its members, each in some of its groups; what each
/// group may; and who may run exactly what, which it settles into each scope as the scope opens.
/// Whoever decides for it answers what's asked of it.
struct SpaceTests {
    private let family = SpaceID()
    private let ann = UserID.ann
    private let bob = UserID.bob
    private let cat = UserID.cat
    private let forecast = ExactRequest.http(method: "GET", url: "https://example.com/forecast", body: Data())
    private let pets = GroupID("pets")!
    private let helper: Bot
    private let chef: Bot

    init() {
        helper = Self.makeBot("Helper")
        chef = Self.makeBot("Chef")
    }

    /// A bot called `name`, on a model of Ollama on this machine.
    private static func makeBot(_ name: String) -> Bot {
        Bot(
            name: BotName(name)!, instructions: "",
            model: BotModel(
                location: .server(
                    ModelServer(software: .ollama, address: .localOllama, key: nil, context: .chosen(.standard))),
                name: ModelName("llama3")!))
    }

    /// The groups whoever comes in as a member is in.
    private let asMembers = NonEmptySet(GroupID.members)

    /// `state` after each of `commands`, decided in turn from the state the one before left.
    private func run(_ commands: [SpaceCommand], from state: SpaceState) throws -> SpaceState {
        try commands.reduce(state) { state, command in
            SpaceDecider.evolve(state, try SpaceDecider.decide(command, state))
        }
    }

    /// What `command` makes happen in `state`.
    private func decide(_ command: SpaceCommand, _ state: SpaceState) throws -> [SpaceEvent] {
        try SpaceDecider.decide(command, state)
    }

    /// The family space, made by Ann, with Bob and Cat members.
    private func annDecidesForBob() throws -> SpaceState {
        try run(
            [
                .make(named: SpaceName("Family")!, by: ann, bot: helper), .admit(bob, into: asMembers),
                .admit(cat, into: asMembers),
            ],
            from: SpaceDecider.initial(family))
    }

    /// The family space, its guests allowed to use its bots, and `guest` in it.
    private func withAGuest(_ guest: UserID) throws -> SpaceState {
        try run(
            [.setPermissions(.guests, Permissions(bots: .use), by: ann), .admit(guest, into: NonEmptySet(.guests))],
            from: try annDecidesForBob())
    }

    /// It made.
    private func made(_ state: SpaceState) throws -> SpaceState.Space {
        try #require(state.space)
    }

    /// `bob` asking for the forecast, as `asker`, the request `id`.
    private func asking(_ id: AccessRequestID, as asker: Party? = nil) -> SpaceCommand {
        .ask(forecast, by: asker ?? .person(bob), id: id)
    }

    /// What work that starts for someone may do, by who asked. A person may what their groups
    /// may; one of the space's own actors is in no group and may only what's shared with it;
    /// anyone else is refused.
    @Test func workIsForOneOfItsPeopleOrOneOfItsOwnActors() throws {
        let space = try made(try annDecidesForBob())
        let counter = try Party(VirtualActorID.owned(by: family, "object", "counter"))
        let elsewhere = try Party(VirtualActorID.owned(by: SpaceID(), "object", "counter"))

        #expect(try space.scope(of: Party.person(ann)).permissions == .all)
        #expect(try space.scope(of: Party.person(bob)).groups == [.members])
        let its = try space.scope(of: counter)
        #expect(its.asker == counter && its.person == nil)
        #expect(its.permissions == .none && its.groups.isEmpty && !its.allows(forecast))
        // What's its own, and what's shared with it; nothing a person's, though they made it.
        #expect(Access(madeBy: counter).allows(its, .write))
        #expect(!Access(madeBy: .person(bob)).allows(its, .read))
        #expect(Access(madeBy: .person(bob)).sharing(with: Audience(counter), .read).allows(its, .read))

        #expect(throws: SpaceRefusal.notInIt) { try space.scope(of: Party.person(.guest(UUID()))) }
        #expect(throws: SpaceRefusal.notInIt) { try space.scope(of: elsewhere) }
    }

    @Test func nothingButMakingHappensBeforeItsMade() throws {
        let empty = SpaceDecider.initial(family)
        #expect(empty.space == nil)
        #expect(empty.listing(for: ann) == nil)
        #expect(throws: SpaceRefusal.notMadeYet) { try decide(.admit(ann, into: asMembers), empty) }
        #expect(throws: SpaceRefusal.notMadeYet) { try decide(.rename(to: SpaceName("Home")!, by: ann), empty) }
    }

    /// Whoever comes in is in the groups their way in names, never in none, and only in groups
    /// it has.
    @Test func whoeverComesInIsInTheGroupsTheirWayInNames() throws {
        let guest = UserID.guest(UUID())
        let state = try run([.admit(bob, into: NonEmptySet(.guests))], from: try withAGuest(guest))
        let space = try made(state)
        #expect(space.members[bob] == asMembers)
        #expect(space.members[guest] == NonEmptySet(.guests))
        #expect(space.permissions(of: guest) == Permissions(bots: .use))
        #expect(throws: SpaceRefusal.noSuchGroup(pets)) { try decide(.admit(.dad, into: NonEmptySet(pets)), state) }
    }

    @Test func thePlatformSaysWhoTheAdminsAre() throws {
        var state = try run(
            [.makeForPlatform(named: SpaceName("Family")!, admins: NonEmptySet(ann, [bob]), groups: [:], bot: helper)],
            from: SpaceDecider.initial(family))
        #expect(try made(state).admins == NonEmptySet(ann, [bob]))

        // Bob is no longer one, and Cat now is: Bob stays, as a member.
        let events = try decide(.setAdmins(NonEmptySet(ann, [cat])), state)
        #expect(events == [.adminMade(cat), .adminSteppedDown(bob, inGroups: asMembers)])
        state = SpaceDecider.evolve(state, events)
        #expect(try made(state).admins == NonEmptySet(ann, [cat]))
        #expect(try made(state).members[bob] == asMembers)
        // The same admins again change nothing.
        #expect(try decide(.setAdmins(NonEmptySet(ann, [cat])), state).isEmpty)
    }

    @Test func anAdminsOwnRequestRunsAndAMembersIsAsked() throws {
        let state = try annDecidesForBob()
        #expect(try made(state).scope(of: ann).allows(forecast))
        #expect(try !made(state).scope(of: bob).allows(forecast))
        let id = AccessRequestID(UUID())
        #expect(
            try decide(asking(id), state)
                == [.asked(AccessRequest(id: id, request: forecast, by: .person(bob), standing: .waiting))])
    }

    @Test func aRequestStillWaitingIsTheSameOne() throws {
        let id = AccessRequestID(UUID())
        let waiting = try run([asking(id)], from: try annDecidesForBob())
        #expect(try decide(asking(AccessRequestID(UUID())), waiting).isEmpty)
        #expect(try made(waiting).request(for: forecast, by: .person(bob))?.id == id)
    }

    @Test func onlyAnAnswerByWhoeverDecidesCounts() throws {
        let id = AccessRequestID(UUID())
        let waiting = try run([asking(id)], from: try annDecidesForBob())
        #expect(try decide(.answer(id, .always, by: bob), waiting).isEmpty)
        #expect(try decide(.answer(id, .always, by: .dad), waiting).isEmpty)
        #expect(try decide(.answer(id, .always, by: ann), waiting) == [.answered(id, .always, by: ann)])
    }

    @Test func aGroupThatMayAnswerDecides() throws {
        let id = AccessRequestID(UUID())
        let parents = GroupID("parents")!
        let state = try run(
            [
                .makeGroup(parents, Permissions(requests: .answer), by: ann),
                .place(cat, inGroups: NonEmptySet(.members, [parents]), by: ann), asking(id),
            ], from: try annDecidesForBob())
        #expect(try decide(.answer(id, .once, by: cat), state) == [.answered(id, .once, by: cat)])
    }

    @Test func alwaysSharesItWithWhoeverAskedFromTheirNextScope() throws {
        let id = AccessRequestID(UUID())
        let shared = try run([asking(id), .answer(id, .always, by: ann)], from: try annDecidesForBob())
        #expect(try made(shared).scope(of: bob).allows(forecast))
        #expect(try made(shared).opening(scopeOf: .person(bob)).0.allows(forecast))
        // Only with Bob, and nothing waits.
        #expect(try !made(shared).scope(of: cat).allows(forecast))
        #expect(try made(shared).requests.isEmpty)
    }

    @Test func everyoneSharesItWithTheGroupsOfWhoeverAsked() throws {
        let id = AccessRequestID(UUID())
        let shared = try run([asking(id), .answer(id, .everyone, by: ann)], from: try annDecidesForBob())
        #expect(try made(shared).scope(of: bob).allows(forecast))
        #expect(try made(shared).scope(of: cat).allows(forecast))
        // Not elsewhere: Bob has no scope at all in a space he isn't in.
        let elsewhere = try run(
            [.make(named: SpaceName("Work")!, by: ann, bot: helper)], from: SpaceDecider.initial(SpaceID()))
        #expect(throws: SpaceRefusal.notInIt) { try made(elsewhere).scope(of: bob) }
    }

    /// A guest doesn't have what's shared with the members' groups: they're in a group of their own.
    @Test func whatsSharedWithEveryoneIsntAGuests() throws {
        let guest = UserID.guest(UUID())
        let id = AccessRequestID(UUID())
        let shared = try run([asking(id), .answer(id, .everyone, by: ann)], from: try withAGuest(guest))
        #expect(try made(shared).scope(of: bob).allows(forecast))
        #expect(try !made(shared).scope(of: guest).allows(forecast))
    }

    /// Every space is made with a guests group allowed nothing, which stays: a guest coming in is
    /// in it, and may use the space's bots only once its admins allow the group to.
    @Test func aGuestIsAllowedWhatItsAdminsAllowGuests() throws {
        let guest = UserID.guest(UUID())
        var state = try run([.admit(guest, into: NonEmptySet(.guests))], from: try annDecidesForBob())
        #expect(try made(state).groups[.guests] == Permissions.none)
        #expect(try made(state).permissions(of: guest) == Permissions.none)
        #expect(throws: SpaceRefusal.guestsGroupStays) { try decide(.removeGroup(.guests, by: ann), state) }
        #expect(throws: SpaceRefusal.notAllowed) {
            try decide(.setPermissions(.guests, Permissions(bots: .use), by: bob), state)
        }
        state = try run([.setPermissions(.guests, Permissions(bots: .use), by: ann)], from: state)
        #expect(try made(state).permissions(of: guest) == Permissions(bots: .use))
    }

    /// What's allowed once goes to exactly the one that asked: what an object's own work asked
    /// for isn't Bob's turn's, nor the other way round.
    @Test func onceGoesToExactlyTheOneThatAsked() throws {
        let id = AccessRequestID(UUID())
        let clock = try Party(DynamicObject.actorID(for: ObjectIdentity(rawValue: "clock"), in: family))
        let once = try run([asking(id, as: clock), .answer(id, .once, by: ann)], from: try annDecidesForBob())
        let (turn, spentByTurn) = try made(once).opening(scopeOf: .person(bob))
        #expect(!turn.allows(forecast))
        #expect(spentByTurn.isEmpty)
        let (own, spent) = try made(once).opening(scopeOf: clock)
        #expect(own.allows(forecast))
        #expect(spent == [.spent(id)])
    }

    @Test func onceIsInTheNextScopeThatOpensAndNoneAfter() throws {
        let id = AccessRequestID(UUID())
        let once = try run([asking(id), .answer(id, .once, by: ann)], from: try annDecidesForBob())
        // Not what's shared with Bob: only the scope that opens next has it, which spends it.
        #expect(try !made(once).scope(of: bob).allows(forecast))
        let (scope, spent) = try made(once).opening(scopeOf: .person(bob))
        #expect(scope.allows(forecast))
        #expect(spent == [.spent(id)])
        let after = SpaceDecider.evolve(once, spent)
        #expect(try !made(after).opening(scopeOf: .person(bob)).0.allows(forecast))
    }

    @Test func refusedItCanBeAskedAgain() throws {
        let id = AccessRequestID(UUID())
        let refused = try run([asking(id), .answer(id, .no, by: ann)], from: try annDecidesForBob())
        #expect(try !made(refused).scope(of: bob).allows(forecast))
        let again = AccessRequestID(UUID())
        #expect(
            try decide(asking(again), refused)
                == [.asked(AccessRequest(id: again, request: forecast, by: .person(bob), standing: .waiting))])
    }

    /// A space someone made: called what they named it, with them its first admin. A guest makes
    /// none, and one is made once.
    @Test func aSpaceIsMadeOnceByWhoeverNamesIt() throws {
        let name = SpaceName("  Family ")!
        let empty = SpaceDecider.initial(SpaceID())
        #expect(throws: SpaceRefusal.guestsStayOut) {
            try decide(.make(named: name, by: .guest(UUID()), bot: helper), empty)
        }

        let state = try run([.make(named: name, by: ann, bot: helper)], from: empty)
        #expect(try made(state).name.rawValue == "Family")
        #expect(try made(state).admins == NonEmptySet(ann))
        #expect(state.listing(for: ann)?.permissions == .all)
        #expect(throws: SpaceRefusal.alreadyMade) { try decide(.make(named: name, by: bob, bot: helper), state) }
        #expect(SpaceName("   ") == nil)
        #expect(SpaceName(String(repeating: "a", count: SpaceName.maximumLength + 1)) == nil)
    }

    /// Only whoever may configure it renames it, makes its groups and sets what they may; its
    /// members group stays.
    @Test func onlyWhoeverMayConfigureItChangesItsGroups() throws {
        let state = try annDecidesForBob()
        let kids = GroupID("kids")!
        #expect(throws: SpaceRefusal.notAllowed) { try decide(.rename(to: SpaceName("Home")!, by: bob), state) }
        #expect(throws: SpaceRefusal.notAllowed) { try decide(.makeGroup(kids, .none, by: bob), state) }
        #expect(throws: SpaceRefusal.notInIt) { try decide(.makeGroup(kids, .none, by: .dad), state) }
        #expect(try decide(.rename(to: SpaceName("Family")!, by: ann), state).isEmpty)

        let grouped = try run([.makeGroup(kids, Permissions(tasks: .see), by: ann)], from: state)
        #expect(throws: SpaceRefusal.groupExists(kids)) { try decide(.makeGroup(kids, .none, by: ann), grouped) }
        #expect(throws: SpaceRefusal.membersGroupStays) { try decide(.removeGroup(.members, by: ann), grouped) }
        #expect(throws: SpaceRefusal.noSuchGroup(pets)) { try decide(.setPermissions(pets, .none, by: ann), grouped) }
    }

    /// What someone may is what their groups may together; a group removed takes what it gave,
    /// but not while someone is in it and no other.
    @Test func whatSomeoneMayIsWhatTheirGroupsMay() throws {
        let kids = GroupID("kids")!
        var state = try run(
            [
                .makeGroup(kids, Permissions(tasks: .see, deleteConversations: true), by: ann),
                .place(bob, inGroups: NonEmptySet(.members, [kids]), by: ann),
            ], from: try annDecidesForBob())
        #expect(
            try made(state).permissions(of: bob)
                == Permissions(people: .see, bots: .use, tasks: .see, deleteConversations: true))
        #expect(try made(state).scope(of: bob).groups == [.members, kids])
        // An admin is in every group.
        #expect(try made(state).scope(of: ann).groups == [.members, .guests, kids])

        state = try run([.setPermissions(kids, Permissions(tasks: .manage), by: ann)], from: state)
        #expect(try made(state).permissions(of: bob)?.tasks == .manage)
        state = try run([.place(cat, inGroups: NonEmptySet(kids), by: ann)], from: state)
        #expect(throws: SpaceRefusal.someoneIsOnlyIn(kids)) { try decide(.removeGroup(kids, by: ann), state) }
        state = try run([.place(cat, inGroups: asMembers, by: ann), .removeGroup(kids, by: ann)], from: state)
        #expect(try made(state).members[bob] == asMembers)
        #expect(try made(state).permissions(of: bob) == .members)
    }

    /// Only whoever manages its people places its members in groups, and only in groups it has;
    /// an admin is in every one.
    @Test func onlyWhoeverManagesItsPeoplePlacesThem() throws {
        let state = try annDecidesForBob()
        #expect(throws: SpaceRefusal.notAllowed) { try decide(.place(cat, inGroups: asMembers, by: bob), state) }
        #expect(throws: SpaceRefusal.noSuchGroup(pets)) {
            try decide(.place(cat, inGroups: NonEmptySet(pets), by: ann), state)
        }
        #expect(throws: SpaceRefusal.notInIt) { try decide(.place(.dad, inGroups: asMembers, by: ann), state) }
        #expect(throws: SpaceRefusal.anAdmin) { try decide(.place(ann, inGroups: asMembers, by: ann), state) }
        #expect(try decide(.place(cat, inGroups: asMembers, by: ann), state).isEmpty)
    }

    /// An admin may make another admin, and step one down, but never its last.
    @Test func itsAdminsChangeButNeverToNone() throws {
        var state = try annDecidesForBob()
        #expect(throws: SpaceRefusal.notAllowed) { try decide(.makeAdmin(cat, by: bob), state) }
        #expect(throws: SpaceRefusal.lastAdmin) { try decide(.removeAdmin(ann, by: ann), state) }
        state = try run([.makeAdmin(bob, by: ann), .removeAdmin(ann, by: bob)], from: state)
        #expect(try made(state).admins == NonEmptySet(bob))
        #expect(try made(state).members[bob] == nil)
        // Ann, no longer an admin, is in the members group.
        #expect(try made(state).members[ann] == asMembers)
    }

    /// Who's in it, each with their groups, as someone who may see its people sees them: guests
    /// aren't shown.
    @Test func whoMaySeeItsPeopleSeesThem() throws {
        let guest = UserID.guest(UUID())
        let state = try withAGuest(guest)
        #expect(try made(state).people(for: bob) == [ann: [.members, .guests], bob: [.members], cat: [.members]])
        #expect(throws: SpaceRefusal.notAllowed) { try made(state).people(for: guest) }
        #expect(throws: SpaceRefusal.notInIt) { try made(state).people(for: .dad) }
    }

    /// An invite lets one person in, once, while it works; one already in leaves it for another.
    @Test func anInviteLetsOnePersonInOnce() throws {
        var state = try run(
            [.make(named: SpaceName("Family")!, by: ann, bot: helper)], from: SpaceDecider.initial(SpaceID()))
        let token = SpaceInviteToken.new()
        #expect(throws: SpaceRefusal.notInIt) {
            try decide(.invite(SpaceInvite(hash: token.hash, by: bob, lifetime: .untilUsed)), state)
        }
        state = try run([.invite(SpaceInvite(hash: token.hash, by: ann, lifetime: .untilUsed))], from: state)

        #expect(try decide(.join(with: token.hash, as: ann, at: Date()), state).isEmpty)
        state = try run([.join(with: token.hash, as: bob, at: Date())], from: state)
        #expect(try made(state).members[bob] == asMembers)
        #expect(throws: SpaceRefusal.notAllowed) {
            try decide(.invite(SpaceInvite(hash: SpaceInviteToken.new().hash, by: bob, lifetime: .untilUsed)), state)
        }
        #expect(throws: SpaceRefusal.inviteDoesNotWork) {
            try decide(.join(with: token.hash, as: .dad, at: Date()), state)
        }
        #expect(throws: SpaceRefusal.guestsStayOut) {
            try decide(.join(with: token.hash, as: .guest(UUID()), at: Date()), state)
        }
        #expect(throws: SpaceRefusal.inviteDoesNotWork) {
            try decide(.join(with: SpaceInviteToken("made up").hash, as: .dad, at: Date()), state)
        }
    }

    /// An invite stops working when its time is up, or it's taken back.
    @Test func anInviteEnds() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let short = SpaceInviteToken.new()
        let kept = SpaceInviteToken.new()
        let ending = SpaceInvite(hash: short.hash, by: ann, lifetime: .until(now.addingTimeInterval(60)))
        let lasting = SpaceInvite(hash: kept.hash, by: ann, lifetime: .untilUsed)
        var state = try run([.invite(ending), .invite(lasting)], from: try annDecidesForBob())

        #expect(try made(state).openInvites(at: now.addingTimeInterval(61)) == [lasting])
        #expect(throws: SpaceRefusal.inviteDoesNotWork) {
            try decide(.join(with: short.hash, as: .dad, at: now.addingTimeInterval(61)), state)
        }
        #expect(throws: SpaceRefusal.notAllowed) { try decide(.takeBack(lasting.id, by: bob), state) }
        state = try run([.takeBack(lasting.id, by: ann)], from: state)
        #expect(throws: SpaceRefusal.inviteDoesNotWork) { try decide(.join(with: kept.hash, as: .dad, at: now), state) }
    }

    /// A space its platform makes, as a chat's is: called after the chat, with the admins the
    /// platform says, once.
    @Test func aPlatformMakesASpaceOnce() throws {
        let state = try run(
            [.makeForPlatform(named: SpaceName("Family")!, admins: NonEmptySet(ann, [.dad]), groups: [:], bot: helper)],
            from: SpaceDecider.initial(SpaceID()))
        #expect(try made(state).name == SpaceName("Family"))
        #expect(try made(state).admins == NonEmptySet(ann, [.dad]))
        #expect(throws: SpaceRefusal.alreadyMade) {
            try decide(
                .makeForPlatform(named: SpaceName("Work")!, admins: NonEmptySet(bob), groups: [:], bot: helper), state)
        }
    }

    /// Only whoever may configure it archives a space, and uses it again; archived, no one is
    /// invited or joins.
    @Test func onlyWhoeverMayConfigureItArchivesIt() throws {
        let token = SpaceInviteToken.new()
        var state = try run(
            [.invite(SpaceInvite(hash: token.hash, by: ann, lifetime: .untilUsed))], from: try annDecidesForBob())

        #expect(throws: SpaceRefusal.notAllowed) { try decide(.archive(by: bob), state) }
        state = try run([.archive(by: ann)], from: state)
        #expect(state.status == .archived)
        #expect(try decide(.archive(by: ann), state).isEmpty)
        #expect(throws: SpaceRefusal.archived) {
            try decide(.invite(SpaceInvite(hash: SpaceInviteToken.new().hash, by: ann, lifetime: .untilUsed)), state)
        }
        #expect(throws: SpaceRefusal.archived) { try decide(.join(with: token.hash, as: .dad, at: Date()), state) }

        #expect(throws: SpaceRefusal.notAllowed) { try decide(.unarchive(by: bob), state) }
        state = try run([.unarchive(by: ann)], from: state)
        #expect(state.status == .active)
        #expect(try decide(.unarchive(by: ann), state).isEmpty)
    }

    /// Anyone in it may leave, but its last admin, and no one leaves a space they're not in.
    @Test func theLastAdminStays() throws {
        var state = try annDecidesForBob()
        #expect(throws: SpaceRefusal.lastAdmin) { try decide(.leave(ann), state) }
        #expect(throws: SpaceRefusal.notInIt) { try decide(.leave(.dad), state) }
        state = try run([.leave(bob)], from: state)
        #expect(try !made(state).has(bob))
        state = try run([.makeAdmin(cat, by: ann), .leave(ann)], from: state)
        #expect(try !made(state).has(ann))
        #expect(try made(state).admins == NonEmptySet(cat))
    }

    /// A space is made with its first bot, its main; whoever may configure its bots adds, changes
    /// and removes them, and chooses its main; everyone in it who may use them sees them.
    @Test func whoeverMayConfigureItsBotsConfiguresThem() throws {
        var state = try annDecidesForBob()
        #expect(try made(state).bots.main == helper)
        #expect(throws: SpaceRefusal.notAllowed) { try decide(.addBot(chef, by: bob), state) }

        state = try run([.addBot(chef, by: ann)], from: state)
        #expect(throws: SpaceRefusal.botExists(chef.id)) { try decide(.addBot(chef, by: ann), state) }
        #expect(try made(state).bots.all == [helper, chef])
        var renamed = chef
        renamed.name = BotName("Cook")!
        state = try run([.changeBot(renamed, by: ann)], from: state)
        #expect(try made(state).bots[chef.id]?.name == BotName("Cook"))
        #expect(try decide(.changeBot(renamed, by: ann), state).isEmpty)
        let ghost = Self.makeBot("Ghost")
        #expect(throws: SpaceRefusal.noSuchBot(ghost.id)) { try decide(.changeBot(ghost, by: ann), state) }
    }

    /// The main bot stays until another is chosen; a removed bot is no longer one of its bots.
    @Test func theMainBotStaysAndAnswersForOnesGone() throws {
        var state = try run([.addBot(chef, by: ann)], from: try annDecidesForBob())
        #expect(throws: SpaceRefusal.mainBotStays) { try decide(.removeBot(helper.id, by: ann), state) }

        state = try run([.chooseMain(chef.id, by: ann)], from: state)
        #expect(try made(state).bots.main == chef)
        #expect(try made(state).bots.others == [helper.id: helper])
        state = try run([.removeBot(helper.id, by: ann)], from: state)
        #expect(try made(state).bots[helper.id] == nil)
        #expect(throws: SpaceRefusal.noSuchBot(helper.id)) { try decide(.chooseMain(helper.id, by: ann), state) }
    }
}
