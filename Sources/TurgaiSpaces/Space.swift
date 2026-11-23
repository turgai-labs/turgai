import AttributedCalls
import Distributed
import DistributedCluster
import EventSourcing
import TurgaiCalls
import TurgaiConversations
import TurgaiDomain
import TurgaiObjects
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A space, in a journal of its own: its state is what its events fold to from empty, and each
/// command is decided from it. It settles each chain's scope as the chain starts.
@EventSourced
@VirtualActor
public distributed actor Space: ConversationOwner {
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
        self.state = SpaceDecider.initial(id)
        try await actorSystem.journal.register(actor: self, with: Self.persistenceID(for: id))
        // Its connections' runs are told how to run now, whatever they were last told: one that
        // missed a change, or comes back after a restart, runs as the space has it. It's the
        // space's own doing, whoever's call started it.
        try? await Call.asWork(of: .space(id)) { try await tellRuns() }
    }

    /// Its tasks as they change, as `person`, who's in it, follows them: which of them they see,
    /// what they may do in it says.
    public distributed func tasks(for person: UserID) async throws -> SpaceTasks {
        _ = try made().scope(of: person)
        return try await SpaceTasks.identified(by: state.id, on: actorSystem)
    }

    public static func actorID(for id: SpaceID) -> VirtualActorID {
        .space(id)
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
    public static func identified(by id: SpaceID, on actorSystem: ClusterSystem) async throws -> Space {
        try await actorSystem.virtualActors.getActor(identifiedBy: actorID(for: id), dependency: id)
    }

    // MARK: Commands

    /// It made by its platform, called `name`, with `admins` deciding for it, `groups` besides its
    /// members group, and `bot` its first bot.
    public distributed func make(
        named name: SpaceName, admins: NonEmptySet<UserID>, groups: [GroupID: Permissions] = [:], bot: Bot
    ) async throws {
        try await run(.makeForPlatform(named: name, admins: admins, groups: groups, bot: bot))
    }

    /// It made, called `name`, with `person` its first admin and `bot` its first bot.
    public distributed func make(named name: SpaceName, by person: UserID, bot: Bot) async throws {
        try await run(.make(named: name, by: person, bot: bot))
    }

    /// `bot` one of its bots, as `person`, who may configure them, adds it.
    public distributed func addBot(_ bot: Bot, by person: UserID) async throws {
        try await run(.addBot(bot, by: person))
    }

    /// Its bot as `bot` says from now on, as `person`, who may configure them, changes it.
    public distributed func changeBot(_ bot: Bot, by person: UserID) async throws {
        try await run(.changeBot(bot, by: person))
    }

    /// The bot `id` removed, as `person`, who may configure them, asks: it's in none of its
    /// conversations any more.
    public distributed func removeBot(_ id: BotID, by person: UserID) async throws {
        try await run(.removeBot(id, by: person))
    }

    /// The bot `id` its main from now on, as `person`, who may configure them, chooses it.
    public distributed func chooseMain(_ id: BotID, by person: UserID) async throws {
        try await run(.chooseMain(id, by: person))
    }

    /// Its admins exactly `admins` from now on, as its platform says.
    public distributed func setAdmins(_ admins: NonEmptySet<UserID>) async throws {
        try await run(.setAdmins(admins))
    }

    /// `person` taking part, as someone writing in it does, in `groups`, as the way they came in
    /// says: unless they're in it already.
    public distributed func admit(_ person: UserID, into groups: NonEmptySet<GroupID>) async throws {
        try await run(.admit(person, into: groups))
    }

    /// It called `name` from now on, as `person`, who may configure it, asks.
    public distributed func rename(to name: SpaceName, by person: UserID) async throws {
        try await run(.rename(to: name, by: person))
    }

    /// A group called `group`, which may what `permissions` says, as `person` makes it.
    public distributed func makeGroup(_ group: GroupID, may permissions: Permissions, by person: UserID) async throws {
        try await run(.makeGroup(group, permissions, by: person))
    }

    /// `group` may what `permissions` says from now on, as `person` sets it.
    public distributed func setPermissions(of group: GroupID, to permissions: Permissions, by person: UserID)
        async throws
    {
        try await run(.setPermissions(group, permissions, by: person))
    }

    /// `group` removed, as `person` asks: no one is in it any more.
    public distributed func removeGroup(_ group: GroupID, by person: UserID) async throws {
        try await run(.removeGroup(group, by: person))
    }

    /// `person`, one of its members, in exactly `groups` from now on, as `placer`, who manages its
    /// people, places them.
    public distributed func place(_ person: UserID, in groups: NonEmptySet<GroupID>, by placer: UserID) async throws {
        try await run(.place(person, inGroups: groups, by: placer))
    }

    /// `person` one of its admins, as `maker` makes them.
    public distributed func makeAdmin(_ person: UserID, by maker: UserID) async throws {
        try await run(.makeAdmin(person, by: maker))
    }

    /// `person` no longer one of its admins, as `remover` asks.
    public distributed func removeAdmin(_ person: UserID, by remover: UserID) async throws {
        try await run(.removeAdmin(person, by: remover))
    }

    /// `invite` open, as whoever made it, who manages its people, asks.
    public distributed func invite(_ invite: SpaceInvite) async throws {
        try await run(.invite(invite))
    }

    /// The invite `id` taken back, as `person`, who manages its people, asks.
    public distributed func takeBack(_ id: SpaceInviteID, by person: UserID) async throws {
        try await run(.takeBack(id, by: person))
    }

    /// `person` joining with the invite whose token hashes to `hash`.
    public distributed func join(with hash: SpaceInviteHash, as person: UserID) async throws {
        try await run(.join(with: hash, as: person, at: Date()))
    }

    /// `person` leaving it.
    public distributed func leave(_ person: UserID) async throws {
        try await run(.leave(person))
    }

    /// It archived, as `person`, who may configure it, asks.
    public distributed func archive(by person: UserID) async throws {
        try await run(.archive(by: person))
        try await tellRuns()
    }

    /// It in use again, as `person`, who may configure it, asks.
    public distributed func unarchive(by person: UserID) async throws {
        try await run(.unarchive(by: person))
        try await tellRuns()
    }

    /// Exactly `request`, made through `chain`, decided now, as whoever decides for the space has
    /// it: granted by what its person may do, by what's shared with them, or by an allowance for
    /// exactly that asker, which it spends; refused otherwise, asking whoever decides, and the
    /// request it opens, when it opens one. Decided once no other change is being made.
    public distributed func decide(_ request: ExactRequest, for chain: CallChain) async throws -> RequestDecision {
        let decision: RequestDecision = try await changing {
            let space = try made()
            switch try space.deciding(request, for: chain.scope.asker) {
            case .allowed:
                return .granted
            case .allowedOnce(let id):
                try await emit(event: .spent(id))
                return .granted
            case .notAllowed:
                let asking = SpaceCommand.ask(request, by: chain.scope.asker, id: AccessRequestID(UUID()))
                let events = try SpaceDecider.decide(asking, state)
                for event in events { try await emit(event: event) }
                let asked = events.lazy.compactMap { if case .asked(let asked) = $0 { asked } else { nil } }.first
                return .refused(asked)
            }
        }
        // What one of its own actors asks, working by itself, no turn shows: the chat it works in
        // does, where whoever decides answers it. With no chat, it waits among what the space asks,
        // which every chat's links show as they open.
        if case .refused(let asked?) = decision, chain.scope.person == nil, let place = chain.place {
            try? await conversation(place).asks(asked)
        }
        return decision
    }

    /// Whether work with `chain`, calling through `caller`, may go as far as `level` with something
    /// `access` says who may use, as the space has whoever asked now: the groups they're in and
    /// what they may do. Not if they're not in it. It changes nothing, so it's read as the space
    /// is, without waiting on a change being made.
    public distributed func decide(
        _ access: Access, _ level: AccessLevel, for chain: CallChain, calledBy caller: CallActor?
    ) -> Bool {
        guard let space = try? made(), let scope = try? space.scope(of: chain.scope.asker) else { return false }
        return access.allows(scope, calledBy: caller, level)
    }

    /// Whoever this call is on behalf of needing exactly `request`, which their scope didn't allow:
    /// it waits for whoever decides for it. The request it opens, when it opens one.
    public distributed func needed(_ request: ExactRequest) async throws -> AccessRequest? {
        guard let chain = CallChain.current else { throw CallOnBehalfOfNoOne(actor: .actor(id)) }
        let events = try await run(.ask(request, by: chain.scope.asker, id: AccessRequestID(UUID())))
        // Asked already, as deciding it refused it: the request that's open is the one waited for.
        return events.lazy.compactMap { if case .asked(let asked) = $0 { asked } else { nil } }.first
            ?? state.space?.request(for: request, by: chain.scope.asker).flatMap {
                $0.standing == .waiting ? $0 : nil
            }
    }

    /// `person`'s answer to the request `id`, as the link they answered through, in its
    /// conversation `conversation`, says: only an answer by whoever may decide for what it asks
    /// counts. The conversation's links show it, and the turn that waited for it continues.
    public distributed func answer(
        _ id: AccessRequestID, _ answer: AccessAnswer, by person: UserID, in conversation: ConversationID
    ) async throws {
        guard let open = state.space?.requests[id], !(try await run(.answer(id, answer, by: person))).isEmpty
        else { return }
        try await self.conversation(conversation).answered(open, answer, by: person, from: self)
    }

    /// The scope of work that starts here for `asker`, one of its people or one of its own actors,
    /// as it starts: what's allowed them once is in it, and spent. With nothing to spend, it
    /// changes nothing, and is read as the space is, without waiting on a change being made.
    public distributed func opening(scopeOf asker: Party) async throws -> CallScope {
        let (scope, spent) = try made().opening(scopeOf: asker)
        guard !spent.isEmpty else { return scope }
        return try await changing {
            let (scope, spent) = try made().opening(scopeOf: asker)
            for event in spent { try await emit(event: event) }
            return scope
        }
    }

    // MARK: Queries

    /// Whom a call `person` makes here is on behalf of, and what's shared with them: refused when
    /// they're not in it.
    public distributed func scope(of person: UserID) throws -> CallScope {
        try made().scope(of: person)
    }

    /// Whether it's in use: none before it's made.
    public distributed func status() -> SpaceStatus? {
        state.status
    }

    /// It as `person`'s list shows it: none before it's made, or when they're not in it.
    public distributed func listing(for person: UserID) -> SpaceListing? {
        state.listing(for: person)
    }

    /// Who's in it, as `person`, who may see its people, sees them: guests aren't among them.
    public distributed func people(for person: UserID) throws -> [UserID: Set<GroupID>] {
        try made().people(for: person)
    }

    /// Its bots, the main first, as `person`, who may use them, sees them.
    public distributed func bots(for person: UserID) throws -> [Bot] {
        let space = try made()
        guard let permissions = space.permissions(of: person) else { throw SpaceRefusal.notInIt }
        guard permissions.bots != nil else { throw SpaceRefusal.notAllowed }
        return space.bots.all
    }

    /// Its bot `id`, as it is now: none once it's removed, or when it never was one of its bots.
    public distributed func bot(_ id: BotID) -> Bot? {
        state.space?.bots[id]
    }

    /// Its main bot: who answers when no other is asked for.
    public distributed func mainBot() throws -> Bot {
        try made().bots.main
    }

    /// Its groups, each with what it may, as `person`, one of its people, sees them.
    public distributed func groups(for person: UserID) throws -> [GroupID: Permissions] {
        let space = try made()
        guard space.permissions(of: person) != nil else { throw SpaceRefusal.notInIt }
        return space.groups
    }

    /// The invites that still work, as `person`, who manages its people, sees them.
    public distributed func openInvites(for person: UserID) throws -> [SpaceInvite] {
        let space = try made()
        guard let permissions = space.permissions(of: person) else { throw SpaceRefusal.notInIt }
        guard permissions.people == .manage else { throw SpaceRefusal.notAllowed }
        return space.openInvites(at: Date())
    }

    /// What waits for an answer.
    public distributed func waiting() -> [AccessRequest] {
        (state.space?.requests.values.filter { $0.standing == .waiting } ?? []).sorted {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
    }

    // MARK: Running

    /// What `command` makes happen, decided from its state and emitted, once no other change is
    /// being made.
    @discardableResult
    func run(_ command: SpaceCommand) async throws -> [SpaceEvent] {
        let events = try await changing {
            let events = try SpaceDecider.decide(command, state)
            for event in events { try await emit(event: event) }
            return events
        }
        return events
    }

    /// It, once it's made: refused before.
    func made() throws(SpaceRefusal) -> SpaceState.Space {
        guard let space = state.space else { throw .notMadeYet }
        return space
    }

    /// Makes `change` to its state once no other change is being made: it reads the state, decides
    /// and emits, calling nothing that could call back.
    func changing<Result>(_ change: () async throws -> Result) async rethrows -> Result {
        await changes.wait()
        defer { changes.signal() }
        return try await change()
    }

    public func handleEvent(_ event: SpaceEvent) {
        state = SpaceDecider.evolve(state, event)
    }
}

/// How the space decided exactly a request.
public enum RequestDecision: Codable, Hashable, Sendable {
    case granted
    /// Refused, with the request it opened for whoever decides, when it opened one.
    case refused(AccessRequest?)
}
