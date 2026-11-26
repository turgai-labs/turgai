import ComposableArchitecture
import Foundation
import OSLog
import TurgaiModels

/// What the app's connection does, as Console shows it: what it sends, what comes back and when,
/// and how it ends.
private let log = Logger(subsystem: "Turgai", category: "live")

/// The app's one connection, `/api/v1/live`, open while someone's signed in: it shows one
/// conversation at a time, and whatever the app's windows ask and join.
@DependencyClient
package struct LiveClient: Sendable {
    /// Opens the signed-in account's one connection, showing no conversation until one is opened
    /// on it. The stream ends when the socket closes; replies never come in it.
    package var connect: @Sendable (Session) async -> AsyncThrowingStream<LiveEvent, any Error> = { _ in .finished() }
    /// What the connection hears, but replies, from whichever connection is open, until the one
    /// listening stops: a connection made again doesn't end it.
    package var events: @Sendable () async -> AsyncStream<LiveEvent> = { .finished }
    /// Sends what the window asks on the open connection: a conversation to show, a message to it,
    /// or an answer to an access request.
    package var send: @Sendable (LiveCommand) async throws -> Void
    /// Pushes `ask` and waits for its reply: throws when there's no connection, it closes first, or
    /// no reply comes in time.
    package var ask: @Sendable (LiveAsk) async throws -> LiveReply
    package var disconnect: @Sendable () async -> Void
}

/// Why a push got no reply.
package enum LiveSocketError: Error, Equatable {
    /// The connection closed before it came.
    case closed
    /// It didn't come in time.
    case noReply
    /// It came, and said it couldn't be done, and why.
    case failed(ChatError)
    /// It came, but wasn't what was asked for.
    case refused
    /// It came, but couldn't be read, as from a server newer than the app.
    case unreadable
}

/// What the connection heard, read: an event, or what couldn't be read, which is skipped, and,
/// when it was a reply, fails only the push it answers. One thing that can't be read never ends
/// the connection.
package enum Heard: Equatable {
    case event(LiveEvent)
    /// It couldn't be read; the push it replies to, when it's a reply whose ref can be.
    case unreadable(reply: PushRef?)

    package init(_ text: String) {
        let data = Data(text.utf8)
        if let event = try? JSONDecoder().decode(LiveEvent.self, from: data) {
            self = .event(event)
        } else {
            self = .unreadable(reply: (try? JSONDecoder().decode(Replying.self, from: data))?.ref)
        }
    }

    /// Only which push something replies to.
    private struct Replying: Decodable {
        let ref: PushRef
    }
}

extension LiveClient {
    /// `ask` done: throws when it wasn't.
    package func perform(_ ask: LiveAsk) async throws {
        switch try await self.ask(ask) {
        case .ok, .joined: return
        case .failed(let error): throw LiveSocketError.failed(error)
        case .memory: throw LiveSocketError.refused
        }
    }

    /// `topic` joined: what it is now, as its join's answer tells it, as the chat's open answers
    /// with its history; none for a topic that tells nothing until it changes.
    package func join(_ topic: LiveTopic) async throws -> LiveEvent? {
        switch try await ask(.join(topic)) {
        case .joined(let now): return now
        case .ok: return nil
        case .failed(let error): throw LiveSocketError.failed(error)
        case .memory: throw LiveSocketError.refused
        }
    }

    /// `topic` followed while `listen` hears it: what it is now, as its join answers, then each
    /// change as the connection hears it, listened to before it's joined, so none goes unheard.
    /// Left once `listen` ends, also when it's cancelled, as it is when another space is shown.
    package func following(_ topic: LiveTopic, _ listen: (AsyncStream<LiveEvent>) async -> Void) async {
        let heard = await events()
        let (told, telling) = AsyncStream.makeStream(of: LiveEvent.self)
        do {
            let now = try await join(topic)
            log.info(
                "Joined \(String(describing: topic), privacy: .public): \(now.map { $0.type.rawValue } ?? "nothing", privacy: .public)"
            )
            if let now { telling.yield(now) }
        } catch {
            log.error("Not joined \(String(describing: topic), privacy: .public): \(error, privacy: .public)")
        }
        let forwarding = Task {
            for await event in heard { telling.yield(event) }
            telling.finish()
        }
        await listen(told)
        log.info(
            "Following \(String(describing: topic), privacy: .public) ended, cancelled: \(Task.isCancelled, privacy: .public)"
        )
        forwarding.cancel()
        await Task { try? await perform(.leave(topic)) }.value
    }
}

extension LiveClient: DependencyKey {
    package static let liveValue: LiveClient = {
        let socket = LiveSocket()
        return LiveClient(
            connect: { await socket.connect($0) },
            events: { await socket.events() },
            send: { try await socket.send($0) },
            ask: { try await socket.ask($0) },
            disconnect: { await socket.disconnect() }
        )
    }()
}

extension DependencyValues {
    package var chat: LiveClient {
        get { self[LiveClient.self] }
        set { self[LiveClient.self] = newValue }
    }
}

/// Owns the one open socket, and the pushes waiting for their replies.
private actor LiveSocket {
    private var task: URLSessionWebSocketTask?
    private var waiting: [PushRef: CheckedContinuation<LiveReply, any Error>] = [:]
    /// When each push still waiting was asked.
    private var asked: [PushRef: ContinuousClock.Instant] = [:]
    /// The joins sent again on a new connection, whose answers no one waits for: what each says a
    /// topic is now is heard as the topic's other events are.
    private var rejoins: Set<PushRef> = []
    /// The topics joined, each as often as it's joined, joined again on each new connection, as
    /// Phoenix's client rejoins: a topic is followed until every join of it is left.
    private var joined: [LiveTopic: Int] = [:]
    /// Who listens to what's heard, while they listen.
    private var listeners: [UUID: AsyncStream<LiveEvent>.Continuation] = [:]
    /// How long a push waits for its reply.
    private static let replyTimeout: Duration = .seconds(10)

    package func connect(_ account: Session) async -> AsyncThrowingStream<LiveEvent, any Error> {
        task?.cancel(with: .goingAway, reason: nil)
        // To the session's own server, as a socket, its opening and closing told by its delegate, as
        // TCA's socket is.
        var request = account.request("api/v1/live")
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.scheme = account.server.url.scheme == "https" ? "wss" : "ws"
        request.url = components.url
        let delegate = SocketDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        log.info("Connecting, joining \(self.joined.count, privacy: .public) topics again")
        for (topic, joins) in joined {
            // As often as it was joined, so each leave still finds one. Its answer, what it is now,
            // is heard as its other events are.
            for _ in 0..<joins {
                let ref = PushRef()
                rejoins.insert(ref)
                try? await send(.push(ref: ref, ask: .join(topic)))
            }
        }

        return AsyncThrowingStream { continuation in
            let connection = Task {
                // Open until it closes, a message can't be received, or a ping isn't answered;
                // what's heard is taken in the meantime.
                let why = await withTaskGroup(of: (any Error)?.self) { group in
                    group.addTask {
                        for await result in Self.receive(task) {
                            switch result {
                            case .success(.string(let text)): await self.take(text, into: continuation)
                            case .success: continue
                            case .failure(let error): return error
                            }
                        }
                        return nil
                    }
                    group.addTask {
                        for await event in delegate.events {
                            if case .closed(let code) = event {
                                log.info("Closed: \(code.rawValue, privacy: .public)")
                                return nil
                            }
                        }
                        return nil
                    }
                    group.addTask { await Self.keepAlive(task) }
                    let why = await group.next() ?? nil
                    group.cancelAll()
                    return why
                }
                if let why {
                    log.error("Connection ended: \(why, privacy: .public)")
                    continuation.finish(throwing: why)
                } else {
                    log.info("Connection ended")
                    continuation.finish()
                }
                task.cancel(with: .goingAway, reason: nil)
                session.finishTasksAndInvalidate()
                self.ended(task)
            }
            continuation.onTermination = { _ in
                connection.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    /// `task`'s messages, each as it comes, a failure as one of them: the one place a socket's
    /// messages are made a stream, as TCA's socket makes them.
    private nonisolated static func receive(
        _ task: URLSessionWebSocketTask
    ) -> AsyncStream<Result<URLSessionWebSocketTask.Message, any Error>> {
        AsyncStream { continuation in
            let receiving = Task {
                while !Task.isCancelled {
                    do {
                        continuation.yield(.success(try await task.receive()))
                    } catch {
                        continuation.yield(.failure(error))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in receiving.cancel() }
        }
    }

    /// `task` pinged every ten seconds, as TCA's socket is, so a connection gone quiet is noticed:
    /// why it's gone, once a ping isn't answered.
    private nonisolated static func keepAlive(_ task: URLSessionWebSocketTask) async -> (any Error)? {
        for await _ in ContinuousClock().timer(interval: .seconds(10)) {
            do {
                try await withCheckedThrowingContinuation { (answered: CheckedContinuation<Void, any Error>) in
                    task.sendPing { error in
                        if let error { answered.resume(throwing: error) } else { answered.resume() }
                    }
                }
            } catch {
                return error
            }
        }
        return nil
    }

    /// `text`, as it's heard: told to whoever listens, or, when it's a reply, given to the push it
    /// answers; skipped, when it can't be read.
    private func take(_ text: String, into continuation: AsyncThrowingStream<LiveEvent, any Error>.Continuation) {
        let event: LiveEvent
        switch Heard(text) {
        case .event(let heard):
            event = heard
        case .unreadable(let reply):
            // Only the push it answers, when it's a reply, fails.
            log.error("Not read: \(String(text.prefix(300)), privacy: .public)")
            if let reply { unread(reply) }
            return
        }
        if case .reply(let ref, let reply) = event.payload {
            heard(ref, reply)
            if let now = rejoined(ref, reply) {
                continuation.yield(now)
                tell(now)
            }
            answer(ref, with: .success(reply))
        } else {
            continuation.yield(event)
            tell(event)
        }
    }

    /// What's heard from now on, until the stream's dropped.
    package func events() -> AsyncStream<LiveEvent> {
        let (events, continuation) = AsyncStream.makeStream(of: LiveEvent.self)
        let listener = UUID()
        listeners[listener] = continuation
        continuation.onTermination = { _ in Task { await self.stopListening(listener) } }
        return events
    }

    private func tell(_ event: LiveEvent) {
        for listener in listeners.values { listener.yield(event) }
    }

    private func stopListening(_ listener: UUID) {
        listeners[listener] = nil
    }

    package func send(_ command: LiveCommand) async throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        let data = try JSONEncoder().encode(command)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    package func ask(_ ask: LiveAsk) async throws -> LiveReply {
        switch ask {
        case .join(let topic): joined[topic, default: 0] += 1
        case .leave(let topic):
            joined[topic, default: 0] -= 1
            if joined[topic] ?? 0 <= 0 { joined[topic] = nil }
        case .memory, .forgetMemory, .setRemembering, .archiveSpace, .unarchiveSpace, .leaveConversation,
            .deleteConversation, .stopConversation, .changeSchedule, .cancelReminder, .pressPage:
            break
        }
        let ref = PushRef()
        log.info("Asked \(ref.rawValue, privacy: .public): \(String(describing: ask), privacy: .public)")
        return try await withCheckedThrowingContinuation { continuation in
            // Waiting before it's sent, so a reply quicker than the send still finds it.
            waiting[ref] = continuation
            asked[ref] = .now
            Task {
                do {
                    try await self.send(.push(ref: ref, ask: ask))
                } catch {
                    self.answer(ref, with: .failure(error))
                }
                try? await Task.sleep(for: Self.replyTimeout)
                self.answer(ref, with: .failure(LiveSocketError.noReply))
            }
        }
    }

    /// The reply to `ref` heard: who it's for, and how long it took.
    private func heard(_ ref: PushRef, _ reply: LiveReply) {
        let took = asked[ref].map { ContinuousClock.now - $0 }
        let whose = waiting[ref] != nil ? "waited for" : rejoins.contains(ref) ? "a join again" : "no one waits"
        log.info(
            "Replied \(ref.rawValue, privacy: .public): \(reply.description, privacy: .public), \(whose, privacy: .public), after \(String(describing: took), privacy: .public)"
        )
    }

    /// What a join sent again on a new connection says its topic is now, when `ref` is one.
    private func rejoined(_ ref: PushRef, _ reply: LiveReply) -> LiveEvent? {
        guard rejoins.remove(ref) != nil, case .joined(let now) = reply else { return nil }
        return now
    }

    /// The reply to `ref` couldn't be read: the push it answers fails, and a join sent again isn't
    /// waited for.
    private func unread(_ ref: PushRef) {
        rejoins.remove(ref)
        answer(ref, with: .failure(LiveSocketError.unreadable))
    }

    /// The push `ref` answered with `result`, if it's still waiting.
    private func answer(_ ref: PushRef, with result: Result<LiveReply, any Error>) {
        guard let waited = waiting.removeValue(forKey: ref) else { return }
        asked[ref] = nil
        if case .failure(let error) = result {
            log.error("No reply \(ref.rawValue, privacy: .public): \(error, privacy: .public)")
        }
        waited.resume(with: result)
    }

    /// `ended` closed: what's still waiting fails, unless a new connection has taken its place.
    private func ended(_ ended: URLSessionWebSocketTask) {
        guard ended === task else { return }
        failWaiting()
    }

    /// Every push still waiting, failed: the connection closed.
    private func failWaiting() {
        if !waiting.isEmpty { log.error("Closed with \(self.waiting.count, privacy: .public) pushes waiting") }
        for continuation in waiting.values { continuation.resume(throwing: LiveSocketError.closed) }
        waiting = [:]
        asked = [:]
    }

    package func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        joined = [:]
        failWaiting()
    }
}

/// What a socket's delegate tells of it: that it opened, and that it closed, and how.
private enum SocketEvent: Sendable {
    case opened
    case closed(URLSessionWebSocketTask.CloseCode)
}

/// A socket's delegate: its opening and closing, as a stream, as TCA's socket's delegate tells
/// them. It ends as the socket closes, or fails before it opens.
private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    let events: AsyncStream<SocketEvent>
    private let telling: AsyncStream<SocketEvent>.Continuation

    override init() {
        (events, telling) = AsyncStream.makeStream(of: SocketEvent.self)
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?
    ) {
        telling.yield(.opened)
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        telling.yield(.closed(closeCode))
        telling.finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        telling.finish()
    }
}
