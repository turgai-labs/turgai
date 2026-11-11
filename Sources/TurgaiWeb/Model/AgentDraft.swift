import Hail
import TurgaiApplication
import TurgaiDomain
import TurgaiHail

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
    var provider: AgentProvider
    var modelID: String
    /// The chosen level's name: empty is the provider's default.
    var reasoningEffort: String
    var settings: ProviderSettingsDraft
}

/// The chosen provider's own settings, as typed.
struct ProviderSettingsDraft: Sendable, Equatable {
    /// A server's address: for Ollama, empty is the one on this machine.
    var address: String
    var compatibleAPI: String
    var modelFile: String
    var gpuLayers: String
    /// Empty is the model's own.
    var contextWindow: String
    /// Empty is no limit.
    var requestLimit: String
    /// A key typed now. Never shown back.
    var apiKey: String
    /// The provider whose key is already saved, when one is.
    var savedKeyProvider: AgentProvider?
}

extension AgentDraft {
    /// A new agent called `name`, on Ollama on this machine.
    static func new(named name: String) -> AgentDraft {
        AgentDraft(
            name: name, persona: "", instructions: "",
            provider: .ollama,
            modelID: "", reasoningEffort: "",
            settings: ProviderSettingsDraft(
                address: "", compatibleAPI: OpenAICompatibleAPI.chatCompletions.rawValue, modelFile: "",
                gpuLayers: "-1", contextWindow: "", requestLimit: "", apiKey: "", savedKeyProvider: nil))
    }

    /// The saved `profile`, whose provider account takes `requestLimit` requests at once.
    init(_ profile: TurgaiAgentProfile, requestLimit: Int?) {
        let configuration = profile.providerConfiguration
        var settings = ProviderSettingsDraft(
            address: "", compatibleAPI: OpenAICompatibleAPI.chatCompletions.rawValue, modelFile: "", gpuLayers: "-1",
            contextWindow: "", requestLimit: requestLimit.map(String.init) ?? "", apiKey: "",
            savedKeyProvider: configuration.credentialReference == nil ? nil : configuration.provider)
        switch configuration {
        case .local(.appleSystem):
            break
        #if Llama
            case .local(.llamaCPP(let file, let layers, let window)):
                settings.modelFile = file
                settings.gpuLayers = String(layers)
                settings.contextWindow = String(window.tokens)
        #endif
        case .server(let server):
            settings.address = server.address.description
            if case .openAICompatible(let api) = server.software { settings.compatibleAPI = api.rawValue }
            settings.contextWindow = String(server.contextWindow.tokens)
        case .cloud(let account):
            settings.contextWindow = String(account.contextWindow.tokens)
        }
        self.init(
            name: profile.name, persona: profile.persona ?? "", instructions: profile.instructions,
            provider: configuration.provider, modelID: profile.model.id.rawValue,
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
        provider = typed("provider").flatMap(AgentProvider.init(name:)) ?? saved.provider
        modelID = typed("modelID") ?? saved.modelID
        reasoningEffort = typed("reasoningEffort") ?? saved.reasoningEffort
        settings.address = typed("address") ?? saved.settings.address
        settings.compatibleAPI = typed("compatibleAPI") ?? saved.settings.compatibleAPI
        settings.modelFile = typed("modelFile") ?? saved.settings.modelFile
        settings.gpuLayers = typed("gpuLayers") ?? saved.settings.gpuLayers
        settings.contextWindow = typed("contextWindow") ?? saved.settings.contextWindow
        settings.requestLimit = typed("requestLimit") ?? saved.settings.requestLimit
        settings.apiKey = typed("apiKey") ?? ""
    }
}
