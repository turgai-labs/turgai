import Distributed
import DistributedCluster
import DurableWorkflows
import EventSourcing
import Hail
import NorbyDomain
import NorbyHail
import NorbyMemory
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
        turnID: NorbyDomain.TurnID,
        completion: ConversationCompletion
    )
    case failed(
        turnID: NorbyDomain.TurnID,
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

private struct ExtractionBatch: Sendable {
    let id: UUID
    let userID: NorbyDomain.UserID
    let pending: [PendingMemoryObservation]

    var observations: [MemoryObservation] {
        pending.map { item in
            MemoryObservation(
                id: ObservationID(rawValue: item.message.id.rawValue),
                sourceID: MemorySourceID(rawValue: item.message.id.rawValue),
                text: item.message.text,
                response: item.response,
                observedAt: item.message.receivedAt
            )
        }
    }

    var turnIDs: [NorbyDomain.TurnID] { pending.map(\.turnID) }
}

private struct MemoryExtractionAttempt: Sendable {
    let id: UUID
    let batch: ExtractionBatch
    var task: Task<Void, Never>?
}

public enum MemoryExtractionCompletion: Codable, Sendable, Equatable {
    case completed(ExtractionOutcome)
    case failed
    case cancelled
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
    let turnID: NorbyDomain.TurnID
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

/// One durable Norby conversation aggregate.
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
        public let snapshotPolicy: AgentSnapshotPolicy

        public init(
            conversationID: ConversationID,
            agentDirectoryID: AgentDirectoryID = "agent-directory",
            agentRole: String = "conversation",
            snapshotPolicy: AgentSnapshotPolicy = .default
        ) {
            self.conversationID = conversationID
            self.agentDirectoryID = agentDirectoryID
            self.agentRole = agentRole
            self.snapshotPolicy = snapshotPolicy
        }
    }

    public var state: ConversationState

    public let snapshotting: Snapshotting<ConversationEvent, ConversationState> = .every(
        numberOfEvents: 50,
        retention: .keepLast(2)
    )

    private let conversationID: ConversationID
    private let peer: HailConversationPeer
    private let memoryExtractor: HailMemoryCandidateExtractor
    private let connectionRegistry = ConversationConnectionRegistry()
    private var modelTask: Task<Void, Never>?
    private var extraction: MemoryExtractionAttempt?

    private static let memoryExtractionBatchLimit = 8

    public init(actorSystem: ClusterSystem, dependency: Config) async throws {
        self.actorSystem = actorSystem
        self.conversationID = dependency.conversationID
        self.state = ConversationState(
            conversationID: dependency.conversationID
        )
        self.memoryExtractor = try HailMemoryCandidateExtractor(actorSystem: actorSystem)
        let adapter = HailAgentAdapter(
            actorSystem: actorSystem,
            agentDirectoryID: dependency.agentDirectoryID,
            agentRole: dependency.agentRole,
            snapshotPolicy: dependency.snapshotPolicy
        )
        self.peer = try await adapter.peer(for: dependency.conversationID)
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
        snapshotPolicy: AgentSnapshotPolicy = .default
    ) async throws -> Conversation {
        try await actorSystem.virtualActors.getActor(
            identifiedBy: actorID(for: conversationID),
            dependency: Config(
                conversationID: conversationID,
                agentDirectoryID: agentDirectoryID,
                agentRole: agentRole,
                snapshotPolicy: snapshotPolicy
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
            && extraction == nil
            && state.pendingMemoryObservations.isEmpty
    }

    public distributed func currentRecord() -> ConversationState {
        state
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
        turnID: NorbyDomain.TurnID
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
    public distributed func showMemory(for userID: NorbyDomain.UserID) async throws {
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

    /// Clears the user's logical memory projection without touching the
    /// conversation or Hail transcript. Stale background extraction is
    /// rejected by the generation check in `User`.
    public distributed func forgetMemory(for userID: NorbyDomain.UserID) async throws {
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

        guard state.activeTurnID == nil else {
            return
        }
        startPendingMemoryExtractionIfIdle()
    }

    private static func nextBatch(
        from pending: [PendingMemoryObservation],
        limit: Int
    ) -> ExtractionBatch? {
        guard let first = pending.first else { return nil }
        let selected =
            pending
            .filter { $0.message.userID == first.message.userID }
            .prefix(limit)
        guard !selected.isEmpty else { return nil }
        return ExtractionBatch(
            id: UUID(),
            userID: first.message.userID,
            pending: Array(selected)
        )
    }

    private func startModel(for request: ModelRequest) {
        modelTask?.cancel()
        let peer = self.peer
        let actorSystem = self.actorSystem
        let conversationID = self.conversationID
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
            },
            operation: { updates in
                let turnContext = await Self.memoryContext(
                    for: request,
                    actorSystem: actorSystem,
                    conversationID: conversationID
                )
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
        if case .receive = action, next != previous {
            // Memory extraction is background work, but it shares the local
            // model slot with foreground conversation turns. A new message
            // always wins; the cancelled request is put back in the queue.
            cancelActiveMemoryExtractions()
        }
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

        // Launch the next conversation turn before starting extraction. The
        // Ollama server is commonly configured with one parallel slot; if the
        // extractor is created first, it can occupy that slot between two
        // user messages and make the next reply appear to hang.
        startPendingMemoryExtractionIfIdle()
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

    /// Retrieves memory immediately before a primary model turn. Retrieval is
    /// best-effort: memory is useful context, but it must not make the
    /// conversation unavailable while the separate User actor is recovering.
    ///
    /// Returns only the retrieved facts — per-turn data that lives in the
    /// request's tail context. The static capability guidance is part of the
    /// agent's system prompt, so it stays inside the reusable prompt prefix.
    private static func memoryContext(
        for request: ModelRequest,
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

    /// Starts one owned extraction while the conversation is idle.
    private func startPendingMemoryExtractionIfIdle() {
        guard
            state.activeTurnID == nil,
            state.pendingMessages.isEmpty,
            modelTask == nil,
            extraction == nil,
            let batch = Self.nextBatch(
                from: state.pendingMemoryObservations,
                limit: Self.memoryExtractionBatchLimit
            )
        else {
            return
        }

        let actorSystem = self.actorSystem
        let memoryExtractor = self.memoryExtractor
        let conversationID = self.conversationID

        let task = Task(priority: .background) {
            [weak self, actorSystem, memoryExtractor, batch, conversationID]
            in
            let completion = await Self.process(
                batch: batch,
                conversationID: conversationID,
                actorSystem: actorSystem,
                memoryExtractor: memoryExtractor
            )
            try? await self?.memoryExtractionCompleted(
                attemptID: batch.id,
                completion: completion
            )
        }
        extraction = MemoryExtractionAttempt(id: batch.id, batch: batch, task: task)
    }

    public distributed func memoryExtractionCompleted(
        attemptID: UUID,
        completion: MemoryExtractionCompletion
    ) async {
        guard let attempt = extraction, attempt.id == attemptID else { return }
        switch completion {
        case .cancelled:
            extraction = nil
            // The captured observations remain pending. A foreground turn may
            // have caused this cancellation, so let the idle path claim them.
            startPendingMemoryExtractionIfIdle()
            return
        case .failed:
            // Keep the observations pending, but do not immediately retry a
            // provider failure in a tight loop. The next idle opportunity or
            // recovery will claim them again.
            extraction = nil
            return
        case .completed(let outcome):
            let update: MemoryUpdate?
            switch outcome {
            case .committed(let value): update = value
            case .stale, .alreadyHandled: update = nil
            }

            if let update, update.shouldNotify {
                await publish(
                    .notice(
                        conversationID: conversationID,
                        turnID: attempt.batch.turnIDs.last,
                        text: Self.memoryNotice(for: update)
                    )
                )
            }

            do {
                try await emit(event: .memoryObservationsCompleted(attempt.batch.turnIDs))
            } catch {
                // A committed User event is safe to retry: User recognizes
                // the captured sources as already handled. Leave the source
                // observations pending for the next idle/recovery attempt.
                actorSystem.log.warning(
                    "Could not acknowledge memory extraction",
                    metadata: [
                        "conversationID": .string(conversationID.stableKey),
                        "attemptID": .string(attemptID.uuidString),
                        "error": .string(String(describing: error)),
                    ]
                )
                extraction = nil
                return
            }

            extraction = nil
            startPendingMemoryExtractionIfIdle()
        }
    }

    private func cancelActiveMemoryExtractions() {
        extraction?.task?.cancel()
    }

    private static func process(
        batch: ExtractionBatch,
        conversationID: ConversationID,
        actorSystem: ClusterSystem,
        memoryExtractor: HailMemoryCandidateExtractor
    ) async -> MemoryExtractionCompletion {
        do {
            let user = try await User.resolve(on: actorSystem, userID: batch.userID)
            let preparation = try await user.prepareExtraction(batch.observations)
            try Task.checkCancellation()
            switch preparation {
            case .alreadyHandled:
                return .completed(.alreadyHandled)
            case .ready(let input):
                let proposals = try await memoryExtractor.extract(from: input)
                try Task.checkCancellation()
                return .completed(
                    try await user.commitExtraction(input, proposals: proposals)
                )
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            if Task.isCancelled { return .cancelled }
            actorSystem.log.warning(
                "Could not record completed user memory",
                metadata: [
                    "conversationID": .string(conversationID.stableKey),
                    "userID": .string(batch.userID.rawValue),
                    "error": .string(String(describing: error)),
                ]
            )
            return .failed
        }
    }

    private static func memoryNotice(for update: MemoryUpdate) -> String {
        let newCount = update.newFactCount
        let updatedCount = update.updatedFactCount
        switch (newCount, updatedCount) {
        case (let newCount, 0):
            return newCount == 1
                ? "Noted down 1 fact."
                : "Noted down \(newCount) facts."
        case (0, let updatedCount):
            return updatedCount == 1
                ? "Updated 1 existing fact."
                : "Updated \(updatedCount) existing facts."
        default:
            return "Noted down \(newCount) facts and updated \(updatedCount) existing facts."
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
            contentsOf: newPendingMemoryObservations(
                from: previous.pendingMemoryObservations,
                to: next.pendingMemoryObservations
            ).map(ConversationEvent.memoryObservationQueued)
        )

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

    private func newPendingMemoryObservations(
        from previous: [PendingMemoryObservation],
        to next: [PendingMemoryObservation]
    ) -> [PendingMemoryObservation] {
        let previousTurnIDs = Set(previous.map(\.turnID))
        return next.filter { !previousTurnIDs.contains($0.turnID) }
    }

    private func deliveredReplies(
        from previous: [PendingConversationReply],
        to next: [PendingConversationReply]
    ) -> [NorbyDomain.TurnID] {
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
