import Hail
import TurgaiApplication
import TurgaiDomain
import TurgaiHail
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

enum OnboardingInput {
    /// Where `draft` says its model runs.
    static func location(from draft: AgentDraft) throws(FormValidationError) -> ModelLocation {
        let values = draft.settings
        switch draft.provider {
        case .appleSystem:
            return .appleSystem
        #if Llama
            case .llamaCPP:
                guard !values.modelFile.isEmpty else { throw .invalidValue("GGUF model file") }
                guard let layers = Int32(values.gpuLayers) else { throw .invalidValue("number of GPU layers") }
                return .llamaCPP(file: values.modelFile, gpuLayers: layers)
        #endif
        case .ollama:
            return .server(.ollama, values.address.isEmpty ? .localOllama : try address(values.address))
        case .openAICompatible:
            guard let api = OpenAICompatibleAPI(rawValue: values.compatibleAPI) else {
                throw .invalidValue("compatible API")
            }
            return .server(.openAICompatible(api), try address(values.address))
        case .openAI:
            return .cloud(.openAI)
        case .anthropic:
            return .cloud(.anthropic)
        case .gemini:
            return .cloud(.gemini)
        }
    }

    /// What `draft` gives for its model, read: its key the one typed, or else the one `saved`
    /// keeps for the same place.
    static func submission(from draft: AgentDraft, saved: AgentProviderConfiguration?) throws(FormValidationError)
        -> ModelSubmission
    {
        let location = try location(from: draft)
        guard !draft.modelID.isEmpty else { throw .invalidValue("model") }
        var window: ContextWindow?
        if !draft.settings.contextWindow.isEmpty {
            guard let tokens = Int(draft.settings.contextWindow), let typed = try? ContextWindow(tokens: tokens) else {
                throw .invalidValue("context window")
            }
            window = typed
        }
        return ModelSubmission(
            location: location, model: AgentModelID(rawValue: draft.modelID),
            key: ModelSubmission.Key(typed: draft.settings.apiKey, at: location, saved: saved),
            contextWindow: window)
    }

    private static func address(_ written: String) throws(FormValidationError) -> ServerAddress {
        do { return try ServerAddress(written) } catch { throw .invalidValue("server address") }
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
