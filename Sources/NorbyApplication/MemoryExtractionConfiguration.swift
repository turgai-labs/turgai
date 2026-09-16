import Hail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Configuration for Norby's current background memory extractor.
///
/// The extractor is intentionally named as an Ollama configuration until it
/// can use the same provider router as user-facing turns. Keeping the pair
/// together prevents endpoint and model IDs from being passed independently
/// through every connection layer.
public struct OllamaMemoryConfiguration: Codable, Sendable, Equatable {
    public let model: AgentModelID
    public let baseURL: URL

    public init(model: AgentModelID, baseURL: URL) {
        self.model = model
        self.baseURL = baseURL
    }
}
