import Foundation
import NorbyApplication
import NorbyDomain
import NorbyMemory
import Testing

struct ConversationTests {
    private let conversationID = ConversationID(
        channel: ChannelID("test"),
        externalAddress: ExternalConversationAddress("chat")
    )

    @Test
    func conversationRecordOwnsQueueAndTurnLifecycle() {
        let participantID = ParticipantID("user")
        let first = PendingConversationMessage(
            message: InboundMessage(
                conversationID: conversationID,
                participantID: participantID,
                text: "first",
                receivedAt: Date(timeIntervalSince1970: 1)
            ),
            turnID: TurnID()
        )
        let second = PendingConversationMessage(
            message: InboundMessage(
                conversationID: conversationID,
                participantID: participantID,
                text: "second",
                receivedAt: Date(timeIntervalSince1970: 2)
            ),
            turnID: TurnID()
        )

        var record = ConversationRecord(conversationID: conversationID)
        record.apply(.turnStarted(first))
        record.apply(.messageQueued(second))

        #expect(record.status == .running(first.turnID))
        #expect(record.activeMessage == first)
        #expect(record.pendingMessages == [second])
        #expect(record.requiresRecovery)

        let reply = PendingConversationReply(turnID: first.turnID, text: "answer")
        record.apply(.replyQueued(reply))
        #expect(record.status == .idle)
        #expect(record.activeMessage == nil)
        #expect(record.pendingMessages == [second])
        #expect(record.pendingReplies == [reply])

        // The later lifecycle event is harmless when replayed after the
        // reply queue event already closed the turn.
        record.apply(.turnCompleted(first.turnID))
        record.apply(.replyDelivered(first.turnID))
        #expect(record.pendingReplies.isEmpty)
    }

    @Test
    func failedConversationDoesNotAutomaticallyRetry() {
        var record = ConversationRecord(conversationID: conversationID)
        let message = PendingConversationMessage(
            message: InboundMessage(
                conversationID: conversationID,
                participantID: ParticipantID("user"),
                text: "hello",
                receivedAt: Date(timeIntervalSince1970: 1)
            ),
            turnID: TurnID()
        )
        record.apply(.turnStarted(message))
        record.apply(
            .turnFailed(
                message.turnID,
                ConversationFailure(kind: .model, message: "unavailable")
            )
        )

        #expect(!record.requiresRecovery)
    }

    @Test
    func recoveryFindsQueuedRepliesInAConversationJournal() {
        let reply = PendingConversationReply(
            turnID: TurnID(),
            text: "answer"
        )
        let journal = ConversationJournal(
            conversationID: conversationID,
            events: [.replyQueued(reply)]
        )

        let recovered = ConversationRecovery()
            .recoverableConversationIDs(from: [journal])

        #expect(recovered == [conversationID])
    }

    @Test
    func userRecordLinksParticipantsIdempotently() {
        let userID = UserID("user:1")
        let participantID = ParticipantID(channel: ChannelID("telegram"), rawValue: "1")
        let link = UserParticipantLink(userID: userID, participantID: participantID)
        var record = UserRecord(userID: userID)

        record.apply(.participantLinked(link, at: Date(timeIntervalSince1970: 1)))
        record.apply(.participantLinked(link, at: Date(timeIntervalSince1970: 2)))

        #expect(record.participantLinks == [link])
        #expect(record.isLinked(to: participantID))
    }

    @Test
    func memoryToolUsesStableSnakeCaseInputKeys() throws {
        let input = try JSONDecoder().decode(
            MemoryTool.Input.self,
            from: Data(
                #"{"operation":"revise","fact_id":"00000000-0000-0000-0000-000000000003","namespace":"profile","predicate":"name","value":"Ada","value_kind":"person","supporting_text":"My name is Ada","confidence":0.98,"importance":0.9,"stability":"stable"}"#.utf8
            )
        )

        #expect(input.operation == .revise)
        #expect(input.factID == "00000000-0000-0000-0000-000000000003")
        #expect(input.valueKind == .person)
        #expect(input.stability == .stable)
    }
}
