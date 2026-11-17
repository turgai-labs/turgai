import TurgaiDomain
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The first space, as setting up chose it: made as the server starts, by whoever set it up, as
/// anyone makes a space; forgotten once it's made.
public struct FirstSpace: Codable, Sendable {
    public let id: SpaceID
    public let name: SpaceName
    public let maker: UserID
    public let bot: Bot
}

public actor TurgaiSetupStore {
    struct State: Codable {
        var storage: TurgaiStorageConfiguration?
        /// The first space, until it's made.
        var firstSpace: FirstSpace?
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
    /// The first space, once setting up has one, until it's made.
    public var firstSpace: FirstSpace? { state.firstSpace }

    func waitUntilComplete() async {
        guard !state.complete else { return }
        for await _ in completionStream {
            return
        }
    }

    func stopWaiting() {
        completionContinuation.finish()
    }

    /// Whether setting up has all it asks for: where memory is kept, and the first space.
    var isReady: Bool {
        state.storage != nil && state.firstSpace != nil
    }

    func setFirstSpace(_ space: FirstSpace) throws {
        state.firstSpace = space
        try persist()
    }

    /// The first space made: setting up holds it no more.
    public func firstSpaceMade() throws {
        state.firstSpace = nil
        try persist()
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
