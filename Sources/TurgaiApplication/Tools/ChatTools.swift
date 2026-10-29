import AnyLanguageModel
import DiscoverableActors
import Hail
import TurgaiDomain
import TurgaiObjects

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The chat a call happens in: what an object's code says there, as a timer's message is said.
/// Its code never names the chat; the call's chain says where it happens.
@Tool("chat", description: "The chat this happens in.")
public struct Chat: Sendable {
    public init() {}

    @Command("say", description: "Say text in the chat this happens in.")
    public func say(_ saying: ChatSaying) throws -> ChatSayEffect {
        try ChatSayEffect(saying)
    }

    /// What was said.
    public func render(_ said: ChatSaid) -> ToolOutput {
        .text("Said: \(said.text)")
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
