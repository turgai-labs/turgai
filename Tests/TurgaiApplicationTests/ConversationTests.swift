import AnyLanguageModel
import Testing
import TurgaiDomain
import TurgaiMemory

@testable import TurgaiApplication
import TurgaiPeople

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

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
                userID: .ann,
                text: "first",
                receivedAt: Date(timeIntervalSince1970: 1)
            ),
            turnID: TurnID(),
            agentRole: "test"
        )
        let second = PendingConversationMessage(
            message: InboundMessage(
                conversationID: conversationID,
                participantID: participantID,
                userID: .ann,
                text: "second",
                receivedAt: Date(timeIntervalSince1970: 2)
            ),
            turnID: TurnID(),
            agentRole: "test"
        )

        var record = ConversationState(conversationID: conversationID)
        record.apply(.inbox(.turnStarted(first)))
        record.apply(.inbox(.queued(second)))

        #expect(record.inbox.status == .running(first.turnID))
        #expect(record.inbox.activeMessage == first)
        #expect(record.inbox.pendingMessages == [second])
        #expect(record.requiresRecovery)

        let reply = PendingConversationReply(
            turnID: first.turnID,
            reply: ConversationReply("answer")!
        )
        record.apply(.replyQueued(reply))
        #expect(record.inbox.status == .idle)
        #expect(record.inbox.activeMessage == nil)
        #expect(record.inbox.pendingMessages == [second])
        #expect(record.pendingReplies == [reply])

        // The later lifecycle event is harmless when replayed after the
        // reply queue event already closed the turn.
        record.apply(.inbox(.turnCompleted(first.turnID)))
        record.apply(.replyDelivered(first.turnID))
        #expect(record.pendingReplies.isEmpty)
    }

    /// A noted message keeps its mark until it's taken off: one a restart leaves is still known, to
    /// take off with the next message.
    @Test
    func aNotedMessageIsKeptUntilItsMarkIsTakenOff() {
        var record = ConversationState(conversationID: conversationID)
        let noted = NotedMessage(id: MessageID(), channelID: ChannelMessageID(rawValue: "123"))
        record.apply(.noted(noted))
        #expect(record.noted == noted)
        record.apply(.unnoted)
        #expect(record.noted == nil)
    }

    /// `/memory` shows what's remembered, with a button to forget each fact, one to turn memory off
    /// or on, and one to forget everything when anything is remembered.
    @Test
    func memoryIsShownWithItsButtons() {
        let fact = MemoryFact(
            id: MemoryFactID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            path: MemoryPath(["lives in"])!,
            value: "Haar, Germany",
            evidence: [],
            confidence: 0.9,
            observedAt: Date(timeIntervalSince1970: 1)
        )
        let remembered = MemoryTree([fact])
        #expect(
            MemoryPresentation.text(remembered, remembering: .on)
                == "Remembered:\n```\nYou\n└─ lives in: Haar, Germany\n```")
        #expect(
            MemoryPresentation.actions(for: remembered, remembering: .on).map(\.command) == [
                "/forget-fact 00000000-0000-0000-0000-000000000001", "/memory-off", "/forget",
            ])
        #expect(MemoryPresentation.actions(for: remembered, remembering: .on).first?.label == "Forget lives in: Haar, Germany")
        #expect(
            MemoryPresentation.text(MemoryTree([]), remembering: .off)
                == "Memory is off: nothing new is remembered.\nNothing is remembered.")
        #expect(MemoryPresentation.actions(for: MemoryTree([]), remembering: .off).map(\.label) == ["Turn memory on"])
    }

    @Test
    func failedConversationDoesNotAutomaticallyRetry() {
        var record = ConversationState(conversationID: conversationID)
        let message = PendingConversationMessage(
            message: InboundMessage(
                conversationID: conversationID,
                participantID: ParticipantID("user"),
                userID: .ann,
                text: "hello",
                receivedAt: Date(timeIntervalSince1970: 1)
            ),
            turnID: TurnID(),
            agentRole: "test"
        )
        record.apply(.inbox(.turnStarted(message)))
        record.apply(
            .inbox(.turnFailed(message.turnID, ConversationFailure(kind: .model, message: "unavailable")))
        )

        #expect(!record.requiresRecovery)
    }

    @Test
    func recoveryFindsQueuedRepliesInAConversationJournal() {
        let reply = PendingConversationReply(
            turnID: TurnID(),
            reply: ConversationReply("answer")!
        )
        let journal = ConversationJournal(
            conversationID: conversationID,
            events: [.replyQueued(reply)]
        )

        let recovered = ConversationRecovery()
            .recoverableConversationIDs(from: [journal])

        #expect(recovered == [conversationID])
    }

    /// A person holds the spaces they're in, the first joined first, as each space tells them.
    @Test
    func aPersonHoldsTheirSpaces() {
        let family = SpaceID()
        let work = SpaceID()
        var record = UserRecord(userID: .ann)
        for event in [UserEvent.joinedSpace(family), .joinedSpace(work), .joinedSpace(family), .leftSpace(family)] {
            record.apply(event)
        }
        #expect(record.spaces == [work])
    }

    /// A new person remembers what they say; a guest, whom no one signed in as, doesn't.
    @Test
    func aGuestRemembersNothing() {
        #expect(UserRecord(userID: .ann).memory.remembering == .on)
        #expect(UserRecord(userID: .guest(UUID())).memory.remembering == .off)
    }
}
