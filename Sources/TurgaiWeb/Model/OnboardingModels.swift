import TurgaiDomain
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

struct CredentialsFormValues: Sendable, Equatable {
    let username: String
    let password: String

    init(form: [String: [String]]) {
        username = form["username"]?.first?.trimmed() ?? ""
        password = form["password"]?.first ?? ""
    }
}
