import Hail
import TurgaiApplication
import TurgaiHail
import TurgaiPersistence
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

enum OnboardingInput {
    struct ProviderSubmission: Sendable {
        let configuration: AgentProviderConfiguration
        let credential: (reference: AgentCredentialReference, value: String)?
    }
    static func model(from draft: AgentDraft) throws -> AgentModel {
        let providerValue = draft.provider.rawValue
        let modelValue = draft.modelID
        guard !providerValue.isEmpty, !modelValue.isEmpty else {
            throw FormValidationError.invalidValue("model")
        }

        let provider = AgentModelProvider(rawValue: providerValue)
        if modelValue.contains("/") {
            guard let fullModel = try? AgentModel(modelValue), fullModel.provider == provider else {
                throw FormValidationError.invalidValue("model")
            }
            return fullModel
        }
        guard let model = try? AgentModel(provider: provider, id: AgentModelID(rawValue: modelValue)) else {
            throw FormValidationError.invalidValue("model")
        }
        return model
    }

    static func providerSubmission(
        from draft: AgentDraft,
        for model: AgentModel,
        existing: AgentProviderConfiguration? = nil
    ) throws -> ProviderSubmission {
        /// Only providers whose window is a choice ask for one.
        let values = draft.settings
        func contextWindow() throws -> Int {
            try positiveInteger(values.contextWindow, field: "context window")
        }
        switch model.provider {
        case .ollama:
            let rawValue =
                values.endpointURL.isEmpty ? OllamaConfiguration.defaultBaseURL.absoluteString : values.endpointURL
            return ProviderSubmission(
                configuration: .ollama(baseURL: try httpURL(rawValue), contextWindow: try contextWindow()),
                credential: nil
            )
        case .openAI:
            return try credentialSubmission(
                value: values.apiKey,
                existing: existing,
                matches: { if case .openAI = $0 { true } else { false } },
                configuration: { [window = try contextWindow()] in .openAI(credential: $0, contextWindow: window) }
            )
        case .anthropic:
            return try credentialSubmission(
                value: values.apiKey,
                existing: existing,
                matches: { if case .anthropic = $0 { true } else { false } },
                configuration: { [window = try contextWindow()] in .anthropic(credential: $0, contextWindow: window) }
            )
        case .gemini:
            return try credentialSubmission(
                value: values.apiKey,
                existing: existing,
                matches: { if case .gemini = $0 { true } else { false } },
                configuration: { [window = try contextWindow()] in .gemini(credential: $0, contextWindow: window) }
            )
        case .openAICompatible:
            let endpoint = values.endpointURL
            guard !endpoint.isEmpty else {
                throw FormValidationError.invalidValue("model endpoint URL")
            }
            guard let api = OpenAICompatibleAPI(rawValue: values.compatibleAPI) else {
                throw FormValidationError.invalidValue("compatible API")
            }
            let existingReference: AgentCredentialReference?
            if case .openAICompatible(_, let reference, _, _) = existing {
                existingReference = reference
            } else {
                existingReference = nil
            }
            let reference = values.apiKey.isEmpty ? (existingReference ?? .new()) : .new()
            return try submission(
                configuration: .openAICompatible(
                    baseURL: httpURL(endpoint),
                    credential: reference,
                    api: api,
                    contextWindow: contextWindow()
                ),
                reference: reference,
                apiKey: values.apiKey,
                hasExistingCredential: existingReference != nil
            )
        case .system:
            return ProviderSubmission(configuration: .appleSystem, credential: nil)
        #if Llama
            case .llamaCPP:
                let modelPath = values.modelPath
                guard !modelPath.isEmpty else {
                    throw FormValidationError.invalidValue("GGUF model path")
                }
                let gpuLayers = Int32(values.gpuLayers) ?? -1
                return ProviderSubmission(
                    configuration: .llamaCPP(
                        .init(modelPath: modelPath, gpuLayers: gpuLayers), contextWindow: try contextWindow()),
                    credential: nil
                )
        #endif
        default:
            throw FormValidationError.invalidValue("provider")
        }
    }

    private static func httpURL(_ rawValue: String) throws -> URL {
        guard let url = URL(string: rawValue),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil
        else {
            throw FormValidationError.invalidValue("model endpoint URL")
        }
        return url
    }

    private static func credentialSubmission(
        value: String?,
        existing: AgentProviderConfiguration?,
        matches: (AgentProviderConfiguration) -> Bool,
        configuration: (AgentCredentialReference) -> AgentProviderConfiguration
    ) throws -> ProviderSubmission {
        let existingReference = existing.flatMap { matches($0) ? $0.credentialReference : nil }
        let reference = value?.isEmpty == false ? .new() : (existingReference ?? .new())
        return try submission(
            configuration: configuration(reference),
            reference: reference,
            apiKey: value,
            hasExistingCredential: existingReference != nil
        )
    }

    private static func submission(
        configuration: AgentProviderConfiguration,
        reference: AgentCredentialReference,
        apiKey: String?,
        hasExistingCredential: Bool
    ) throws -> ProviderSubmission {
        if let apiKey, !apiKey.isEmpty {
            return ProviderSubmission(
                configuration: configuration,
                credential: (reference, apiKey)
            )
        }
        guard hasExistingCredential else {
            throw FormValidationError.invalidValue("API key")
        }
        return ProviderSubmission(configuration: configuration, credential: nil)
    }

    static func reasoningEffort(from draft: AgentDraft) throws -> ReasoningEffort? {
        let rawValue = draft.reasoningEffort
        guard !rawValue.isEmpty else { return nil }
        guard let effort = try? ReasoningEffort(rawValue) else {
            throw FormValidationError.invalidValue("reasoning effort")
        }
        return effort
    }

    static func storageConfiguration(from form: [String: [String]]) throws -> TurgaiStorageConfiguration {
        let values = StorageFormValues(form: form)
        switch values.backend {
        case .local:
            return .local
        case .postgres:
            guard let rawURL = URL(string: values.postgresURL.trimmed()) else {
                throw FormValidationError.invalidValue("PostgreSQL URL")
            }
            return try TurgaiStorageConfiguration.postgresStore(url: rawURL, username: values.postgresUsername)
        }
    }

    static func positiveInteger(_ value: String?, field: String) throws -> Int {
        guard let value, let integer = Int(value), integer > 0 else {
            throw FormValidationError.invalidValue(field)
        }
        return integer
    }

    static func chatIDs(from value: String?) throws -> [Int64] {
        guard let value else { return [] }
        let normalizedValue = value.trimmed()
        guard !normalizedValue.isEmpty else { return [] }
        var result: [Int64] = []
        var seen = Set<Int64>()
        for value in normalizedValue.split(separator: ",", omittingEmptySubsequences: false) {
            let rawValue = value.trimmed()
            guard !rawValue.isEmpty, let id = Int64(rawValue), id != 0 else {
                throw FormValidationError.invalidValue("Telegram chat ID")
            }
            guard seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }
}
