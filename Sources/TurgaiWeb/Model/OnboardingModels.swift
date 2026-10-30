import TurgaiDomain
#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

enum StorageBackend: String, Sendable, Equatable {
    /// Turgai's own database, on this machine.
    case local
    case postgres
}

struct StorageFormValues: Sendable, Equatable {
    let backend: StorageBackend
    let postgresURL: String
    let postgresUsername: String

    init(
        backend: StorageBackend,
        postgresURL: String,
        postgresUsername: String
    ) {
        self.backend = backend
        self.postgresURL = postgresURL
        self.postgresUsername = postgresUsername
    }

    init(form: [String: [String]]) {
        self.backend = StorageBackend(rawValue: form["backend"]?.first ?? "") ?? .local
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
