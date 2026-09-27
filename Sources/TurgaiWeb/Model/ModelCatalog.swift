import Hail
import TurgaiApplication

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

#if canImport(FoundationModels)
    import FoundationModels
#endif

public enum TurgaiModelPresentation {
    public static func displayName(for model: AgentModel) -> String {
        guard model.provider == .system else { return model.identifier }
        return "Apple Intelligence · \(appleSystemModelName)"
    }

    public static var appleSystemModelName: String {
        #if canImport(FoundationModels)
            if #available(macOS 27.0, *) {
                return SystemLanguageModel.default.variant.displayName
            }
        #endif
        return "Apple Foundation Model"
    }
}

/// How a provider supplies model names to the dashboard.
public struct ModelProviderID: RawRepresentable, Hashable, Codable, Sendable, Equatable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let system = Self(rawValue: "system")
    public static let ollama = Self(rawValue: "ollama")
    public static let openAI = Self(rawValue: "openai")
    public static let anthropic = Self(rawValue: "anthropic")
    public static let gemini = Self(rawValue: "gemini")
    public static let openAICompatible = Self(rawValue: "openai-compatible")
    public static let llamaCPP = Self(rawValue: "llama-cpp")
}

public struct TurgaiProviderDescriptor: Sendable, Equatable {
    public enum Discovery: String, Codable, Sendable, Equatable {
        case fixed
        case local
        case account
        case manual
    }

    public let provider: ModelProviderID
    public let name: String
    public let summary: String
    public let discovery: Discovery

    public var id: String { provider.rawValue }

    public init(
        provider: ModelProviderID,
        name: String,
        summary: String,
        discovery: Discovery
    ) {
        self.provider = provider
        self.name = name
        self.summary = summary
        self.discovery = discovery
    }
}

/// One model the dashboard may suggest. Suggestions are never authoritative:
/// the profile stores the provider/model identifier and users may enter a
/// model that a provider did not return from discovery.
public struct TurgaiModelChoice: Sendable, Equatable, Identifiable {
    public enum Source: String, Codable, Sendable, Equatable {
        case fixed
        case discovered
        case configured
    }

    public let provider: ModelProviderID
    public let identifier: String
    public let displayName: String
    public let source: Source

    public var id: String { "\(provider.rawValue)/\(identifier)" }

    public init(
        provider: ModelProviderID,
        identifier: String,
        displayName: String,
        source: Source
    ) {
        self.provider = provider
        self.identifier = identifier
        self.displayName = displayName
        self.source = source
    }
}

/// Provider-aware model suggestions used by Turgai's HTML forms.
public struct TurgaiModelCatalog: Sendable, Equatable {
    public let providers: [TurgaiProviderDescriptor]
    public let choicesByProvider: [ModelProviderID: [TurgaiModelChoice]]
    public let noticesByProvider: [ModelProviderID: String]

    public init(
        providers: [TurgaiProviderDescriptor],
        choicesByProvider: [ModelProviderID: [TurgaiModelChoice]],
        noticesByProvider: [ModelProviderID: String] = [:]
    ) {
        self.providers = providers
        self.choicesByProvider = choicesByProvider
        self.noticesByProvider = noticesByProvider
    }

    public func choices(for provider: ModelProviderID) -> [TurgaiModelChoice] {
        choicesByProvider[provider] ?? []
    }

    public func provider(for provider: ModelProviderID) -> TurgaiProviderDescriptor? {
        providers.first { $0.provider == provider }
    }

    public func notice(for provider: ModelProviderID) -> String? {
        noticesByProvider[provider]
    }
}
