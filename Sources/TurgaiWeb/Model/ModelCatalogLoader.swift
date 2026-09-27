import Hail
import TurgaiApplication
import TurgaiHail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

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
        let providerDescriptors = Self.baseProviders
        var choices: [ModelProviderID: [TurgaiModelChoice]] = [:]
        var notices: [ModelProviderID: String] = [:]

        #if canImport(FoundationModels)
            if let model = try? AgentModel(
                provider: .system,
                id: AgentModelID(rawValue: "default")
            ) {
                choices[.system] = [
                    TurgaiModelChoice(
                        provider: .system,
                        identifier: model.identifier,
                        displayName: TurgaiModelPresentation.appleSystemModelName,
                        source: .fixed
                    )
                ]
            }
            notices[.system] = "Uses the on-device Foundation Model; there is no remote model list."
        #endif

        var ollamaBaseURLs: [URL] = profiles.compactMap { profile in
            guard case .ollama(let baseURL) = profile.providerConfiguration else { return nil }
            return baseURL
        }
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
                    TurgaiModelChoice(
                        provider: .ollama,
                        identifier: model.identifier,
                        displayName: name,
                        source: .discovered
                    ),
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

        notices[.openAI] = "Enter a model ID available to your OpenAI API account."
        notices[.anthropic] = "Enter a model ID available to your Anthropic API account."
        notices[.gemini] = "Enter a model ID available to your Gemini API account."
        notices[.openAICompatible] = "Enter the model ID supported by the configured compatible endpoint."
        notices[.llamaCPP] = "Choose a local GGUF file and enter its model ID."

        for profile in profiles {
            let model = profile.model
            let providerID = ModelProviderID(rawValue: model.provider.rawValue)
            // The catalog is the set of providers Turgai actually supports.
            // A model left in a profile must not make an excluded or unknown
            // Hail provider selectable again.
            guard providerDescriptors.contains(where: { $0.provider == providerID }) else { continue }
            Self.add(
                TurgaiModelChoice(
                    provider: providerID,
                    identifier: model.identifier,
                    displayName: model.id.rawValue,
                    source: .configured
                ),
                to: providerID,
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
        providers.append(
            TurgaiProviderDescriptor(
                provider: .anthropic,
                name: "Anthropic",
                summary: "Models available to an Anthropic API account",
                discovery: .account
            )
        )
        providers.append(
            TurgaiProviderDescriptor(
                provider: .gemini,
                name: "Gemini",
                summary: "Models available to a Gemini API account",
                discovery: .account
            )
        )
        providers.append(
            TurgaiProviderDescriptor(
                provider: .openAICompatible,
                name: "OpenAI-compatible endpoint",
                summary: "A custom Chat Completions or Responses endpoint",
                discovery: .manual
            )
        )
        providers.append(
            TurgaiProviderDescriptor(
                provider: .llamaCPP,
                name: "llama.cpp",
                summary: "A local GGUF model loaded by llama.cpp",
                discovery: .local
            )
        )
        return providers
    }

    private static func add(
        _ choice: TurgaiModelChoice,
        to provider: ModelProviderID,
        choices: inout [ModelProviderID: [TurgaiModelChoice]]
    ) {
        var providerChoices = choices[provider] ?? []
        guard !providerChoices.contains(where: { $0.identifier == choice.identifier }) else {
            return
        }
        providerChoices.append(choice)
        providerChoices.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        choices[provider] = providerChoices
    }

}
