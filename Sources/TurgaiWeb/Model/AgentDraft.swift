import Hail
import TurgaiApplication
import TurgaiHail
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// An agent as its form shows it and sends it back: a new one, a saved one, or what was just
/// submitted, shown again when saving it failed. What's typed stays as typed; it's read into a
/// profile only when it's saved.
struct AgentDraft: Sendable, Equatable {
    var name: String
    var persona: String
    var instructions: String
    var provider: AgentModelProvider
    var modelID: String
    /// The chosen level's name: empty is the provider's default.
    var reasoningEffort: String
    var settings: ProviderSettingsDraft
}

/// The chosen provider's own settings, as typed.
struct ProviderSettingsDraft: Sendable, Equatable {
    var endpointURL: String
    var compatibleAPI: String
    var modelPath: String
    var gpuLayers: String
    var contextWindow: String
    /// Empty is no limit.
    var requestLimit: String
    /// A key typed now. Never shown back.
    var apiKey: String
    /// The provider whose key is already saved, when one is.
    var savedKeyProvider: AgentModelProvider?
}

extension AgentDraft {
    /// A new agent called `name`, on the catalog's first local provider.
    static func new(named name: String, in catalog: TurgaiModelCatalog) -> AgentDraft {
        let providers = catalog.providers.map { AgentModelProvider(rawValue: $0.provider.rawValue) }
        let provider = providers.contains(.ollama) ? .ollama : providers.first ?? .ollama
        return AgentDraft(
            name: name, persona: "", instructions: "",
            provider: provider,
            modelID: "", reasoningEffort: "",
            settings: ProviderSettingsDraft(
                endpointURL: provider == .ollama ? OllamaConfiguration.defaultBaseURL.absoluteString : "",
                compatibleAPI: OpenAICompatibleAPI.chatCompletions.rawValue, modelPath: "", gpuLayers: "-1",
                contextWindow: String(TurgaiAgentProfileStore.defaultContextWindow), requestLimit: "", apiKey: "",
                savedKeyProvider: nil))
    }

    /// The saved `profile`, whose provider account takes `requestLimit` requests at once.
    init(_ profile: TurgaiAgentProfile, requestLimit: Int?) {
        let configuration = profile.providerConfiguration
        var settings = ProviderSettingsDraft(
            endpointURL: "",
            compatibleAPI: OpenAICompatibleAPI.chatCompletions.rawValue, modelPath: "", gpuLayers: "-1",
            contextWindow: String(profile.contextWindow), requestLimit: requestLimit.map(String.init) ?? "",
            apiKey: "", savedKeyProvider: configuration.credentialReference == nil ? nil : profile.model.provider)
        switch configuration {
        case .ollama(let url, _):
            settings.endpointURL = url.absoluteString
        case .openAICompatible(let url, _, let api, _):
            settings.endpointURL = url.absoluteString
            settings.compatibleAPI = api.rawValue
        #if Llama
            case .llamaCPP(let llama, _):
                settings.modelPath = llama.modelPath
                settings.gpuLayers = String(llama.gpuLayers)
        #endif
        case .openAI, .anthropic, .gemini, .appleSystem:
            break
        }
        self.init(
            name: profile.name, persona: profile.persona ?? "", instructions: profile.instructions,
            provider: profile.model.provider, modelID: profile.model.id.rawValue,
            reasoningEffort: profile.reasoningEffort?.rawValue ?? "", settings: settings)
    }

    /// What was submitted, over `saved`: a key not typed again stays the saved one.
    init(form: [String: [String]], over saved: AgentDraft) {
        func typed(_ key: String) -> String? {
            form[key]?.first?.trimmed()
        }
        self = saved
        name = form["name"]?.first ?? saved.name
        persona = form["persona"]?.first ?? saved.persona
        instructions = form["instructions"]?.first ?? saved.instructions
        provider = typed("provider").map(AgentModelProvider.init(rawValue:)) ?? saved.provider
        modelID = typed("modelID") ?? saved.modelID
        reasoningEffort = typed("reasoningEffort") ?? saved.reasoningEffort
        settings.endpointURL = typed("endpointURL") ?? saved.settings.endpointURL
        settings.compatibleAPI = typed("compatibleAPI") ?? saved.settings.compatibleAPI
        settings.modelPath = typed("modelPath") ?? saved.settings.modelPath
        settings.gpuLayers = typed("gpuLayers") ?? saved.settings.gpuLayers
        settings.contextWindow = typed("contextWindow") ?? saved.settings.contextWindow
        settings.requestLimit = typed("requestLimit") ?? saved.settings.requestLimit
        settings.apiKey = typed("apiKey") ?? ""
    }
}
