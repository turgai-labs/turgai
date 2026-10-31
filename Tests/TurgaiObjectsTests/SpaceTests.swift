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
}
