import AttributedCalls
import Crypto
import DiscoverableActors
import DistributedCluster
import DurableWorkflows
import Hail
import TurgaiDomain
import TurgaiObjects
import TurgaiTimers

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What a chat's schedule or timer does each time it's due: says text in the chat, or asks the
/// chat's agent, as a message from whoever made it.
@Describable
public enum WhenDue: Codable, Sendable, Equatable {
    /// Says this text in the chat.
    case say(text: String)
    /// Asks the chat's agent this, which it answers there.
    case ask(instruction: String)
}

/// A chat's schedule or timer, as the space's scheduler or timers say about it as they set it: by
/// the name it was given in the chat, doing `then` there each time it's due. It's the chat's:
/// whoever is in the chat may change it.
public struct ChatReminder: Codable, Sendable, Equatable {
    public let name: String
    public let then: WhenDue
    /// Who asked for it: whom the bot answers each time it's due and asks the bot something.
    public let askedBy: Party
    /// The space whose chat it's in, which it does what it does through.
    public let space: SpaceID
    public let conversationID: ConversationID

    public init(name: String, then: WhenDue, askedBy: Party, in space: SpaceID, conversationID: ConversationID) {
        self.name = name
        self.then = then
        self.askedBy = askedBy
        self.space = space
        self.conversationID = conversationID
    }

    /// What it's set due by, for the space's scheduler or timers: its name in its chat, one for
    /// each name in each chat.
    static func timerName(_ name: String, in conversation: ConversationID) -> String {
        conversation.stableKey + "\u{1F}" + name
    }

    /// Does what it says, as the run `run` of it being due: says its text, or asks the chat's
    /// bot, for whoever asked for it.
    func doing(run: WorkflowID, on system: ClusterSystem) async throws {
        let space = try await Space.identified(by: space, on: system)
        switch then {
        case .say(let text):
            try await space.notify(conversationID, text)
        case .ask(let instruction):
            // What's asked of the bot is a message, which only a person writes for now.
            guard let person = askedBy.person else { throw DueInChatError.noPersonAsked }
            let message = InboundMessage(
                id: MessageID(rawValue: turgaiDeterministicUUID("message:\(run.rawValue)")),
                conversationID: conversationID,
                participantID: ParticipantID(channel: conversationID.channel, rawValue: person.key), userID: person,
                author: nil, text: instruction, receivedAt: Date())
            try await space.say(
                message, turnID: TurgaiDomain.TurnID(rawValue: turgaiDeterministicUUID("turn:\(run.rawValue)")))
        }
    }
}

extension WhenDue {
    /// What it does, as a person reads it: `says …`, `asks …`.
    var described: String {
        switch self {
        case .say(let text): "says \(text)"
        case .ask(let instruction): "asks \(instruction)"
        }
    }
}

extension KeptTask {
    /// What's due as `now` is, as `space`'s tasks show it: a chat's reminder, or an object's field.
    /// None for what isn't `space`'s.
    public init?(_ now: Kept, in space: SpaceID) {
        let firing = now.firing
        if let object = firing.about(as: ObjectTimerAbout.self) {
            guard object.space == space else { return nil }
            self.init(id: firing.id, of: .object(object.object, field: firing.name), due: firing.due, paused: now.paused)
        } else if let reminder = firing.about(as: ChatReminder.self) {
            guard reminder.space == space else { return nil }
            self.init(
                id: firing.id, of: .chat(reminder.conversationID, name: reminder.name, does: reminder.then.described),
                due: firing.due, paused: now.paused)
        } else {
            return nil
        }
    }
}

internal func turgaiDeterministicUUID(_ value: String) -> UUID {
    let digest = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
    return UUID(
        uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
}
