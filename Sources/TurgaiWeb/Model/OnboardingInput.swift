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

    static func providerConfiguration(
        from values: ModelFormValues,
        for model: AgentModel
    ) throws -> AgentProviderConfiguration {
        guard model.provider == .ollama else { return .none }
        guard let rawValue = values.endpointURL, !rawValue.isEmpty else {
            return .ollama(baseURL: OllamaConfiguration.defaultBaseURL)
        }
        guard let url = URL(string: rawValue),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil
        else {
            throw FormValidationError.invalidValue("model endpoint URL")
        }
        return .ollama(baseURL: url)
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
