import Distributed
import DistributedCluster
import EventSourcing
import Foundation
import Hail
import NorbyDomain
import NorbyHail
import NorbyMemory
import VirtualActors

/// Durable coordination state for one Norby conversation.
///
/// Hail's Agent journal is the transcript authority. This record therefore
/// contains delivery/turn coordination only: the active input, queued inputs,
/// and the lifecycle status needed by the channel-facing aggregate.
public struct ConversationRecord: Codable, Sendable, Equatable {
    public let conversationID: ConversationID
    public private(set) var capabilities: ChannelCapabilities
    public private(set) var status: ConversationStatus
    public private(set) var pendingMessages: [PendingConversationMessage]
    public private(set) var pendingReplies: [PendingConversationReply]
    public private(set) var activeMessage: PendingConversationMessage?
    public private(set) var revision: UInt64

    public init(
        conversationID: ConversationID,
        capabilities: ChannelCapabilities = .default
    ) {
        self.conversationID = conversationID
        self.capabilities = capabilities
        self.status = .idle
        self.pendingMessages = []
        self.pendingReplies = []
        self.activeMessage = nil
        self.revision = 0
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID
        case capabilities
        case status
        case pendingMessages
        case pendingReplies
        case activeMessage
        case revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.conversationID = try container.decode(ConversationID.self, forKey: .conversationID)
        self.capabilities = try container.decode(ChannelCapabilities.self, forKey: .capabilities)
        self.status = try container.decode(ConversationStatus.self, forKey: .status)
        self.pendingMessages = try container.decodeIfPresent(
            [PendingConversationMessage].self,
            forKey: .pendingMessages
        ) ?? []
        self.pendingReplies = try container.decodeIfPresent(
            [PendingConversationReply].self,
            forKey: .pendingReplies
        ) ?? []
        self.activeMessage = try container.decodeIfPresent(
            PendingConversationMessage.self,
            forKey: .activeMessage
        )
        self.revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
    }

    public mutating func apply(_ event: ConversationEvent) {
        switch event {
        case .capabilitiesChanged(let capabilities):
            self.capabilities = capabilities
            revision &+= 1

        case .messageQueued(let pending):
            pendingMessages.append(pending)
            revision &+= 1

        case .replyQueued(let reply):
            if !pendingReplies.contains(reply) {
                pendingReplies.append(reply)
            }
            // Queueing the terminal reply is the durable completion barrier.
            // It is deliberately applied before turnCompleted is emitted so
            // a crash between journal writes cannot lose the reply.
            if activeTurnID == reply.turnID {
                activeMessage = nil
                status = .idle
            }
            revision &+= 1

        case .replyDelivered(let turnID):
            pendingReplies.removeAll { $0.turnID == turnID }
            revision &+= 1

        case .turnStarted(let pending):
            if let index = pendingMessages.firstIndex(where: { $0.turnID == pending.turnID }) {
                pendingMessages.remove(at: index)
            }
            activeMessage = pending
            status = .running(pending.turnID)
            revision &+= 1

        case .turnCompleted(let turnID):
            guard activeTurnID == turnID else { return }
            activeMessage = nil
            status = .idle
            revision &+= 1

        case .turnFailed(let turnID, let failure):
            guard activeTurnID == turnID else { return }
            activeMessage = nil
            status = .failed(failure)
            revision &+= 1

        case .reset:
            activeMessage = nil
            pendingMessages.removeAll(keepingCapacity: true)
            pendingReplies.removeAll(keepingCapacity: true)
            status = .idle
            revision &+= 1
        }
    }

    public var activeTurnID: NorbyDomain.TurnID? {
        guard case .running(let turnID) = status else { return nil }
        return turnID
    }

    public var requiresRecovery: Bool {
        switch status {
        case .running:
            true
        case .idle:
            !pendingMessages.isEmpty || !pendingReplies.isEmpty
        case .failed:
            !pendingMessages.isEmpty || !pendingReplies.isEmpty
        }
    }
}

/// Model lifecycle messages sent back into the Conversation aggregate from
/// its transient model task. The Conversation actor remains the only owner of
/// turn state.
public enum ConversationModelEvent: Codable, Sendable, Equatable {
    case completed(turnID: NorbyDomain.TurnID, text: String)
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
    typealias Result = String
    typealias Update = ConversationProgress

    let conversationID: ConversationID
    let turnID: NorbyDomain.TurnID
    let connections: ConversationConnectionRegistry
    let complete: @Sendable (String) async -> Void
    let operation: @Sendable (PartialSink<ConversationProgress>) async throws -> String
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
    ) async throws -> String {
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

    func finish(_ outcome: ScopeOutcome<String>) async {
        switch outcome {
        case .completed(let text):
            // Persist first. The conversation then attempts delivery from its
            // durable pending-reply projection.
            await complete(text)
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
    public typealias State = ConversationRecord
    public typealias Dependency = Config
    public typealias PersistenceID = ConversationPersistenceID

    public struct Config: Codable, Sendable {
        public let conversationID: ConversationID
        public let capabilities: ChannelCapabilities
        public let agentDirectoryID: AgentDirectoryID
        public let agentRole: String
        public let snapshotPolicy: AgentSnapshotPolicy

        public init(
            conversationID: ConversationID,
            capabilities: ChannelCapabilities = .default,
            agentDirectoryID: AgentDirectoryID = "agent-directory",
            agentRole: String = "conversation",
            snapshotPolicy: AgentSnapshotPolicy = .default
        ) {
            self.conversationID = conversationID
            self.capabilities = capabilities
            self.agentDirectoryID = agentDirectoryID
            self.agentRole = agentRole
            self.snapshotPolicy = snapshotPolicy
        }
    }

    public var state: ConversationRecord

    public let snapshotting: Snapshotting<ConversationEvent, ConversationRecord> = .every(
        numberOfEvents: 50,
        retention: .keepLast(2)
    )

    private let conversationID: ConversationID
    private let peer: HailConversationPeer
    private let memoryExtractor: HailMemoryCandidateExtractor
    /// The functional core's full state. `ConversationRecord` is the durable
    /// journal projection; this value is the state passed through `reduce`.
    private var coreState: ConversationState
    private let connectionRegistry = ConversationConnectionRegistry()
    private var modelTask: Task<Void, Never>?
    private var memoryTasks: [NorbyDomain.TurnID: Task<Void, Never>] = [:]

    public init(actorSystem: ClusterSystem, dependency: Config) async throws {
        self.actorSystem = actorSystem
        self.conversationID = dependency.conversationID
        self.state = ConversationRecord(
            conversationID: dependency.conversationID,
            capabilities: dependency.capabilities
        )
        self.coreState = ConversationState(
            conversationID: dependency.conversationID,
            capabilities: dependency.capabilities
        )
        self.memoryExtractor = HailMemoryCandidateExtractor(actorSystem: actorSystem)
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
        self.coreState = Self.coreState(from: state)
        try await resumeAfterReplay()
    }

    private static func coreState(
        from record: ConversationRecord
    ) -> ConversationState {
        ConversationState(
            conversationID: record.conversationID,
            capabilities: record.capabilities,
            status: record.status,
            pendingMessages: record.pendingMessages,
            pendingReplies: record.pendingReplies,
            activeMessage: record.activeMessage,
            revision: record.revision
        )
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
        capabilities: ChannelCapabilities = .default,
        agentDirectoryID: AgentDirectoryID = "agent-directory",
        agentRole: String = "conversation",
        snapshotPolicy: AgentSnapshotPolicy = .default
    ) async throws -> Conversation {
        try await actorSystem.virtualActors.getActor(
            identifiedBy: actorID(for: conversationID),
            dependency: Config(
                conversationID: conversationID,
                capabilities: capabilities,
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
        return state.activeTurnID == nil && noConnections && memoryTasks.isEmpty
    }

    public distributed func currentRecord() -> ConversationRecord {
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
        turnID: NorbyDomain.TurnID,
        capabilities: ChannelCapabilities
    ) async throws {
        guard message.conversationID == conversationID else {
            throw ConversationActorError.conversationMismatch
        }

        try await dispatch(
            .receive(
                message: message,
                turnID: turnID,
                capabilities: capabilities
            )
        )
    }

    public distributed func reset() async throws {
        try await dispatch(.reset)
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
        guard state.activeTurnID != nil || !state.pendingMessages.isEmpty else {
            return
        }

        guard state.activeMessage != nil || state.activeTurnID == nil else {
            actorSystem.log.error(
                "Recovered running conversation without an active message",
                metadata: ["conversationID": .string(conversationID.stableKey)]
            )
            return
        }
        try await dispatch(.resume)
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
            complete: { [weak self] text in
                try? await self?.modelEvent(
                    .completed(turnID: request.turnID, text: text)
                )
            },
            operation: { updates in
                let instructions = await Self.memoryInstructions(
                    for: request,
                    actorSystem: actorSystem,
                    conversationID: conversationID
                )
                let accumulator = ReplyTextAccumulator()
                let response = try await peer.run(
                    to: request,
                    systemInstructions: instructions
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
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw ConversationFailure(
                        kind: .emptyResponse,
                        message: "The model returned an empty response."
                    )
                }
                return text
            }
        )

        modelTask = Task { [weak self] in
            do {
                _ = try await withScope(scope)

            } catch is CancellationError {
                try? await self?.modelEvent(
                    .failed(
                        turnID: request.turnID,
                        kind: .cancelled,
                        message: "The model request was cancelled."
                    )
                )
            } catch {
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
                        kind: .model,
                        message: HailAgentAdapter.userFacingMessage(for: error)
                    )
                )
            }
        }
    }

    private func dispatch(
        _ requestedAction: ConversationAction
    ) async throws {
        let previous = coreState
        let action = requestedAction

        let (next, effects) = reduce(previous, action)
        for event in events(for: action, from: previous, to: next) {
            try await emit(event: event)
        }
        coreState = next

        if case .modelCompleted = action {
            modelTask = nil
        } else if case .modelFailed = action {
            modelTask = nil
        }

        // A completed reply is journaled before this point. Delivery is an
        // at-least-once side effect: a failed transport leaves the reply in
        // the aggregate and a later input/reconnect gets another attempt.
        if case .replyDelivered = action {
            // Avoid recursively trying to deliver while acknowledging one.
        } else {
            await deliverPendingReplies()
        }

        if case .modelCompleted = action {
            startMemoryExtraction(from: previous, action: action)
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
        let pendingReplies = coreState.pendingReplies
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
    private static func memoryInstructions(
        for request: ModelRequest,
        actorSystem: ClusterSystem,
        conversationID: ConversationID
    ) async -> [String] {
        let message = request.message
        guard !message.text.isEmpty else {
            return []
        }
        let userID = message.userID

        var instructions = [MemoryRetrieval.capabilityInstruction]
        do {
            let user = try await User.resolve(on: actorSystem, userID: userID)
            if let instruction = try await user.memoryInstruction(for: message.text) {
                instructions.append(instruction)
            }
            return instructions
        } catch {
            actorSystem.log.warning(
                "Could not retrieve user memory for turn",
                metadata: [
                    "conversationID": .string(conversationID.stableKey),
                    "error": .string(String(describing: error)),
                ]
            )
            return instructions
        }
    }

    /// Starts one application-owned background operation for a completed turn.
    /// The task is retained until it finishes so an active extraction prevents
    /// passivation, while the reply and any queued turn proceed immediately.
    private func startMemoryExtraction(
        from previous: ConversationState,
        action: ConversationAction
    ) {
        guard
            case .modelCompleted(let turnID, let response) = action,
            previous.activeTurnID == turnID,
            let activeMessage = previous.activeMessage
        else {
            return
        }

        let observation = MemoryObservation(
            id: ObservationID(rawValue: activeMessage.message.id.rawValue),
            sourceID: MemorySourceID(rawValue: activeMessage.message.id.rawValue),
            text: activeMessage.message.text,
            response: response,
            observedAt: activeMessage.message.receivedAt
        )
        let userID = activeMessage.message.userID
        let actorSystem = self.actorSystem
        let memoryExtractor = self.memoryExtractor
        let conversationID = self.conversationID

        let task = Task {
            [weak self, actorSystem, memoryExtractor, observation, userID, conversationID]
            in
            let update = await Self.recordCompletedMemory(
                observation: observation,
                userID: userID,
                conversationID: conversationID,
                actorSystem: actorSystem,
                memoryExtractor: memoryExtractor
            )
            try? await self?.memoryExtractionCompleted(
                turnID: turnID,
                update: update
            )
        }
        memoryTasks[turnID] = task
    }

    public distributed func memoryExtractionCompleted(
        turnID: NorbyDomain.TurnID,
        update: MemoryUpdate?
    ) async {
        memoryTasks[turnID] = nil
        guard let update, update.shouldNotify else {
            return
        }

        await publish(
            .notice(
                conversationID: conversationID,
                turnID: turnID,
                text: Self.memoryNotice(for: update)
            )
        )
    }

    /// Persists the completed user/assistant pair in the background. The User
    /// aggregate owns observation persistence, extraction, and policy.
    private static func recordCompletedMemory(
        observation: MemoryObservation,
        userID: NorbyDomain.UserID,
        conversationID: ConversationID,
        actorSystem: ClusterSystem,
        memoryExtractor: HailMemoryCandidateExtractor
    ) async -> MemoryUpdate? {
        do {
            let user = try await User.resolve(on: actorSystem, userID: userID)
            _ = try await user.recordObservation(observation)
            let userRecord = try await user.currentRecord()
            let context = MemoryExtractionContext(
                observation: observation,
                previousObservations: userRecord.memory.previousObservations(
                    before: observation.sourceID,
                    limit: 8
                ),
                existingFacts: Array(
                    userRecord.memory.currentFacts().suffix(32)
                )
            )
            let proposals = try await memoryExtractor.extract(from: context)
            return try await user.recordCompletedObservation(
                observation,
                proposals: proposals
            )
        } catch {
            actorSystem.log.warning(
                "Could not record completed user memory",
                metadata: [
                    "conversationID": .string(conversationID.stableKey),
                    "userID": .string(userID.rawValue),
                    "error": .string(String(describing: error)),
                ]
            )
            return nil
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
        case .completed(let turnID, let text):
            return .modelCompleted(turnID: turnID, text: text)
        case .failed(let turnID, let kind, let message):
            return .modelFailed(
                turnID: turnID,
                failure: ConversationFailure(kind: kind, message: message)
            )
        }
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
        if previous.capabilities != next.capabilities {
            events.append(.capabilitiesChanged(next.capabilities))
        }

        // Persist the terminal output before the lifecycle bookkeeping. The
        // reply event is the recovery point if the process crashes between
        // individual journal appends.
        events.append(contentsOf: newPendingReplies(
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

        events.append(contentsOf: newPendingMessages(
            from: previous.pendingMessages,
            to: next.pendingMessages
        ).map(ConversationEvent.messageQueued))

        events.append(contentsOf: deliveredReplies(
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
}
