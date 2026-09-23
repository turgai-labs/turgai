import Hail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Provider-specific configuration for the background extractor.
///
/// The enum is deliberately exhaustive for providers implemented by Turgai.
/// Adding another extraction backend requires adding a case here and handling
/// it in ``MemoryExtractionEndpointFactory``.
public enum MemoryExtractionProviderConfiguration: Codable, Sendable, Equatable {
    /// Extraction was deliberately turned off by configuration or policy.
    case disabled
    case ollama(baseURL: URL, keepAlive: String?)
    /// The selected provider is valid, but has no extraction adapter here.
    case unavailable(provider: AgentModelProvider)
}

/// Configuration for Turgai's background memory extractor.
public struct MemoryExtractionConfiguration: Codable, Sendable, Equatable {
    public let model: AgentModelID
    public let provider: MemoryExtractionProviderConfiguration
    /// Context window used by background extraction. A smaller value reduces
    /// memory use; matching the chat window avoids provider-side model
    /// switching where applicable.
    public let contextWindow: Int

    public init(
        model: AgentModelID,
        provider: MemoryExtractionProviderConfiguration,
        contextWindow: Int = 4_096
    ) {
        self.model = model
        self.provider = provider
        self.contextWindow = contextWindow
    }

    /// Extraction runs on the same model that serves the conversation.
    /// Returns nil when the configured provider has no extraction endpoint.
    public init?(profile: TurgaiAgentProfile) {
        let provider: MemoryExtractionProviderConfiguration
        switch profile.providerConfiguration {
        case .ollama(let baseURL):
            provider = .ollama(baseURL: baseURL, keepAlive: "10m")
        case .none where profile.model.provider != .ollama:
            provider = .unavailable(provider: profile.model.provider)
        case .none:
            return nil
        }
        self.init(
            model: profile.model.id,
            provider: provider,
            contextWindow: profile.contextWindow
        )
    }
}

/// Creates the isolated endpoint used by background extraction.
///
/// Extraction deliberately does not reuse the conversational agent: doing so
/// would append the extraction prompt and report to the user's durable chat
/// transcript. Provider construction belongs here instead of in Conversation,
/// so the conversation actor depends only on the application-level factory.
public enum MemoryExtractionEndpointFactory {
    public static func make(
        configuration: MemoryExtractionConfiguration
    ) -> (any ModelEndpoint)? {
        switch configuration.provider {
        case .disabled, .unavailable:
            return nil
        case .ollama(let baseURL, let keepAlive):
            return OllamaEndpoint(
                model: configuration.model.rawValue,
                baseURL: baseURL,
                temperature: 0.2,
                numContext: configuration.contextWindow,
                keepAlive: keepAlive,
                think: false
            )
        }
    }
}

extension TurgaiAgentProfileStore {
    /// The extraction configuration for conversations served by a profile:
    /// the conversation's own model, or nil when extraction cannot run.
    func memoryExtractionConfiguration(forProfileID id: String) async -> MemoryExtractionConfiguration? {
        guard let profile = profile(id: id) else { return nil }
        return MemoryExtractionConfiguration(profile: profile)
    }
}
