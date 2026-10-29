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
        case .ollama(let baseURL, _):
            let think: Bool?
            switch reasoning?.encoding {
            case nil: think = nil
            case .disabled: think = false
            // Ollama's `think` is on or off, so effort none means off for any model, whether or not
            // a catalog lists the model's reasoning levels.
            case .raw where reasoning?.effort == ReasoningEffort.none: think = false
            case .raw, .dynamic, .tokenBudget:
                throw ModelRouterError.unsupportedReasoningEffort(
                    provider: agentModel.provider,
                    model: model,
                    effort: reasoning?.effort ?? .none
                )
            }
            return AnyLanguageModelEndpoint.ollama(
                model: model,
                baseURL: baseURL,
                temperature: temperature,
                contextWindow: contextWindow,
                keepAlive: ollamaKeepAlive,
                think: think,
                transport: transport
            )
        case .openAI(let reference, _):
            let apiKey = try await credential(reference)
            return AnyLanguageModelEndpoint(
                languageModel: OpenAILanguageModel(
                    apiKey: apiKey,
                    model: model,
                    transport: transport
                ),
                modelIdentifier: model,
                temperature: temperature,
                effectiveContextWindow: contextWindow,
                generationOptions: try ModelRouter.generationOptions(
                    provider: .openAI, model: model, temperature: temperature, reasoning: reasoning
                ),
                failures: .openAI
            )
        case .anthropic(let reference, _):
            let apiKey = try await credential(reference)
            return AnyLanguageModelEndpoint(
                languageModel: AnthropicLanguageModel(
                    apiKey: apiKey,
                    model: model,
                    transport: transport
                ),
                modelIdentifier: model,
                temperature: temperature,
                effectiveContextWindow: contextWindow,
                generationOptions: try ModelRouter.generationOptions(
                    provider: .anthropic, model: model, temperature: temperature, reasoning: reasoning
                ),
                failures: .anthropic
            )
        case .gemini(let reference, _):
            let apiKey = try await credential(reference)
            return AnyLanguageModelEndpoint(
                languageModel: GeminiLanguageModel(
                    apiKey: apiKey,
                    model: model,
                    transport: transport
                ),
                modelIdentifier: model,
                temperature: temperature,
                effectiveContextWindow: contextWindow,
                generationOptions: try ModelRouter.geminiGenerationOptions(
                    model: model, temperature: temperature, reasoning: reasoning
                ),
                failures: .gemini
            )
        case .openAICompatible(let baseURL, let reference, let api, _):
            let key = try await credential(reference)
            switch api {
            case .chatCompletions:
                return AnyLanguageModelEndpoint(
                    languageModel: OpenAILanguageModel(
                        baseURL: baseURL,
                        apiKey: key,
                        model: model,
                        transport: transport
                    ),
                    modelIdentifier: model,
                    temperature: temperature,
                    effectiveContextWindow: contextWindow,
                    generationOptions: try ModelRouter.generationOptions(
                        provider: .openAI, model: model, temperature: temperature, reasoning: reasoning
                    ),
                    failures: .openAICompatible
                )
            case .responses:
                try rejectReasoning(reasoning, provider: agentModel.provider, model: model)
                return AnyLanguageModelEndpoint(
                    languageModel: OpenResponsesLanguageModel(
                        baseURL: baseURL,
                        apiKey: key,
                        model: model,
                        transport: transport
                    ),
                    modelIdentifier: model,
                    temperature: temperature,
                    effectiveContextWindow: contextWindow,
                    failures: .openAICompatible
                )
            }
        case .appleSystem:
            try rejectReasoning(reasoning, provider: agentModel.provider, model: model)
            #if canImport(FoundationModels)
                return AnyLanguageModelEndpoint.system(
                    model: model,
                    temperature: temperature,
                    contextWindow: contextWindow
                )
            #else
                throw AgentModelEndpointFactoryError.unavailable(.system)
            #endif
        #if Llama
            case .llamaCPP(let configuration, _):
                try rejectReasoning(reasoning, provider: agentModel.provider, model: model)
                return await llamaCache.endpoint(
                    model: model,
                    modelPath: configuration.modelPath,
                    temperature: temperature,
                    contextWindow: contextWindow,
                    gpuLayers: configuration.gpuLayers
                )
        #endif
        }
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
        guard let value = await credentials.value(for: reference) else {
            throw AgentModelEndpointFactoryError.missingCredential(reference)
        }
        return value
    }
}

public enum AgentModelEndpointFactoryError: Error, Sendable, Equatable {
    case missingCredential(AgentCredentialReference)
    case unavailable(AgentModelProvider)
}
