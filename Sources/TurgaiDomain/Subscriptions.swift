#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What an actor that gives its live updates as a sequence keeps of its subscribers, as Hail's
/// agent keeps its activity's: each one's backlog, and its pull while one waits. It holds no one:
/// a subscriber is an id.
public struct Pulls<Element: Sendable>: Sendable {
    /// What a pull finds now.
    public enum Taken: Sendable {
        case element(Element)
        /// Nothing yet: the pull waits for the next one told.
        case empty
        /// The subscriber has left.
        case ended
    }

    private var backlogs: [UUID: [Element]] = [:]
    private var waiting: [UUID: CheckedContinuation<Element?, Never>] = [:]

    public init() {}

    /// Whether no one is subscribed.
    public var isEmpty: Bool { backlogs.isEmpty }

    /// `subscriber` told each element from now on, before it first pulls.
    public mutating func subscribe(_ subscriber: UUID) {
        if backlogs[subscriber] == nil { backlogs[subscriber] = [] }
    }

    /// What `subscriber`'s pull finds now: the first of its backlog, nothing yet, or that it left.
    public mutating func take(_ subscriber: UUID) -> Taken {
        guard var backlog = backlogs[subscriber] else { return .ended }
        guard !backlog.isEmpty else { return .empty }
        let element = backlog.removeFirst()
        backlogs[subscriber] = backlog
        return .element(element)
    }

    /// `subscriber`'s pull waiting for the next element told: one it had waiting ends.
    public mutating func park(_ subscriber: UUID, _ pull: CheckedContinuation<Element?, Never>) {
        waiting.updateValue(pull, forKey: subscriber)?.resume(returning: nil)
    }

    /// `subscriber` gone: a pull it has waiting ends.
    public mutating func leave(_ subscriber: UUID) {
        backlogs.removeValue(forKey: subscriber)
        waiting.removeValue(forKey: subscriber)?.resume(returning: nil)
    }

    /// `element` told to each subscriber `to` picks: a waiting pull returns it, the others find it in
    /// their backlog.
    public mutating func tell(_ element: Element, to picks: (UUID) -> Bool = { _ in true }) {
        for subscriber in backlogs.keys where picks(subscriber) {
            if let pull = waiting.removeValue(forKey: subscriber) {
                pull.resume(returning: element)
            } else {
                backlogs[subscriber]?.append(element)
            }
        }
    }
}

/// One subscriber's live updates from an actor, `for await element in subscription`, subscribed
/// already: until it's cancelled, or its task is.
public struct Subscription<Element: Sendable>: AsyncSequence, Sendable {
    private let subscriber: UUID
    private let pull: @Sendable (UUID) async throws -> Element?
    private let leaving: @Sendable (UUID) async throws -> Void

    /// `subscriber`'s updates, pulled by `pull`, and left by `leave`.
    public init(
        _ subscriber: UUID, pull: @escaping @Sendable (UUID) async throws -> Element?,
        leave: @escaping @Sendable (UUID) async throws -> Void
    ) {
        self.subscriber = subscriber
        self.pull = pull
        self.leaving = leave
    }

    /// It's left: a pull waiting ends.
    public func cancel() async {
        try? await leaving(subscriber)
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(subscription: self)
    }

    public struct Iterator: AsyncIteratorProtocol {
        let subscription: Subscription

        public func next() async -> Element? {
            if Task.isCancelled { return nil }
            let subscription = self.subscription
            return await withTaskCancellationHandler {
                try? await subscription.pull(subscription.subscriber)
            } onCancel: {
                Task { await subscription.cancel() }
            }
        }
    }
}
