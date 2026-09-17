import Hail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Configuration for Turgai's current background memory extractor.
///
/// The extractor is intentionally named as an Ollama configuration until it
/// can use the same provider router as user-facing turns. Keeping the pair
/// together prevents endpoint and model IDs from being passed independently
/// through every connection layer.
public struct OllamaMemoryConfiguration: Codable, Sendable, Equatable {
    public let model: AgentModelID
    public let baseURL: URL
    /// Context window used by background extraction. A smaller value reduces
    /// memory use; matching the chat window avoids Ollama runner switching.
    public let contextWindow: Int
    public let keepAlive: String?

    public init(model: AgentModelID, baseURL: URL, contextWindow: Int = 4_096, keepAlive: String? = "10m") {
        self.model = model
        self.baseURL = baseURL
        self.contextWindow = contextWindow
        self.keepAlive = keepAlive
    }
}
