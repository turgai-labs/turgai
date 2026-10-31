import Distributed
import DistributedCluster
import EventSourcing
import TurgaiCalls
import TurgaiDomain
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A space, in a journal of its own: the people in it, each with their role, who may run each
/// exact request it decides, and what's asked of its admins until they answer: a conversation's,
/// and Turgai's own. It settles each chain's scope as the chain starts.
@EventSourced
@VirtualActor
public distributed actor Space {
    public typealias Event = SpaceEvent
    public typealias ActorSystem = ClusterSystem
    public typealias State = SpaceState
    public typealias Dependency = SpaceID

    public var state: SpaceState

    public let snapshotting: Snapshotting<SpaceEvent, SpaceState> = .every(
        numberOfEvents: 50,
        retention: .keepLast(2)
    )

    public init(actorSystem: ClusterSystem, dependency id: SpaceID) async throws {
        self.actorSystem = actorSystem
        self.state = SpaceState(id: id)
        try await actorSystem.journal.register(actor: self, with: Self.persistenceID(for: id))
    }

    public static func actorID(for id: SpaceID) -> VirtualActorID {
        VirtualActorID(rawValue: "space:\(id.rawValue.uuidString)")
    }

    public static func persistenceID(for id: SpaceID) -> String {
        "turgai-space-\(id.rawValue.uuidString)"
    }

    /// The space `id`, wherever and whenever it runs.
    public static func resolve(on actorSystem: ClusterSystem, id: SpaceID) async throws -> Space {
        try await actorSystem.virtualActors.getActor(identifiedBy: actorID(for: id), dependency: id)
    }

    /// Whom a call `person` makes here is on behalf of, and what's shared with them.
    public distributed func scope(of person: UserID) -> CallScope {
        state.scope(of: person)
    }

    /// The scope of a chain `person` starts here for `asker`, settled as it starts: what's allowed
    /// `asker` once is in it, and spent.
    public distributed func opening(scopeOf person: UserID, for asker: Asker) async throws -> CallScope {
        let (scope, spent) = state.opening(scopeOf: person, for: asker)
        for event in spent { try await emit(event: event) }
        return scope
    }

    /// `person` taking part, as someone writing in it does: a member, unless they're in it already.
    public distributed func admit(_ person: UserID) async throws {
        if let joined = state.admitting(person) { try await emit(event: joined) }
    }

    /// Who its admins are now, as its platform says: they decide for it.
    public distributed func setAdmins(_ admins: Set<UserID>) async throws {
        for event in state.having(admins: admins) { try await emit(event: event) }
    }

    /// The role `person` has in it, as its platform says.
    public distributed func setRole(_ role: SpaceRole, of person: UserID) async throws {
        if let event = state.setting(role, of: person) { try await emit(event: event) }
    }

    /// Whoever this call is on behalf of needing exactly `request`, which their scope didn't allow:
    /// it waits for its admins. The request it opens, when it opens one.
    public distributed func needed(_ request: ExactRequest) async throws -> AccessRequest? {
        guard let chain = CallChain.current else { throw CallOnBehalfOfNoOne(actor: .actor(id)) }
        var opened: AccessRequest?
        for event in state.requesting(request, by: chain.scope.person, as: chain.asker, id: AccessRequestID(UUID())) {
            try await emit(event: event)
            if case .asked(let asked, _) = event { opened = asked }
        }
        return opened
    }

    /// `person`'s answer to the request `id`, as the link they answered through says: only an
    /// answer by whoever may decide for what it asks counts. The request it answered, when it did.
    public distributed func answer(_ id: AccessRequestID, _ answer: AccessAnswer, by person: UserID) async throws
        -> AccessRequest?
    {
        guard let open = state.requests[id] else { return nil }
        let events = state.answering(id, answer, by: state.scope(of: person))
        for event in events { try await emit(event: event) }
        return events.isEmpty ? nil : open
    }

    /// What waits for its admins to answer.
    public distributed func waiting() -> [AccessRequest] {
        state.requests.values.filter { $0.standing == .waiting }.sorted {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
    }

    public func handleEvent(_ event: SpaceEvent) {
        state = state.applying(event)
    }
}
