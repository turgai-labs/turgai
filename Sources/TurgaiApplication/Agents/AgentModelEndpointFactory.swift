import AnyLanguageModel
import Hail

public actor AgentModelEndpointFactory {
    private let credentials: AgentCredentialStore
    #if Llama
        private let llamaCache = LlamaCPPEndpointCache()
    #endif
    /// How models send their requests: each in its provider account's limit, if it has one.
    private let transports: ModelTransports

    public init(credentials: AgentCredentialStore, transports: ModelTransports = ModelTransports()) {
        self.credentials = credentials
        self.transports = transports
    }

    public func endpoint(
        for profile: TurgaiAgentProfile,
        temperature: Double,
        ollamaKeepAlive: String? = nil,
        reasoning: ReasoningEffortSelection? = nil
    ) async throws -> any ModelEndpoint {
        try await endpoint(
            model: profile.model,
            configuration: profile.providerConfiguration,
            temperature: temperature,
            ollamaKeepAlive: ollamaKeepAlive,
            reasoning: reasoning
        )
    }

    public func endpoint(
        model agentModel: AgentModel,
        configuration: AgentProviderConfiguration,
        temperature: Double,
        ollamaKeepAlive: String? = nil,
        reasoning: ReasoningEffortSelection? = nil
    ) async throws -> any ModelEndpoint {
        let model = agentModel.id.rawValue
        let contextWindow = configuration.contextWindow
        let transport: any HTTPTransport =
            configuration.account(for: agentModel).map { transports.transport(for: $0) } ?? makeDefaultTransport()
        switch configuration {
        case .local(.appleSystem):
            try rejectReasoning(reasoning, provider: agentModel.provider, model: model)
            #if canImport(FoundationModels)
                return AnyLanguageModelEndpoint.system(
                    model: model,
                    temperature: temperature,
                    contextWindow: LocalModel.appleSystemContextWindow
                )
            #else
                throw AgentModelEndpointFactoryError.unavailable(.system)
            #endif
        #if Llama
            case .local(.llamaCPP(let file, let layers, let window)):
                try rejectReasoning(reasoning, provider: agentModel.provider, model: model)
                return await llamaCache.endpoint(
                    model: model,
                    modelPath: file,
                    temperature: temperature,
                    contextWindow: window.tokens,
                    gpuLayers: layers
                )
        #endif
        case .server(let server):
            var key: String?
            if let reference = server.key { key = try await credential(reference) }
            switch server.software {
            case .ollama:
                return AnyLanguageModelEndpoint.ollama(
                    model: model,
                    baseURL: server.address.url,
                    apiKey: key,
                    temperature: temperature,
                    context: Self.ollamaContext(server.context),
                    keepAlive: ollamaKeepAlive,
                    think: try Self.think(reasoning, model: agentModel),
                    transport: transport
                )
            case .openAICompatible(.chatCompletions):
                return AnyLanguageModelEndpoint(
                    languageModel: try Self.remote(configuration, model, key: key, transport: transport),
                    modelIdentifier: model,
                    temperature: temperature,
                    effectiveContextWindow: contextWindow,
                    generationOptions: try ModelRouter.generationOptions(
                        provider: .openAI, model: model, temperature: temperature, reasoning: reasoning
                    ),
                    failures: .openAICompatible
                )
            case .openAICompatible(.responses):
                try rejectReasoning(reasoning, provider: agentModel.provider, model: model)
                return AnyLanguageModelEndpoint(
                    languageModel: try Self.remote(configuration, model, key: key, transport: transport),
                    modelIdentifier: model,
                    temperature: temperature,
                    effectiveContextWindow: contextWindow,
                    failures: .openAICompatible
                )
            }
        case .cloud(let account):
            let key = try await credential(account.key)
            let languageModel = try Self.remote(configuration, model, key: key, transport: transport)
            switch account.provider {
            case .openAI:
                return AnyLanguageModelEndpoint(
                    languageModel: languageModel,
                    modelIdentifier: model,
                    temperature: temperature,
                    effectiveContextWindow: contextWindow,
                    generationOptions: try ModelRouter.generationOptions(
                        provider: .openAI, model: model, temperature: temperature, reasoning: reasoning
                    ),
                    failures: .openAI
                )
            case .anthropic:
                return AnyLanguageModelEndpoint(
                    languageModel: languageModel,
                    modelIdentifier: model,
                    temperature: temperature,
                    effectiveContextWindow: contextWindow,
                    generationOptions: try ModelRouter.generationOptions(
                        provider: .anthropic, model: model, temperature: temperature, reasoning: reasoning
                    ),
                    failures: .anthropic
                )
            case .gemini:
                return AnyLanguageModelEndpoint(
                    languageModel: languageModel,
                    modelIdentifier: model,
                    temperature: temperature,
                    effectiveContextWindow: contextWindow,
                    generationOptions: try ModelRouter.geminiGenerationOptions(
                        model: model, temperature: temperature, reasoning: reasoning
                    ),
                    failures: .gemini
                )
            }
        }
    }

    /// What an Ollama server is told of `context`: a window you chose, which it gives the model;
    /// or the model's own, which Ollama's cloud keeps whatever it's told, so it isn't sent.
    private static func ollamaContext(_ context: ModelContext) -> OllamaContext? {
        switch context {
        case .chosen(let window): .given(window.tokens)
        case .providers(.said(let window)): .own(window.tokens)
        case .providers(.unsaid): nil
        }
    }

    /// Ollama's `think` for `reasoning`: on or off, so effort none means off for any model, whether
    /// or not a catalog lists the model's reasoning levels; other levels can't be said.
    private static func think(_ reasoning: ReasoningEffortSelection?, model: AgentModel) throws -> Bool? {
        switch reasoning?.encoding {
        case nil: return nil
        case .disabled: return false
        case .raw where reasoning?.effort == ReasoningEffort.none: return false
        case .raw, .dynamic, .tokenBudget:
            throw ModelRouterError.unsupportedReasoningEffort(
                provider: model.provider,
                model: model.id.rawValue,
                effort: reasoning?.effort ?? .none
            )
        }
    }

    /// AnyLanguageModel's model for `model` where `configuration` says, as the check makes it too.
    private static func remote(
        _ configuration: AgentProviderConfiguration, _ model: String, key: String?, transport: any HTTPTransport
    ) throws -> any LanguageModel {
        guard let languageModel = configuration.location.remoteLanguageModel(model, key: key, transport: transport)
        else {
            throw AgentModelEndpointFactoryError.unavailable(configuration.provider.modelProvider)
        }
        return languageModel
    }

    private func rejectReasoning(
        _ reasoning: ReasoningEffortSelection?,
        provider: AgentModelProvider,
        model: String
    ) throws {
        guard let reasoning else { return }
        throw ModelRouterError.unsupportedReasoningEffort(
            provider: provider,
            model: model,
            effort: reasoning.effort
        )
    }

    private func credential(_ reference: AgentCredentialReference) async throws -> String {
        guard let value = try await credentials.value(for: reference) else {
            throw AgentModelEndpointFactoryError.missingCredential(reference)
        }
        return value
    }
}

public enum AgentModelEndpointFactoryError: Error, Sendable, Equatable {
    case missingCredential(AgentCredentialReference)
    case unavailable(AgentModelProvider)
}

extension ModelEndpoint {
    /// What the model answers `entries` with, in text, offered no tools: one request; `nil` when it
    /// gives no answer.
    func answer(_ entries: [Transcript.Entry]) async throws -> String? {
        let stream = stream(
            request: ModelRequest(input: entries, entries: entries), tools: [], authority: FullAuthority(),
            generating: String.self, purpose: .generation)
        for await event in stream {
            switch event {
            case .generated(let text): return text
            case .failed(let error): throw AgentRuntimeError.modelMisbehavior(String(describing: error))
            default: continue
            }
        }
        return nil
    }
}
