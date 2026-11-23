import Distributed
import DistributedCluster
import Hail
import TurgaiCalls
import TurgaiDomain
import TurgaiHail
import TurgaiMemory
import TurgaiPeople

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

    /// The conversation it's in, which holds it.
    private weak var conversation: Conversation?
    private let conversationID: ConversationID
    /// The space whose conversation it's in.
    private let space: SpaceID
    /// The agent's id in the cluster: its bot's role in the conversation of its space.
    private let agentID: AgentID
    private let peer: HailConversationPeer
    /// The turn it's running, if one is.
    private var running: (turnID: TurgaiDomain.TurnID, task: Task<Void, Never>)?
    /// The agent's turn each of its turns opened, until it ends: what a failure or a cancellation
    /// links to, as a reply does on its own.
    private var agentTurns: [TurgaiDomain.TurnID: AgentTurnID] = [:]
    /// The turn the agent is running, as what it does in it shows it.
    private var followedTurn: FollowedTurn?
    /// The request naming the conversation, while one runs.
    private var namingPass: Task<Void, Never>?

    init(
        in conversation: Conversation, conversationID: ConversationID, of space: SpaceID, role: String,
        actorSystem: ClusterSystem
    ) async throws {
        self.actorSystem = actorSystem
        self.conversation = conversation
        self.conversationID = conversationID
        self.space = space
        self.agentID = HailAgentAdapter.agentID(for: conversationID, in: space, role: role)
        self.peer = try await HailAgentAdapter(actorSystem: actorSystem, agentRole: role, space: space)
            .peer(for: conversationID)
    }

    /// Runs the turn that answers `request`, on behalf of `turnScope`: the agent's reply, or why
    /// there's none, goes back to the conversation. A turn it was running is cancelled first.
    distributed func answer(
        _ request: ConversationTurnRequest, as turnScope: CallScope
    ) {
        running?.task.cancel()
        let peer = self.peer
        let actorSystem = self.actorSystem
        let conversationID = self.conversationID
        let conversation = self.conversation
        let participant = self
        let agentID = self.agentID
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
                _ = await participant.whenLocal { $0.ended(request.turnID) }
                try? await conversation?.modelEvent(.completed(turnID: request.turnID, completion: completion))
            },
            operation: {
                // The agent's turn starts a chain of its own, on behalf of whoever it answers, in
                // the conversation it answers in: what it calls comes from it. What it does
                // meanwhile comes back with it, and reaches whoever watches the conversation.
                let conversationKey = request.conversationID.stableKey
                let turn = request.turnID.rawValue
                let started = ContinuousClock.now
                actorSystem.log.debug(
                    "Turn started", metadata: ["conversation": "\(conversationKey)", "turn": "\(turn)"])
                let response = try await CallChain.$current.withValue(.start(turnScope, in: request.conversationID)) {
                    try await peer.run(to: request) { event in
                        await participant.whenLocal { await $0.follow(event, of: request.turnID) }
                    }
                }
                actorSystem.log.debug(
                    "Turn answered",
                    metadata: [
                        "conversation": "\(conversationKey)", "turn": "\(turn)",
                        "took": "\(ContinuousClock.now - started)",
                    ])
                await participant.whenLocal {
                    await $0.remember(request, answered: response.reply.text)
                    $0.nameIfUntitled(after: request, answered: response.reply.text)
                }
                return .reply(response.reply, agentTurn: response.agentTurn)
            }
        )

        let task = Task {
            let failure: ConversationFailure
            do {
                _ = try await withScope(scope) { error in Self.modelFailure(for: error) }
                return
            } catch is CancellationError {
                failure = ConversationFailure(kind: .cancelled, message: "Stopped.")
            } catch let thrown as ConversationFailure {
                failure = thrown
                Self.log(failure.message, of: request, on: actorSystem)
            } catch {
                // The scope already published the mapped failure. The conversation still needs
                // it, so the durable turn closes, while the original error stays in the logs.
                failure = Self.modelFailure(for: error)
                Self.log(String(describing: error), of: request, on: actorSystem)
            }
            let agentTurn = await participant.whenLocal { $0.ended(request.turnID) } ?? nil
            try? await conversation?.modelEvent(
                .failed(turnID: request.turnID, kind: failure.kind, message: failure.message, agentTurn: agentTurn))
        }
        running = (request.turnID, task)
    }

    /// Stops the turn it's running, as a reset does.
    distributed func cancel() {
        running?.task.cancel()
        running = nil
    }

    /// What the agent holds in its context now.
    distributed func contextSnapshot() async throws -> AgentContextSnapshot {
        try await peer.contextSnapshot()
    }

    /// The turn `turnID` ended: the agent's turn it opened, if it did.
    private func ended(_ turnID: TurgaiDomain.TurnID) -> AgentTurnID? {
        if running?.turnID == turnID { running = nil }
        return agentTurns.removeValue(forKey: turnID)
    }

    // MARK: Following the agent's turn

    /// One thing the agent did in the turn `turnID`, shown as part of it.
    private func follow(_ event: HailModelEvent, of turnID: TurgaiDomain.TurnID) async {
        if case .started(let agentTurn) = event {
            agentTurns[turnID] = agentTurn
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
            // The turn's scope didn't allow it: the conversation that opened it asks its space, in
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

    /// What was said and answered in `request`, kept for its author's memory when they remember: the
    /// conversation is told it heard it, and its owner reads it once they've been quiet.
    private func remember(_ request: ConversationTurnRequest, answered response: String) async {
        guard !request.message.text.trimmed().isEmpty else { return }
        let observation = MemoryObservation(
            id: ObservationID(rawValue: request.message.id.rawValue),
            sourceID: MemorySourceID(rawValue: request.message.id.rawValue),
            conversation: request.conversationID,
            heardBy: request.bot,
            channelMessageID: request.message.channelMessageID,
            text: request.message.text,
            response: response,
            observedAt: request.message.receivedAt
        )
        do {
            let user = try await User.identified(by: request.message.userID, on: actorSystem)
            guard try await user.currentRemembering() == .on else { return }
            try await user.recordObservation(observation)
            try await conversation?.heard(observation, of: request.message.userID)
        } catch {
            actorSystem.log.warning(
                "Could not record memory observation",
                metadata: ["error": .string(String(describing: error))]
            )
        }
    }

    /// Names the conversation from `request` and its answer, when it has no title yet: one request
    /// to its agent's model, as its node's agent runtime gives it, while the conversation goes on.
    /// One that fails leaves it for the next turn.
    private func nameIfUntitled(after request: ConversationTurnRequest, answered response: String) {
        guard namingPass == nil, let conversation else { return }
        let actorSystem = self.actorSystem
        let agentID = self.agentID
        namingPass = Task {
            do {
                if try await conversation.untitled() {
                    let runtime = actorSystem.agentRuntime
                    let model = try await runtime.modelConfiguration(for: agentID).model
                    let endpoint = try await runtime.endpoint(for: model.identifier, agentID: agentID)
                    let name = try await ConversationNamingService.name(
                        endpoint: endpoint, said: request.message.text, answered: response)
                    if let title = ConversationTitle(name.title) { try await conversation.name(title) }
                }
            } catch {
                actorSystem.log.warning(
                    "Could not name the conversation", metadata: ["error": .string(String(describing: error))])
            }
            namingPass = nil
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
