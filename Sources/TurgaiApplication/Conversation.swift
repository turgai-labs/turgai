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
        case .inbox(.turnCompleted), .inbox(.turnFailed), .awaiting, .answered, .replyQueued, .replyDelivered,
            .reset:
            return nil
        }
    }
}

private enum MemoryPresentation {
    static func facts(_ facts: [MemoryFact]) -> String {
        guard !facts.isEmpty else {
            return "I don't have any saved personal memory for you."
        }

        return "Saved personal memory:\n"
            + facts.map { fact in
                "- [\(fact.namespace.rawValue)] \(fact.predicate): \(fact.value.rendered)"
            }.joined(separator: "\n")
    }

    static func forgotten(factCount: Int) -> String {
        factCount == 0
            ? "There was no saved personal memory to forget."
            : "I forgot your saved personal memory."
    }
}

private enum DeferredActionPresentation {
    private enum Command {
        static let cancelReminder = "/cancel-reminder"
        static let pauseTask = "/pause-task"
        static let unpauseTask = "/unpause-task"
        static let cancelTask = "/cancel-task"
    }

    static func reminders(_ values: [(WorkflowID, Date, DeferredAction)]) -> (String, [OutboundAction]) {
        guard !values.isEmpty else { return ("No active reminders.", []) }
        var lines: [String] = []
        var actions: [OutboundAction] = []
        for (id, fireAt, action) in values {
            lines.append(action.content)
            lines.append(
                "  Action: \(action.kind == .deliverPreparedMessage ? "deliver prepared message" : "perform task")")
            lines.append("  At: \(fireAt.formatted(date: .abbreviated, time: .shortened))")
            actions.append(
                OutboundAction(
                    label: "Cancel",
                    command: "\(Command.cancelReminder) \(WorkflowID.compactTimerID(id))"
                )
            )
        }
        return (lines.joined(separator: "\n"), actions)
    }

    static func tasks(
        _ values: [(ScheduleID, Date, Date?, Date?, Bool, DeferredAction)]
    ) -> (String, [OutboundAction]) {
        guard !values.isEmpty else { return ("No active tasks.", []) }
        var lines: [String] = []
        var actions: [OutboundAction] = []
        for (id, createdAt, lastFiredAt, nextFireAt, paused, action) in values {
            lines.append(action.content)
            lines.append(
                "  Action: \(action.kind == .deliverPreparedMessage ? "deliver prepared message" : "perform task")")
            lines.append("  Created: \(createdAt.formatted(date: .abbreviated, time: .shortened))")
            if let lastFiredAt {
                lines.append("  Last run: \(lastFiredAt.formatted(date: .abbreviated, time: .shortened))")
            }
            lines.append(
                "  Next: \(nextFireAt?.formatted(date: .abbreviated, time: .shortened) ?? "unknown")"
            )
            lines.append("  Status: \(paused ? "paused" : "active")")
            actions.append(
                OutboundAction(
                    label: paused ? "Resume" : "Pause",
                    command: paused
                        ? "\(Command.unpauseTask) \(ScheduleID.compactScheduleID(id))"
                        : "\(Command.pauseTask) \(ScheduleID.compactScheduleID(id))"
                )
            )
            actions.append(
                OutboundAction(
                    label: "Cancel",
                    command: "\(Command.cancelTask) \(ScheduleID.compactScheduleID(id))"
                )
            )
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
    /// on a transient Task existing.
    public func shouldDeactivate() async -> Bool {
        let noConnections = connections.isEmpty
        return state.inbox.activeTurnID == nil
            && noConnections
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

    /// Its group: who's in it, and what its admins allow.
    private func group() async throws -> Group {
        try await Group.resolve(on: actorSystem, id: GroupID(conversationID))
    }

    /// The agent's past turns, step by step, as `person` asks for them.
    public distributed func turns(askedBy person: TurgaiDomain.UserID) async throws -> [ConversationTurn] {
        let participant = try await participant(for: agentRole)
        let scope = try await group().scope(of: person)
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
        // What's asked of its group's admins is shown through its links, this one too, from what
        // still waits.
        for request in try await group().waiting() {
            try? await connection.receive(.asked(conversationID: conversationID, request))
        }
        await deliverPendingReplies()
    }

    /// A turn of its own needed exactly `request`, which its scope didn't allow: its group asks its
    /// admins, and its links show them what's asked.
    public distributed func needed(_ request: ExactRequest) async throws {
        guard let opened = try await group().needed(request) else { return }
        // The turn waits for the answer, which continues it.
        try await dispatch(.awaiting(opened.id))
        await publishLive(.asked(conversationID: conversationID, opened))
    }

    /// `person`'s answer to one of its group's access requests, as the link they answered through
    /// says: its links show it, so each stops asking, when it counted.
    public distributed func answer(
        _ id: AccessRequestID, _ answer: AccessAnswer, by person: TurgaiDomain.UserID
    ) async throws {
        guard let answered = try await group().answer(id, answer, by: person) else { return }
        await publishLive(.answered(conversationID: conversationID, answered, answer, by: person))
        // The turn that waited for it continues, on behalf of whoever asked.
        try await dispatch(.answered(answered, answer, turnID: TurgaiDomain.TurnID(), at: Date()))
    }

    /// Who its group's admins are now, as its platform says: they decide for it.
    public distributed func setAdmins(_ admins: Set<TurgaiDomain.UserID>) async throws {
        try await group().setAdmins(admins)
    }

    /// Whom a call `person` makes here is on behalf of, and what's shared with them.
    public distributed func scope(of person: TurgaiDomain.UserID) async throws -> CallScope {
        try await group().scope(of: person)
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

        memoryExtractionConfiguration = configuration.memoryExtraction
        turnConfigurations[turnID] = configuration
        // Whoever writes takes part in its group.
        try await group().admit(message.userID)
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
        let facts = try await user.currentMemoryFacts(limit: 20)
        await publish(
            .notice(
                conversationID: conversationID,
                turnID: nil,
                text: MemoryPresentation.facts(facts)
            )
        )
    }

    /// Shows durable runtime diagnostics without opening a model turn. The
    /// snapshot is read from Hail's event-sourced agent in one operation, so
    /// token usage and lifecycle data describe one coherent state.
    public distributed func showContext(for person: TurgaiDomain.UserID) async throws {
        let participant = try await participant(for: agentRole)
        let scope = try await group().scope(of: person)
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

    public distributed func showReminders() async throws {
        let descriptions = try await actorSystem.workflows.listWorkflows(workflow: TimerWorkflow.self)
        let decoder = JSONDecoder()
        let reminders = descriptions.compactMap { description -> (WorkflowID, Date, DeferredAction)? in
            guard case .running = description.status,
                let inputData = description.inputData,
                let input = try? decoder.decode(Timer.Input.self, from: inputData),
                input.request.conversationID == conversationID
            else { return nil }
            return (description.id, input.fireAt, input.request.action)
        }
        .sorted { $0.1 < $1.1 }
        let presentation = DeferredActionPresentation.reminders(reminders)
        await publish(
            .noticeWithActions(
                conversationID: conversationID,
                turnID: nil,
                text: presentation.0,
                actions: presentation.1
            )
        )
    }

    public distributed func showTasks() async throws {
        let descriptions = try await actorSystem.workflows.listSchedules(workflow: ScheduleWorkflow.self)
        let decoder = JSONDecoder()
        let tasks = descriptions.compactMap { description -> (ScheduleID, Date, Date?, Date?, Bool, DeferredAction)? in
            guard let request = try? decoder.decode(Schedule.Request.self, from: description.inputData),
                request.conversationID == conversationID
            else { return nil }
            return (
                description.id,
                description.createdAt,
                description.lastFiredAt,
                description.nextFireAt,
                description.paused,
                request.action
            )
        }
        .sorted { left, right in
            switch (left.3, right.3) {
            case (let left?, let right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.0.rawValue < right.0.rawValue
            }
        }
        let presentation = DeferredActionPresentation.tasks(tasks)
        await publish(
            .noticeWithActions(
                conversationID: conversationID,
                turnID: nil,
                text: presentation.0,
                actions: presentation.1
            )
        )
    }

    public distributed func pauseTask(id: String) async throws {
        guard let id = ScheduleID.scheduleID(from: id) else {
            await publish(.notice(conversationID: conversationID, turnID: nil, text: "Usage: /pause-task <task-id>"))
            return
        }
        let workflows = actorSystem.workflows
        guard
            try await workflows.listSchedules(workflow: ScheduleWorkflow.self).contains(where: { description in
                guard description.id == id,
                    let request = try? JSONDecoder().decode(Schedule.Request.self, from: description.inputData)
                else { return false }
                return request.conversationID == conversationID
            })
        else {
            await publish(.notice(conversationID: conversationID, turnID: nil, text: "Task not found."))
            return
        }
        try await workflows.pauseSchedule(
            id: id,
            workflow: ScheduleWorkflow.self,
            reason: "Telegram command"
        )
        await publish(
            .notice(
                conversationID: conversationID, turnID: nil,
                text: DeferredActionPresentation.action("paused", id: id.rawValue)))
    }

    public distributed func unpauseTask(id: String) async throws {
        guard let id = ScheduleID.scheduleID(from: id) else {
            await publish(.notice(conversationID: conversationID, turnID: nil, text: "Usage: /unpause-task <task-id>"))
            return
        }
        let workflows = actorSystem.workflows
        guard
            try await workflows.listSchedules(workflow: ScheduleWorkflow.self).contains(where: { description in
                guard description.id == id,
                    let request = try? JSONDecoder().decode(Schedule.Request.self, from: description.inputData)
                else { return false }
                return request.conversationID == conversationID
            })
        else {
            await publish(.notice(conversationID: conversationID, turnID: nil, text: "Task not found."))
            return
        }
        try await workflows.unpauseSchedule(
            id: id,
            workflow: ScheduleWorkflow.self,
            reason: "Telegram command"
        )
        await publish(
            .notice(
                conversationID: conversationID, turnID: nil,
                text: DeferredActionPresentation.action("unpaused", id: id.rawValue)))
    }

    public distributed func cancelTask(id: String) async throws {
        guard let id = ScheduleID.scheduleID(from: id) else {
            await publish(.notice(conversationID: conversationID, turnID: nil, text: "Usage: /cancel-task <task-id>"))
            return
        }
        let workflows = actorSystem.workflows
        guard
            try await workflows.listSchedules(workflow: ScheduleWorkflow.self).contains(where: { description in
                guard description.id == id,
                    let request = try? JSONDecoder().decode(Schedule.Request.self, from: description.inputData)
                else { return false }
                return request.conversationID == conversationID
            })
        else {
            await publish(.notice(conversationID: conversationID, turnID: nil, text: "Task not found."))
            return
        }
        try await workflows.cancelSchedule(
            id: id,
            workflow: ScheduleWorkflow.self
        )
        await publish(
            .notice(
                conversationID: conversationID, turnID: nil,
                text: DeferredActionPresentation.action("cancelled", id: id.rawValue)))
    }

    public distributed func cancelReminder(id: String) async throws {
        guard let id = WorkflowID.timerID(from: id) else {
            await publish(
                .notice(conversationID: conversationID, turnID: nil, text: "Usage: /cancel-reminder <reminder-id>"))
            return
        }
        let workflows = actorSystem
        let descriptions = try await workflows.workflows.listWorkflows(workflow: TimerWorkflow.self)
        guard
            descriptions.contains(where: { description in
                guard description.id == id,
                    case .running = description.status,
                    let inputData = description.inputData,
                    let input = try? JSONDecoder().decode(Timer.Input.self, from: inputData)
                else { return false }
                return input.request.conversationID == conversationID
            })
        else {
            await publish(.notice(conversationID: conversationID, turnID: nil, text: "Reminder not found."))
            return
        }
        try await workflows.workflows.cancel(
            type: TimerWorkflow.self,
            options: WorkflowOptions(id: id)
        )
        await publish(
            .notice(
                conversationID: conversationID, turnID: nil,
                text: DeferredActionPresentation.reminderAction("cancelled", id: id.rawValue)))
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
            // The turn's scope, as its sender's group settles it now that it starts.
            let scope = try await group().opening(scopeOf: request.message.userID)
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
        let previous = state
        let action = requestedAction

        let decision = ConversationDecision(action, in: previous)
        let effects = decision.effects
        for event in decision.events {
            try await emit(event: event)
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
