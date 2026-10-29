import DurableWorkflows
import Hail
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The work a durable timer or schedule performs when it fires.
public enum DeferredAction: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        case deliverPreparedMessage = "deliver_prepared_message"
        case performTask = "perform_task"
    }

    case deliverPreparedMessage(message: String)
    case performTask(instruction: String)

    public var kind: Kind {
        switch self {
        case .deliverPreparedMessage: .deliverPreparedMessage
        case .performTask: .performTask
        }
    }

    public var content: String {
        switch self {
        case .deliverPreparedMessage(let message): message
        case .performTask(let instruction): instruction
        }
    }

    public init(kind: Kind, content: String) {
        switch kind {
        case .deliverPreparedMessage: self = .deliverPreparedMessage(message: content)
        case .performTask: self = .performTask(instruction: content)
        }
    }
}

extension ConversationID {
    /// The user a conversation belongs to: its participant on that channel.
    var participantUserID: TurgaiDomain.UserID? {
        let participant = externalAddress.rawValue
        guard !participant.isEmpty else { return nil }
        return TurgaiDomain.UserID(rawValue: "participant:\(channel.rawValue):\(participant)")
    }
}

private struct DeferredToolTarget: Sendable {
    let ownerID: TurgaiDomain.UserID
    let conversationID: ConversationID
    let participantID: ParticipantID

    init(context: AgentTurnContext) throws {
        guard let conversationID = ConversationID(stableKey: context.agentID.contextID.rawValue) else {
            throw TimerTools.Error.invalidConversationID(context.agentID.contextID.rawValue)
        }
        guard let ownerID = conversationID.participantUserID else {
            throw TimerTools.Error.invalidParticipantID(conversationID.externalAddress.rawValue)
        }
        self.ownerID = ownerID
        self.conversationID = conversationID
        participantID = ParticipantID(
            channel: conversationID.channel, rawValue: conversationID.externalAddress.rawValue)
    }

    func timerRequest(action: DeferredAction) -> Timer.Request {
        Timer.Request(
            ownerID: ownerID, conversationID: conversationID, participantID: participantID, action: action)
    }

    func scheduleRequest(action: DeferredAction) -> Schedule.Request {
        Schedule.Request(
            ownerID: ownerID, conversationID: conversationID, participantID: participantID, action: action)
    }
}

enum DeferredActionToolSupport {
    static func make(kind: DeferredAction.Kind, message: String?, instruction: String?) throws -> DeferredAction {
        switch kind {
        case .deliverPreparedMessage:
            guard let message, !message.trimmed().isEmpty else {
                throw TimerTools.Error.emptyMessage
            }
            return .deliverPreparedMessage(message: message.trimmed())
        case .performTask:
            guard let instruction, !instruction.trimmed().isEmpty else {
                throw TimerTools.Error.emptyInstruction
            }
            return .performTask(instruction: instruction.trimmed())
        }
    }
}

struct TimerTarget {
    private let value: DeferredToolTarget
    init(context: AgentTurnContext) throws { value = try DeferredToolTarget(context: context) }
    func request(action: DeferredAction) -> Timer.Request {
        value.timerRequest(action: action)
    }
    var conversationID: ConversationID { value.conversationID }
}

struct ScheduleTarget {
    private let value: DeferredToolTarget
    init(context: AgentTurnContext) throws { value = try DeferredToolTarget(context: context) }
    func request(action: DeferredAction) -> Schedule.Request {
        value.scheduleRequest(action: action)
    }
    var ownerID: TurgaiDomain.UserID { value.ownerID }
    var conversationID: ConversationID { value.conversationID }
}
