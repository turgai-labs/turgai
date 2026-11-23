import Testing

@testable import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct ConversationReducerTests {
    private let conversationID = ConversationID(
        channel: ChannelID("test"),
        externalAddress: ExternalConversationAddress("conversation-1")
    )
    private let participantID = ParticipantID("user-1")
    private let person = UserID.telegram(1)
    /// The bot that answers in these turns.
    private let answering = BotID()
    /// When the model answers, in these turns.
    private let replied = Date(timeIntervalSince1970: 3)
    /// The agent's turn that answers, in these turns.
    private let agentTurn = AgentTurnID(rawValue: "agent-turn-1")

    /// What `action` comes to, as the conversation runs it: its events applied, and its effects.
    private func step(
        _ state: ConversationState, _ action: ConversationAction
    ) -> (ConversationState, [ConversationEffect]) {
        let decision = ConversationDecision(action, in: state)
        return (state.applying(decision.events), decision.effects)
    }

    /// A turn that needed what its scope didn't allow waits for the answer, which continues it:
    /// its asker is told the answer, as their next message, whoever gave it.
    @Test
    func anAnswerContinuesTheTurnThatWaitedForIt() {
        let asked = InboundMessage(
            conversationID: conversationID, participantID: participantID, userID: person,
            text: "What's the forecast?",
            receivedAt: Date(timeIntervalSince1970: 1))
        let turn = TurnID()
        var state = step(
            ConversationState(conversationID: conversationID),
            .receive(message: asked, turnID: turn, bot: answering)
        ).0
        let forecast = ExactRequest.http(method: "GET", url: "https://example.com/forecast", body: Data())
        let request = AccessRequest(
            id: AccessRequestID(UUID()), request: forecast, by: .person(asked.userID), standing: .waiting)

        state = step(state, .awaiting(request.id)).0
        #expect(state.awaiting[request.id]?.message == asked)
        // The same request again is the same wait.
        #expect(ConversationDecision(.awaiting(request.id), in: state).events.isEmpty)
        state = step(state, .modelCompleted(turnID: turn, completion: .void, at: replied)).0

        let next = TurnID()
        let (continued, effects) = step(
            state, .answered(request, .once, turnID: next, at: Date(timeIntervalSince1970: 2)))
        #expect(continued.awaiting.isEmpty)
        guard case .runReply(let reply)? = effects.first else {
            Issue.record("the waiting turn didn't continue")
            return
        }
        #expect(reply.turnID == next)
        #expect(reply.message.userID == asked.userID)
        #expect(reply.message.text == "Allowed once: GET https://example.com/forecast")
        // An answer no turn waits for continues nothing.
        #expect(
            ConversationDecision(.answered(request, .no, turnID: TurnID(), at: Date()), in: continued).events.isEmpty)
    }

    /// The only one in a conversation, or someone who may delete any in its space, deletes it; anyone else may only
    /// leave it. Deleted, no one reads it.
    @Test
    func theOnlyOneOrWhoeverMayDeleteAnyDeletesIt() throws {
        let other = UserID.telegram(2)
        var state = ConversationState(conversationID: conversationID)
        state = state.applying(try state.starting(with: BotID(), by: person))
        #expect(throws: ConversationRefusal.notInIt) { try state.deleting(by: other, mayDeleteAny: true) }

        let alone = state
        #expect(try alone.deleting(by: person, mayDeleteAny: false) == [.deleted(by: person)])

        state = state.applying([.joined(.person(other))])
        #expect(throws: ConversationRefusal.othersAreInIt) { try state.deleting(by: person, mayDeleteAny: false) }
        state = state.applying(try state.deleting(by: other, mayDeleteAny: true))
        #expect(throws: ConversationRefusal.deleted) { try state.reading(by: person) }
        #expect(throws: ConversationRefusal.deleted) { try state.leaving(person) }
    }

    /// What `/link` asks for, however the code is typed.
    @Test
    func linkAsksForWhatsGiven() {
        #expect(LinkAsk(nil) == .newCode)
        #expect(LinkAsk("") == .newCode)
        #expect(LinkAsk("k7q-4p2") == .code(LinkCode("K7Q4P2")!))
        #expect(LinkAsk(" K7Q 4P2 ") == .code(LinkCode("K7Q-4P2")!))
        #expect(LinkAsk("hello") == .notACode("hello"))
        #expect(LinkAsk("K7Q-4P0") == .notACode("K7Q-4P0"))
        #expect(LinkCode("k7q4p2")!.description == "K7Q-4P2")
    }

    @Test
    func participantIdentityIsChannelScoped() {
        let telegram = ParticipantID(channel: ChannelID("telegram"), rawValue: "42")
        let discord = ParticipantID(channel: ChannelID("discord"), rawValue: "42")

        #expect(telegram != discord)
        #expect(telegram.stableKey == "telegram:42")
    }

    @Test
    func conversationIDRoundTripsItsStableKey() {
        let original = ConversationID(
            channel: ChannelID("telegram"),
            externalAddress: ExternalConversationAddress("chat:42")
        )

        #expect(ConversationID(stableKey: original.stableKey) == original)
        #expect(ConversationID(stableKey: "missing-separator") == nil)
    }

    @Test
    func conversationPersistenceIDRoundTripsItsRawValue() {
        let original = ConversationID(
            channel: ChannelID("telegram"),
            externalAddress: ExternalConversationAddress("chat:42")
        )
        let space = SpaceID()
        let persistenceID = ConversationPersistenceID(space: space, conversationID: original)

        #expect(ConversationPersistenceID(rawValue: persistenceID.rawValue)?.space == space)
        #expect(
            ConversationPersistenceID(rawValue: persistenceID.rawValue)?.conversationID
                == original
        )
        #expect(ConversationPersistenceID(rawValue: "other-journal") == nil)
    }

    private func makeMessage(
        id: UUID = UUID(),
        text: String,
        at: Date = Date(timeIntervalSince1970: 100)
    ) -> InboundMessage {
        InboundMessage(
            id: MessageID(rawValue: id),
            conversationID: conversationID,
            participantID: participantID,
            userID: person,
            text: text,
            receivedAt: at
        )
    }

    private func makeTurnID(_ value: UInt8) -> TurnID {
        TurnID(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value)))
    }

    private func makeReply(_ text: String) -> ConversationReply {
        ConversationReply(text)!
    }

    @Test
    func receivingMessageStartsTurnAndPersists() {
        let state = ConversationState(conversationID: conversationID)

        let (next, effects) = step(
            state,
            .receive(message: makeMessage(text: "  hello  "), turnID: makeTurnID(1), bot: answering)
        )

        guard case .running(let turnID) = next.inbox.status else {
            Issue.record("Expected a running turn")
            return
        }
        #expect(next.inbox.pendingMessages.isEmpty)
        #expect(
            effects.contains(where: { effect in
                if case .runReply(let request) = effect {
                    return request.conversationID == conversationID
                        && request.turnID == turnID
                        && request.message.text == "hello"
                }
                return false
            }))
    }

    @Test
    func messagesReceivedDuringTurnAreQueuedAndProcessedInOrder() {
        let initial = ConversationState(conversationID: conversationID)
        let (running, _) = step(
            initial,
            .receive(message: makeMessage(text: "first"), turnID: makeTurnID(1), bot: answering)
        )
        guard case .running(let firstTurnID) = running.inbox.status else {
            Issue.record("Expected first turn to be running")
            return
        }

        let (queued, _) = step(
            running,
            .receive(message: makeMessage(text: "second"), turnID: makeTurnID(2), bot: answering)
        )
        #expect(queued.inbox.pendingMessages.count == 1)

        let (completed, completionEffects) = step(
            queued,
            .modelCompleted(
                turnID: firstTurnID,
                completion: .reply(makeReply("first answer"), agentTurn: agentTurn),
                at: replied
            )
        )

        guard case .running(let secondTurnID) = completed.inbox.status else {
            Issue.record("Expected queued message to start a second turn")
            return
        }
        #expect(completed.inbox.pendingMessages.isEmpty)
        #expect(
            completionEffects.contains(where: { effect in
                if case .runReply(let request) = effect {
                    return request.turnID == secondTurnID
                        && request.message.text == "second"
                }
                return false
            }))
    }

    @Test
    func receivingTheSameMessageAgainIsIdempotent() {
        let message = makeMessage(text: "scheduled prompt")
        let initial = ConversationState(conversationID: conversationID)
        let (running, _) = step(
            initial,
            .receive(
                message: message,
                turnID: makeTurnID(1),
                bot: answering
            )
        )
        guard case .running(let turnID) = running.inbox.status else {
            Issue.record("Expected the first message to start a turn")
            return
        }

        let (completed, _) = step(
            running,
            .modelCompleted(
                turnID: turnID,
                completion: .reply(makeReply("answer"), agentTurn: agentTurn),
                at: replied
            )
        )
        let (duplicate, effects) = step(
            completed,
            .receive(
                message: message,
                turnID: makeTurnID(2),
                bot: answering
            )
        )

        #expect(duplicate == completed)
        #expect(effects.isEmpty)
    }

    @Test
    func modelCompletionDoesNotPublishBecauseReplyScopeOwnsDelivery() {
        let state = ConversationState(conversationID: conversationID)
        let (running, _) = step(
            state,
            .receive(message: makeMessage(text: "hello"), turnID: makeTurnID(1), bot: answering)
        )
        guard case .running(let turnID) = running.inbox.status else {
            Issue.record("Expected a running turn")
            return
        }

        let (completed, effects) = step(
            running,
            .modelCompleted(
                turnID: turnID,
                completion: .reply(makeReply("hello"), agentTurn: agentTurn),
                at: replied
            )
        )

        #expect(completed.inbox.status == .idle)
        #expect(
            completed.pendingReplies == [
                PendingConversationReply(
                    turnID: turnID,
                    reply: ConversationReply("hello")!,
                    agentTurn: agentTurn,
                    at: replied
                )
            ])
        #expect(effects.isEmpty)
        // The conversation keeps which of the agent's turns answered it.
        #expect(completed.agentTurns == [agentTurn: turnID])

        let (delivered, deliveryEffects) = step(
            completed,
            .replyDelivered(turnID: turnID)
        )
        #expect(delivered.pendingReplies.isEmpty)
        #expect(deliveryEffects.isEmpty)
    }

    @Test
    func voidCompletionClosesTurnWithoutQueueingReply() {
        let state = ConversationState(conversationID: conversationID)
        let (running, _) = step(
            state,
            .receive(message: makeMessage(text: "work"), turnID: makeTurnID(1), bot: answering)
        )
        guard case .running(let turnID) = running.inbox.status else {
            Issue.record("Expected a running turn")
            return
        }

        let (completed, effects) = step(
            running,
            .modelCompleted(turnID: turnID, completion: .void, at: replied)
        )

        #expect(completed.inbox.status == .idle)
        #expect(completed.pendingReplies.isEmpty)
        #expect(
            effects == [
                .publish(
                    .reply(
                        .completed(
                            conversationID: conversationID,
                            turnID: turnID
                        )
                    )
                )
            ])
    }

    @Test
    func recoveryRestartsRunningTurnWithoutChangingItsState() {
        let pending = PendingConversationMessage(
            message: makeMessage(text: "hello"),
            turnID: makeTurnID(1),
            bot: answering
        )
        let running = ConversationState(conversationID: conversationID).applying([.inbox(.turnStarted(pending))])

        let (recovered, effects) = step(running, .resume)

        #expect(recovered == running)
        #expect(
            effects == [
                .runReply(
                    ConversationTurnRequest(
                        conversationID: conversationID,
                        turnID: pending.turnID,
                        message: pending.message,
                        bot: pending.bot
                    )
                )
            ])
    }

    @Test
    func recoveryStartsAQueuedTurnLeftAfterAnIdleCrashWindow() {
        let pending = PendingConversationMessage(
            message: makeMessage(text: "queued"),
            turnID: makeTurnID(1),
            bot: answering
        )
        // Queued, and then the process stopped before its turn started.
        let state = ConversationState(conversationID: conversationID).applying([.inbox(.queued(pending))])

        let (recovered, effects) = step(state, .resume)

        #expect(recovered.inbox.status == .running(pending.turnID))
        #expect(recovered.inbox.activeMessage == pending)
        #expect(recovered.inbox.pendingMessages.isEmpty)
        #expect(
            effects.contains(where: { effect in
                if case .runReply(let request) = effect {
                    return request.turnID == pending.turnID
                }
                return false
            }))
    }

    @Test
    func staleModelEventsAreIgnored() {
        let state = ConversationState(conversationID: conversationID)
        let (running, _) = step(
            state,
            .receive(message: makeMessage(text: "hello"), turnID: makeTurnID(1), bot: answering)
        )
        let staleTurnID = makeTurnID(99)

        let (next, effects) = step(
            running,
            .modelCompleted(
                turnID: staleTurnID,
                completion: .reply(makeReply("stale"), agentTurn: agentTurn),
                at: replied
            )
        )

        #expect(next == running)
        #expect(effects.isEmpty)
    }

    /// A message waiting when a turn fails is the person's next word: it starts right away, as
    /// after a reply. With nothing waiting, the failure stays until it's cleared.
    @Test
    func aFailedTurnLetsTheNextQueuedMessageStart() {
        let state = ConversationState(conversationID: conversationID)
        let (running, _) = step(
            state,
            .receive(message: makeMessage(text: "first"), turnID: makeTurnID(1), bot: answering)
        )
        let (queued, _) = step(
            running,
            .receive(message: makeMessage(text: "second"), turnID: makeTurnID(2), bot: answering)
        )
        let failure = ConversationFailure(kind: .model, message: "Ollama unavailable")
        let (next, effects) = step(
            queued, .modelFailed(turnID: makeTurnID(1), failure: failure, agentTurn: nil, at: replied))

        #expect(next.inbox.status == .running(makeTurnID(2)))
        #expect(next.inbox.pendingMessages.isEmpty)
        #expect(
            effects.contains(where: { effect in
                if case .runReply = effect { return true }
                return false
            }))

        let (failed, failureEffects) = step(
            next, .modelFailed(turnID: makeTurnID(2), failure: failure, agentTurn: nil, at: replied))
        #expect(failed.inbox.status == .failed(failure))
        #expect(failureEffects.isEmpty)
    }

    @Test
    func resetCancelsActiveTurnAndClearsConversation() {
        let state = ConversationState(conversationID: conversationID)
        let (running, _) = step(
            state,
            .receive(message: makeMessage(text: "hello"), turnID: makeTurnID(1), bot: answering)
        )
        guard case .running(let turnID) = running.inbox.status else {
            Issue.record("Expected a running turn")
            return
        }

        let (reset, effects) = step(running, .reset)

        #expect(reset.inbox.status == .idle)
        #expect(reset.inbox.pendingMessages.isEmpty)
        #expect(effects.contains(.cancelModel(turnID)))
        #expect(effects.contains(.publish(.reset(conversationID: conversationID))))
    }

    /// Stopping cancels the turn running and keeps everything said; the model's failure, as
    /// cancelled, then closes the turn. With nothing running, it does nothing.
    @Test
    func stopCancelsTheRunningTurnAndKeepsTheConversation() {
        let state = ConversationState(conversationID: conversationID)
        let (running, _) = step(
            state,
            .receive(message: makeMessage(text: "hello"), turnID: makeTurnID(1), bot: answering)
        )
        guard case .running(let turnID) = running.inbox.status else {
            Issue.record("Expected a running turn")
            return
        }

        let (stopped, effects) = step(running, .stop)

        #expect(stopped == running)
        #expect(effects == [.cancelModel(turnID)])

        let (idle, idleEffects) = step(state, .stop)
        #expect(idle == state)
        #expect(idleEffects.isEmpty)
    }

    @Test
    func emptyInputProducesErrorWithoutChangingState() {
        let state = ConversationState(conversationID: conversationID)
        let (next, effects) = step(
            state,
            .receive(message: makeMessage(text: " \n\t "), turnID: makeTurnID(1), bot: answering)
        )

        #expect(next == state)
        #expect(
            effects == [
                .publish(
                    .reply(
                        .failed(
                            conversationID: conversationID,
                            turnID: nil,
                            message: "Message cannot be empty."
                        )
                    )
                )
            ])
    }

    @Test
    func emptyInputDuringRunningTurnDoesNotFailTheTurn() {
        let state = ConversationState(conversationID: conversationID)
        let (running, _) = step(
            state,
            .receive(message: makeMessage(text: "hello"), turnID: makeTurnID(1), bot: answering)
        )
        guard case .running(let turnID) = running.inbox.status else {
            Issue.record("Expected a running turn")
            return
        }

        let (next, effects) = step(
            running,
            .receive(message: makeMessage(text: "  "), turnID: makeTurnID(2), bot: answering)
        )

        #expect(next == running)
        #expect(
            effects == [
                .publish(
                    .reply(
                        .failed(
                            conversationID: conversationID,
                            turnID: nil,
                            message: "Message cannot be empty."
                        )
                    )
                )
            ])
        #expect(next.inbox.status == .running(turnID))
    }

    /// Its agent names it only while it has no title: one its people gave it stays.
    @Test
    func itsAgentNamesItOnlyWhileUntitled() {
        let untitled = ConversationState(conversationID: conversationID)
        let dinner = ConversationTitle("Dinner")!
        #expect(untitled.naming(dinner) == [.titled(dinner)])
        let titled = untitled.applying([.titled(ConversationTitle("Plans")!)])
        #expect(titled.naming(dinner).isEmpty)
    }
}
