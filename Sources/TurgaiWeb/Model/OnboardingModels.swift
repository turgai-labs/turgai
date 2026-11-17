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

/// A new account's username and password, the password typed twice.
struct NewCredentialsFormValues: Sendable, Equatable {
    let username: String
    let password: String
    /// The password typed again.
    let passwordAgain: String

    init(form: [String: [String]]) {
        username = form["username"]?.first?.trimmed() ?? ""
        password = form["password"]?.first ?? ""
        passwordAgain = form["passwordAgain"]?.first ?? ""
    }

    /// Whether both passwords are the same.
    var passwordsMatch: Bool { password == passwordAgain }

    /// What's said when they aren't.
    static let passwordsDiffer = "The two passwords differ. Type the same password in both."
}
