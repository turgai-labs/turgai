import TurgaiPersistence
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public actor TurgaiSetupStore {
    struct State: Codable {
        var storage: TurgaiStorageConfiguration?
        var complete = false
    }
    private let stateURL: URL
    private let completionStream: AsyncStream<Void>
    private let completionContinuation: AsyncStream<Void>.Continuation
    private var state: State

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        stateURL = directory.appendingPathComponent("setup.json")
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

    func waitUntilComplete() async {
        guard !state.complete else { return }
        for await _ in completionStream {
            return
        }
    }

    func stopWaiting() {
        completionContinuation.finish()
    }

    var isReady: Bool {
        state.storage != nil
    }

    func setStorage(_ storage: TurgaiStorageConfiguration) throws {
        state.storage = storage
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
