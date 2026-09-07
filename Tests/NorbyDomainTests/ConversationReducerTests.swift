import Testing

@testable import NorbyDomain

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

    private var capabilities: ChannelCapabilities {
        ChannelCapabilities(
            supportsDrafts: true,
            supportsTyping: true,
            maximumTextLength: 4_096,
            supportsThreads: false
        )
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
        let state = ConversationState(
            conversationID: conversationID,
            capabilities: capabilities
        )

        let (next, effects) = reduce(
            state,
            .receive(message: makeMessage(text: "  hello  "), turnID: makeTurnID(1), capabilities: capabilities)
        )

        guard case .running(let turnID) = next.status else {
            Issue.record("Expected a running turn")
            return
        }
        #expect(next.pendingMessages.isEmpty)
        #expect(next.revision == 1)
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
            .receive(message: makeMessage(text: "first"), turnID: makeTurnID(1), capabilities: .default)
        )
        guard case .running(let firstTurnID) = running.status else {
            Issue.record("Expected first turn to be running")
            return
        }

        let (queued, _) = reduce(
            running,
            .receive(message: makeMessage(text: "second"), turnID: makeTurnID(2), capabilities: .default)
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
                capabilities: .default
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
                capabilities: .default
            )
        )

        #expect(duplicate == completed)
        #expect(effects.isEmpty)
    }

    @Test
    func modelCompletionDoesNotPublishBecauseReplyScopeOwnsDelivery() {
        let state = ConversationState(
            conversationID: conversationID,
            capabilities: capabilities
        )
        let (running, _) = reduce(
            state,
            .receive(message: makeMessage(text: "hello"), turnID: makeTurnID(1), capabilities: capabilities)
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
                PendingConversationReply(turnID: turnID, text: "hello")
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
        let state = ConversationState(
            conversationID: conversationID,
            capabilities: capabilities
        )
        let (running, _) = reduce(
            state,
            .receive(message: makeMessage(text: "work"), turnID: makeTurnID(1), capabilities: capabilities)
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
            turnID: makeTurnID(1)
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
                    ModelRequest(
                        conversationID: conversationID,
                        turnID: pending.turnID,
                        message: pending.message
                    )
                )
            ])
    }

    @Test
    func recoveryStartsAQueuedTurnLeftAfterAnIdleCrashWindow() {
        let pending = PendingConversationMessage(
            message: makeMessage(text: "queued"),
            turnID: makeTurnID(1)
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
            .receive(message: makeMessage(text: "hello"), turnID: makeTurnID(1), capabilities: .default)
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

    @Test
    func modelFailureCanBeClearedAndQueuedWorkContinues() {
        let state = ConversationState(conversationID: conversationID)
        let (running, _) = reduce(
            state,
            .receive(message: makeMessage(text: "first"), turnID: makeTurnID(1), capabilities: .default)
        )
        guard case .running(let turnID) = running.status else {
            Issue.record("Expected a running turn")
            return
        }
        let (queued, _) = reduce(
            running,
            .receive(message: makeMessage(text: "second"), turnID: makeTurnID(2), capabilities: .default)
        )
        let failure = ConversationFailure(kind: .model, message: "Ollama unavailable")
        let (failed, failureEffects) = reduce(
            queued,
            .modelFailed(turnID: turnID, failure: failure)
        )

        #expect(failed.status == .failed(failure))
        #expect(failed.pendingMessages.count == 1)
        #expect(failureEffects.isEmpty)

        let (recovered, recoveryEffects) = reduce(failed, .resume)
        guard case .running = recovered.status else {
            Issue.record("Expected queued work to recover")
            return
        }
        #expect(recovered.pendingMessages.isEmpty)
        #expect(
            recoveryEffects.contains(where: { effect in
                if case .runReply = effect { return true }
                return false
            }))

        let (resumed, resumeEffects) = reduce(failed, .clearFailure)
        guard case .running = resumed.status else {
            Issue.record("Expected queued work to resume")
            return
        }
        #expect(resumed.pendingMessages.isEmpty)
        #expect(
            resumeEffects.contains(where: { effect in
                if case .runReply = effect { return true }
                return false
            }))
    }

    @Test
    func resetCancelsActiveTurnAndClearsConversation() {
        let state = ConversationState(conversationID: conversationID)
        let (running, _) = reduce(
            state,
            .receive(message: makeMessage(text: "hello"), turnID: makeTurnID(1), capabilities: .default)
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
            .receive(message: makeMessage(text: " \n\t "), turnID: makeTurnID(1), capabilities: .default)
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
            .receive(message: makeMessage(text: "hello"), turnID: makeTurnID(1), capabilities: .default)
        )
        guard case .running(let turnID) = running.status else {
            Issue.record("Expected a running turn")
            return
        }

        let (next, effects) = reduce(
            running,
            .receive(message: makeMessage(text: "  "), turnID: makeTurnID(2), capabilities: .default)
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
