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
/// exact request it decides, and what's asked of its admins until they answer. It settles each
/// chain's scope as the chain starts.
@EventSourced
@VirtualActor
public distributed actor Space {
    public typealias Event = SpaceEvent
    public typealias ActorSystem = ClusterSystem
    public typealias State = SpaceState
    public typealias Dependency = SpaceID

    public var state: SpaceState
    /// One change of its state at a time: each decides from the state the one before left.
    private let changes = AsyncSemaphore(value: 1)

    public let snapshotting: Snapshotting<SpaceEvent, SpaceState> = .every(
        numberOfEvents: 50,
        retention: .keepLast(2)
    )

    /// Every space's events, which the space directory is kept from.
    public let tagging: Tagging<SpaceEvent> = .always(.space)

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

    /// The space whose journal is `persistenceID`: the inverse of `persistenceID(for:)`.
    public static func space(persistedAs persistenceID: PersistenceID) throws(SpaceDirectoryError) -> SpaceID {
        guard persistenceID.hasPrefix("turgai-space-"),
            let id = UUID(uuidString: String(persistenceID.dropFirst("turgai-space-".count)))
        else { throw .notASpace(persistenceID) }
        return SpaceID(rawValue: id)
    }

    /// The space `id`, wherever and whenever it runs.
    public static func resolve(on actorSystem: ClusterSystem, id: SpaceID) async throws -> Space {
        try await actorSystem.virtualActors.getActor(identifiedBy: actorID(for: id), dependency: id)
    }

    /// Whom a call `person` makes here is on behalf of, and what's shared with them: refused when
    /// they're not in it.
    public distributed func scope(of person: UserID) throws -> CallScope {
        try state.scope(of: person)
    }

    /// The scope of a chain `person` starts here for `asker`, settled as it starts: what's allowed
    /// `asker` once is in it, and spent.
    public distributed func opening(scopeOf person: UserID, for asker: Asker) async throws -> CallScope {
        try await changing {
            let (scope, spent) = try state.opening(scopeOf: person, for: asker)
            for event in spent { try await emit(event: event) }
            return scope
        }
    }

    /// `person` taking part, as someone writing in it does: a member, unless they're in it already.
    public distributed func admit(_ person: UserID) async throws {
        try await changing { if let joined = state.admitting(person) { try await emit(event: joined) } }
    }

    /// Who its admins are now, as its platform says: they decide for it.
    public distributed func setAdmins(_ admins: Set<UserID>) async throws {
        try await changing { for event in state.having(admins: admins) { try await emit(event: event) } }
    }

    /// Turgai's own space as its accounts say it is: called `name`, with exactly `accounts` in it,
    /// each with its role.
    public distributed func follow(accounts: [UserID: SpaceRole], named name: SpaceName) async throws {
        try await changing {
            for event in state.following(accounts: accounts, named: name) { try await emit(event: event) }
        }
    }

    /// The role `person` has in it, as its platform says.
    public distributed func setRole(_ role: SpaceRole, of person: UserID) async throws {
        try await changing { if let event = state.setting(role, of: person) { try await emit(event: event) } }
    }

    /// Whoever this call is on behalf of needing exactly `request`, which their scope didn't allow:
    /// it waits for its admins. The request it opens, when it opens one.
    public distributed func needed(_ request: ExactRequest) async throws -> AccessRequest? {
        guard let chain = CallChain.current else { throw CallOnBehalfOfNoOne(actor: .actor(id)) }
        return try await changing {
            var opened: AccessRequest?
            for event in try state.requesting(
                request, by: chain.scope.person, as: chain.asker, id: AccessRequestID(UUID()))
            {
                try await emit(event: event)
                if case .asked(let asked, _) = event { opened = asked }
            }
            return opened
        }
    }

    /// `person`'s answer to the request `id`, as the link they answered through says: only an
    /// answer by whoever may decide for what it asks counts. The request it answered, when it did.
    public distributed func answer(_ id: AccessRequestID, _ answer: AccessAnswer, by person: UserID) async throws
        -> AccessRequest?
    {
        try await changing {
            // An answer by someone who isn't in it doesn't count.
            guard let open = state.requests[id], let scope = try? state.scope(of: person) else { return nil }
            let events = state.answering(id, answer, by: scope)
            for event in events { try await emit(event: event) }
            return events.isEmpty ? nil : open
        }
    }

    /// It made by its platform, called `name`, with `admins` deciding for it.
    public distributed func make(named name: SpaceName, admins: Set<UserID>) async throws {
        try await changing { for event in try state.making(named: name, admins: admins) { try await emit(event: event) } }
    }

    /// It made, called `name`, with `person` its first admin.
    public distributed func make(named name: SpaceName, by person: UserID) async throws {
        try await changing { for event in try state.making(named: name, by: person) { try await emit(event: event) } }
    }

    /// It called `name` from now on, as its admin `person` asks.
    public distributed func rename(to name: SpaceName, by person: UserID) async throws {
        try await changing { for event in try state.renaming(to: name, by: person) { try await emit(event: event) } }
    }

    /// `invite` open, as its admin made it.
    public distributed func invite(_ invite: SpaceInvite) async throws {
        try await changing { for event in try state.inviting(invite) { try await emit(event: event) } }
    }

    /// The invite `id` taken back, as its admin `person` asks.
    public distributed func takeBack(_ id: SpaceInviteID, by person: UserID) async throws {
        try await changing { for event in try state.takingBack(id, by: person) { try await emit(event: event) } }
    }

    /// `person` joining with the invite whose token hashes to `hash`.
    public distributed func join(with hash: SpaceInviteHash, as person: UserID) async throws {
        try await changing {
            for event in try state.joining(with: hash, as: person, at: Date()) { try await emit(event: event) }
        }
    }

    /// It archived, as its admin `person` asks.
    public distributed func archive(by person: UserID) async throws {
        try await changing { for event in try state.archiving(by: person) { try await emit(event: event) } }
    }

    /// It in use again, as its admin `person` asks.
    public distributed func unarchive(by person: UserID) async throws {
        try await changing { for event in try state.unarchiving(by: person) { try await emit(event: event) } }
    }

    /// Whether it's in use.
    public distributed func status() -> SpaceStatus {
        state.status
    }

    /// `person` leaving it.
    public distributed func leave(_ person: UserID) async throws {
        try await changing { for event in try state.leaving(person) { try await emit(event: event) } }
    }

    /// It as `person`'s list shows it: none when it has no name, or they're not in it.
    public distributed func listing(for person: UserID) -> SpaceListing? {
        guard let name = state.name, let role = state.role(of: person) else { return nil }
        return SpaceListing(id: state.id, name: name, role: role, status: state.status)
    }

    /// Who's in it, each with their role, as `person`, one of them, sees them: guests aren't among
    /// them.
    public distributed func people(for person: UserID) throws -> [UserID: SpaceRole] {
        try state.people(for: person)
    }

    /// The invites that still work, as its admin `person` sees them.
    public distributed func openInvites(for person: UserID) throws -> [SpaceInvite] {
        guard state.role(of: person) == .admin else { throw SpaceRefusal.onlyAdmins }
        return state.openInvites(at: Date())
    }

    /// Makes `change` to its state once no other change is being made: it reads the state, decides
    /// and emits, calling nothing that could call back.
    private func changing<Result>(_ change: () async throws -> Result) async rethrows -> Result {
        await changes.wait()
        defer { changes.signal() }
        return try await change()
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
