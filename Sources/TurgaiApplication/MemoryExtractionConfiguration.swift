import Hail

/// Provider configuration captured by a durable extraction workflow.
/// Credentials remain references, so secret values never enter workflow history.
public enum MemoryExtractionProviderConfiguration: Codable, Sendable, Equatable {
    case disabled
    case configured(
        AgentProviderConfiguration,
        ollamaKeepAlive: String?
    )
}

/// The model snapshot used by one background extraction workflow.
/// Profile edits affect newly scheduled work; accepted work remains replayable
/// from the configuration captured when it was scheduled.
public struct MemoryExtractionConfiguration: Codable, Sendable, Equatable {
    public let model: AgentModel
    public let provider: MemoryExtractionProviderConfiguration

    public init(
        model: AgentModel,
        provider: MemoryExtractionProviderConfiguration
    ) {
        self.model = model
        self.provider = provider
    }

    public init(profile: TurgaiAgentProfile) {
        self.init(
            model: profile.model,
            provider: .configured(
                profile.providerConfiguration,
                ollamaKeepAlive: profile.model.provider == .ollama ? "10m" : nil
            )
        )
    }

    public var isEnabled: Bool {
        if case .configured = provider { return true }
        return false
    }
}

extension TurgaiAgentProfileStore {
    func memoryExtractionConfiguration(forProfileID id: String) async throws -> MemoryExtractionConfiguration? {
        guard let profile = try await profile(id: id) else { return nil }
        return MemoryExtractionConfiguration(profile: profile)
    }
}
