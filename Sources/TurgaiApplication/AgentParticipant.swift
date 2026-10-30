import Distributed
import DistributedCluster
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
    private static let extractionQuietPeriod: Duration = .seconds(240)
    /// How long a failed extraction waits before it's tried again, each time.
    private static let extractionRetries: [Duration] = [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(80)]

    /// The conversation it's in, which holds it.
    private weak var conversation: Conversation?
    private let conversationID: ConversationID
    private let peer: HailConversationPeer
    /// The turn it's running, if one is.
    private var running: (turnID: TurgaiDomain.TurnID, task: Task<Void, Never>)?
    /// The turn the agent is running, as what it does in it shows it.
    private var followedTurn: FollowedTurn?
    /// The pass that extracts what was said once its author has been quiet, while it waits or runs.
    private var rememberingPass: Task<Void, Never>?

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
                // The agent's turn starts a chain of its own, on behalf of whoever it answers, in
                // the conversation it answers in: what it calls comes from it. What it does
                // meanwhile comes back with it, and reaches whoever watches the conversation.
                let agentID = HailAgentAdapter.agentID(for: request.conversationID, role: request.agentRole)
                let conversationKey = request.conversationID.stableKey
                let turn = request.turnID.rawValue
                let started = ContinuousClock.now
                actorSystem.log.debug("Turn started", metadata: ["conversation": "\(conversationKey)", "turn": "\(turn)"])
                let response = try await CallChain.$current.withValue(.start(turnScope, in: request.conversationID)) {
                    try await Agent.answering(as: agentID) {
                        try await peer.run(to: request) { event in
                            await participant.whenLocal { await $0.follow(event, of: request.turnID) }
                        }
                    }
                }
                actorSystem.log.debug(
                    "Turn answered",
                    metadata: [
                        "conversation": "\(conversationKey)", "turn": "\(turn)", "took": "\(ContinuousClock.now - started)",
                    ])
                await participant.whenLocal {
                    await $0.remember(request, answered: response.reply.text, with: memoryExtraction)
                }
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

    /// What was said and answered in `request`, kept for its author's memory when memory is set up
    /// and they remember: the wait for them to go quiet starts over, and once they have, what they
    /// said is extracted.
    private func remember(
        _ request: ConversationTurnRequest, answered response: String,
        with configuration: MemoryExtractionConfiguration?
    ) async {
        let text = request.message.text.trimmed()
        guard !text.isEmpty, let configuration, configuration.isEnabled,
            let endpoints = try? await actorSystem.installedTurgaiChannelRuntime?.dependencies().endpoints
        else { return }
        let observation = MemoryObservation(
            id: ObservationID(rawValue: request.message.id.rawValue),
            sourceID: MemorySourceID(rawValue: request.message.id.rawValue),
            text: request.message.text,
            response: response,
            observedAt: request.message.receivedAt
        )
        do {
            let user = try await User.resolve(on: actorSystem, userID: request.message.userID)
            guard try await user.currentRemembering() == .on else { return }
            try await user.recordObservation(observation)
            extractOnceQuiet(
                for: user, after: observation.sourceID, with: configuration, from: endpoints,
                noting: NotedMessage(id: request.message.id, channelID: request.message.channelMessageID))
        } catch {
            actorSystem.log.warning(
                "Could not record memory observation",
                metadata: ["error": .string(String(describing: error))]
            )
        }
    }

    /// Extracts what `user` said once they've been quiet, unless they say something else first: the
    /// pass waiting is cancelled, and this one waits instead. `message`, the last they said here, is
    /// marked when something was noted.
    private func extractOnceQuiet(
        for user: User, after latest: MemorySourceID, with configuration: MemoryExtractionConfiguration,
        from endpoints: AgentModelEndpointFactory, noting message: NotedMessage
    ) {
        rememberingPass?.cancel()
        let actorSystem = self.actorSystem
        rememberingPass = Task {
            let noted = await MemoryPass.run(
                after: Self.extractionQuietPeriod, retries: Self.extractionRetries,
                extract: {
                    // Asked again: they may have stopped remembering while it waited.
                    guard try await user.currentRemembering() == .on else { return .alreadyHandled }
                    return try await MemoryExtractionService.extractAndCommit(
                        endpoint: try await MemoryExtractionService.endpoint(for: configuration, from: endpoints),
                        actorSystem: actorSystem,
                        user: user,
                        expectedLatestSourceID: latest
                    )
                },
                failed: { error in
                    actorSystem.log.warning(
                        "Memory extraction failed", metadata: ["error": .string(String(describing: error))])
                }
            )
            guard !Task.isCancelled else { return }
            rememberingPass = nil
            if noted { try? await conversation?.noted(message) }
        }
    }

    /// Whether it waits to extract what was said, or extracts it now.
    var isRemembering: Bool {
        rememberingPass != nil
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
