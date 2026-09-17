#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

enum StorageBackend: String, Sendable, Equatable {
    case file
    case postgres
}

struct StorageFormValues: Sendable, Equatable {
    let backend: StorageBackend
    let fileURL: String
    let postgresURL: String
    let postgresUsername: String

    init(
        backend: StorageBackend,
        fileURL: String,
        postgresURL: String,
        postgresUsername: String
    ) {
        self.backend = backend
        self.fileURL = fileURL
        self.postgresURL = postgresURL
        self.postgresUsername = postgresUsername
    }

    init(form: [String: [String]], defaultFileDirectory: URL) {
        self.backend = StorageBackend(rawValue: form["backend"]?.first ?? "") ?? .file
        self.fileURL = form["fileURL"]?.first ?? defaultFileDirectory.absoluteString
        self.postgresURL = form["postgresURL"]?.first ?? ""
        self.postgresUsername = form["postgresUsername"]?.first ?? ""
    }
}

struct BotFormValues: Sendable, Equatable {
    let name: String
    let contextWindow: String?
    let persona: String?
    let instructions: String
    let telegramChatIDs: String?

    init(form: [String: [String]], nameKey: String = "name") {
        name = form[nameKey]?.first ?? ""
        contextWindow = form["contextWindow"]?.first
        persona = form["persona"]?.first
        instructions = form["instructions"]?.first ?? ""
        telegramChatIDs = form["telegramChatIDs"]?.first
    }
}

struct TelegramFormValues: Sendable, Equatable {
    let token: String?
    let chatIDs: String?

    init(form: [String: [String]]) {
        token = form["token"]?.first
        chatIDs = form["chatIDs"]?.first
    }
}

struct ModelFormValues: Sendable, Equatable {
    let provider: String
    let modelID: String
    let ollamaBaseURL: String?

    init(form: [String: [String]]) {
        provider = form["provider"]?.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        modelID = form["modelID"]?.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ollamaBaseURL = form["ollamaBaseURL"]?.first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CredentialsFormValues: Sendable, Equatable {
    let username: String
    let password: String

    init(form: [String: [String]]) {
        username = form["username"]?.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        password = form["password"]?.first ?? ""
    }
}
