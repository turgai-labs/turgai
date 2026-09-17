import Hail
import TurgaiApplication
import TurgaiHail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// How a provider supplies model names to the dashboard.
public struct TurgaiProviderDescriptor: Sendable, Equatable {
    public enum Discovery: String, Codable, Sendable, Equatable {
        case fixed
        case local
        case account
        case manual
    }

    public let provider: AgentModelProvider
    public let name: String
    public let summary: String
    public let discovery: Discovery

    public var id: String { provider.rawValue }

    public init(
        provider: AgentModelProvider,
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

    public let model: AgentModel
    public let displayName: String
    public let source: Source

    public var id: String { model.identifier }

    public init(
        model: AgentModel,
        displayName: String,
        source: Source
    ) {
        self.model = model
        self.displayName = displayName
        self.source = source
    }
}

/// Provider-aware model suggestions used by Turgai's HTML forms.
public struct TurgaiModelCatalog: Sendable, Equatable {
    public let providers: [TurgaiProviderDescriptor]
    public let choicesByProvider: [AgentModelProvider: [TurgaiModelChoice]]
    public let noticesByProvider: [AgentModelProvider: String]

    public init(
        providers: [TurgaiProviderDescriptor],
        choicesByProvider: [AgentModelProvider: [TurgaiModelChoice]],
        noticesByProvider: [AgentModelProvider: String] = [:]
    ) {
        self.providers = providers
        self.choicesByProvider = choicesByProvider
        self.noticesByProvider = noticesByProvider
    }

    public func choices(for provider: AgentModelProvider) -> [TurgaiModelChoice] {
        choicesByProvider[provider] ?? []
    }

    public func provider(for model: AgentModel?) -> TurgaiProviderDescriptor? {
        guard let model else { return nil }
        return providers.first { $0.provider == model.provider }
    }

    public func notice(for provider: AgentModelProvider) -> String? {
        noticesByProvider[provider]
    }
}

/// Loads model suggestions at the dashboard boundary. The model runtime does
/// not depend on this type: discovery is UI/configuration infrastructure, and
/// every provider is free to have different availability and credentials.
public enum TurgaiModelCatalogLoader {

    /// Provider discovery is injected so the dashboard can use live adapters
    /// while tests and future configuration backends can stay deterministic.
    public struct Discovery: Sendable {
        public typealias Ollama = @Sendable (URL) async throws -> [String]

        public let ollama: Ollama

        public init(ollama: @escaping Ollama) {
            self.ollama = ollama
        }

        public static let live = Self(
            ollama: { baseURL in
                let service = OllamaService(configuration: OllamaConfiguration(baseURL: baseURL))
                return try await service.models().map(\.rawValue)
            }
        )
    }

    public static func load(
        profiles: [TurgaiAgentProfile],
        discovery: Discovery = .live
    ) async -> TurgaiModelCatalog {
        var providerDescriptors = Self.baseProviders
        var choices: [AgentModelProvider: [TurgaiModelChoice]] = [:]
        var notices: [AgentModelProvider: String] = [:]

        #if canImport(FoundationModels)
            if let model = try? AgentModel(
                provider: .system,
                id: AgentModelID(rawValue: "default")
            ) {
                choices[.system] = [
                    TurgaiModelChoice(
                        model: model,
                        displayName: "On-device Apple model",
                        source: .fixed
                    )
                ]
            }
            notices[.system] = "Uses the on-device Foundation Model; there is no remote model list."
        #endif

        var ollamaBaseURLs = Array(Set(profiles.compactMap(\.ollamaBaseURL)))
        if ollamaBaseURLs.isEmpty {
            ollamaBaseURLs = [OllamaConfiguration.defaultBaseURL]
        }
        let ollamaNames = await Self.discoverOllama(
            baseURLs: ollamaBaseURLs,
            discovery: discovery
        )

        if let names = ollamaNames {
            for name in names {
                guard
                    let model = try? AgentModel(
                        provider: .ollama,
                        id: AgentModelID(rawValue: name)
                    )
                else { continue }
                Self.add(
                    TurgaiModelChoice(model: model, displayName: name, source: .discovered),
                    to: .ollama,
                    choices: &choices
                )
            }
            notices[.ollama] =
                names.isEmpty
                ? "No models were discovered. Start Ollama or enter a model ID manually."
                : "Models discovered from this Ollama server."
        } else {
            notices[.ollama] = "Ollama could not be reached. Enter a model ID manually or check its URL."
        }

        notices[.openAI] = "OpenAI model discovery will be available when an account is configured."

        for profile in profiles {
            let model = profile.model
            if !providerDescriptors.contains(where: { $0.provider == model.provider }) {
                providerDescriptors.append(
                    TurgaiProviderDescriptor(
                        provider: model.provider,
                        name: model.provider.rawValue,
                        summary: "Configured provider; enter model IDs manually.",
                        discovery: .manual
                    )
                )
                notices[model.provider] = "Enter a model ID for this provider."
            }
            Self.add(
                TurgaiModelChoice(
                    model: model,
                    displayName: model.id.rawValue,
                    source: .configured
                ),
                to: model.provider,
                choices: &choices
            )
        }

        return TurgaiModelCatalog(
            providers: providerDescriptors,
            choicesByProvider: choices,
            noticesByProvider: notices
        )
    }

    private static func discoverOllama(
        baseURLs: [URL],
        discovery: Discovery
    ) async -> [String]? {
        var discovered = Set<String>()
        var reachedServer = false
        for baseURL in baseURLs {
            guard let names = try? await discovery.ollama(baseURL) else { continue }
            reachedServer = true
            discovered.formUnion(names)
        }
        guard reachedServer else { return nil }
        return discovered.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private static var baseProviders: [TurgaiProviderDescriptor] {
        var providers: [TurgaiProviderDescriptor] = []
        #if canImport(FoundationModels)
            providers.append(
                TurgaiProviderDescriptor(
                    provider: .system,
                    name: "Apple Intelligence",
                    summary: "On-device Foundation Model",
                    discovery: .fixed
                )
            )
        #endif
        providers.append(
            TurgaiProviderDescriptor(
                provider: .ollama,
                name: "Ollama",
                summary: "Models from a local Ollama server",
                discovery: .local
            )
        )
        providers.append(
            TurgaiProviderDescriptor(
                provider: .openAI,
                name: "OpenAI",
                summary: "Models available to an API account",
                discovery: .account
            )
        )
        return providers
    }

    private static func add(
        _ choice: TurgaiModelChoice,
        to provider: AgentModelProvider,
        choices: inout [AgentModelProvider: [TurgaiModelChoice]]
    ) {
        var providerChoices = choices[provider] ?? []
        guard !providerChoices.contains(where: { $0.model.identifier == choice.model.identifier }) else {
            return
        }
        providerChoices.append(choice)
        providerChoices.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        choices[provider] = providerChoices
    }

}
