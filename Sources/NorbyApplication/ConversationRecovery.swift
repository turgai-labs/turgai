import NorbyDomain

/// Finds durable conversations that need a channel connection after process
/// startup. Replaying and resuming the aggregate remains Conversation's job;
/// this service only folds already-read journals and performs discovery.
public struct ConversationRecovery: Sendable {
    public init() {}

    public func recoverableConversationIDs(
        from journals: [ConversationJournal]
    ) -> [ConversationID] {
        var conversationIDs: [ConversationID] = []
        conversationIDs.reserveCapacity(journals.count)

        for journal in journals {
            var record = ConversationState(
                conversationID: journal.conversationID
            )
            for event in journal.events {
                record.apply(event)
            }
            if record.requiresRecovery {
                conversationIDs.append(journal.conversationID)
            }
        }

        return conversationIDs
    }
}
