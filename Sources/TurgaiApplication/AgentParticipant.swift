import Distributed
import DistributedCluster
import DurableWorkflows
import Hail
import TurgaiDomain
import TurgaiHail
import TurgaiMemory
import TurgaiObjects

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// An agent in a conversation, while the conversation is active: it runs the agent's turns the
/// conversation starts, one at a time, and shows what the agent does to whoever watches. It keeps
/// nothing: the conversation journals the turns, and the agent its own history.
public distributed actor AgentParticipant {
    public typealias ActorSystem = ClusterSystem

    /// Long enough for a follow-up exchange to join the same extraction batch.
    private static let extractionQuietPeriod: TimeInterval = 240

    /// The conversation it's in, which holds it.
    private weak var conversation: Conversation?
    private let conversationID: ConversationID
    private let peer: HailConversationPeer
    /// The turn it's running, if one is.
    private var running: (turnID: TurgaiDomain.TurnID, task: Task<Void, Never>)?
    /// The turn the agent is running, as what it does in it shows it.
    private var followedTurn: FollowedTurn?

    init(
        in conversation: Conversation, conversationID: ConversationID, role: String, actorSystem: ClusterSystem
    ) async throws {
        self.actorSystem = actorSystem
        self.conversation = conversation
        self.conversationID = conversationID
        self.peer = try await HailAgentAdapter(actorSystem: actorSystem, agentRole: role).peer(for: conversationID)
    }

    /// Runs the turn that answers `request`, on behalf of `turnScope`: the agent's reply, or why
    /// there's none, goes back to the conversation. A turn it was running is cancelled first.
    distributed func answer(
        _ request: ConversationTurnRequest, as turnScope: CallScope, memoryExtraction: MemoryExtractionConfiguration?
    ) {
        running?.task.cancel()
        let peer = self.peer
        let actorSystem = self.actorSystem
        let conversationID = self.conversationID
        let conversation = self.conversation
        let participant = self
        let scope = ConversationScope(
            conversationID: conversationID,
            turnID: request.turnID,
            broadcast: { event in
                try? await conversation?.publishLive(event)
            },
            phase: {
                await participant.whenLocal { $0.followedPhase() } ?? .thinking
            },
            complete: { completion in
                await participant.whenLocal { $0.ended(request.turnID) }
                try? await conversation?.modelEvent(.completed(turnID: request.turnID, completion: completion))
            },
            operation: {
                // The agent's turn starts a chain of its own, on behalf of whoever it answers: what
                // it calls comes from it. What it does meanwhile comes back with it, and reaches
                // whoever watches the conversation.
                let agentID = HailAgentAdapter.agentID(for: request.conversationID, role: request.agentRole)
                let response = try await CallChain.$current.withValue(.start(turnScope)) {
                    try await Agent.answering(as: agentID) {
                        try await peer.run(to: request) { event in
                            await participant.whenLocal { await $0.follow(event, of: request.turnID) }
                        }
                    }
                }
                await Self.remember(request, answered: response.reply.text, with: memoryExtraction, on: actorSystem)
                return .reply(response.reply)
            }
        )

        let task = Task {
            let failure: ConversationFailure
            do {
                _ = try await withScope(scope) { error in Self.modelFailure(for: error) }
                return
            } catch is CancellationError {
                failure = ConversationFailure(kind: .cancelled, message: "The model request was cancelled.")
            } catch let thrown as ConversationFailure {
                failure = thrown
                Self.log(failure.message, of: request, on: actorSystem)
            } catch {
                // The scope already published the mapped failure. The conversation still needs
                // it, so the durable turn closes, while the original error stays in the logs.
                failure = Self.modelFailure(for: error)
                Self.log(String(describing: error), of: request, on: actorSystem)
            }
            await participant.whenLocal { $0.ended(request.turnID) }
            try? await conversation?.modelEvent(
                .failed(turnID: request.turnID, kind: failure.kind, message: failure.message))
        }
        running = (request.turnID, task)
    }

    /// Stops the turn it's running, as a reset does.
    distributed func cancel() {
        running?.task.cancel()
        running = nil
    }

    /// The agent's past turns, step by step.
    distributed func turns() async throws -> [ConversationTurn] {
        try ConversationTurns.turns(of: try await peer.history())
    }

    /// What the agent holds in its context now.
    distributed func contextSnapshot() async throws -> AgentContextSnapshot {
        try await peer.contextSnapshot()
    }

    private func ended(_ turnID: TurgaiDomain.TurnID) {
        if running?.turnID == turnID { running = nil }
    }

    // MARK: Following the agent's turn

    /// One thing the agent did in the turn `turnID`, shown as part of it.
    private func follow(_ event: HailModelEvent, of turnID: TurgaiDomain.TurnID) async {
        if case .started = event {
            followedTurn = FollowedTurn(id: turnID)
            return
        }
        if case .completed = event {
            followedTurn = nil
            return
        }
        var turn = followedTurn ?? FollowedTurn(id: turnID)
        defer { followedTurn = turn }
        switch event {
        case .reasoning:
            await publish(phase: .thinking, of: &turn)
        case .status(let message):
            await publishLive(.reply(.status(conversationID: conversationID, turnID: turnID, message: message)))
        case .toolCalled(let name, let arguments, let at):
            await publishLive(
                .reply(.status(conversationID: conversationID, turnID: turnID, message: "Using \(name)…")))
            await publishLive(
                .reply(
                    .step(
                        conversationID: conversationID, turnID: turnID,
                        step: .toolCalled(name: name, arguments: arguments, at: at))))
        case .toolFinished(let name, let output, let failure, let at):
            await publishLive(
                .reply(
                    .step(
                        conversationID: conversationID, turnID: turnID,
                        step: .toolFinished(name: name, output: output, failure: failure, at: at))))
        case .reply(let text):
            await publish(phase: .typing, of: &turn)
            turn.text = text
            await publishLive(.reply(.partial(conversationID: conversationID, turnID: turnID, text: turn.text)))
        case .needed(let request):
            // The turn's scope didn't allow it: the conversation that opened it asks its group, in
            // the turn's own chain.
            do {
                try await conversation?.needed(request)
            } catch {
                actorSystem.log.error(
                    "Could not ask for what a turn needed",
                    metadata: ["request": .string("\(request)"), "error": .string("\(error)")])
            }
        case .started, .completed:
            break
        }
    }

    private func publish(phase: ReplyPhase, of turn: inout FollowedTurn) async {
        guard turn.phase != phase else { return }
        turn.phase = phase
        await publishLive(.reply(.phase(conversationID: conversationID, turnID: turn.id, phase: phase)))
    }

    private func publishLive(_ event: OutboundEvent) async {
        try? await conversation?.publishLive(event)
    }

    private func followedPhase() -> ReplyPhase {
        followedTurn?.phase ?? .thinking
    }

    // MARK: After a turn

    /// What was said and answered in `request`, kept for the person's memory when it's on.
    private static func remember(
        _ request: ConversationTurnRequest, answered response: String,
        with configuration: MemoryExtractionConfiguration?, on actorSystem: ClusterSystem
    ) async {
        let text = request.message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let configuration, configuration.isEnabled else { return }
        let observation = MemoryObservation(
            id: ObservationID(rawValue: request.message.id.rawValue),
            sourceID: MemorySourceID(rawValue: request.message.id.rawValue),
            text: request.message.text,
            response: response,
            observedAt: request.message.receivedAt
        )
        let workflowInput = MemoryExtractionWorkflowInput(
            userID: request.message.userID,
            observation: observation,
            configuration: configuration,
            fireAt: Date().addingTimeInterval(Self.extractionQuietPeriod)
        )
        do {
            _ = try await actorSystem.workflows.start(
                type: MemoryExtractionWorkflow.self,
                options: WorkflowOptions(
                    id: MemoryExtractionWorkflow.id(userID: request.message.userID, sourceID: observation.sourceID),
                    retryPolicy: MemoryExtractionWorkflow.retryPolicy
                ),
                input: workflowInput
            )
        } catch WorkflowRuntimeError.workflowInputMismatch {
            // A replay of this source already has a durable timer. Its original input remains
            // authoritative.
            actorSystem.log.info(
                "Memory extraction workflow already exists",
                metadata: ["source": .string(observation.sourceID.rawValue.uuidString)]
            )
        } catch {
            actorSystem.log.error(
                "Could not start memory extraction workflow",
                metadata: [
                    "source": .string(observation.sourceID.rawValue.uuidString),
                    "error": .string(String(describing: error)),
                ]
            )
        }
        do {
            let user = try await User.resolve(on: actorSystem, userID: request.message.userID)
            try await user.recordObservation(observation)
        } catch {
            actorSystem.log.warning(
                "Could not record memory observation",
                metadata: ["error": .string(String(describing: error))]
            )
        }
    }

    static func modelFailure(for error: any Error) -> ConversationFailure {
        ConversationFailure(kind: .model, message: HailAgentAdapter.userFacingMessage(for: error))
    }

    private static func log(_ error: String, of request: ConversationTurnRequest, on actorSystem: ClusterSystem) {
        actorSystem.log.error(
            "Model turn failed",
            metadata: [
                "conversationID": .string(request.conversationID.stableKey),
                "turnID": .string(request.turnID.rawValue.uuidString),
                "error": .string(error),
            ]
        )
    }
}

/// The turn whose activity a participant is following: what it shows, so far.
private struct FollowedTurn: Sendable {
    let id: TurgaiDomain.TurnID
    var phase: ReplyPhase = .thinking
    var text = ""
}

/// The application-side interpreter for one scoped model output.
///
/// It resolves the live connections for every lifecycle event. This matters after recovery: a
/// channel connection may reconnect while the durable turn is still running, and the terminal
/// reply must reach that new connection.
private struct ConversationScope: ScopeLifecycle {
    typealias Result = ConversationCompletion
    typealias Update = Never

    let conversationID: ConversationID
    let turnID: TurgaiDomain.TurnID
    let broadcast: @Sendable (OutboundEvent) async -> Void
    /// What the turn is doing now, which the participant follows from the agent's activity.
    let phase: @Sendable () async -> ReplyPhase
    let complete: @Sendable (ConversationCompletion) async -> Void
    let operation: @Sendable () async throws -> ConversationCompletion

    func start() async {}

    func heartbeat() async {
        await broadcast(.reply(.keepAlive(conversationID: conversationID, turnID: turnID, phase: await phase())))
    }

    func perform(using _: PartialSink<Never>) async throws -> ConversationCompletion {
        try await operation()
    }

    func update(_ update: Never) async {}

    func finish(_ outcome: ScopeOutcome<ConversationCompletion>) async {
        switch outcome {
        case .completed(let completion):
            // Persist first. A reply is delivered from the durable pending projection; a void
            // completion publishes only the lifecycle terminal event.
            await complete(completion)
        case .failed(let failure):
            await broadcast(.reply(.failed(conversationID: conversationID, turnID: turnID, message: failure.message)))
        case .cancelled:
            break
        }
    }
}
