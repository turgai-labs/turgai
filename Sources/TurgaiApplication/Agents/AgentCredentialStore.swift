import TurgaiPersistence

public actor AgentCredentialStore {
    private let files: FileClient

    public init(files: FileClient) {
        self.files = files
    }

    public func save(_ value: String, for reference: AgentCredentialReference) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TurgaiAgentCredentialError.empty }
        try files.saveSecret(value, at: path(for: reference))
    }

    public func value(for reference: AgentCredentialReference) -> String? {
        (try? files.loadSecret(at: path(for: reference))) ?? nil
    }

    public func contains(_ reference: AgentCredentialReference) -> Bool {
        value(for: reference) != nil
    }

    public func remove(_ reference: AgentCredentialReference) throws {
        try files.delete(at: path(for: reference))
    }

    private func path(for reference: AgentCredentialReference) -> String {
        "agents/credentials/\(reference.rawValue).secret"
    }
}

public enum TurgaiAgentCredentialError: Error, Sendable, Equatable {
    case empty
    case missing(AgentCredentialReference)
}
