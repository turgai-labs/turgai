import ComposableArchitecture
import Foundation
import TurgaiModels

/// The app's one connection, `/api/v1/live`, showing one conversation at a time.
@DependencyClient
struct ChatClient: Sendable {
    /// Opens the signed-in account's one connection, showing no conversation until one is opened
    /// on it. The stream ends when the socket closes.
    var connect: @Sendable (Session) async -> AsyncThrowingStream<ChatEvent, any Error> = { _ in .finished() }
    /// Sends what the window asks on the open connection: a conversation to show, a message to it,
    /// or an answer to an access request.
    var send: @Sendable (ChatCommand) async throws -> Void
    var disconnect: @Sendable () async -> Void
}

extension ChatClient: DependencyKey {
    static let liveValue: ChatClient = {
        let socket = ChatSocket(baseURL: LocalServer.baseURL)
        return ChatClient(
            connect: { await socket.connect($0) },
            send: { try await socket.send($0) },
            disconnect: { await socket.disconnect() }
        )
    }()
}

extension DependencyValues {
    var chat: ChatClient {
        get { self[ChatClient.self] }
        set { self[ChatClient.self] = newValue }
    }
}

/// Owns the one open socket.
private actor ChatSocket {
    let baseURL: URL
    private let session = URLSession(configuration: .ephemeral)
    private var task: URLSessionWebSocketTask?

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func connect(_ account: Session) async -> AsyncThrowingStream<ChatEvent, any Error> {
        task?.cancel(with: .goingAway, reason: nil)
        var components = URLComponents(url: baseURL.appending(path: "api/v1/live"), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: components.url!)
        request.setValue("\(LocalServer.sessionCookieName)=\(account.token)", forHTTPHeaderField: "Cookie")
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()

        return AsyncThrowingStream { continuation in
            let receiving = Task {
                do {
                    while !Task.isCancelled {
                        guard case .string(let text) = try await task.receive() else { continue }
                        continuation.yield(try JSONDecoder().decode(ChatEvent.self, from: Data(text.utf8)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                receiving.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    func send(_ command: ChatCommand) async throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        let data = try JSONEncoder().encode(command)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}
