import Mosaic

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum LiveEventKind: String, Codable, Sendable {
    case ready
    case history
    case messageAccepted = "message.accepted"
    case turnStarted = "turn.started"
    case turnPhase = "turn.phase"
    case turnStatus = "turn.status"
    case turnPartial = "turn.partial"
    case turnCompleted = "turn.completed"
    case turnFailed = "turn.failed"
    case accessRequested = "access.requested"
    case accessAnswered = "access.answered"
    case notice
    case conversations
    case spaces
    case conversationJoined = "conversation.joined"
    case conversationSaid = "conversation.said"
    case conversationTitled = "conversation.titled"
    case conversationLeft = "conversation.left"
    case conversationDeleted = "conversation.deleted"
    case spaceJoined = "space.joined"
    case spaceListed = "space.listed"
    case spaceLeft = "space.left"
    case reply
    case memory
    case objects
    case pages
    case page
    case pageFailed = "page.failed"
    case tasks
    case taskKept = "task.kept"
    case taskEnded = "task.ended"
}

public struct LiveEvent: Codable, Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        /// The conversation is open.
        /// The conversation is open, for `you`: the id of the person the client is.
        case ready(
            conversationID: ConversationID,
            /// The bot that answers in it: none once it's left.
            botID: BotID?,
            status: ConversationStatus,
            you: String
        )
        case history(
            conversationID: ConversationID,
            messages: [Message]
        )
        case messageAccepted(
            conversationID: ConversationID,
            turnID: TurnID?,
            message: Message
        )
        case turnStarted(conversationID: ConversationID, turnID: TurnID)
        case turnPhase(
            conversationID: ConversationID,
            turnID: TurnID,
            phase: ConversationPhase
        )
        case turnStatus(
            conversationID: ConversationID,
            turnID: TurnID,
            activity: String
        )
        case turnPartial(
            conversationID: ConversationID,
            turnID: TurnID,
            reply: ReplySoFar
        )
        case turnCompleted(
            conversationID: ConversationID,
            turnID: TurnID,
            message: Message
        )
        case turnFailed(
            conversationID: ConversationID,
            turnID: TurnID?,
            error: ChatError
        )
        /// Someone asked the conversation's admins for access.
        case accessRequested(
            conversationID: ConversationID,
            request: AccessRequest
        )
        /// An admin answered it.
        case accessAnswered(
            conversationID: ConversationID,
            requestID: UUID,
            answer: AccessAnswer
        )
        case notice(
            conversationID: ConversationID?,
            turnID: TurnID?,
            error: ChatError
        )
        /// The conversations the person is in, as they're listed now, the one something was last
        /// said in first: to a connection that joined ``LiveTopic/conversations``, in its join's
        /// answer. Each change follows as its own event.
        case conversations(conversations: [Conversation])
        /// The spaces the person is in, each as it lists itself for them now: to a connection that
        /// joined ``LiveTopic/spaces``, in its join's answer. Each change follows as its own event.
        case spaces(spaces: [SpaceSummary])
        /// The person is in one more conversation, as it's listed now.
        case conversationJoined(conversation: Conversation)
        /// Something was said in one of the person's other conversations, as it's listed now.
        case conversationSaid(conversation: Conversation)
        /// One of the person's conversations is called something else, as it's listed now.
        case conversationTitled(conversation: Conversation)
        /// The person is no longer in one of their conversations.
        case conversationLeft(conversationID: ConversationID)
        /// It was deleted: it's gone from everyone's list, the one open too.
        case conversationDeleted(conversationID: ConversationID)
        /// The person is in one more space, as it lists itself for them now.
        case spaceJoined(space: SpaceSummary)
        /// One of the person's spaces lists itself differently for them now: renamed, archived, or
        /// what they may do in it.
        case spaceListed(space: SpaceSummary)
        /// The person is no longer in the space with this id.
        case spaceLeft(spaceID: SpaceID)
        /// The answer to the push `ref`.
        case reply(ref: PushRef, reply: LiveReply)
        /// What's remembered about the person, and whether they're remembered, as it is now: to a
        /// connection that joined ``LiveTopic/memory``, in its join's answer and each time it changes.
        case memory(MemorySummary)
        /// The objects of the space with this id the person may read, as they are now: to a
        /// connection that joined ``LiveTopic/objects(space:)``, as it joins and each time they change.
        case objects(space: SpaceID, objects: [ObjectListing])
        /// The pages of the space with this id the person may read, as they are now: to a connection
        /// that joined ``LiveTopic/pages(space:)``, as it joins and each time its objects change.
        case pages(space: SpaceID, pages: [PageListing])
        /// What one of the space's pages shows now: to a connection that joined
        /// ``LiveTopic/page(space:page:)``, as it joins and each time that changes.
        case page(space: SpaceID, page: MadeObjectID, shown: PageShown)
        /// One of the space's pages can't be shown now, and why: in place of what it shows.
        case pageFailed(space: SpaceID, page: MadeObjectID, reason: String)
        /// The tasks of the space with this id the person may change, as they are as a connection
        /// joins ``LiveTopic/tasks(space:)``: each change follows.
        case tasks(space: SpaceID, tasks: [TaskListing])
        /// One of them is kept due as it says now: new, or changed.
        case taskKept(space: SpaceID, task: TaskListing)
        /// The one with this id isn't due any more.
        case taskEnded(space: SpaceID, id: TaskListing.ID)

        public var type: LiveEventKind {
            switch self {
            case .ready: .ready
            case .history: .history
            case .messageAccepted: .messageAccepted
            case .turnStarted: .turnStarted
            case .turnPhase: .turnPhase
            case .turnStatus: .turnStatus
            case .turnPartial: .turnPartial
            case .turnCompleted: .turnCompleted
            case .turnFailed: .turnFailed
            case .accessRequested: .accessRequested
            case .accessAnswered: .accessAnswered
            case .notice: .notice
            case .conversations: .conversations
            case .spaces: .spaces
            case .conversationJoined: .conversationJoined
            case .conversationSaid: .conversationSaid
            case .conversationTitled: .conversationTitled
            case .conversationLeft: .conversationLeft
            case .conversationDeleted: .conversationDeleted
            case .spaceJoined: .spaceJoined
            case .spaceListed: .spaceListed
            case .spaceLeft: .spaceLeft
            case .reply: .reply
            case .memory: .memory
            case .objects: .objects
            case .pages: .pages
            case .page: .page
            case .pageFailed: .pageFailed
            case .tasks: .tasks
            case .taskKept: .taskKept
            case .taskEnded: .taskEnded
            }
        }
    }

    public let payload: Payload

    public init(payload: Payload) {
        self.payload = payload
    }

    public var type: LiveEventKind { payload.type }

    private enum CodingKeys: String, CodingKey {
        case type, conversationID, botID, turnID, you
        case status, phase, activity, message, messages, error, reply
        case request, requestID, answer
        case conversation
        case ref, memory, tasks, task, id, space, listing
        case objects, pages, shown, reason, state, conversations, spaces
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(LiveEventKind.self, forKey: .type)

        switch type {
        case .ready:
            payload = .ready(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                botID: try values.decodeIfPresent(BotID.self, forKey: .botID),
                status: try values.decode(ConversationStatus.self, forKey: .status),
                you: try values.decode(String.self, forKey: .you)
            )
        case .history:
            payload = .history(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                messages: try values.decode([Message].self, forKey: .messages)
            )
        case .messageAccepted:
            payload = .messageAccepted(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                turnID: try values.decodeIfPresent(TurnID.self, forKey: .turnID),
                message: try values.decode(Message.self, forKey: .message)
            )
        case .turnStarted:
            payload = .turnStarted(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                turnID: try values.decode(TurnID.self, forKey: .turnID)
            )
        case .turnPhase:
            payload = .turnPhase(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                turnID: try values.decode(TurnID.self, forKey: .turnID),
                phase: try values.decode(ConversationPhase.self, forKey: .phase)
            )
        case .turnStatus:
            payload = .turnStatus(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                turnID: try values.decode(TurnID.self, forKey: .turnID),
                activity: try values.decode(String.self, forKey: .activity)
            )
        case .turnPartial:
            payload = .turnPartial(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                turnID: try values.decode(TurnID.self, forKey: .turnID),
                reply: try values.decode(ReplySoFar.self, forKey: .reply)
            )
        case .turnCompleted:
            payload = .turnCompleted(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                turnID: try values.decode(TurnID.self, forKey: .turnID),
                message: try values.decode(Message.self, forKey: .message)
            )
        case .turnFailed:
            payload = .turnFailed(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                turnID: try values.decodeIfPresent(TurnID.self, forKey: .turnID),
                error: try values.decode(ChatError.self, forKey: .error)
            )
        case .accessRequested:
            payload = .accessRequested(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                request: try values.decode(AccessRequest.self, forKey: .request)
            )
        case .accessAnswered:
            payload = .accessAnswered(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                requestID: try values.decode(UUID.self, forKey: .requestID),
                answer: try values.decode(AccessAnswer.self, forKey: .answer)
            )
        case .notice:
            payload = .notice(
                conversationID: try values.decodeIfPresent(ConversationID.self, forKey: .conversationID),
                turnID: try values.decodeIfPresent(TurnID.self, forKey: .turnID),
                error: try values.decode(ChatError.self, forKey: .error)
            )
        case .conversations:
            payload = .conversations(conversations: try values.decode([Conversation].self, forKey: .conversations))
        case .spaces:
            payload = .spaces(spaces: try values.decode([SpaceSummary].self, forKey: .spaces))
        case .conversationJoined:
            payload = .conversationJoined(conversation: try values.decode(Conversation.self, forKey: .conversation))
        case .conversationSaid:
            payload = .conversationSaid(conversation: try values.decode(Conversation.self, forKey: .conversation))
        case .conversationTitled:
            payload = .conversationTitled(conversation: try values.decode(Conversation.self, forKey: .conversation))
        case .conversationLeft:
            payload = .conversationLeft(conversationID: try values.decode(ConversationID.self, forKey: .conversationID))
        case .conversationDeleted:
            payload = .conversationDeleted(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID))
        case .spaceJoined:
            payload = .spaceJoined(space: try values.decode(SpaceSummary.self, forKey: .listing))
        case .spaceListed:
            payload = .spaceListed(space: try values.decode(SpaceSummary.self, forKey: .listing))
        case .spaceLeft:
            payload = .spaceLeft(spaceID: try values.decode(SpaceID.self, forKey: .space))
        case .reply:
            let reply: LiveReply =
                switch try values.decode(LiveReply.Status.self, forKey: .status) {
                case .ok:
                    if let state = try values.decodeIfPresent(LiveEvent.self, forKey: .state) {
                        .joined(state)
                    } else {
                        try values.decodeIfPresent(MemorySummary.self, forKey: .memory).map(LiveReply.memory) ?? .ok
                    }
                case .failed: .failed(try values.decode(ChatError.self, forKey: .error))
                }
            payload = .reply(ref: try values.decode(PushRef.self, forKey: .ref), reply: reply)
        case .memory:
            payload = .memory(try values.decode(MemorySummary.self, forKey: .memory))
        case .objects:
            payload = .objects(
                space: try values.decode(SpaceID.self, forKey: .space),
                objects: try values.decode([ObjectListing].self, forKey: .objects))
        case .pages:
            payload = .pages(
                space: try values.decode(SpaceID.self, forKey: .space),
                pages: try values.decode([PageListing].self, forKey: .pages))
        case .page:
            payload = .page(
                space: try values.decode(SpaceID.self, forKey: .space),
                page: MadeObjectID(rawValue: try values.decode(String.self, forKey: .id)),
                shown: try values.decode(PageShown.self, forKey: .shown))
        case .pageFailed:
            payload = .pageFailed(
                space: try values.decode(SpaceID.self, forKey: .space),
                page: MadeObjectID(rawValue: try values.decode(String.self, forKey: .id)),
                reason: try values.decode(String.self, forKey: .reason))
        case .tasks:
            payload = .tasks(
                space: try values.decode(SpaceID.self, forKey: .space),
                tasks: try values.decode([TaskListing].self, forKey: .tasks))
        case .taskKept:
            payload = .taskKept(
                space: try values.decode(SpaceID.self, forKey: .space),
                task: try values.decode(TaskListing.self, forKey: .task))
        case .taskEnded:
            payload = .taskEnded(
                space: try values.decode(SpaceID.self, forKey: .space),
                id: try values.decode(TaskListing.ID.self, forKey: .id))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)

        switch payload {
        case .ready(let conversationID, let botID, let status, let you):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encodeIfPresent(botID, forKey: .botID)
            try values.encode(status, forKey: .status)
            try values.encode(you, forKey: .you)
        case .history(let conversationID, let messages):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(messages, forKey: .messages)
        case .messageAccepted(let conversationID, let turnID, let message):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encodeIfPresent(turnID, forKey: .turnID)
            try values.encode(message, forKey: .message)
        case .turnStarted(let conversationID, let turnID):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(turnID, forKey: .turnID)
        case .turnPhase(let conversationID, let turnID, let phase):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(turnID, forKey: .turnID)
            try values.encode(phase, forKey: .phase)
        case .turnStatus(let conversationID, let turnID, let activity):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(turnID, forKey: .turnID)
            try values.encode(activity, forKey: .activity)
        case .turnPartial(let conversationID, let turnID, let reply):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(turnID, forKey: .turnID)
            try values.encode(reply, forKey: .reply)
        case .turnCompleted(let conversationID, let turnID, let message):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(turnID, forKey: .turnID)
            try values.encode(message, forKey: .message)
        case .turnFailed(let conversationID, let turnID, let error):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encodeIfPresent(turnID, forKey: .turnID)
            try values.encode(error, forKey: .error)
        case .accessRequested(let conversationID, let request):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(request, forKey: .request)
        case .accessAnswered(let conversationID, let requestID, let answer):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(requestID, forKey: .requestID)
            try values.encode(answer, forKey: .answer)
        case .notice(let conversationID, let turnID, let error):
            try values.encodeIfPresent(conversationID, forKey: .conversationID)
            try values.encodeIfPresent(turnID, forKey: .turnID)
            try values.encode(error, forKey: .error)
        case .conversations(let conversations):
            try values.encode(conversations, forKey: .conversations)
        case .spaces(let spaces):
            try values.encode(spaces, forKey: .spaces)
        case .conversationJoined(let conversation), .conversationSaid(let conversation),
            .conversationTitled(let conversation):
            try values.encode(conversation, forKey: .conversation)
        case .conversationLeft(let conversationID), .conversationDeleted(let conversationID):
            try values.encode(conversationID, forKey: .conversationID)
        case .spaceJoined(let space), .spaceListed(let space):
            try values.encode(space, forKey: .listing)
        case .spaceLeft(let spaceID):
            try values.encode(spaceID, forKey: .space)
        case .reply(let ref, let reply):
            try values.encode(ref, forKey: .ref)
            switch reply {
            case .ok:
                try values.encode(LiveReply.Status.ok, forKey: .status)
            case .memory(let memory):
                try values.encode(LiveReply.Status.ok, forKey: .status)
                try values.encode(memory, forKey: .memory)
            case .joined(let state):
                try values.encode(LiveReply.Status.ok, forKey: .status)
                try values.encode(state, forKey: .state)
            case .failed(let error):
                try values.encode(LiveReply.Status.failed, forKey: .status)
                try values.encode(error, forKey: .error)
            }
        case .memory(let memory):
            try values.encode(memory, forKey: .memory)
        case .objects(let space, let objects):
            try values.encode(space, forKey: .space)
            try values.encode(objects, forKey: .objects)
        case .pages(let space, let pages):
            try values.encode(space, forKey: .space)
            try values.encode(pages, forKey: .pages)
        case .page(let space, let page, let shown):
            try values.encode(space, forKey: .space)
            try values.encode(page.rawValue, forKey: .id)
            try values.encode(shown, forKey: .shown)
        case .pageFailed(let space, let page, let reason):
            try values.encode(space, forKey: .space)
            try values.encode(page.rawValue, forKey: .id)
            try values.encode(reason, forKey: .reason)
        case .tasks(let space, let tasks):
            try values.encode(space, forKey: .space)
            try values.encode(tasks, forKey: .tasks)
        case .taskKept(let space, let task):
            try values.encode(space, forKey: .space)
            try values.encode(task, forKey: .task)
        case .taskEnded(let space, let id):
            try values.encode(space, forKey: .space)
            try values.encode(id, forKey: .id)
        }
    }
}
