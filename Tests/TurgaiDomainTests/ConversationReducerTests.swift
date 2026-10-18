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

    @Test
    func participantAndUserIdentityAreChannelScoped() {
        let telegram = ParticipantID(channel: ChannelID("telegram"), rawValue: "42")
        let discord = ParticipantID(channel: ChannelID("discord"), rawValue: "42")

        #expect(telegram != discord)
        #expect(telegram.stableKey == "telegram:42")
        #expect(UserID(participantID: telegram) != UserID(participantID: discord))
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
        let persistenceID = ConversationPersistenceID(conversationID: original)

        #expect(
            ConversationPersistenceID(rawValue: persistenceID.rawValue)?.conversationID
                == original
        )
        #expect(ConversationPersistenceID(rawValue: "other-journal") == nil)
    }

    @Test
    func inboundMessageDefaultsToItsParticipantUser() {
        let message = InboundMessage(
            conversationID: conversationID,
            participantID: participantID,
            text: "hello",
            receivedAt: Date(timeIntervalSince1970: 1)
        )

        #expect(message.userID == UserID(participantID: participantID))
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

        let (next, effects) = reduce(
            state,
            .receive(message: makeMessage(text: "  hello  "), turnID: makeTurnID(1), agentRole: "test")
        )

        guard case .running(let turnID) = next.status else {
            Issue.record("Expected a running turn")
            return
        }
        #expect(next.pendingMessages.isEmpty)
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
        let (running, _) = reduce(
            initial,
            .receive(message: makeMessage(text: "first"), turnID: makeTurnID(1), agentRole: "test")
        )
        guard case .running(let firstTurnID) = running.status else {
            Issue.record("Expected first turn to be running")
            return
        }

        let (queued, _) = reduce(
            running,
            .receive(message: makeMessage(text: "second"), turnID: makeTurnID(2), agentRole: "test")
        )
        #expect(queued.pendingMessages.count == 1)

        let (completed, completionEffects) = reduce(
            queued,
            .modelCompleted(
                turnID: firstTurnID,
                completion: .reply(makeReply("first answer"))
            )
        )

        guard case .running(let secondTurnID) = completed.status else {
            Issue.record("Expected queued message to start a second turn")
            return
        }
        #expect(completed.pendingMessages.isEmpty)
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
        let (running, _) = reduce(
            initial,
            .receive(
                message: message,
                turnID: makeTurnID(1),
                agentRole: "test"
            )
        )
        guard case .running(let turnID) = running.status else {
            Issue.record("Expected the first message to start a turn")
            return
        }

        let (completed, _) = reduce(
            running,
            .modelCompleted(
                turnID: turnID,
                completion: .reply(makeReply("answer"))
            )
        )
        let (duplicate, effects) = reduce(
            completed,
            .receive(
                message: message,
                turnID: makeTurnID(2),
                agentRole: "test"
            )
        )

        #expect(duplicate == completed)
        #expect(effects.isEmpty)
    }

    @Test
    func modelCompletionDoesNotPublishBecauseReplyScopeOwnsDelivery() {
        let state = ConversationState(conversationID: conversationID)
        let (running, _) = reduce(
            state,
            .receive(message: makeMessage(text: "hello"), turnID: makeTurnID(1), agentRole: "test")
        )
        guard case .running(let turnID) = running.status else {
            Issue.record("Expected a running turn")
            return
        }

        let (completed, effects) = reduce(
            running,
            .modelCompleted(
                turnID: turnID,
                completion: .reply(makeReply("hello"))
            )
        )

        #expect(completed.status == .idle)
        #expect(
            completed.pendingReplies == [
                PendingConversationReply(
                    turnID: turnID,
                    reply: ConversationReply("hello")!
                )
            ])
        #expect(effects.isEmpty)

        let (delivered, deliveryEffects) = reduce(
            completed,
            .replyDelivered(turnID: turnID)
        )
        #expect(delivered.pendingReplies.isEmpty)
        #expect(deliveryEffects.isEmpty)
    }

    @Test
    func voidCompletionClosesTurnWithoutQueueingReply() {
        let state = ConversationState(conversationID: conversationID)
        let (running, _) = reduce(
            state,
            .receive(message: makeMessage(text: "work"), turnID: makeTurnID(1), agentRole: "test")
        )
        guard case .running(let turnID) = running.status else {
            Issue.record("Expected a running turn")
            return
        }

        let (completed, effects) = reduce(
            running,
            .modelCompleted(turnID: turnID, completion: .void)
        )

        #expect(completed.status == .idle)
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
            agentRole: "test"
        )
        let running = ConversationState(
            conversationID: conversationID,
            status: .running(pending.turnID),
            activeMessage: pending
        )

        let (recovered, effects) = reduce(running, .resume)

        #expect(recovered == running)
        #expect(
            effects == [
                .runReply(
                    ConversationTurnRequest(
                        conversationID: conversationID,
                        turnID: pending.turnID,
                        message: pending.message,
                        agentRole: pending.agentRole
                    )
                )
            ])
    }

    @Test
    func recoveryStartsAQueuedTurnLeftAfterAnIdleCrashWindow() {
        let pending = PendingConversationMessage(
            message: makeMessage(text: "queued"),
            turnID: makeTurnID(1),
            agentRole: "test"
        )
        let state = ConversationState(
            conversationID: conversationID,
            pendingMessages: [pending]
        )

        let (recovered, effects) = reduce(state, .resume)

        #expect(recovered.status == .running(pending.turnID))
        #expect(recovered.activeMessage == pending)
        #expect(recovered.pendingMessages.isEmpty)
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
        let (running, _) = reduce(
            state,
            .receive(message: makeMessage(text: "hello"), turnID: makeTurnID(1), agentRole: "test")
        )
        let staleTurnID = makeTurnID(99)

        let (next, effects) = reduce(
            running,
            .modelCompleted(
                turnID: staleTurnID,
                completion: .reply(makeReply("stale"))
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
        let (running, _) = reduce(
            state,
            .receive(message: makeMessage(text: "first"), turnID: makeTurnID(1), agentRole: "test")
        )
        let (queued, _) = reduce(
            running,
            .receive(message: makeMessage(text: "second"), turnID: makeTurnID(2), agentRole: "test")
        )
        let failure = ConversationFailure(kind: .model, message: "Ollama unavailable")
        let (next, effects) = reduce(queued, .modelFailed(turnID: makeTurnID(1), failure: failure))

        #expect(next.status == .running(makeTurnID(2)))
        #expect(next.pendingMessages.isEmpty)
        #expect(
            effects.contains(where: { effect in
                if case .runReply = effect { return true }
                return false
            }))

        let (failed, failureEffects) = reduce(next, .modelFailed(turnID: makeTurnID(2), failure: failure))
        #expect(failed.status == .failed(failure))
        #expect(failureEffects.isEmpty)
        let (cleared, _) = reduce(failed, .clearFailure)
        #expect(cleared.status == .idle)
    }

    @Test
    func resetCancelsActiveTurnAndClearsConversation() {
        let state = ConversationState(conversationID: conversationID)
        let (running, _) = reduce(
            state,
            .receive(message: makeMessage(text: "hello"), turnID: makeTurnID(1), agentRole: "test")
        )
        guard case .running(let turnID) = running.status else {
            Issue.record("Expected a running turn")
            return
        }

        let (reset, effects) = reduce(running, .reset)

        #expect(reset.status == .idle)
        #expect(reset.pendingMessages.isEmpty)
        #expect(effects.contains(.cancelModel(turnID)))
        #expect(effects.contains(.publish(.reset(conversationID: conversationID))))
    }

    @Test
    func emptyInputProducesErrorWithoutChangingState() {
        let state = ConversationState(conversationID: conversationID)
        let (next, effects) = reduce(
            state,
            .receive(message: makeMessage(text: " \n\t "), turnID: makeTurnID(1), agentRole: "test")
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
        let (running, _) = reduce(
            state,
            .receive(message: makeMessage(text: "hello"), turnID: makeTurnID(1), agentRole: "test")
        )
        guard case .running(let turnID) = running.status else {
            Issue.record("Expected a running turn")
            return
        }

        let (next, effects) = reduce(
            running,
            .receive(message: makeMessage(text: "  "), turnID: makeTurnID(2), agentRole: "test")
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
        #expect(next.status == .running(turnID))
    }

}
