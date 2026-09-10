import DurableWorkflows
import Hail
import NorbyDomain

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

private struct DeferredToolTarget: Sendable {
    let ownerID: NorbyDomain.UserID
    let conversationID: ConversationID
    let participantID: ParticipantID

    init(context: AgentTurnContext) throws {
        guard let conversationID = ConversationID(stableKey: context.agentID.contextID.rawValue) else {
            throw TimerTools.Error.invalidConversationID(context.agentID.contextID.rawValue)
        }
        guard case .text(let sender, _, _) = context.message else {
            throw TimerTools.Error.invalidParticipantID("non-text message")
        }
        let prefix = "participant:\(conversationID.channel.rawValue):"
        guard sender.hasPrefix(prefix) else { throw TimerTools.Error.invalidParticipantID(sender) }
        let participant = String(sender.dropFirst(prefix.count))
        guard !participant.isEmpty else { throw TimerTools.Error.invalidParticipantID(sender) }
        ownerID = NorbyDomain.UserID(rawValue: sender)
        self.conversationID = conversationID
        participantID = ParticipantID(channel: conversationID.channel, rawValue: participant)
    }

    func timerRequest(action: DeferredAction, snapshotPolicy: AgentSnapshotPolicy) -> Timer.Request {
        Timer.Request(
            ownerID: ownerID, conversationID: conversationID, participantID: participantID, action: action,
            snapshotPolicy: snapshotPolicy)
    }

    func scheduleRequest(action: DeferredAction, snapshotPolicy: AgentSnapshotPolicy) -> Schedule.Request {
        Schedule.Request(
            ownerID: ownerID, conversationID: conversationID, participantID: participantID, action: action,
            snapshotPolicy: snapshotPolicy)
    }
}

enum DeferredActionToolSupport {
    static func make(kind: DeferredAction.Kind, message: String?, instruction: String?) throws -> DeferredAction {
        switch kind {
        case .deliverPreparedMessage:
            guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TimerTools.Error.emptyMessage
            }
            return .deliverPreparedMessage(message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        case .performTask:
            guard let instruction, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TimerTools.Error.emptyInstruction
            }
            return .performTask(instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

struct TimerTarget {
    private let value: DeferredToolTarget
    init(context: AgentTurnContext) throws { value = try DeferredToolTarget(context: context) }
    func request(action: DeferredAction, snapshotPolicy: AgentSnapshotPolicy) -> Timer.Request {
        value.timerRequest(action: action, snapshotPolicy: snapshotPolicy)
    }
    var conversationID: ConversationID { value.conversationID }
}

struct ScheduleTarget {
    private let value: DeferredToolTarget
    init(context: AgentTurnContext) throws { value = try DeferredToolTarget(context: context) }
    func request(action: DeferredAction, snapshotPolicy: AgentSnapshotPolicy) -> Schedule.Request {
        value.scheduleRequest(action: action, snapshotPolicy: snapshotPolicy)
    }
    var ownerID: NorbyDomain.UserID { value.ownerID }
    var conversationID: ConversationID { value.conversationID }
}
