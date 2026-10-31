import AnyLanguageModel
import DiscoverableActors
import DistributedCluster
import Hail
import TurgaiCalls
import TurgaiDomain
import TurgaiObjects

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The chat a call happens in: what an object's code says there, as a timer's message is said, and
/// what it asks the chat's model on its own. Its code never names the chat; the call's chain says
/// where it happens.
@Tool("chat", description: "The chat this happens in.")
public struct Chat: Sendable {
    public init() {}

    @Command("say", description: "Say text in the chat this happens in.")
    public func say(_ saying: ChatSaying) throws -> ChatSayEffect {
        try ChatSayEffect(saying)
    }

    @Command(
        "ask",
        description:
            "Ask the chat's model one question on its own: its answer comes back, and nothing is said in the chat."
    )
    public func ask(_ asking: ChatAsking) throws -> ChatAskEffect {
        try ChatAskEffect(asking)
    }

    /// What was said.
    public func render(_ said: ChatSaid) -> ToolOutput {
        .text("Said: \(said.text)")
    }

    /// What the chat's model answered.
    public func render(_ answer: ChatAnswer) -> ToolOutput {
        .text(answer.text)
    }
}

/// Something to say in a chat.
@Generable(description: "Something to say in a chat.")
@Describable
public struct ChatSaying: Sendable {
    /// What to say.
    @Guide(description: "What to say.")
    public var text: String
}

/// What was said in a chat.
@Describable
public struct ChatSaid: Codable, Sendable {
    /// The words, as they were said.
    public var text: String
}

/// Saying text in the conversation the call's chain happens in. Where it goes is the chain's own:
/// it reaches no other chat.
public struct ChatSayEffect: ScopedEffect, Sendable {
    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case nothingToSay
        case inNoChat

        public var description: String {
            switch self {
            case .nothingToSay: "there's nothing to say"
            case .inNoChat: "this happens in no chat"
            }
        }
    }

    public let name = "chat.say"
    public let text: String

    init(_ saying: ChatSaying) throws {
        let text = saying.text.trimmed()
        guard !text.isEmpty else { throw Error.nothingToSay }
        self.text = text
    }

    public static func run(in token: borrowing EffectToken<ChatSayEffect>) async throws -> ChatSaid {
        let text = token.withConfiguration { $0.text }
        guard let place = CallChain.current?.place else { throw Error.inNoChat }
        try await ActorSystemDependency<Self>.current.virtualActors.notify(place, text)
        return ChatSaid(text: text)
    }
}

/// A question for the chat's model, asked on its own.
@Generable(description: "A question for the chat's model, asked on its own.")
@Describable
public struct ChatAsking: Sendable {
    /// The question, with all it's about.
    @Guide(description: "The question, with all it's about.")
    public var text: String
}

/// What the chat's model answered.
@Describable
public struct ChatAnswer: Codable, Sendable {
    /// The answer, in the model's words.
    public var text: String
}

/// Asking the model of the agent that answers the conversation the call's chain happens in one
/// question, on its own: nothing comes before it, it's offered no tools, and nothing is said in the
/// chat. Which chat is the chain's own: it reaches no other chat's model.
public struct ChatAskEffect: ScopedEffect, Sendable {
    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case nothingToAsk
        case inNoChat
        case unanswered

        public var description: String {
            switch self {
            case .nothingToAsk: "there's nothing to ask"
            case .inNoChat: "this happens in no chat"
            case .unanswered: "the chat's model gave no answer"
            }
        }
    }

    public let name = "chat.ask"
    public let text: String

    init(_ asking: ChatAsking) throws {
        let text = asking.text.trimmed()
        guard !text.isEmpty else { throw Error.nothingToAsk }
        self.text = text
    }

    public static func run(in token: borrowing EffectToken<ChatAskEffect>) async throws -> ChatAnswer {
        let text = token.withConfiguration { $0.text }
        guard let place = CallChain.current?.place else { throw Error.inNoChat }
        return ChatAnswer(text: try await ActorSystemDependency<Self>.current.virtualActors.ask(place, text))
    }
}

/// The models chats' agents answer with, each asked a question on its own: the profile of the
/// agent that answers the chat, on its endpoint.
public struct ChatModels: Sendable {
    let agentProfiles: TurgaiAgentProfileStore
    let endpoints: AgentModelEndpointFactory
    let temperature: Double
    let ollamaKeepAlive: String?

    public init(
        agentProfiles: TurgaiAgentProfileStore, endpoints: AgentModelEndpointFactory, temperature: Double,
        ollamaKeepAlive: String?
    ) {
        self.agentProfiles = agentProfiles
        self.endpoints = endpoints
        self.temperature = temperature
        self.ollamaKeepAlive = ollamaKeepAlive
    }

    /// What the model of the agent that answers `conversation` answers `question` with, asked on
    /// its own.
    func ask(_ question: String, in conversation: ConversationID, on system: ClusterSystem) async throws -> String {
        let role = try await TurgaiConnections.agentRole(for: conversation, agentProfiles: agentProfiles, on: system)
        guard let profile = try await agentProfiles.profile(id: role) else {
            throw TurgaiAgentProfileError.unknownProfile(role)
        }
        let endpoint = try await endpoints.endpoint(
            for: profile, temperature: temperature, ollamaKeepAlive: ollamaKeepAlive)
        guard let answer = try await endpoint.answer([.prompt(.init(segments: [.text(.init(content: question))]))])
        else { throw ChatAskEffect.Error.unanswered }
        return answer
    }
}
