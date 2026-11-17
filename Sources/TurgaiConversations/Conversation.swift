import Distributed
import DistributedCluster
import EventSourcing
import Hail
import TurgaiCalls
import TurgaiDomain
import TurgaiHail
import TurgaiMemory
import TurgaiPeople
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
    import FoundationInternationalization
#else
    import Foundation
#endif

/// Model lifecycle messages sent back into the Conversation aggregate from
/// its transient model task. The Conversation actor remains the only owner of
/// turn state.
public enum ConversationModelEvent: Codable, Sendable, Equatable {
    case completed(
        turnID: TurgaiDomain.TurnID,
        completion: ConversationCompletion
    )
    case failed(
        turnID: TurgaiDomain.TurnID,
        kind: ConversationFailureKind,
        message: String,
        /// The agent's turn it failed in, when the agent had opened one.
        agentTurn: AgentTurnID?
    )
}

/// A node-local delivery endpoint held by a durable Conversation actor.
///
/// It mirrors the connection actors used by Stagehand: connections and
/// callbacks are transient, while the Conversation aggregate is durable.
public distributed actor ConversationConnection {
    public typealias ActorSystem = ClusterSystem
    public typealias EventHandler = @Sendable (OutboundEvent) async throws -> Void

    private let onEvent: EventHandler

    public init(
        actorSystem: ClusterSystem,
        onEvent: @escaping EventHandler
    ) {
        self.actorSystem = actorSystem
        self.onEvent = onEvent
    }

    public distributed func receive(_ event: OutboundEvent) async throws {
        try await onEvent(event)
    }
}

/// Non-persistent state for activity belonging to the currently running turn.
///
/// This state is intentionally separate from ``ConversationState``: it is not
/// part of the journal and is reconstructed only while the conversation actor
/// is alive. Every transition is applied before its outbound projection is
/// delivered by ``Conversation.broadcast``.
private struct ConversationLiveState: Sendable {
    private(set) var latestActivity: ReplyEvent?

    mutating func apply(_ reply: ReplyEvent) {
        switch reply {
        case .userMessage, .started, .phase, .keepAlive, .status:
            latestActivity = reply
        case .finished, .completed, .failed:
            latestActivity = nil
        case .partial, .step:
            break
        }
    }
}

private enum PublishEvent: Sendable {
    case userMessage(PendingConversationMessage)
    case turnStarted(PendingConversationMessage)
    /// Said to others in it, with no turn.
    case said(InboundMessage)

    init?(conversationEvent: ConversationEvent) {
        switch conversationEvent {
        case .inbox(.queued(let pending)):
            self = .userMessage(pending)
        case .inbox(.turnStarted(let pending)):
            self = .turnStarted(pending)
        case .said(let message):
            self = .said(message)
        case .started, .joined, .left, .titled, .inbox(.turnCompleted), .inbox(.turnFailed), .awaiting, .answered,
            .replyQueued,
            .replyDelivered, .reset, .deleted, .noted, .unnoted:
            return nil
        }
    }
}

/// What's remembered about a person, as `/memory` shows it, and its buttons.
enum MemoryPresentation {
    /// How long a fact is on its button, at most.
    private static let maximumLabel = 48

    /// What's remembered, a line for each relation.
    static func text(_ remembered: Remembered, remembering: Remembering) -> String {
        let off = remembering == .off ? "Memory is off: nothing new is remembered.\n" : ""
        guard !remembered.isEmpty else { return off + "Nothing is remembered." }
        let lines = remembered.lines.map { "\($0.relation.words): \($0.said)" }
        return off + "Remembered:\n" + lines.joined(separator: "\n")
    }

    /// A button to forget each fact, one to turn remembering off or on, and one to forget everything.
    static func actions(for remembered: Remembered, remembering: Remembering) -> [OutboundAction] {
        let forgetting = remembered.facts.map { fact in
            OutboundAction(
                label: "Forget " + shortened(fact.line),
                command: "/forget-fact \(fact.id.rawValue.uuidString)")
        }
        let turning =
            switch remembering {
            case .on: OutboundAction(label: "Turn memory off", command: "/memory-off")
            case .off: OutboundAction(label: "Turn memory on", command: "/memory-on")
            }
        return forgetting + [turning]
            + (remembered.isEmpty ? [] : [OutboundAction(label: "Forget everything", command: "/forget")])
    }

    private static func shortened(_ text: String) -> String {
        text.count <= maximumLabel ? text : String(text.prefix(maximumLabel - 1)) + "…"
    }

    static func forgotten(factCount: Int) -> String {
        factCount == 0
            ? "There was no saved personal memory to forget."
            : "I forgot your saved personal memory."
    }
}

/// A fact's id that isn't one.
private struct NotAFact: Error, CustomStringConvertible {
    let written: String

    var description: String { "`\(written)` isn't a remembered fact's id" }
}

/// Human-readable rendering of Hail's context diagnostics for the /context
/// command. Identifiers and request IDs are omitted on purpose: they mean
/// nothing in a chat message.
enum ContextPresentation {
    static func text(for snapshot: AgentContextSnapshot) -> String {
        var lines: [String] = ["Context diagnostics", ""]
        lines.append("Status: \(snapshot.state.rawValue)")
        if let usage = snapshot.contextUsage, let limit = usage.limitTokens, limit > 0 {
            let percentage = Int((Double(usage.usedTokens) / Double(limit) * 100).rounded())
            lines.append(
                "Context window: \(counted(usage.usedTokens)) / \(counted(limit)) tokens"
                    + " (\(percentage)%, \(render(source: usage.source)))")
        } else if let usage = snapshot.contextUsage {
            // The provider doesn't say its window: only what it was sent is known.
            lines.append(
                "Context: \(counted(usage.usedTokens)) tokens; the provider doesn't say its window"
                    + " (\(render(source: usage.source)))")
        } else {
            lines.append("Context window: not reported")
        }
        lines.append("Turns in context: \(counted(snapshot.historyTurnCount))")
        lines.append("Compaction summary: \(snapshot.hasContextSummary ? "yes" : "no")")
        let usage = snapshot.usageSummary
        guard usage.requestCount > 0 else { return lines.joined(separator: "\n") }
        return (lines + [""] + usageLines(usage)).joined(separator: "\n")
    }

    /// What the model was asked and gave, counted: each count it reported.
    private static func usageLines(_ usage: AgentUsageSummary) -> [String] {
        let counts: [(String, Int?)] = [
            ("Input tokens", usage.inputTokens),
            ("Output tokens", usage.outputTokens),
            ("Reasoning tokens", usage.reasoningTokens),
            ("Cached tokens read", usage.cachedReadTokens),
            ("Total tokens", usage.totalTokens),
        ]
        let reported: [String] = counts.compactMap { (label: String, count: Int?) -> String? in
            count.map { (count: Int) -> String in "\(label): \(counted(count))" }
        }
        return ["Model usage", "Requests: \(counted(usage.requestCount))"] + reported
    }

    /// A count, written as people read it.
    private static func counted(_ count: Int) -> String {
        count.formatted(.number.locale(numberLocale))
    }

    private static func render(source: ModelMeasurementSource) -> String {
        switch source {
        case .reported: "reported by the model"
        case .estimated: "estimated"
        }
    }

    /// Token counts render identically regardless of the host's locale.
    private static let numberLocale = Locale(identifier: "en_US")
}

/// Whoever starts conversations and owns them: what a conversation of theirs asks them while its
/// turns run. A conversation is handed its owner's type when it's told something that runs a turn,
/// and reaches its owner by the id it was started with.
public protocol ConversationOwner: DistributedActor, Codable where ActorSystem == ClusterSystem {
    /// The owner `id`, wherever and whenever it runs.
    static func identified(by id: SpaceID, on actorSystem: ClusterSystem) async throws -> Self

    /// The scope of a chain `person` starts for `asker`, settled as it starts.
    distributed func opening(scopeOf person: TurgaiDomain.UserID, for asker: Asker) async throws -> CallScope

    /// Whoever the current chain is on behalf of needing exactly `request`, which their scope didn't
    /// allow: the request it opens, when it opens one.
    distributed func needed(_ request: ExactRequest) async throws -> AccessRequest?

    /// `exchange`, `person`'s, heard in its conversation `conversation`: read into their memory once
    /// they've been quiet.
    distributed func heard(
        _ exchange: MemoryObservation, of person: TurgaiDomain.UserID, in conversation: ConversationID)
        async throws
}

/// One durable Turgai conversation aggregate.
///
/// The actor owns turn serialization and the queue. The Hail Agent owns the
/// durable transcript and model turn journal. Model tasks, activity streams,
/// and channel connections are intentionally transient actor state.
@EventSourced
@VirtualActor
public distributed actor Conversation {
    public typealias Event = ConversationEvent
    public typealias ActorSystem = ClusterSystem
    public typealias State = ConversationState
    public typealias Dependency = Config
    public typealias PersistenceID = ConversationPersistenceID

    /// What it's started in, by the space it's a conversation of: that space, which it reports to,
    /// and its own id there.
    public struct Config: Codable, Sendable {
        public let space: SpaceID
        public let conversationID: ConversationID
        public let agentDirectoryID: AgentDirectoryID

        public init(space: SpaceID, conversationID: ConversationID, agentDirectoryID: AgentDirectoryID) {
            self.space = space
            self.conversationID = conversationID
            self.agentDirectoryID = agentDirectoryID
        }
    }

    public var state: ConversationState

    public let snapshotting: Snapshotting<ConversationEvent, ConversationState> = .every(
        numberOfEvents: 50,
        retention: .keepLast(2)
    )

    /// What the conversation directory is kept from: how it started, who's in it, what it's called,
    /// each time something's said in it, and its deletion.
    public let tagging = Tagging<ConversationEvent> { event in
        switch event {
        case .started, .joined, .left, .titled, .said, .inbox(.queued), .inbox(.turnStarted), .replyQueued, .deleted:
            [.conversation]
        case .inbox(.turnCompleted), .inbox(.turnFailed), .awaiting, .answered, .replyDelivered, .reset, .noted,
            .unnoted:
            []
        }
    }

    private let conversationID: ConversationID
    /// The space that started it, which it reports to: given, never kept in its state.
    private let home: SpaceID
    private let agentDirectoryID: AgentDirectoryID
    /// Its agents while it's active: one for each role a turn asked for.
    private var participants: [String: AgentParticipant] = [:]
    /// Its owner, as it was last handed it: none until it's told something that runs a turn.
    private var owner: OwnerCalls?
    private var connections: Set<ConversationConnection> = []
    private var liveState = ConversationLiveState()
    /// Takes the noted message's mark off once it has shown long enough.
    private var unnoting: Task<Void, Never>?
    /// One change of its state at a time: each decides from the state the one before left.
    private let changes = AsyncSemaphore(value: 1)
    /// How long a noted message shows its mark.
    private static let notedFor: Duration = .seconds(60)
    /// Live-only echo bookkeeping: message IDs whose user-message echo was
    /// already broadcast. Bounded like `AgentInbox.acceptedMessageIDs`.
    private var echoedMessageIDs: [MessageID] = []

    public init(actorSystem: ClusterSystem, dependency: Config) async throws {
        self.actorSystem = actorSystem
        self.conversationID = dependency.conversationID
        self.home = dependency.space
        self.agentDirectoryID = dependency.agentDirectoryID
        self.state = ConversationState(
            conversationID: dependency.conversationID
        )
        try await actorSystem.journal.register(
            actor: self,
            with: Self.persistenceID(for: dependency.conversationID, in: dependency.space)
        )
    }

    /// What it asks its owner, `Owner`, which it reaches by the id it was started with.
    private struct OwnerCalls: Sendable {
        let opening: @Sendable (TurgaiDomain.UserID) async throws -> CallScope
        let needed: @Sendable (ExactRequest) async throws -> AccessRequest?
        let heard: @Sendable (MemoryObservation, TurgaiDomain.UserID) async throws -> Void

        init<Owner: ConversationOwner>(
            _: Owner.Type, id: SpaceID, conversation: ConversationID, on actorSystem: ClusterSystem
        ) {
            opening = { try await Owner.identified(by: id, on: actorSystem).opening(scopeOf: $0, for: .person) }
            needed = { try await Owner.identified(by: id, on: actorSystem).needed($0) }
            heard = { try await Owner.identified(by: id, on: actorSystem).heard($0, of: $1, in: conversation) }
        }
    }

    /// `owner` its owner from now on: the first time it's handed its owner, a turn that was running
    /// when it last stopped runs again, and what waited after it.
    private func owned<Owner: ConversationOwner>(by owner: Owner) async throws {
        let first = self.owner == nil
        self.owner = OwnerCalls(Owner.self, id: home, conversation: conversationID, on: actorSystem)
        if first { try await resumeAfterReplay() }
    }

    /// Its id in the cluster: its space's, then its own there.
    static func actorID(for conversationID: ConversationID, in space: SpaceID) -> VirtualActorID {
        VirtualActorID(rawValue: "conversation:\(space.rawValue.uuidString)/\(conversationID.stableKey)")
    }

    static func persistenceID(for conversationID: ConversationID, in space: SpaceID) -> String {
        PersistenceID(space: space, conversationID: conversationID).rawValue
    }

    /// The conversation `conversationID` of `space`, wherever and whenever it runs, started or not:
    /// only its space reaches it.
    package static func identified(
        by conversationID: ConversationID, in space: SpaceID, on actorSystem: ClusterSystem,
        agentDirectoryID: AgentDirectoryID = "agent-directory"
    ) async throws -> Conversation {
        try await actorSystem.virtualActors.getActor(
            identifiedBy: actorID(for: conversationID, in: space),
            dependency: Config(space: space, conversationID: conversationID, agentDirectoryID: agentDirectoryID)
        )
    }

    /// A conversation can passivate while idle, but never while a model turn
    /// is marked running. The running bit is journaled, so this does not rely
    /// on a transient Task existing. Nor while a noted message shows its mark.
    public func shouldDeactivate() async -> Bool {
        state.inbox.activeTurnID == nil && connections.isEmpty && unnoting == nil
    }

    public distributed func currentRecord() -> ConversationState {
        state
    }

    /// What's been said in it, as `person` reads it: refused unless they're one of its people.
    public distributed func history(for person: TurgaiDomain.UserID) throws -> [ConversationHistoryEntry] {
        _ = try state.reading(by: person)
        return state.history
    }

    /// Whether its agent is answering, as `person` sees it: refused unless they're one of its people.
    public distributed func status(for person: TurgaiDomain.UserID) throws -> ConversationStatus {
        _ = try state.reading(by: person)
        return state.inbox.status
    }

    /// The bot that answers in it: none until it has started, or once it has left.
    public distributed func answeringBot() -> BotID? {
        state.bots.first
    }

    /// It as `person` reads it: refused unless they're one of its people.
    public distributed func reading(by person: TurgaiDomain.UserID) throws -> ConversationOutline {
        try state.reading(by: person)
    }

    /// It started, answered by `bot`, with `person` the first of its people, as its space starts
    /// it: refused when it has started already.
    public distributed func start(with bot: BotID, by person: TurgaiDomain.UserID) async throws {
        try await changing {
            for event in try state.starting(with: bot, by: person) { try await emit(event: event) }
        }
    }

    /// `person` in it, as someone writing in its chat is, through one of its space's connections:
    /// the first time, it starts, answered by `bot`, the space's main one.
    public distributed func follow(by person: TurgaiDomain.UserID, startingWith bot: BotID) async throws {
        try await changing {
            if !state.isStarted {
                for event in try state.starting(with: bot, by: person) { try await emit(event: event) }
            } else if let joined = state.admitting(person) {
                try await emit(event: joined)
            }
        }
    }

    /// `participant` in it, as `adder`, one of its people, adds them: someone its space let in.
    public distributed func add(_ participant: Participant, by adder: TurgaiDomain.UserID) async throws {
        try await changing { for event in try state.adding(participant, by: adder) { try await emit(event: event) } }
    }

    /// `bot` out of it, as its space no longer has it: what's said in it isn't answered until
    /// another is brought in.
    public distributed func botLeft(_ bot: BotID) async throws {
        try await changing {
            if state.bots.contains(bot) { try await emit(event: .left(.bot(bot))) }
        }
    }

    /// `person` leaving it: it's off their list, and they no longer read it. Refused unless
    /// they're one of its people.
    public distributed func leave(_ person: TurgaiDomain.UserID) async throws {
        try await changing { for event in try state.leaving(person) { try await emit(event: event) } }
    }

    /// It deleted by `person`, one of its people: by the only one in it, or by someone who
    /// `mayDeleteAny`, as its space says. Its agent stops what it's doing, and no one reads it any
    /// more.
    public distributed func delete(by person: TurgaiDomain.UserID, mayDeleteAny: Bool) async throws {
        try await changing {
            for event in try state.deleting(by: person, mayDeleteAny: mayDeleteAny) { try await emit(event: event) }
        }
        for participant in participants.values { try? await participant.cancel() }
    }

    /// It called `title`, as `person`, one of its people, titles it.
    public distributed func title(_ title: ConversationTitle, by person: TurgaiDomain.UserID) async throws {
        try await changing { for event in try state.titling(title, by: person) { try await emit(event: event) } }
    }

    /// Whether it has no title yet.
    public distributed func untitled() -> Bool {
        state.title == nil
    }

    /// Its agent naming it `title`, unless it has a title by now.
    public distributed func name(_ title: ConversationTitle) async throws {
        try await changing { for event in state.naming(title) { try await emit(event: event) } }
    }

    /// `person` one of its people, as its platform says someone writing in its chat is.
    public distributed func admit(_ person: TurgaiDomain.UserID) async throws {
        try await changing { if let joined = state.admitting(person) { try await emit(event: joined) } }
    }

    /// Makes `change` to its state once no other change is being made: it reads the state, decides
    /// and emits, calling nothing that could call back.
    private func changing<Result>(_ change: () async throws -> Result) async rethrows -> Result {
        await changes.wait()
        defer { changes.signal() }
        return try await change()
    }

    /// Where its past turns are, as `person` asks for them: refused unless they're one of its people.
    public distributed func agentTurns(askedBy person: TurgaiDomain.UserID) throws -> ConversationAgentTurns {
        _ = try state.reading(by: person)
        return ConversationAgentTurns(bots: Array(state.bots), links: state.agentTurns)
    }

    /// `connection` told what happens in it from now on, as `owner` opens it: shown what its owner
    /// still asks, `waiting`, too.
    public distributed func addConnection<Owner: ConversationOwner>(
        _ connection: ConversationConnection, waiting: [AccessRequest], from owner: Owner
    ) async throws {
        try await owned(by: owner)
        connections.insert(connection)
        if let turnID = state.inbox.activeTurnID {
            let activity = liveState.latestActivity
            try? await connection.receive(
                .reply(.started(conversationID: conversationID, turnID: turnID))
            )
            switch activity {
            case .phase(_, _, let phase), .keepAlive(_, _, let phase):
                try? await connection.receive(
                    .reply(.phase(conversationID: conversationID, turnID: turnID, phase: phase))
                )
            case .status(_, _, let message):
                try? await connection.receive(
                    .reply(.status(conversationID: conversationID, turnID: turnID, message: message))
                )
            default:
                break
            }
        }
        // What its space still asks is shown through its links, this one too.
        for request in waiting {
            try? await connection.receive(.asked(conversationID: conversationID, request))
        }
        await deliverPendingReplies()
    }

    /// A turn of its own needed exactly `request`, which its scope didn't allow: it asks its owner,
    /// in the turn's chain, and its links show what's asked.
    public distributed func needed(_ request: ExactRequest) async throws {
        guard state.inbox.activeTurnID != nil, let owner, let opened = try await owner.needed(request) else { return }
        // The turn waits for the answer, which continues it.
        try await dispatch(.awaiting(opened.id))
        await publishLive(.asked(conversationID: conversationID, opened))
    }

    /// `exchange`, `person`'s, which its bot heard in a turn of its own: its owner is told, and reads
    /// it into their memory once they've been quiet.
    distributed func heard(_ exchange: MemoryObservation, of person: TurgaiDomain.UserID) async throws {
        guard let owner else { throw ConversationActorError.noOwner }
        try await owner.heard(exchange, person)
    }

    /// The answer to `answered`, one of its owner's requests, as `owner` counted it: its links show
    /// it, so each stops asking, and the turn that waited continues.
    public distributed func answered<Owner: ConversationOwner>(
        _ answered: AccessRequest, _ answer: AccessAnswer, by person: TurgaiDomain.UserID, from owner: Owner
    ) async throws {
        try await owned(by: owner)
        await publishLive(.answered(conversationID: conversationID, answered, answer, by: person))
        try await dispatch(.answered(answered, answer, turnID: TurgaiDomain.TurnID(), at: Date()))
    }

    public distributed func removeConnection(_ connection: ConversationConnection) async {
        connections.remove(connection)
    }

    /// `message`, said in it, as `owner` passes it on: answered by its bot when it's said to it;
    /// kept for its people otherwise.
    public distributed func send<Owner: ConversationOwner>(
        _ message: InboundMessage, turnID: TurgaiDomain.TurnID, from owner: Owner
    ) async throws {
        try await owned(by: owner)
        guard message.conversationID == conversationID else {
            throw ConversationActorError.conversationMismatch
        }

        guard try state.answers(message) else {
            // Said to others in it: kept and shown to them, with no turn.
            let said = try await changing {
                let events = state.saying(message)
                for event in events { try await emit(event: event) }
                return !events.isEmpty
            }
            if said { await publish(.said(message)) }
            return
        }
        guard let bot = state.bots.first else { throw ConversationRefusal.notStarted }
        // A mark a restart left is taken off with the next message.
        await unnote()
        try await dispatch(.receive(message: message, turnID: turnID, bot: bot))
    }

    /// Marks `message` as noted for its author's memory, for a moment: a mark already shown is
    /// taken off first. It's kept until it's taken off, so one a restart leaves goes with the next
    /// message.
    public distributed func noted(_ message: NotedMessage) async {
        await unnote()
        do {
            try await changing { try await emit(event: .noted(message)) }
        } catch {
            actorSystem.log.warning(
                "Could not mark a noted message", metadata: ["error": .string(String(describing: error))])
            return
        }
        await publish(.noted(conversationID: conversationID, message))
        unnoting = Task {
            try? await Task.sleep(for: Self.notedFor)
            guard !Task.isCancelled else { return }
            unnoting = nil
            await takeMarkOff()
        }
    }

    /// Takes the noted message's mark off now, if one is shown.
    private func unnote() async {
        unnoting?.cancel()
        unnoting = nil
        await takeMarkOff()
    }

    private func takeMarkOff() async {
        let taken: NotedMessage?
        do {
            taken = try await changing {
                guard let noted = state.noted else { return nil }
                try await emit(event: .unnoted)
                return noted
            }
        } catch {
            actorSystem.log.warning(
                "Could not take a noted mark off", metadata: ["error": .string(String(describing: error))])
            return
        }
        guard let taken else { return }
        await publish(.unnoted(conversationID: conversationID, taken))
    }

    /// Delivers a non-agent notification through the currently attached
    /// channel. This is intentionally not journaled: the durable workflow is
    /// the owner of retrying the activity when no channel is available.
    public distributed func notify(_ text: String) async throws {
        let text = text.trimmed()
        guard !text.isEmpty else {
            throw ConversationActorError.emptyNotification
        }

        let connections = Array(connections)
        guard !connections.isEmpty else {
            throw ConversationActorError.noConnection
        }

        var failures: [String] = []
        for connection in connections {
            do {
                try await connection.receive(
                    .notice(
                        conversationID: conversationID,
                        turnID: nil,
                        text: text
                    )
                )
                return
            } catch {
                failures.append(String(describing: error))
            }
        }

        throw ConversationActorError.deliveryFailed(failures.joined(separator: "; "))
    }

    /// Emptied by `person`: refused unless they're one of its people.
    public distributed func reset(by person: TurgaiDomain.UserID) async throws {
        _ = try state.reading(by: person)
        try await dispatch(.reset)
    }

    /// Shows only the requesting user's bounded active memory. The command is
    /// handled here rather than sent through the model, so it cannot create a
    /// turn or become a new memory observation.
    public distributed func showMemory(for userID: TurgaiDomain.UserID) async throws {
        _ = try state.reading(by: userID)
        let user = try await User.identified(by: userID, on: actorSystem)
        let remembered = try await user.remembered()
        let remembering = try await user.currentRemembering()
        await publish(
            .noticeWithActions(
                conversationID: conversationID,
                turnID: nil,
                text: MemoryPresentation.text(remembered, remembering: remembering),
                actions: MemoryPresentation.actions(for: remembered, remembering: remembering)
            )
        )
    }

    /// Forgets `userID`'s remembered fact `written`, by its id, then shows what's remembered.
    public distributed func forgetFact(_ written: String, for userID: TurgaiDomain.UserID) async throws {
        _ = try state.reading(by: userID)
        guard let id = UUID(uuidString: written) else { throw NotAFact(written: written) }
        let user = try await User.identified(by: userID, on: actorSystem)
        _ = try await user.forgetFact(MemoryFactID(rawValue: id))
        try await showMemory(for: userID)
    }

    /// Turns remembering what `userID` says on or off, then shows what's remembered.
    public distributed func setRemembering(_ remembering: Remembering, for userID: TurgaiDomain.UserID) async throws {
        _ = try state.reading(by: userID)
        try await User.identified(by: userID, on: actorSystem).setRemembering(remembering)
        try await showMemory(for: userID)
    }

    /// Shows durable runtime diagnostics, as `scope`, one of its people's, reads them, without
    /// opening a model turn. The
    /// snapshot is read from Hail's event-sourced agent in one operation, so
    /// token usage and lifecycle data describe one coherent state.
    public distributed func showContext(as scope: CallScope) async throws {
        _ = try state.reading(by: scope.person)
        guard let bot = state.bots.first else { throw ConversationRefusal.notStarted }
        let participant = try await participant(for: bot.role)
        let snapshot = try await CallChain.$current.withValue(.start(scope, in: conversationID)) {
            try await participant.contextSnapshot()
        }
        await publish(
            .notice(
                conversationID: conversationID,
                turnID: nil,
                text: ContextPresentation.text(for: snapshot)
            )
        )
    }

    /// The diagnostics task given to the agent. Deliberately generic: it
    /// names no tools, so coverage follows the live tool set instead of a
    /// hardcoded list that could drift. With no memory tool registered,
    /// "each of your tools" is exactly the callable set.
    private static let diagnosticsRequest = """
        Diagnostics: call each of your tools once with harmless arguments, \
        undoing anything you create as you go. Then reply with a short \
        summary of what passed and what failed.
        """

    /// Asks the agent to exercise its tools and report what passed or failed.
    /// The request runs as a normal turn: the model reads the live tool
    /// schemas and produces each call itself — the part that actually breaks
    /// (a wrong shape, a bad field name) — hail executes through the real
    /// path, the run streams to the user, and the agent's reply is the
    /// report. The text states the task; it carries no format contract —
    /// schemas, grammar, and validation errors enforce the contract.
    public distributed func showDiagnostics<Owner: ConversationOwner>(
        for userID: TurgaiDomain.UserID, from owner: Owner
    ) async throws {
        _ = try state.reading(by: userID)
        await publish(
            .notice(
                conversationID: conversationID,
                turnID: nil,
                text: "Running tool diagnostics — the agent will exercise its tools now. This takes a few minutes."
            )
        )
        try await send(
            InboundMessage(
                conversationID: conversationID,
                participantID: ParticipantID(channel: conversationID.channel, rawValue: userID.key),
                userID: userID,
                text: Self.diagnosticsRequest,
                receivedAt: Date()
            ),
            turnID: TurnID(rawValue: UUID()), from: owner
        )
    }

    /// Clears the user's logical memory projection without touching the
    /// conversation or Hail transcript. Stale background extraction is
    /// rejected by the generation check in `User`.
    public distributed func forgetMemory(for userID: TurgaiDomain.UserID) async throws {
        _ = try state.reading(by: userID)
        let user = try await User.identified(by: userID, on: actorSystem)
        let forgottenFactCount = try await user.forgetMemory()
        await publish(
            .notice(
                conversationID: conversationID,
                turnID: nil,
                text: MemoryPresentation.forgotten(factCount: forgottenFactCount)
            )
        )
    }

    /// `text` shown in it, with `actions` its people can take, as its space says: an answer to a
    /// command someone gave in it.
    public distributed func showNotice(_ text: String, actions: [OutboundAction]) async {
        await publish(.noticeWithActions(conversationID: conversationID, turnID: nil, text: text, actions: actions))
    }

    /// Receives ephemeral model output from the current turn runner. The
    /// durable state transition still happens here, in the Conversation actor.
    public distributed func modelEvent(_ event: ConversationModelEvent) async {
        do {
            try await dispatch(action(for: event))
        } catch {
            actorSystem.log.error(
                "Could not persist conversation model transition",
                metadata: ["error": .string(String(describing: error))]
            )
        }
    }

    private func resumeAfterReplay() async throws {
        if state.inbox.activeTurnID != nil || !state.inbox.pendingMessages.isEmpty {
            guard state.inbox.activeMessage != nil || state.inbox.activeTurnID == nil else {
                actorSystem.log.error(
                    "Recovered running conversation without an active message",
                    metadata: ["conversationID": .string(conversationID.stableKey)]
                )
                return
            }
            try await dispatch(.resume)
        }

    }

    /// The agent of `role` in this conversation, which runs its turns while it's active.
    private func participant(for role: String) async throws -> AgentParticipant {
        if let participant = participants[role] { return participant }
        let made = try await AgentParticipant(
            in: self, conversationID: conversationID, of: home, role: role, actorSystem: actorSystem)
        // Another call may have made it while this one waited.
        if let participant = participants[role] { return participant }
        participants[role] = made
        return made
    }

    private func startModel(for request: ConversationTurnRequest) async {
        do {
            // The turn's scope, as its owner settles it now that it starts.
            guard let owner else { throw ConversationActorError.noOwner }
            let scope = try await owner.opening(request.message.userID)
            try await participant(for: request.bot.role).answer(request, as: scope)
        } catch {
            actorSystem.log.error(
                "Could not resolve agent for conversation turn",
                metadata: [
                    "conversationID": .string(conversationID.stableKey),
                    "bot": .string(request.bot.description),
                    "error": .string(String(describing: error)),
                ]
            )
            await modelEvent(
                .failed(
                    turnID: request.turnID,
                    kind: .model,
                    message: "The selected agent configuration could not be activated.",
                    agentTurn: nil
                )
            )
        }
    }

    private func dispatch(
        _ requestedAction: ConversationAction
    ) async throws {
        let action = requestedAction
        // Decided from the state the change before left, and emitted before the next is decided.
        let decision = try await changing {
            let decision = ConversationDecision(action, in: state)
            for event in decision.events { try await emit(event: event) }
            return decision
        }
        let effects = decision.effects
        for event in decision.events {
            if let publishEvent = PublishEvent(conversationEvent: event) {
                await publish(publishEvent)
            }
        }

        // A model completion is journaled before this point. A reply is an
        // at-least-once side effect: a failed transport leaves it in the
        // aggregate and a later input/reconnect gets another attempt. A void
        // completion has no message to retry; its terminal lifecycle event is
        // published as the corresponding effect below.
        if case .replyDelivered = action {
            // Avoid recursively trying to deliver while acknowledging one.
        } else {
            await deliverPendingReplies()
        }

        for effect in effects {
            switch effect {
            case .runReply(let request):
                await startModel(for: request)
            case .publish(let event):
                await publish(event)
            case .cancelModel:
                for participant in participants.values { try? await participant.cancel() }
            }
        }

    }

    /// Delivers terminal replies from the durable projection and removes each
    /// one only after a channel acknowledges the outbound operation.
    ///
    /// The first successful connection wins. Other live connections are only
    /// fallbacks, which avoids sending the same Telegram reply to every
    /// transient session attached to this conversation.
    private func deliverPendingReplies() async {
        let pendingReplies = state.pendingReplies
        guard !pendingReplies.isEmpty else { return }

        let connections = Array(connections)
        guard !connections.isEmpty else { return }

        for pendingReply in pendingReplies {
            let event = OutboundEvent.reply(
                .finished(
                    conversationID: conversationID,
                    turnID: pendingReply.turnID,
                    text: pendingReply.text,
                    at: pendingReply.at
                )
            )

            var delivered = false
            for connection in connections {
                do {
                    try await connection.receive(event)
                    delivered = true
                    break
                } catch {
                    actorSystem.log.warning(
                        "Could not deliver pending conversation reply",
                        metadata: [
                            "conversationID": .string(conversationID.stableKey),
                            "turnID": .string(pendingReply.turnID.rawValue.uuidString),
                            "error": .string(String(describing: error)),
                        ]
                    )
                }
            }

            if delivered {
                try? await dispatch(.replyDelivered(turnID: pendingReply.turnID))
            }
        }
    }

    private func action(for event: ConversationModelEvent) -> ConversationAction {
        switch event {
        case .completed(let turnID, let completion):
            return .modelCompleted(turnID: turnID, completion: completion, at: Date())
        case .failed(let turnID, let kind, let message, let agentTurn):
            return .modelFailed(
                turnID: turnID,
                failure: ConversationFailure(kind: kind, message: message),
                agentTurn: agentTurn,
                at: Date()
            )
        }
    }

    /// Publishes a live event after its durable source event has been emitted.
    /// Journal replay never creates a ``PublishEvent``.
    ///
    /// A user-message echo is published exactly once per message. An idle
    /// send starts its turn in the same transition, so its only echo comes
    /// from `.turnStarted`. A busy send echoes when queued
    /// (`.messageQueued`) and its later `.turnStarted` must not echo again.
    private func publish(_ event: PublishEvent) async {
        switch event {
        case .userMessage(let pending):
            await publishUserMessageEcho(pending.message, answeredIn: pending.turnID)
        case .said(let message):
            await publishUserMessageEcho(message, answeredIn: nil)
        case .turnStarted(let pending):
            await publishUserMessageEcho(pending.message, answeredIn: pending.turnID)
            try? await publishLive(
                .reply(
                    .started(
                        conversationID: conversationID,
                        turnID: pending.turnID
                    )
                )
            )
        }
    }

    private func publishUserMessageEcho(_ message: InboundMessage, answeredIn turnID: TurgaiDomain.TurnID?) async {
        guard !echoedMessageIDs.contains(message.id) else { return }
        echoedMessageIDs.append(message.id)
        if echoedMessageIDs.count > 256 {
            echoedMessageIDs.removeFirst(echoedMessageIDs.count - 256)
        }
        try? await publishLive(
            .reply(
                .userMessage(
                    conversationID: conversationID,
                    turnID: turnID,
                    messageID: message.id,
                    text: message.text,
                    author: message.userID,
                    to: message.to,
                    at: message.receivedAt
                )
            )
        )
    }

    distributed func publishLive(_ event: OutboundEvent) async {
        if case .reply(let reply) = event {
            liveState.apply(reply)
        }

        // Delivery rendezvous ends at the session's output channel, never at
        // the client: a slow or dead connection cannot stall the conversation.
        for connection in connections {
            try? await connection.receive(event)
        }
    }

    private func publish(_ event: OutboundEvent) async {
        await publishLive(event)
    }

    /// Applies events during both live execution and journal recovery. Live
    /// publication is intentionally handled by ``dispatch`` after ``emit``.
    public func handleEvent(_ event: ConversationEvent) {
        state.apply(event)
    }
}

public enum ConversationActorError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    case conversationMismatch
    case emptyNotification
    case noConnection
    case deliveryFailed(String)
    /// A turn started before it was told whom it reports to.
    case noOwner

    public var description: String {
        switch self {
        case .conversationMismatch: "the message is for another conversation"
        case .emptyNotification: "the notification has no text"
        case .noConnection: "no chat is connected to the conversation"
        case .deliveryFailed(let reason): "the delivery failed: \(reason)"
        case .noOwner: "the conversation wasn't told whom it reports to"
        }
    }
}
