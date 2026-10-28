import Foundation
import Testing
import TurgaiDomain

@testable import TurgaiObjects

/// A group: who's in it, and who may run exactly what, which it settles into each scope as the
/// scope opens; its admins answer what's asked of them.
struct GroupTests {
    private let family = GroupID(rawValue: "family")
    private let ann = UserID("ann")
    private let bob = UserID("bob")
    private let cat = UserID("cat")
    private let forecast = ExactRequest.http(method: "GET", url: "https://example.com/forecast", body: Data())

    private func group(_ events: [GroupEvent]) -> GroupState {
        events.reduce(GroupState(id: family)) { $0.applying($1) }
    }

    /// Ann decides for the family; Bob is in it.
    private var annDecidesForBob: GroupState { group([.joined(ann, as: .admin), .joined(bob, as: .member)]) }

    @Test func whoeverWritesJoinsAsAMember() {
        var state = GroupState(id: family)
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
            annDecidesForBob.requesting(forecast, by: bob, id: id)
                == [.asked(AccessRequest(id: id, request: forecast, by: bob, standing: .waiting))])
    }

    @Test func aRequestStillWaitingIsTheSameOne() {
        let id = AccessRequestID(UUID())
        let waiting = annDecidesForBob.applying(
            .asked(AccessRequest(id: id, request: forecast, by: bob, standing: .waiting)))
        #expect(waiting.requesting(forecast, by: bob, id: AccessRequestID(UUID())).isEmpty)
        #expect(waiting.request(for: forecast, by: bob)?.id == id)
    }

    @Test func onlyAnAdminsAnswerCounts() {
        let id = AccessRequestID(UUID())
        let waiting = annDecidesForBob.applying(
            .asked(AccessRequest(id: id, request: forecast, by: bob, standing: .waiting)))
        #expect(waiting.answering(id, .always, by: waiting.scope(of: bob)).isEmpty)
        #expect(waiting.answering(id, .always, by: waiting.scope(of: ann)) == [.answered(id, .always, by: ann)])
    }

    @Test func alwaysSharesItWithWhoeverAskedFromTheirNextScope() {
        let id = AccessRequestID(UUID())
        let shared =
            annDecidesForBob
            .applying(.asked(AccessRequest(id: id, request: forecast, by: bob, standing: .waiting)))
            .applying(.answered(id, .always, by: ann))
        #expect(shared.scope(of: bob).allows(forecast))
        #expect(shared.opening(scopeOf: bob).0.allows(forecast))
        // Only with Bob, and nothing waits.
        #expect(!shared.scope(of: cat).allows(forecast))
        #expect(shared.requests.isEmpty)
    }

    @Test func everyoneSharesItWithTheWholeGroup() {
        let id = AccessRequestID(UUID())
        let shared =
            annDecidesForBob
            .applying(.asked(AccessRequest(id: id, request: forecast, by: bob, standing: .waiting)))
            .applying(.answered(id, .everyone, by: ann))
        #expect(shared.scope(of: bob).allows(forecast))
        #expect(shared.scope(of: cat).allows(forecast))
        // Not elsewhere: another group's scope doesn't have it.
        #expect(!GroupState(id: GroupID(rawValue: "school")).scope(of: bob).allows(forecast))
    }

    @Test func onceIsInTheNextScopeThatOpensAndNoneAfter() {
        let id = AccessRequestID(UUID())
        let once =
            annDecidesForBob
            .applying(.asked(AccessRequest(id: id, request: forecast, by: bob, standing: .waiting)))
            .applying(.answered(id, .once, by: ann))
        // Not what's shared with Bob: only the scope that opens next has it, which spends it.
        #expect(!once.scope(of: bob).allows(forecast))
        let (scope, spent) = once.opening(scopeOf: bob)
        #expect(scope.allows(forecast))
        #expect(spent == [.spent(id)])
        let after = spent.reduce(once) { $0.applying($1) }
        #expect(!after.opening(scopeOf: bob).0.allows(forecast))
    }

    @Test func refusedItCanBeAskedAgain() {
        let id = AccessRequestID(UUID())
        let refused =
            annDecidesForBob
            .applying(.asked(AccessRequest(id: id, request: forecast, by: bob, standing: .waiting)))
            .applying(.answered(id, .no, by: ann))
        #expect(!refused.scope(of: bob).allows(forecast))
        let again = AccessRequestID(UUID())
        #expect(
            refused.requesting(forecast, by: bob, id: again)
                == [.asked(AccessRequest(id: again, request: forecast, by: bob, standing: .waiting))])
    }
}
