import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

actor TurgaiSetupStore {
    struct State: Codable {
        var storage: TurgaiStorageConfiguration?
        var telegramChatIDs: [Int64] = []
        var telegramConfigured = false
        var complete = false
    }
    private let stateURL: URL
    private let secretURL: URL
    private let postgresPasswordURL: URL
    private let completionStream: AsyncStream<Void>
    private let completionContinuation: AsyncStream<Void>.Continuation
    private var state: State

    init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        stateURL = directory.appendingPathComponent("setup.json")
        secretURL = directory.appendingPathComponent("telegram-token")
        postgresPasswordURL = directory.appendingPathComponent("postgres-password")
        let completion = AsyncStream<Void>.makeStream()
        completionStream = completion.stream
        completionContinuation = completion.continuation
        state = try (try? Data(contentsOf: stateURL)).map { try JSONDecoder().decode(State.self, from: $0) } ?? State()
        if state.complete {
            completionContinuation.yield(())
            completionContinuation.finish()
        }
    }

    var isComplete: Bool { state.complete }
    var storageConfiguration: TurgaiStorageConfiguration? { state.storage }
    var telegramChatIDs: [Int64] { state.telegramChatIDs }

    func waitUntilComplete() async {
        guard !state.complete else { return }
        for await _ in completionStream {
            return
        }
    }

    var isReady: Bool {
        guard state.storage != nil, state.telegramConfigured,
            let token = try? String(contentsOf: secretURL, encoding: .utf8)
        else { return false }
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setStorage(
        _ storage: TurgaiStorageConfiguration,
        postgresPassword: String?
    ) throws {
        if case .postgres = storage {
            guard let postgresPassword,
                !postgresPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw TurgaiStorageConfigurationError.invalidPostgresPassword
            }
            try Data(postgresPassword.utf8).write(to: postgresPasswordURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: postgresPasswordURL.path
            )
        } else if FileManager.default.fileExists(atPath: postgresPasswordURL.path) {
            try FileManager.default.removeItem(at: postgresPasswordURL)
        }
        state.storage = storage
        try persist()
    }

    func setTelegramToken(_ token: String, chatIDs: [Int64]) throws {
        try Data(token.utf8).write(to: secretURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretURL.path)
        state.telegramChatIDs = chatIDs
        state.telegramConfigured = true
        try persist()
    }

    func complete() throws {
        guard !state.complete else { return }
        state.complete = true
        try persist()
        completionContinuation.yield(())
        completionContinuation.finish()
    }

    private func persist() throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
}
