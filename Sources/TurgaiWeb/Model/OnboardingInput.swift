import Hail
import TurgaiApplication
import TurgaiHail
import TurgaiPersistence

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
    static func model(from values: ModelFormValues) throws -> AgentModel {
        let providerValue = values.provider
        let modelValue = values.modelID
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
        from values: ModelFormValues,
        for model: AgentModel,
        existing: AgentProviderConfiguration? = nil
    ) throws -> ProviderSubmission {
        /// Only providers whose window is a choice ask for one.
        func contextWindow() throws -> Int {
            try positiveInteger(values.contextWindow, field: "context window")
        }
        switch model.provider {
        case .ollama:
            let rawValue =
                values.endpointURL?.isEmpty == false
                ? values.endpointURL!
                : OllamaConfiguration.defaultBaseURL.absoluteString
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
            guard let endpoint = values.endpointURL, !endpoint.isEmpty else {
                throw FormValidationError.invalidValue("model endpoint URL")
            }
            guard let api = OpenAICompatibleAPI(rawValue: values.compatibleAPI ?? "chatCompletions") else {
                throw FormValidationError.invalidValue("compatible API")
            }
            let existingReference: AgentCredentialReference?
            if case .openAICompatible(_, let reference, _, _) = existing {
                existingReference = reference
            } else {
                existingReference = nil
            }
            let reference = values.apiKey?.isEmpty == false ? .new() : (existingReference ?? .new())
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
        case .llamaCPP:
            guard let modelPath = values.modelPath, !modelPath.isEmpty else {
                throw FormValidationError.invalidValue("GGUF model path")
            }
            let gpuLayers = values.gpuLayers.flatMap(Int32.init) ?? -1
            return ProviderSubmission(
                configuration: .llamaCPP(
                    .init(modelPath: modelPath, gpuLayers: gpuLayers), contextWindow: try contextWindow()),
                credential: nil
            )
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

    static func reasoningEffort(from values: ModelFormValues) throws -> ReasoningEffort? {
        guard let rawValue = values.reasoningEffort, !rawValue.isEmpty else { return nil }
        guard let effort = try? ReasoningEffort(rawValue) else {
            throw FormValidationError.invalidValue("reasoning effort")
        }
        return effort
    }

    static func storageConfiguration(
        from form: [String: [String]],
        defaultFileDirectory: URL
    ) throws -> TurgaiStorageConfiguration {
        let values = StorageFormValues(form: form, defaultFileDirectory: defaultFileDirectory)
        switch values.backend {
        case .file:
            let value = values.fileURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(string: value) ?? defaultFileDirectory
            guard url.isFileURL else { throw FormValidationError.invalidValue("file store URL") }
            return try TurgaiStorageConfiguration.fileStore(directory: url)
        case .postgres:
            guard let rawURL = URL(string: values.postgresURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
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
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty else { return [] }
        var result: [Int64] = []
        var seen = Set<Int64>()
        for value in normalizedValue.split(separator: ",", omittingEmptySubsequences: false) {
            let rawValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawValue.isEmpty, let id = Int64(rawValue), id != 0 else {
                throw FormValidationError.invalidValue("Telegram chat ID")
            }
            guard seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }
}
