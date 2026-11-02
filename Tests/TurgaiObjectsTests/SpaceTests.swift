import Foundation
import Testing
import TurgaiCalls
import TurgaiDomain
import TurgaiSpaces

@testable import TurgaiObjects

/// A space: who's in it, and who may run exactly what, which it settles into each scope as the
/// scope opens; its admins answer what's asked of them.
struct SpaceTests {
    private let family = SpaceID()
    private let ann = UserID.ann
    private let bob = UserID.bob
    private let cat = UserID.cat
    private let forecast = ExactRequest.http(method: "GET", url: "https://example.com/forecast", body: Data())

    private func group(_ events: [SpaceEvent]) -> SpaceState {
        events.reduce(SpaceState(id: family)) { $0.applying($1) }
    }

    /// Ann decides for the family; Bob is in it.
    private var annDecidesForBob: SpaceState { group([.joined(ann, as: .admin), .joined(bob, as: .member)]) }

    @Test func whoeverWritesJoinsAsAMember() {
        var state = SpaceState(id: family)
        for person in [ann, bob, ann] {
            if let joined = state.admitting(person) { state = state.applying(joined) }
        }
        #expect(state.members == [ann: .member, bob: .member])
        #expect(state.admins.isEmpty)
    }

    @Test func thePlatformSaysWhoTheAdminsAre() {
        var state = group([.joined(ann, as: .member)])
        state = group(state.having(admins: [ann, bob]))
        #expect(state.members == [ann: .admin, bob: .admin])

        // Bob is no longer one, and Cat now is: Bob stays, as a member.
        let events = state.having(admins: [ann, cat])
        #expect(events == [.joined(cat, as: .admin), .roleChanged(bob, to: .member)])
        state = events.reduce(state) { $0.applying($1) }
        #expect(state.admins == [ann, cat])
        // The same admins again change nothing.
        #expect(state.having(admins: [ann, cat]).isEmpty)
    }

    @Test func anAdminsOwnRequestRunsAndAMembersIsAsked() {
        #expect(annDecidesForBob.scope(of: ann).allows(forecast))
        #expect(!annDecidesForBob.scope(of: bob).allows(forecast))
        let id = AccessRequestID(UUID())
        #expect(
            annDecidesForBob.requesting(forecast, by: bob, as: .person, id: id)
                == [.asked(AccessRequest(id: id, request: forecast, by: bob, standing: .waiting), by: .person)])
    }

    @Test func aRequestStillWaitingIsTheSameOne() {
        let id = AccessRequestID(UUID())
        let waiting = annDecidesForBob.applying(
            .asked(AccessRequest(id: id, request: forecast, by: bob, standing: .waiting), by: .person))
        #expect(waiting.requesting(forecast, by: bob, as: .person, id: AccessRequestID(UUID())).isEmpty)
        #expect(waiting.request(for: forecast, by: bob, as: .person)?.id == id)
    }

    @Test func onlyAnAdminsAnswerCounts() {
        let id = AccessRequestID(UUID())
        let waiting = annDecidesForBob.applying(
            .asked(AccessRequest(id: id, request: forecast, by: bob, standing: .waiting), by: .person))
        #expect(waiting.answering(id, .always, by: waiting.scope(of: bob)).isEmpty)
        #expect(waiting.answering(id, .always, by: waiting.scope(of: ann)) == [.answered(id, .always, by: ann)])
    }

    @Test func alwaysSharesItWithWhoeverAskedFromTheirNextScope() {
        let id = AccessRequestID(UUID())
        let shared =
            annDecidesForBob
            .applying(.asked(AccessRequest(id: id, request: forecast, by: bob, standing: .waiting), by: .person))
            .applying(.answered(id, .always, by: ann))
        #expect(shared.scope(of: bob).allows(forecast))
        #expect(shared.opening(scopeOf: bob, for: .person).0.allows(forecast))
        // Only with Bob, and nothing waits.
        #expect(!shared.scope(of: cat).allows(forecast))
        #expect(shared.requests.isEmpty)
    }

    @Test func everyoneSharesItWithTheWholeGroup() {
        let id = AccessRequestID(UUID())
        let shared =
            annDecidesForBob
            .applying(.asked(AccessRequest(id: id, request: forecast, by: bob, standing: .waiting), by: .person))
            .applying(.answered(id, .everyone, by: ann))
        #expect(shared.scope(of: bob).allows(forecast))
        #expect(shared.scope(of: cat).allows(forecast))
        // Not elsewhere: another group's scope doesn't have it.
        #expect(!SpaceState(id: SpaceID()).scope(of: bob).allows(forecast))
    }

    /// A guest in it doesn't have what's shared with all of it: anyone at all can come in as one.
    @Test func whatsSharedWithEveryoneIsntAGuests() {
        let guest = UserID.guest(UUID())
        let id = AccessRequestID(UUID())
        let shared =
            annDecidesForBob
            .applying(.joined(guest, as: .member))
            .applying(.asked(AccessRequest(id: id, request: forecast, by: bob, standing: .waiting), by: .person))
            .applying(.answered(id, .everyone, by: ann))
        #expect(shared.scope(of: bob).allows(forecast))
        #expect(!shared.scope(of: guest).allows(forecast))
    }

    /// Turgai's own space follows its accounts: each one listed is in it with its role, one that
    /// isn't leaves, and whoever isn't an account stays.
    @Test func turgaisSpaceFollowsItsAccounts() {
        let promoted = UserID.account(UUID())
        let disabled = UserID.account(UUID())
        let registered = UserID.account(UUID())
        let guest = UserID.guest(UUID())
        var state = group([
            .joined(promoted, as: .member), .joined(disabled, as: .member), .joined(guest, as: .member),
            .joined(ann, as: .member),
        ])
        state = state.applying(state.having(accounts: [promoted: .admin, registered: .member]))
        #expect(state.members == [promoted: .admin, registered: .member, guest: .member, ann: .member])
        // The same accounts again change nothing.
        #expect(state.having(accounts: [promoted: .admin, registered: .member]).isEmpty)
    }

    /// What's allowed once goes to exactly the one that asked: an object's own work asking for Bob
    /// doesn't give it to Bob's turn, nor Bob's turn to the object.
    @Test func onceGoesToExactlyTheOneThatAsked() {
        let id = AccessRequestID(UUID())
        let clock = Asker.actor(DynamicObject.callActor(for: ObjectIdentity(rawValue: "clock")))
        let once =
            annDecidesForBob
            .applying(.asked(AccessRequest(id: id, request: forecast, by: bob, standing: .waiting), by: clock))
            .applying(.answered(id, .once, by: ann))
        let (turn, spentByTurn) = once.opening(scopeOf: bob, for: .person)
        #expect(!turn.allows(forecast))
        #expect(spentByTurn.isEmpty)
        let (own, spent) = once.opening(scopeOf: bob, for: clock)
        #expect(own.allows(forecast))
        #expect(spent == [.spent(id)])
    }

    @Test func onceIsInTheNextScopeThatOpensAndNoneAfter() {
        let id = AccessRequestID(UUID())
        let once =
            annDecidesForBob
            .applying(.asked(AccessRequest(id: id, request: forecast, by: bob, standing: .waiting), by: .person))
            .applying(.answered(id, .once, by: ann))
        // Not what's shared with Bob: only the scope that opens next has it, which spends it.
        #expect(!once.scope(of: bob).allows(forecast))
        let (scope, spent) = once.opening(scopeOf: bob, for: .person)
        #expect(scope.allows(forecast))
        #expect(spent == [.spent(id)])
        let after = spent.reduce(once) { $0.applying($1) }
        #expect(!after.opening(scopeOf: bob, for: .person).0.allows(forecast))
    }

    @Test func refusedItCanBeAskedAgain() {
        let id = AccessRequestID(UUID())
        let refused =
            annDecidesForBob
            .applying(.asked(AccessRequest(id: id, request: forecast, by: bob, standing: .waiting), by: .person))
            .applying(.answered(id, .no, by: ann))
        #expect(!refused.scope(of: bob).allows(forecast))
        let again = AccessRequestID(UUID())
        #expect(
            refused.requesting(forecast, by: bob, as: .person, id: again)
                == [.asked(AccessRequest(id: again, request: forecast, by: bob, standing: .waiting), by: .person)])
    }

    /// A space someone made: called what they named it, with them its first admin. A guest makes
    /// none, and one is made once.
    @Test func aSpaceIsMadeOnceByWhoeverNamesIt() throws {
        let family = SpaceName("  Family ")!
        var space = SpaceState(id: SpaceID())
        #expect(throws: SpaceRefusal.guestsStayOut) { try space.making(named: family, by: .guest(UUID())) }

        space = space.applying(try space.making(named: family, by: .ann))
        #expect(space.name?.rawValue == "Family")
        #expect(space.role(of: .ann) == .admin)
        #expect(throws: SpaceRefusal.alreadyMade) { try space.making(named: family, by: .bob) }

        #expect(throws: SpaceRefusal.onlyAdmins) { try space.renaming(to: SpaceName("Home")!, by: .bob) }
        #expect(try space.renaming(to: family, by: .ann).isEmpty)
        #expect(SpaceName("   ") == nil)
        #expect(SpaceName(String(repeating: "a", count: SpaceName.maximumLength + 1)) == nil)
    }

    /// An invite lets one person in, once, while it works; one already in leaves it for another.
    @Test func anInviteLetsOnePersonInOnce() throws {
        var space = SpaceState(id: SpaceID())
        space = space.applying(try space.making(named: SpaceName("Family")!, by: .ann))
        let token = SpaceInviteToken.new()
        let invite = SpaceInvite(hash: token.hash, by: .ann, lifetime: .untilUsed)
        #expect(throws: SpaceRefusal.onlyAdmins) {
            try space.inviting(SpaceInvite(hash: token.hash, by: .bob, lifetime: .untilUsed))
        }
        space = space.applying(try space.inviting(invite))

        #expect(try space.joining(with: token.hash, as: .ann, at: Date()).isEmpty)
        space = space.applying(try space.joining(with: token.hash, as: .bob, at: Date()))
        #expect(space.role(of: .bob) == .member)
        #expect(throws: SpaceRefusal.inviteDoesNotWork) { try space.joining(with: token.hash, as: .dad, at: Date()) }
        #expect(throws: SpaceRefusal.guestsStayOut) {
            try space.joining(with: token.hash, as: .guest(UUID()), at: Date())
        }
        #expect(throws: SpaceRefusal.inviteDoesNotWork) {
            try space.joining(with: SpaceInviteToken("made up").hash, as: .dad, at: Date())
        }
    }

    /// An invite stops working when its time is up, or its admin takes it back.
    @Test func anInviteEnds() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        var space = SpaceState(id: SpaceID())
        space = space.applying(try space.making(named: SpaceName("Family")!, by: .ann))
        let short = SpaceInviteToken.new()
        let kept = SpaceInviteToken.new()
        let ending = SpaceInvite(hash: short.hash, by: .ann, lifetime: .until(now.addingTimeInterval(60)))
        let lasting = SpaceInvite(hash: kept.hash, by: .ann, lifetime: .untilUsed)
        space = space.applying(try space.inviting(ending) + space.inviting(lasting))

        #expect(space.openInvites(at: now.addingTimeInterval(61)) == [lasting])
        #expect(throws: SpaceRefusal.inviteDoesNotWork) {
            try space.joining(with: short.hash, as: .bob, at: now.addingTimeInterval(61))
        }
        #expect(throws: SpaceRefusal.onlyAdmins) { try space.takingBack(lasting.id, by: .bob) }
        space = space.applying(try space.takingBack(lasting.id, by: .ann))
        #expect(throws: SpaceRefusal.inviteDoesNotWork) { try space.joining(with: kept.hash, as: .bob, at: now) }
    }

    /// A conversation's own space takes no invites.
    @Test func aConversationsSpaceTakesNoInvites() {
        var space = SpaceState(id: SpaceID())
        space = space.applying(space.having(admins: [.ann]))
        #expect(throws: SpaceRefusal.aConversations) {
            try space.inviting(SpaceInvite(hash: SpaceInviteToken.new().hash, by: .ann, lifetime: .untilUsed))
        }
    }

    /// Anyone in it may leave, but its last admin, and no one leaves a space they're not in.
    @Test func theLastAdminStays() throws {
        var space = SpaceState(id: SpaceID())
        space = space.applying(try space.making(named: SpaceName("Family")!, by: .ann))
        space = space.applying([.joined(.bob, as: .member)])

        #expect(throws: SpaceRefusal.lastAdmin) { try space.leaving(.ann) }
        #expect(throws: SpaceRefusal.notInIt) { try space.leaving(.dad) }
        space = space.applying(try space.leaving(.bob))
        #expect(space.role(of: .bob) == nil)
        space = space.applying([.joined(.dad, as: .admin)])
        space = space.applying(try space.leaving(.ann))
        #expect(space.role(of: .ann) == nil)
    }
}
