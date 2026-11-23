import AttributedCalls
import DiscoverableActors
import Distributed
import DistributedCluster
import TurgaiCalls
import TurgaiDomain
import TurgaiObjects
import TurgaiPeople
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A space's objects are its own: it lists them, for one of its people, and says what work that
/// starts in it may do.
extension Space {
    /// Its objects, of every kind, as `person`, one of its people, may see them: those every space
    /// has from the start, its scheduler and its timers, its pages, and those made in it. The list
    /// is its own: built here, with what they may do now. Refused for someone who isn't in it.
    public distributed func objects(for person: UserID) async throws -> [ObjectEntry] {
        let scope = try made().scope(of: person)
        let made = try await DynamicObjects.of(state.id, on: actorSystem)
        return try await CallChain.$current.withValue(.start(scope, in: nil)) {
            try await BuiltIn.entries(in: state.id, made, on: actorSystem) + (try await made.held())
        }
    }

    /// Whether a call through `chain` may go as far as `level` with `object`, shared as `access`
    /// says, as its space has whoever asked now. One of the space's own objects, working by
    /// itself, that may not use another asks its space, as it asks for a tool: allowed once or
    /// always, it's let in; refused, the space's deciders are asked.
    public static let decides:
        @Sendable (Access, AccessLevel, ObjectID, CallChain, CallActor?, ClusterSystem) async throws -> Bool = {
            access, level, object, chain, caller, system in
            let space = try await Space.identified(by: chain.scope.space, on: system)
            if try await space.decide(access, level, for: chain, calledBy: caller) { return true }
            guard level == .read, chain.scope.person == nil, case .virtual(let id) = object,
                let wanted = id.spaceActor, wanted.space == chain.scope.space
            else { return false }
            return try await space.decide(.use(wanted), for: chain) == .granted
        }

    /// What work that starts for `asker` in `space` may do, as the space says now: what a node's
    /// objects ask it.
    public static let opens: @Sendable (Party, SpaceID, ClusterSystem) async throws -> CallScope = {
        asker, space, system in
        try await Space.identified(by: space, on: system).opening(scopeOf: asker)
    }
}
