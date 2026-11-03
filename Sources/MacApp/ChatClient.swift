import ComposableArchitecture
import Foundation
import TurgaiModels

/// The app's one connection, `/api/v1/live`, showing one conversation at a time.
@DependencyClient
struct ChatClient: Sendable {
    /// Opens the signed-in account's latest conversation, or a new one with the default bot when
    /// it has none. The stream ends when the socket closes.
    var connect: @Sendable (Session) async -> AsyncThrowingStream<ChatEvent, any Error> = { _ in .finished() }
    /// Sends a message or an answer to an access request on the open socket.
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
    /// The conversation it opened, and whose: reconnecting opens it again.
    private var opened: (account: String, conversation: ConversationID)?

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func connect(_ account: Session) async -> AsyncThrowingStream<ChatEvent, any Error> {
        task?.cancel(with: .goingAway, reason: nil)
        let conversation: ConversationID
        do {
            conversation = try await self.conversation(for: account)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        var components = URLComponents(url: baseURL.appending(path: "api/v1/live"), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: components.url!)
        request.setValue("\(LocalServer.sessionCookieName)=\(account.token)", forHTTPHeaderField: "Cookie")
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        do {
            try await send(.open(conversationID: conversation))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

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
        opened = nil
    }

    /// The conversation `account` chats in: the one it opened before, else its latest, else a new
    /// one with the default bot.
    private func conversation(for account: Session) async throws -> ConversationID {
        if let opened, opened.account == account.token { return opened.conversation }
        let conversations: [Conversation] = try await self.request("GET", "api/v1/conversations", as: account)
        let conversation: ConversationID
        if let latest = conversations.first {
            conversation = latest.id
        } else {
            let started: Conversation = try await self.request(
                "POST", "api/v1/conversations", body: CreateConversationRequest(), as: account)
            conversation = started.id
        }
        opened = (account.token, conversation)
        return conversation
    }

    /// The API's answer to `method` on `path`, asked as `account`: refused unless it succeeded.
    private func request<Answer: Decodable>(
        _ method: String, _ path: String, body: (some Encodable)? = Optional<String>.none, as account: Session
    ) async throws -> Answer {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("\(LocalServer.sessionCookieName)=\(account.token)", forHTTPHeaderField: "Cookie")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Answer.self, from: data)
    }
}
