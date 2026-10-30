import Distributed
import DistributedCluster
import DurableWorkflows
import EventSourcing
import Hail
import TurgaiDomain
import TurgaiHail
import TurgaiMemory
import TurgaiObjects
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
        message: String
    )
}

/// Someone in a conversation who's shown what happens in it.
public protocol ConversationListener: DistributedActor where ActorSystem == ClusterSystem {
    distributed func receive(_ event: OutboundEvent) async throws
}

/// A node-local delivery endpoint held by a durable Conversation actor.
///
/// It mirrors the connection actors used by Stagehand: connections and
/// callbacks are transient, while the Conversation aggregate is durable.
public distributed actor ConversationConnection: ConversationListener {
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

    init?(conversationEvent: ConversationEvent) {
        switch conversationEvent {
        case .inbox(.queued(let pending)):
            self = .userMessage(pending)
        case .inbox(.turnStarted(let pending)):
            self = .turnStarted(pending)
        case .started, .inbox(.turnCompleted), .inbox(.turnFailed), .awaiting, .answered, .replyQueued,
            .replyDelivered, .reset, .noted, .unnoted:
            return nil
        }
    }
}

/// What's remembered about a person, as `/memory` shows it, and its buttons.
enum MemoryPresentation {
    /// How long a fact is on its button, at most.
    private static let maximumLabel = 48

    /// What's remembered, as its tree, drawn in a code block so its lines stay in place.
    static func text(_ remembered: MemoryTree, remembering: Remembering) -> String {
        let off = remembering == .off ? "Memory is off: nothing new is remembered.\n" : ""
        guard !remembered.isEmpty else { return off + "Nothing is remembered." }
        return off + "Remembered:\n```\n" + remembered.rendered() + "\n```"
    }

    /// A button to forget each fact, one to turn remembering off or on, and one to forget everything.
    static func actions(for remembered: MemoryTree, remembering: Remembering) -> [OutboundAction] {
        let forgetting = remembered.facts.map { fact in
            OutboundAction(
                label: "Forget " + shortened("\(fact.path): \(fact.value)"),
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

/// Why an object can't be shown: it isn't one of the person's here, with those that are.
private struct NotYourObject: Error, CustomStringConvertible {
    let written: String
    let yours: [String]

    var description: String {
        "`\(written)` isn't one of your objects here"
            + (yours.isEmpty ? "" : "; yours: " + yours.map { "`\($0)`" }.joined(separator: ", "))
    }
}

private enum DuePresentation {
    private enum Command {
        static let cancelReminder = "/cancel-reminder"
        static let pauseTask = "/pause-task"
        static let unpauseTask = "/unpause-task"
        static let cancelTask = "/cancel-task"
    }

    static func reminders(_ timers: TimersInChat) -> (String, [OutboundAction]) {
        guard !timers.chat.isEmpty || !timers.objects.isEmpty else { return ("No active reminders.", []) }
        var lines: [String] = []
        var actions: [OutboundAction] = []
        for timer in timers.chat {
            switch timer.then {
            case .say(let text): lines.append("\(timer.name): says \(text)")
            case .ask(let instruction): lines.append("\(timer.name): asks \(instruction)")
            }
            lines.append("  At: \(timer.date.formatted(date: .abbreviated, time: .shortened))")
            actions.append(OutboundAction(label: "Cancel", command: "\(Command.cancelReminder) \(timer.name)"))
        }
        // An object's own timers, which its code changes.
        for timer in timers.objects {
            lines.append("\(timer.object) · \(timer.property)")
            lines.append("  At: \(timer.date.formatted(date: .abbreviated, time: .shortened))")
        }
        return (lines.joined(separator: "\n"), actions)
    }

    static func tasks(_ scheduled: SchedulesInChat) -> (String, [OutboundAction]) {
        guard !scheduled.chat.isEmpty || !scheduled.objects.isEmpty else { return ("No active tasks.", []) }
        var lines: [String] = []
        var actions: [OutboundAction] = []
        func next(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .shortened) ?? "unknown" }
        for schedule in scheduled.chat {
            switch schedule.then {
            case .say(let text): lines.append("\(schedule.name): says \(text)")
            case .ask(let instruction): lines.append("\(schedule.name): asks \(instruction)")
            }
            lines.append("  \(schedule.schedule.described)")
            lines.append("  Next: \(next(schedule.next))")
            lines.append("  Status: \(schedule.paused ? "paused" : "active")")
            actions.append(
                OutboundAction(
                    label: schedule.paused ? "Resume" : "Pause",
                    command: "\(schedule.paused ? Command.unpauseTask : Command.pauseTask) \(schedule.name)"))
            actions.append(OutboundAction(label: "Cancel", command: "\(Command.cancelTask) \(schedule.name)"))
        }
        // An object's own schedules, which its code changes.
        for schedule in scheduled.objects {
            lines.append("\(schedule.object) · \(schedule.property)")
            lines.append("  \(schedule.schedule.described)")
            lines.append("  Next: \(next(schedule.next))")
        }
        return (lines.joined(separator: "\n"), actions)
    }

    static func action(_ verb: String, id: String) -> String {
        "Task \(id) \(verb)."
    }

    static func reminderAction(_ verb: String, id: String) -> String {
        "Reminder \(id) \(verb)."
    }
}

/// Human-readable rendering of Hail's context diagnostics for the /context
/// command. Identifiers and request IDs are omitted on purpose: they mean
/// nothing in a chat message.
enum ContextPresentation {
    static func text(for snapshot: AgentContextSnapshot) -> String {
        var lines: [String] = ["Context diagnostics", ""]
        lines.append("Status: \(snapshot.state.rawValue)")
        if let usage = snapshot.contextUsage {
            let percentage: Int =
                usage.limitTokens > 0
                ? Int((Double(usage.usedTokens) / Double(usage.limitTokens) * 100).rounded())
                : 0
            lines.append(
                "Context window: \(counted(usage.usedTokens)) / \(counted(usage.limitTokens)) tokens"
                    + " (\(percentage)%, \(render(source: usage.source)))")
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

    /// Configuration that is selected for one turn. The value is required at
    /// the send boundary so a new turn cannot silently inherit a previous
    /// runtime choice.
    public struct TurnConfiguration: Codable, Sendable {
        public let agentRole: String
        public let memoryExtraction: MemoryExtractionConfiguration?

        public init(
            agentRole: String,
            memoryExtraction: MemoryExtractionConfiguration?
        ) {
            self.agentRole = agentRole
            self.memoryExtraction = memoryExtraction
        }
    }

    public struct Config: Codable, Sendable {
        public let conversationID: ConversationID
        public let agentDirectoryID: AgentDirectoryID
        public let agentRole: String
        /// Optional background memory extractor configuration.
        public let memoryExtraction: MemoryExtractionConfiguration?

        public init(
            conversationID: ConversationID,
            agentDirectoryID: AgentDirectoryID,
            agentRole: String,
            memoryExtraction: MemoryExtractionConfiguration?
        ) {
            self.conversationID = conversationID
            self.agentDirectoryID = agentDirectoryID
            self.memoryExtraction = memoryExtraction
            self.agentRole = agentRole
        }
    }

    public var state: ConversationState

    public let snapshotting: Snapshotting<ConversationEvent, ConversationState> = .every(
        numberOfEvents: 50,
        retention: .keepLast(2)
    )

    private let conversationID: ConversationID
    private let agentDirectoryID: AgentDirectoryID
    /// The role its agent has, unless a turn asks for another.
    private let agentRole: String
    /// Its agents while it's active: one for each role a turn asked for.
    private var participants: [String: AgentParticipant] = [:]
    private var turnConfigurations: [TurgaiDomain.TurnID: TurnConfiguration] = [:]
    private var memoryExtractionConfiguration: MemoryExtractionConfiguration?
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
        self.agentDirectoryID = dependency.agentDirectoryID
        self.state = ConversationState(
            conversationID: dependency.conversationID
        )
        self.agentRole = dependency.agentRole
        self.memoryExtractionConfiguration = dependency.memoryExtraction
        try await actorSystem.journal.register(
            actor: self,
            with: Self.persistenceID(for: dependency.conversationID)
        )
        try await resumeAfterReplay()
    }

    public static func actorID(for conversationID: ConversationID) -> VirtualActorID {
        VirtualActorID(rawValue: "conversation:\(conversationID.stableKey)")
    }

    public static func persistenceID(for conversationID: ConversationID) -> String {
        PersistenceID(conversationID: conversationID).rawValue
    }

    public static func resolve(
        on actorSystem: ClusterSystem,
        conversationID: ConversationID,
        agentDirectoryID: AgentDirectoryID,
        agentRole: String,
        memoryExtraction: MemoryExtractionConfiguration?
    ) async throws -> Conversation {
        try await actorSystem.virtualActors.getActor(
            identifiedBy: actorID(for: conversationID),
            dependency: Config(
                conversationID: conversationID,
                agentDirectoryID: agentDirectoryID,
                agentRole: agentRole,
                memoryExtraction: memoryExtraction
            )
        )
    }

    /// A conversation can passivate while idle, but never while a model turn
    /// is marked running. The running bit is journaled, so this does not rely
    /// on a transient Task existing. Nor while a noted message shows its mark, or one of its
    /// agents waits to extract what was said.
    public func shouldDeactivate() async -> Bool {
        guard state.inbox.activeTurnID == nil, connections.isEmpty, unnoting == nil else { return false }
        for participant in participants.values {
            if await participant.whenLocal({ $0.isRemembering }) == true { return false }
        }
        return true
    }

    public distributed func currentRecord() -> ConversationState {
        state
    }

    public distributed func history() -> [ConversationHistoryEntry] {
        state.history
    }

    public distributed func currentStatus() -> ConversationStatus {
        state.inbox.status
    }

    /// Its space: who's in it, and what its admins allow. A new one is made with it when it starts,
    /// and it's in that one from then on.
    private func space() async throws -> Space {
        if let space = state.space { return try await Space.resolve(on: actorSystem, id: space) }
        let started = try await changing {
            if let space = state.space { return space }
            let space = SpaceID()
            try await emit(event: .started(in: space))
            return space
        }
        return try await Space.resolve(on: actorSystem, id: started)
    }

    /// Makes `change` to its state once no other change is being made: it reads the state, decides
    /// and emits, calling nothing that could call back.
    private func changing<Result>(_ change: () async throws -> Result) async rethrows -> Result {
        await changes.wait()
        defer { changes.signal() }
        return try await change()
    }

    /// The agent's past turns, step by step, as `person` asks for them.
    public distributed func turns(askedBy person: TurgaiDomain.UserID) async throws -> [ConversationTurn] {
        let participant = try await participant(for: agentRole)
        let scope = try await space().scope(of: person)
        return try await CallChain.$current.withValue(.start(scope, in: conversationID)) { try await participant.turns() }
    }

    public distributed func addConnection(_ connection: ConversationConnection) async throws {
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
        // What's asked of its space's admins is shown through its links, this one too, from what
        // still waits.
        for request in try await space().waiting() {
            try? await connection.receive(.asked(conversationID: conversationID, request))
        }
        await deliverPendingReplies()
    }

    /// A turn of its own needed exactly `request`, which its scope didn't allow: its space asks its
    /// admins, and its links show them what's asked.
    public distributed func needed(_ request: ExactRequest) async throws {
        guard let opened = try await space().needed(request) else { return }
        // The turn waits for the answer, which continues it.
        try await dispatch(.awaiting(opened.id))
        await publishLive(.asked(conversationID: conversationID, opened))
    }

    /// `person`'s answer to one of its space's access requests, as the link they answered through
    /// says: its links show it, so each stops asking, when it counted.
    public distributed func answer(
        _ id: AccessRequestID, _ answer: AccessAnswer, by person: TurgaiDomain.UserID
    ) async throws {
        guard let answered = try await space().answer(id, answer, by: person) else { return }
        await publishLive(.answered(conversationID: conversationID, answered, answer, by: person))
        // The turn that waited for it continues, on behalf of whoever asked.
        try await dispatch(.answered(answered, answer, turnID: TurgaiDomain.TurnID(), at: Date()))
    }

    /// Who its space's admins are now, as its platform says: they decide for it.
    public distributed func setAdmins(_ admins: Set<TurgaiDomain.UserID>) async throws {
        try await space().setAdmins(admins)
    }

    /// Whom a call `person` makes here is on behalf of, and what's shared with them.
    public distributed func scope(of person: TurgaiDomain.UserID) async throws -> CallScope {
        try await space().scope(of: person)
    }

    public distributed func removeConnection(_ connection: ConversationConnection) async {
        connections.remove(connection)
    }

    public distributed func send(
        _ message: InboundMessage,
        turnID: TurgaiDomain.TurnID,
        configuration: TurnConfiguration
    ) async throws {
        guard message.conversationID == conversationID else {
            throw ConversationActorError.conversationMismatch
        }

        // A mark a restart left is taken off with the next message.
        await unnote()
        memoryExtractionConfiguration = configuration.memoryExtraction
        turnConfigurations[turnID] = configuration
        // Whoever writes takes part in its space.
        try await space().admit(message.userID)
        try await dispatch(
            .receive(
                message: message,
                turnID: turnID,
                agentRole: configuration.agentRole
            )
        )
        if !state.inbox.acceptedMessageIDs.contains(message.id) {
            turnConfigurations[turnID] = nil
        }
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

    public distributed func reset() async throws {
        try await dispatch(.reset)
    }

    /// Shows only the requesting user's bounded active memory. The command is
    /// handled here rather than sent through the model, so it cannot create a
    /// turn or become a new memory observation.
    public distributed func showMemory(for userID: TurgaiDomain.UserID) async throws {
        let user = try await User.resolve(on: actorSystem, userID: userID)
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
        guard let id = UUID(uuidString: written) else { throw NotAFact(written: written) }
        let user = try await User.resolve(on: actorSystem, userID: userID)
        _ = try await user.forgetFact(MemoryFactID(rawValue: id))
        try await showMemory(for: userID)
    }

    /// Turns remembering what `userID` says on or off, then shows what's remembered.
    public distributed func setRemembering(_ remembering: Remembering, for userID: TurgaiDomain.UserID) async throws {
        try await User.resolve(on: actorSystem, userID: userID).setRemembering(remembering)
        try await showMemory(for: userID)
    }

    /// Shows durable runtime diagnostics without opening a model turn. The
    /// snapshot is read from Hail's event-sourced agent in one operation, so
    /// token usage and lifecycle data describe one coherent state.
    public distributed func showContext(for person: TurgaiDomain.UserID) async throws {
        let participant = try await participant(for: agentRole)
        let scope = try await space().scope(of: person)
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
    public distributed func showDiagnostics(for userID: TurgaiDomain.UserID) async throws {
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
                participantID: conversationID.participantID,
                userID: userID,
                text: Self.diagnosticsRequest,
                receivedAt: Date()
            ),
            turnID: TurnID(rawValue: UUID()),
            configuration: TurnConfiguration(
                agentRole: agentRole,
                memoryExtraction: memoryExtractionConfiguration
            )
        )
    }

    /// Clears the user's logical memory projection without touching the
    /// conversation or Hail transcript. Stale background extraction is
    /// rejected by the generation check in `User`.
    public distributed func forgetMemory(for userID: TurgaiDomain.UserID) async throws {
        let user = try await User.resolve(on: actorSystem, userID: userID)
        let forgottenFactCount = try await user.forgetMemory()
        await publish(
            .notice(
                conversationID: conversationID,
                turnID: nil,
                text: MemoryPresentation.forgotten(factCount: forgottenFactCount)
            )
        )
    }

    /// This chat's timers and its objects', as the timers object lists them for `person`.
    public distributed func showReminders(for person: TurgaiDomain.UserID) async throws {
        let timers = try await asking(person) { try await Timers.resolve(on: $0).list() }
        let presentation = DuePresentation.reminders(timers)
        await publish(
            .noticeWithActions(
                conversationID: conversationID,
                turnID: nil,
                text: presentation.0,
                actions: presentation.1
            )
        )
    }

    /// A change to one of this chat's schedules, as its commands ask for it.
    public enum TaskChange: Codable, Sendable {
        case pause, resume, cancel
    }

    /// This chat's schedules and its objects', as the scheduler lists them for `person`.
    public distributed func showTasks(for person: TurgaiDomain.UserID) async throws {
        let scheduled = try await asking(person) { try await Scheduler.resolve(on: $0).list() }
        let presentation = DuePresentation.tasks(scheduled)
        await publish(
            .noticeWithActions(
                conversationID: conversationID,
                turnID: nil,
                text: presentation.0,
                actions: presentation.1
            )
        )
    }

    /// `change` to this chat's schedule `name`, as the scheduler makes it for `person`: refused,
    /// with why, when it isn't theirs to make.
    public distributed func changeTask(_ change: TaskChange, named name: String, by person: TurgaiDomain.UserID)
        async throws
    {
        do {
            let changed = try await asking(person) { system in
                let scheduler = try await Scheduler.resolve(on: system)
                switch change {
                case .pause: return try await scheduler.pause(name: name)
                case .resume: return try await scheduler.resume(name: name)
                case .cancel: return try await scheduler.cancel(name: name)
                }
            }
            let verb =
                switch change {
                case .pause: "paused"
                case .resume: "resumed"
                case .cancel: "cancelled"
                }
            await publish(
                .notice(
                    conversationID: conversationID, turnID: nil,
                    text: DuePresentation.action(verb, id: changed.name)))
        } catch {
            await publish(.notice(conversationID: conversationID, turnID: nil, text: "\(error)"))
        }
    }

    /// `ask`'s answer, asked of an object on behalf of `person`, in this chat: with their scope,
    /// which asking spends nothing of.
    private func asking<Answer: Sendable>(
        _ person: TurgaiDomain.UserID, _ ask: @Sendable (ClusterSystem) async throws -> Answer
    ) async throws -> Answer {
        let scope = try await space().scope(of: person)
        let system = actorSystem
        return try await CallChain.$current.withValue(.start(scope, in: conversationID)) { try await ask(system) }
    }

    /// Cancels this chat's timer `name`, as the timers object does for `person`: refused, with
    /// why, when it isn't theirs to cancel.
    public distributed func cancelReminder(named name: String, by person: TurgaiDomain.UserID) async throws {
        do {
            let cancelled = try await asking(person) { try await Timers.resolve(on: $0).cancel(name: name) }
            await publish(
                .notice(
                    conversationID: conversationID, turnID: nil,
                    text: DuePresentation.reminderAction("cancelled", id: cancelled.name)))
        } catch {
            await publish(.notice(conversationID: conversationID, turnID: nil, text: "\(error)"))
        }
    }

    /// The objects `person` may read here, made by name, each a button that shows its card.
    public distributed func showObjects(for person: TurgaiDomain.UserID) async throws {
        let objects = try await asking(person) { try await ObjectSession(actorSystem: $0).yourObjects() }
        await publish(
            .noticeWithActions(
                conversationID: conversationID,
                turnID: nil,
                text: objects.isEmpty ? "No objects." : "Objects:",
                actions: objects.map { OutboundAction(label: $0.description, command: "/object \($0)") }
            )
        )
    }

    /// The card of `person`'s object `written`, as they may read it here: refused, with why, when
    /// it isn't one of theirs.
    public distributed func showObject(_ written: String, for person: TurgaiDomain.UserID) async throws {
        do {
            let card = try await asking(person) { system in
                let session = ObjectSession(actorSystem: system)
                let objects = try await session.yourObjects()
                guard let object = objects.first(where: { $0.description == written }) else {
                    throw NotYourObject(written: written, yours: objects.map(\.description))
                }
                return try await session.card(object)
            }
            switch card {
            case .markdown(let text):
                await publish(.notice(conversationID: conversationID, turnID: nil, text: text))
            }
        } catch {
            await publish(.notice(conversationID: conversationID, turnID: nil, text: "\(error)"))
        }
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
            in: self, conversationID: conversationID, role: role, actorSystem: actorSystem)
        // Another call may have made it while this one waited.
        if let participant = participants[role] { return participant }
        participants[role] = made
        return made
    }

    private func startModel(for request: ConversationTurnRequest) async {
        let turnConfiguration = turnConfigurations.removeValue(forKey: request.turnID)
        do {
            // The turn's scope, as its sender's space settles it now that it starts.
            let scope = try await space().opening(scopeOf: request.message.userID, for: .person)
            try await participant(for: request.agentRole).answer(
                request, as: scope,
                memoryExtraction: turnConfiguration?.memoryExtraction ?? memoryExtractionConfiguration)
        } catch {
            actorSystem.log.error(
                "Could not resolve agent for conversation turn",
                metadata: [
                    "conversationID": .string(conversationID.stableKey),
                    "agentRole": .string(request.agentRole),
                    "error": .string(String(describing: error)),
                ]
            )
            await modelEvent(
                .failed(
                    turnID: request.turnID,
                    kind: .model,
                    message: "The selected agent configuration could not be activated."
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
                    text: pendingReply.text
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
            return .modelCompleted(turnID: turnID, completion: completion)
        case .failed(let turnID, let kind, let message):
            return .modelFailed(
                turnID: turnID,
                failure: ConversationFailure(kind: kind, message: message)
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
            await publishUserMessageEcho(pending)
        case .turnStarted(let pending):
            await publishUserMessageEcho(pending)
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

    private func publishUserMessageEcho(_ pending: PendingConversationMessage) async {
        guard !echoedMessageIDs.contains(pending.message.id) else { return }
        echoedMessageIDs.append(pending.message.id)
        if echoedMessageIDs.count > 256 {
            echoedMessageIDs.removeFirst(echoedMessageIDs.count - 256)
        }
        try? await publishLive(
            .reply(
                .userMessage(
                    conversationID: conversationID,
                    turnID: pending.turnID,
                    messageID: pending.message.id,
                    text: pending.message.text
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

    public var description: String {
        switch self {
        case .conversationMismatch: "the message is for another conversation"
        case .emptyNotification: "the notification has no text"
        case .noConnection: "no chat is connected to the conversation"
        case .deliveryFailed(let reason): "the delivery failed: \(reason)"
        }
    }
}
