import ComposableArchitecture
import Foundation
import TurgaiModels

/// The app's one connection, `/api/v1/live`, open while someone's signed in: it shows one
/// conversation at a time, and whatever the app's windows ask and join.
@DependencyClient
struct ChatClient: Sendable {
    /// Opens the signed-in account's one connection, showing no conversation until one is opened
    /// on it. The stream ends when the socket closes; replies never come in it.
    var connect: @Sendable (Session) async -> AsyncThrowingStream<ChatEvent, any Error> = { _ in .finished() }
    /// Sends what the window asks on the open connection: a conversation to show, a message to it,
    /// or an answer to an access request.
    var send: @Sendable (ChatCommand) async throws -> Void
    /// Pushes `ask` and waits for its reply: throws when there's no connection, it closes first, or
    /// no reply comes in time.
    var ask: @Sendable (ChatAsk) async throws -> ChatReply
    var disconnect: @Sendable () async -> Void
}

/// Why a push got no reply.
enum ChatSocketError: Error, Equatable {
    /// The connection closed before it came.
    case closed
    /// It didn't come in time.
    case noReply
    /// It came, but said it failed, or wasn't what was asked for.
    case refused
}

extension ChatClient {
    /// `ask` done: throws when it wasn't.
    func perform(_ ask: ChatAsk) async throws {
        guard try await self.ask(ask) == .ok else { throw ChatSocketError.refused }
    }

    /// What's remembered about the person, and whether they're remembered.
    func memory() async throws -> MemorySummary {
        guard case .memory(let summary) = try await ask(.memory) else { throw ChatSocketError.refused }
        return summary
    }
}

extension ChatClient: DependencyKey {
    static let liveValue: ChatClient = {
        let socket = ChatSocket(baseURL: LocalServer.baseURL)
        return ChatClient(
            connect: { await socket.connect($0) },
            send: { try await socket.send($0) },
            ask: { try await socket.ask($0) },
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

/// Owns the one open socket, and the pushes waiting for their replies.
private actor ChatSocket {
    let baseURL: URL
    private let session = URLSession(configuration: .ephemeral)
    private var task: URLSessionWebSocketTask?
    private var waiting: [PushRef: CheckedContinuation<ChatReply, any Error>] = [:]
    /// The topics joined, joined again on each new connection, as Phoenix's client rejoins.
    private var joined: Set<ChatTopic> = []
    /// How long a push waits for its reply.
    private static let replyTimeout: Duration = .seconds(10)

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
        for topic in joined {
            // Its reply finds no one waiting: what shows it reads again once it's connected.
            try? await send(.push(ref: PushRef(), ask: .join(topic)))
        }

        return AsyncThrowingStream { continuation in
            let receiving = Task {
                do {
                    while !Task.isCancelled {
                        guard case .string(let text) = try await task.receive() else { continue }
                        let event = try JSONDecoder().decode(ChatEvent.self, from: Data(text.utf8))
                        if case .reply(let ref, let reply) = event.payload {
                            self.answer(ref, with: .success(reply))
                        } else {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                self.ended(task)
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

    func ask(_ ask: ChatAsk) async throws -> ChatReply {
        switch ask {
        case .join(let topic): joined.insert(topic)
        case .leave(let topic): joined.remove(topic)
        case .memory, .forgetMemory, .setRemembering: break
        }
        let ref = PushRef()
        return try await withCheckedThrowingContinuation { continuation in
            // Waiting before it's sent, so a reply quicker than the send still finds it.
            waiting[ref] = continuation
            Task {
                do {
                    try await self.send(.push(ref: ref, ask: ask))
                } catch {
                    self.answer(ref, with: .failure(error))
                }
                try? await Task.sleep(for: Self.replyTimeout)
                self.answer(ref, with: .failure(ChatSocketError.noReply))
            }
        }
    }

    /// The push `ref` answered with `result`, if it's still waiting.
    private func answer(_ ref: PushRef, with result: Result<ChatReply, any Error>) {
        waiting.removeValue(forKey: ref)?.resume(with: result)
    }

    /// `ended` closed: what's still waiting fails, unless a new connection has taken its place.
    private func ended(_ ended: URLSessionWebSocketTask) {
        guard ended === task else { return }
        failWaiting()
    }

    /// Every push still waiting, failed: the connection closed.
    private func failWaiting() {
        for continuation in waiting.values { continuation.resume(throwing: ChatSocketError.closed) }
        waiting = [:]
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        joined = []
        failWaiting()
    }
}
