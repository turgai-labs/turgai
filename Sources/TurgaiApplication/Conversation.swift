import Distributed
import DistributedCluster
import DurableWorkflows
import EventSourcing
import Hail
import Synchronization
import TurgaiDomain
import TurgaiHail
import TurgaiMemory
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
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

    public distributed func broadcast(_ event: OutboundEvent) async throws {
        try await onEvent(event)
    }
}

/// Transient connection ownership shared by the durable conversation actor
/// and any reply scope it starts. It is deliberately not part of the journal.
private actor ConversationConnectionRegistry {
    private var values: Set<ConversationConnection> = []

    func insert(_ connection: ConversationConnection) {
        values.insert(connection)
    }

    func remove(_ connection: ConversationConnection) {
        values.remove(connection)
    }

    func snapshot() -> [ConversationConnection] {
        Array(values)
    }

    func isEmpty() -> Bool {
        values.isEmpty
    }
}

private actor ReplyTextAccumulator {
    private var text = ""

    func append(_ fragment: String) -> String {
        text += fragment
        return text
    }
}

private enum ConversationProgress: Sendable {
    case thinking
    case text(String)
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

        var status = snapshot.phase.rawValue
        if let tool = snapshot.currentToolName {
            status += " (running tool: \(tool))"
        }
        lines.append("Status: \(status)")

        if let usage = snapshot.contextUsage {
            let percentage =
                usage.limitTokens > 0
                ? Int((Double(usage.usedTokens) / Double(usage.limitTokens) * 100).rounded())
                : 0
            lines.append(
                "Context window: \(usage.usedTokens.formatted(.number.locale(Self.numberLocale))) / \(usage.limitTokens.formatted(.number.locale(Self.numberLocale))) tokens"
                    + " (\(percentage)%, \(render(source: usage.source)))"
            )
        } else {
            lines.append("Context window: not reported")
        }

        lines.append(
            "Messages in context: \(snapshot.conversationMessageCount.formatted(.number.locale(Self.numberLocale)))")
        lines.append("Compaction summary: \(snapshot.hasContextSummary ? "yes" : "no")")

        let usageSummary = snapshot.usageSummary
        guard usageSummary.requestCount > 0 else {
            return lines.joined(separator: "\n")
        }

        lines.append("")
        lines.append("Model usage")
        lines.append("Requests: \(usageSummary.requestCount.formatted(.number.locale(Self.numberLocale)))")
        if let input = usageSummary.inputTokens {
            lines.append("Input tokens: \(input.formatted(.number.locale(Self.numberLocale)))")
        }
        if let output = usageSummary.outputTokens {
            lines.append("Output tokens: \(output.formatted(.number.locale(Self.numberLocale)))")
        }
        if let reasoning = usageSummary.reasoningTokens {
            lines.append("Reasoning tokens: \(reasoning.formatted(.number.locale(Self.numberLocale)))")
        }
        if let cached = usageSummary.cachedReadTokens {
            lines.append("Cached tokens read: \(cached.formatted(.number.locale(Self.numberLocale)))")
        }
        if let total = usageSummary.totalTokens {
            lines.append("Total tokens: \(total.formatted(.number.locale(Self.numberLocale)))")
        }
        return lines.joined(separator: "\n")
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

private actor ConversationPhase {
    private var value: ReplyPhase = .thinking

    func transition(to next: ReplyPhase) -> Bool {
        guard value != next else { return false }
        value = next
        return true
    }

    func current() -> ReplyPhase {
        value
    }
}

/// The application-side interpreter for one scoped model output.
///
/// It resolves the live connections for every lifecycle event. This matters
/// after recovery: a channel connection may reconnect while the durable turn
/// is still running, and the terminal reply must reach that new connection.
private struct ConversationScope: ScopeLifecycle {
    typealias Result = ConversationCompletion
    typealias Update = ConversationProgress

    let conversationID: ConversationID
    let turnID: TurgaiDomain.TurnID
    let connections: ConversationConnectionRegistry
    let complete: @Sendable (ConversationCompletion) async -> Void
    let operation: @Sendable (PartialSink<ConversationProgress>) async throws -> ConversationCompletion
    let phase = ConversationPhase()

    func start() async {
        await broadcast(
            .reply(.started(conversationID: conversationID, turnID: turnID))
        )
    }

    func heartbeat() async {
        await broadcast(
            .reply(
                .keepAlive(
                    conversationID: conversationID,
                    turnID: turnID,
                    phase: await phase.current()
                )
            )
        )
    }

    func perform(
        using updates: PartialSink<ConversationProgress>
    ) async throws -> ConversationCompletion {
        try await operation(updates)
    }

    func update(_ progress: ConversationProgress) async {
        switch progress {
        case .thinking:
            await publishPhase(.thinking)

        case .text(let text):
            await publishPhase(.typing)
            await broadcast(
                .reply(
                    .partial(
                        conversationID: conversationID,
                        turnID: turnID,
                        text: text
                    )
                )
            )
        }
    }

    func finish(_ outcome: ScopeOutcome<ConversationCompletion>) async {
        switch outcome {
        case .completed(let completion):
            // Persist first. A reply is delivered from the durable pending
            // projection; a void completion publishes only the lifecycle
            // terminal event.
            await complete(completion)
        case .failed(let failure):
            await broadcast(
                .reply(
                    .failed(
                        conversationID: conversationID,
                        turnID: turnID,
                        message: failure.message
                    )
                )
            )
        case .cancelled:
            break
        }
    }

    private func publishPhase(_ next: ReplyPhase) async {
        guard await phase.transition(to: next) else { return }
        await broadcast(
            .reply(
                .phase(
                    conversationID: conversationID,
                    turnID: turnID,
                    phase: next
                )
            )
        )
    }

    private func broadcast(_ event: OutboundEvent) async {
        for connection in await connections.snapshot() {
            try? await connection.broadcast(event)
        }
    }
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

    public struct Config: Codable, Sendable {
        public let conversationID: ConversationID
        public let agentDirectoryID: AgentDirectoryID
        public let agentRole: String
        /// Optional background memory extractor configuration.
        public let memoryExtraction: OllamaMemoryConfiguration?

        public init(
            conversationID: ConversationID,
            agentDirectoryID: AgentDirectoryID = "agent-directory",
            agentRole: String = "conversation",
            memoryExtraction: OllamaMemoryConfiguration? = nil
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
    private let peer: HailConversationPeer
    private let memoryExtractionEndpoint: (any ModelEndpoint)?
    /// The pending extraction timer. A new completed turn cancels and
    /// reschedules it, so extraction fires once per quiet period over
    /// everything accumulated in User's pending set.
    private let extractionScheduler = ExtractionScheduler()
    private let connectionRegistry = ConversationConnectionRegistry()
    private var modelTask: Task<Void, Never>?

    public init(actorSystem: ClusterSystem, dependency: Config) async throws {
        self.actorSystem = actorSystem
        self.conversationID = dependency.conversationID
        self.state = ConversationState(
            conversationID: dependency.conversationID
        )
        let adapter = HailAgentAdapter(
            actorSystem: actorSystem,
            agentDirectoryID: dependency.agentDirectoryID,
            agentRole: dependency.agentRole
        )
        self.peer = try await adapter.peer(for: dependency.conversationID)
        if let memoryExtraction = dependency.memoryExtraction {
            self.memoryExtractionEndpoint = OllamaEndpoint(
                model: memoryExtraction.model.rawValue,
                baseURL: memoryExtraction.baseURL,
                temperature: 0.2,
                numContext: memoryExtraction.contextWindow,
                keepAlive: memoryExtraction.keepAlive,
                think: false
            )
        } else {
            self.memoryExtractionEndpoint = nil
        }
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
        agentDirectoryID: AgentDirectoryID = "agent-directory",
        agentRole: String = "conversation",
        memoryExtraction: OllamaMemoryConfiguration? = nil
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
        let noConnections = await connectionRegistry.isEmpty()
        return state.activeTurnID == nil
            && noConnections
    }

    public distributed func currentRecord() -> ConversationState {
        state
    }

    public distributed func history() -> [ConversationHistoryEntry] {
        state.history
    }

    public distributed func modelHistory() async throws -> [ChatMessage] {
        try await peer.history()
    }

    public distributed func addConnection(_ connection: ConversationConnection) async {
        await connectionRegistry.insert(connection)
        if let turnID = state.activeTurnID {
            try? await connection.broadcast(
                .reply(.started(conversationID: conversationID, turnID: turnID))
            )
        }
        await deliverPendingReplies()
    }

    public distributed func removeConnection(_ connection: ConversationConnection) async {
        await connectionRegistry.remove(connection)
    }

    public distributed func send(
        _ message: InboundMessage,
        turnID: TurgaiDomain.TurnID
    ) async throws {
        guard message.conversationID == conversationID else {
            throw ConversationActorError.conversationMismatch
        }

        try await dispatch(
            .receive(
                message: message,
                turnID: turnID
            )
        )
    }

    /// Delivers a non-agent notification through the currently attached
    /// channel. This is intentionally not journaled: the durable workflow is
    /// the owner of retrying the activity when no channel is available.
    public distributed func notify(_ text: String) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ConversationActorError.emptyNotification
        }

        let connections = await connectionRegistry.snapshot()
        guard !connections.isEmpty else {
            throw ConversationActorError.noConnection
        }

        var failures: [String] = []
        for connection in connections {
            do {
                try await connection.broadcast(
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
    public distributed func showContext() async throws {
        let snapshot = try await peer.contextSnapshot()
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
            turnID: TurnID(rawValue: UUID())
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

    public distributed func clearFailure() async throws {
        try await dispatch(.clearFailure)
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
        if state.activeTurnID != nil || !state.pendingMessages.isEmpty {
            guard state.activeMessage != nil || state.activeTurnID == nil else {
                actorSystem.log.error(
                    "Recovered running conversation without an active message",
                    metadata: ["conversationID": .string(conversationID.stableKey)]
                )
                return
            }
            try await dispatch(.resume)
        }

    }

    /// How long the conversation must be quiet before the accumulated
    /// memory-extraction pass fires. Long enough for an exchange (ask, then
    /// answer) to settle into one batch.
    private static let extractionDebounceDelay: Duration = .seconds(240)

    /// Reference box for the debounce timer; Mutex is noncopyable, and the
    /// completion closure must capture the scheduler without consuming it.
    private final class ExtractionScheduler: Sendable {
        let state = Mutex<Task<Void, Never>?>(nil)
    }

    private func startModel(for request: ConversationTurnRequest) {
        modelTask?.cancel()
        let peer = self.peer
        let actorSystem = self.actorSystem
        let conversationID = self.conversationID
        let extractionEndpoint = memoryExtractionEndpoint
        let extractionScheduler = self.extractionScheduler
        let scope = ConversationScope(
            conversationID: conversationID,
            turnID: request.turnID,
            connections: connectionRegistry,
            complete: { [weak self] completion in
                try? await self?.modelEvent(
                    .completed(
                        turnID: request.turnID,
                        completion: completion
                    )
                )
                guard
                    let endpoint = extractionEndpoint,
                    !request.message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                else { return }
                // Debounced background memory extraction: cancel any
                // pending pass and reschedule. The extraction fires only
                // after the conversation has been quiet for a few minutes,
                // over everything accumulated in User's pending set — one
                // call per exchange, not per message.
                let userID = request.message.userID
                extractionScheduler.state.withLock { box in
                    box?.cancel()
                    box = Task {
                        try? await Task.sleep(for: Self.extractionDebounceDelay)
                        guard !Task.isCancelled else { return }
                        do {
                            _ = try await MemoryExtractionService.extractAndCommit(
                                endpoint: endpoint,
                                actorSystem: actorSystem,
                                userID: userID
                            )
                        } catch {
                            actorSystem.log.warning(
                                "Background memory extraction failed",
                                metadata: ["error": .string(String(describing: error))]
                            )
                        }
                    }
                }
            },
            operation: { updates in
                var turnContext = ["Current date and time: \(Self.timeAnchor())"]
                turnContext.append(
                    contentsOf: await Self.memoryContext(
                        for: request,
                        actorSystem: actorSystem,
                        conversationID: conversationID
                    )
                )
                let user = try await User.resolve(
                    on: actorSystem,
                    userID: request.message.userID
                )
                do {
                    try await user.recordObservation(
                        MemoryObservation(
                            id: ObservationID(rawValue: request.message.id.rawValue),
                            sourceID: MemorySourceID(rawValue: request.message.id.rawValue),
                            text: request.message.text,
                            observedAt: request.message.receivedAt
                        )
                    )
                } catch {
                    actorSystem.log.warning(
                        "Could not record memory observation",
                        metadata: ["error": .string(String(describing: error))]
                    )
                }
                let accumulator = ReplyTextAccumulator()
                let response = try await peer.run(
                    to: request,
                    turnContext: turnContext
                ) { event in
                    switch event {
                    case .reasoning:
                        await updates.send(.thinking)

                    case .text(let fragment):
                        let snapshot = await accumulator.append(fragment)
                        await updates.send(.text(snapshot))

                    default:
                        break
                    }
                }
                return .reply(response.reply)
            }
        )

        modelTask = Task { [weak self] in
            do {
                _ = try await withScope(scope) { error in Self.modelFailure(for: error) }

            } catch is CancellationError {
                try? await self?.modelEvent(
                    .failed(
                        turnID: request.turnID,
                        kind: .cancelled,
                        message: "The model request was cancelled."
                    )
                )
            } catch let failure as ConversationFailure {
                actorSystem.log.error(
                    "Model turn failed",
                    metadata: [
                        "conversationID": .string(conversationID.stableKey),
                        "turnID": .string(request.turnID.rawValue.uuidString),
                        "error": .string(failure.message),
                    ]
                )
                try? await self?.modelEvent(
                    .failed(
                        turnID: request.turnID,
                        kind: failure.kind,
                        message: failure.message
                    )
                )
            } catch {
                // The scope already emitted the mapped lifecycle failure. The
                // model event still needs the same typed failure so the
                // durable conversation closes the turn, while the original
                // error remains available in logs.
                let failure = Self.modelFailure(for: error)
                actorSystem.log.error(
                    "Model turn failed",
                    metadata: [
                        "conversationID": .string(conversationID.stableKey),
                        "turnID": .string(request.turnID.rawValue.uuidString),
                        "error": .string(String(describing: error)),
                    ]
                )
                try? await self?.modelEvent(
                    .failed(
                        turnID: request.turnID,
                        kind: failure.kind,
                        message: failure.message
                    )
                )
            }
        }
    }

    private func dispatch(
        _ requestedAction: ConversationAction
    ) async throws {
        let previous = state
        let action = requestedAction

        let (next, effects) = reduce(previous, action)
        for event in events(for: action, from: previous, to: next) {
            try await emit(event: event)
        }
        state = next

        if case .modelCompleted = action {
            modelTask = nil
        } else if case .modelFailed = action {
            modelTask = nil
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
                startModel(for: request)
            case .publish(let event):
                await publish(event)
            case .cancelModel:
                modelTask?.cancel()
                modelTask = nil
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

        let connections = await connectionRegistry.snapshot()
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
                    try await connection.broadcast(event)
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

    /// Retrieves memory immediately before a primary model turn. Memory is
    /// best-effort, both here and when the turn's observation is recorded:
    /// it is useful context, but it must not make the conversation
    /// unavailable while the separate User actor is recovering.
    ///
    /// Returns only the retrieved facts — per-turn data that lives in the
    /// request's tail context. The static capability guidance is part of the
    /// agent's system prompt, so it stays inside the reusable prompt prefix.
    private static func memoryContext(
        for request: ConversationTurnRequest,
        actorSystem: ClusterSystem,
        conversationID: ConversationID
    ) async -> [String] {
        let message = request.message
        guard !message.text.isEmpty else {
            return []
        }
        let userID = message.userID

        do {
            let user = try await User.resolve(on: actorSystem, userID: userID)
            if let instruction = try await user.memoryInstruction(for: message.text) {
                return [instruction]
            }
            return []
        } catch {
            actorSystem.log.warning(
                "Could not retrieve user memory for turn",
                metadata: [
                    "conversationID": .string(conversationID.stableKey),
                    "error": .string(String(describing: error)),
                ]
            )
            return []
        }
    }

    /// One stable time anchor per turn. The prompt carries no message
    /// timestamps, so without this anchor a long-idle conversation drifts to
    /// whatever time the most recent tool output happened to mention.
    ///
    /// The default is deliberately fixed so the host's timezone cannot alter
    /// the assistant's operating timezone.
    static func timeAnchor(
        at date: Date = Date(),
        timeZone: TimeZone = TimeZone(identifier: "Europe/Berlin")!
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .weekday],
            from: date
        )
        let weekdays = [
            "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
        ]
        let weekday =
            components.weekday
            .flatMap { (0..<7).contains($0 - 1) ? weekdays[$0 - 1] : nil } ?? ""
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let absolute = abs(offset)
        return String(
            format: "%04d-%02d-%02d %02d:%02d %@ (%@, UTC%@%02d:%02d)",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            weekday,
            timeZone.identifier,
            sign,
            absolute / 3600,
            (absolute % 3600) / 60
        )
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

    private static func modelFailure(for error: any Error) -> ConversationFailure {
        return ConversationFailure(
            kind: .model,
            message: HailAgentAdapter.userFacingMessage(for: error)
        )
    }

    private func events(
        for action: ConversationAction,
        from previous: ConversationState,
        to next: ConversationState
    ) -> [ConversationEvent] {
        if case .reset = action {
            return [.reset]
        }

        var events: [ConversationEvent] = []

        // Persist the terminal output before the lifecycle bookkeeping. The
        // reply event is the recovery point if the process crashes between
        // individual journal appends.
        events.append(
            contentsOf: newPendingReplies(
                from: previous.pendingReplies,
                to: next.pendingReplies
            ).map(ConversationEvent.replyQueued))

        if let previousTurnID = previous.activeTurnID,
            previousTurnID != next.activeTurnID
        {
            if case .failed(let failure) = next.status {
                events.append(.turnFailed(previousTurnID, failure))
            } else {
                events.append(.turnCompleted(previousTurnID))
            }
        }

        events.append(
            contentsOf: newPendingMessages(
                from: previous.pendingMessages,
                to: next.pendingMessages
            ).map(ConversationEvent.messageQueued))

        events.append(
            contentsOf: deliveredReplies(
                from: previous.pendingReplies,
                to: next.pendingReplies
            ).map(ConversationEvent.replyDelivered))

        if let activeMessage = next.activeMessage,
            previous.activeTurnID != next.activeTurnID
        {
            events.append(.turnStarted(activeMessage))
        }
        return events
    }

    private func newPendingMessages(
        from previous: [PendingConversationMessage],
        to next: [PendingConversationMessage]
    ) -> [PendingConversationMessage] {
        var unmatchedPrevious = previous
        var added: [PendingConversationMessage] = []
        for pending in next {
            if let index = unmatchedPrevious.firstIndex(of: pending) {
                unmatchedPrevious.remove(at: index)
            } else {
                added.append(pending)
            }
        }
        return added
    }

    private func newPendingReplies(
        from previous: [PendingConversationReply],
        to next: [PendingConversationReply]
    ) -> [PendingConversationReply] {
        var unmatchedPrevious = previous
        var added: [PendingConversationReply] = []
        for reply in next {
            if let index = unmatchedPrevious.firstIndex(of: reply) {
                unmatchedPrevious.remove(at: index)
            } else {
                added.append(reply)
            }
        }
        return added
    }

    private func deliveredReplies(
        from previous: [PendingConversationReply],
        to next: [PendingConversationReply]
    ) -> [TurgaiDomain.TurnID] {
        previous.map(\.turnID).filter { turnID in
            !next.contains { $0.turnID == turnID }
        }
    }

    private func publish(_ event: OutboundEvent) async {
        let connections = await connectionRegistry.snapshot()
        for connection in connections {
            try? await connection.broadcast(event)
        }
    }

    public func handleEvent(_ event: ConversationEvent) {
        state.apply(event)
    }
}

public enum ConversationActorError: Error, Codable, Sendable, Equatable {
    case conversationMismatch
    case emptyNotification
    case noConnection
    case deliveryFailed(String)
}
