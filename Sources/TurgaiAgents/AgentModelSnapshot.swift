import Hail
import TurgaiDomain

/// The answering agent's model, as it was when a message was sent: what the work after its turn
/// asks, remembering what was said and naming the conversation. Profile edits affect newly sent
/// messages; work already accepted stays replayable from the model it was given. Credentials
/// remain references, so secret values never enter a journal.
public struct AgentModelSnapshot: Codable, Sendable, Equatable {
    /// Where the model is asked: with a provider, or nowhere.
    public enum Provider: Codable, Sendable, Equatable {
        case disabled
        case configured(
            AgentProviderConfiguration,
            ollamaKeepAlive: String?
        )
    }

    public enum EndpointError: Error, Equatable, Sendable {
        /// It names no provider to ask.
        case notConfigured
    }

    public let model: AgentModel
    public let provider: Provider

    public init(
        model: AgentModel,
        provider: Provider
    ) {
        self.model = model
        self.provider = provider
    }

    /// What `model` asks: briefly, kept for an Ollama server a while between asks.
    public init(_ model: BotModel) throws {
        self.init(
            model: try model.agentModel,
            provider: .configured(
                model.location, ollamaKeepAlive: model.location.provider == .ollama ? "10m" : nil))
    }

    public var isEnabled: Bool {
        if case .configured = provider { return true }
        return false
    }

    /// The model to ask, from the node's `endpoints`: briefly, without reasoning where that can be
    /// turned off.
    public func endpoint(from endpoints: AgentModelEndpointFactory) async throws -> any ModelEndpoint {
        guard case .configured(let provider, let ollamaKeepAlive) = provider else {
            throw EndpointError.notConfigured
        }
        let reasoning: ReasoningEffortSelection? =
            switch model.provider {
            case .ollama, .gemini:
                .init(effort: .none, encoding: .disabled)
            default:
                nil
            }
        return try await endpoints.endpoint(
            model: model,
            configuration: provider,
            temperature: 0.2,
            ollamaKeepAlive: ollamaKeepAlive,
            reasoning: reasoning
        )
    }
}
