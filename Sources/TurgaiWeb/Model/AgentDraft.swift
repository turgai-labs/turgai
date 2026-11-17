import Hail
import TurgaiAgents
import TurgaiApplication
import TurgaiDomain
import TurgaiHail
import TurgaiModels

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A bot as its form shows it and sends it back: a new one, a saved one, or what was just
/// submitted, shown again when saving it failed. What's typed stays as typed; it's read into a
/// bot only when it's saved.
struct AgentDraft: Sendable, Equatable {
    var name: String
    var instructions: String
    var provider: AgentProvider
    var modelID: String
    var settings: ProviderSettingsDraft
}

/// The chosen provider's own settings, as typed.
struct ProviderSettingsDraft: Sendable, Equatable {
    /// A server's address: for Ollama, empty is the one on this machine.
    var address: String
    var compatibleAPI: String
    var modelFile: String
    var gpuLayers: String
    /// The window chosen, where it's yours to choose: empty is the model's own.
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
            name: name, instructions: "",
            provider: .ollama,
            modelID: "",
            settings: ProviderSettingsDraft(
                address: "", compatibleAPI: OpenAICompatibleAPI.chatCompletions.rawValue, modelFile: "",
                gpuLayers: "-1", contextWindow: "", requestLimit: "", apiKey: "", savedKeyProvider: nil))
    }

    /// The saved `bot`, whose provider account takes `requestLimit` requests at once.
    init(_ bot: TurgaiDomain.Bot, requestLimit: Int?) {
        let configuration = bot.model.location
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
            if case .chosen(let window) = server.context { settings.contextWindow = String(window.tokens) }
        case .cloud:
            break
        }
        self.init(
            name: bot.name.rawValue, instructions: bot.instructions, provider: configuration.provider,
            modelID: bot.model.name.rawValue, settings: settings)
    }

    /// What was submitted, over `saved`: a key not typed again stays the saved one.
    init(form: [String: [String]], over saved: AgentDraft) {
        func typed(_ key: String) -> String? {
            form[key]?.first?.trimmed()
        }
        self = saved
        name = form["name"]?.first ?? saved.name
        instructions = form["instructions"]?.first ?? saved.instructions
        provider = typed("provider").flatMap(AgentProvider.init(name:)) ?? saved.provider
        modelID = typed("modelID") ?? saved.modelID
        settings.address = typed("address") ?? saved.settings.address
        settings.compatibleAPI = typed("compatibleAPI") ?? saved.settings.compatibleAPI
        settings.modelFile = typed("modelFile") ?? saved.settings.modelFile
        settings.gpuLayers = typed("gpuLayers") ?? saved.settings.gpuLayers
        settings.contextWindow = typed("contextWindow") ?? saved.settings.contextWindow
        settings.requestLimit = typed("requestLimit") ?? saved.settings.requestLimit
        settings.apiKey = typed("apiKey") ?? ""
    }
}

extension AgentDraft {
    /// `configuration`, a bot as an app gives it, as its form would: a server that speaks OpenAI's
    /// API with its chat completions.
    init(_ configuration: TurgaiModels.BotConfiguration) {
        let model = configuration.model
        self.init(
            name: configuration.name, instructions: configuration.instructions,
            provider: AgentProvider(name: model.provider.rawValue) ?? .ollama, modelID: model.model,
            settings: ProviderSettingsDraft(
                address: model.address ?? "", compatibleAPI: OpenAICompatibleAPI.chatCompletions.rawValue,
                modelFile: model.model, gpuLayers: "", contextWindow: model.contextWindow.map(String.init) ?? "",
                requestLimit: "", apiKey: model.apiKey ?? "", savedKeyProvider: nil))
    }

    /// The bot it describes, `saved` changed, or a new one: its model checked where it runs with
    /// its key; and a key typed now, which is kept before the bot is saved.
    ///
    /// - Throws: ``FormValidationError`` for a name that isn't one, ``ModelRefusal`` when the model
    ///   can't be used there.
    func bot(over saved: TurgaiDomain.Bot?, credentials: AgentCredentialStore) async throws -> (
        bot: TurgaiDomain.Bot, newKey: (reference: AgentCredentialReference, value: String)?
    ) {
        guard let botName = BotName(name) else { throw FormValidationError.invalidValue("name") }
        let checked = try await OnboardingInput.submission(from: self, saved: saved?.model.location)
            .checked(credentials: credentials)
        guard let modelName = ModelName(checked.model.rawValue) else {
            throw FormValidationError.invalidValue("model")
        }
        let model = BotModel(location: checked.configuration, name: modelName)
        let bot =
            saved.map { TurgaiDomain.Bot(id: $0.id, name: botName, instructions: instructions, model: model) }
            ?? TurgaiDomain.Bot(name: botName, instructions: instructions, model: model)
        return (bot, checked.newKey)
    }
}
