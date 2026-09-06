import AsyncAlgorithms
import NorbyDomain

/// The terminal outcome of one scoped operation.
enum ScopeOutcome<Result: Sendable>: Sendable {
    case completed(Result)
    case failed(ConversationFailure)
    case cancelled
}

/// A one-way update capability given to the work running inside a scope.
///
/// The scope owns its lifetime; callers can send updates but cannot finish or
/// close the underlying transport.
struct PartialSink<Update: Sendable>: Sendable {
    private let sendUpdate: @Sendable (Update) async -> Void

    init(send: @escaping @Sendable (Update) async -> Void) {
        self.sendUpdate = send
    }

    func send(_ update: Update) async {
        await sendUpdate(update)
    }
}

/// The typeclass interpreted by ``withScope``.
///
/// ``perform(using:)`` is the scoped operation itself. It receives only a
/// partial-update sink; lifecycle completion remains owned by ``withScope``.
protocol ScopeLifecycle: Sendable {
    associatedtype Result: Sendable
    associatedtype Update: Sendable

    func start() async
    func perform(using updates: PartialSink<Update>) async throws -> Result
    func update(_ update: Update) async
    func heartbeat() async
    func finish(_ outcome: ScopeOutcome<Result>) async
}

/// Runs one structured lifecycle scope.
///
/// The heartbeat child and the scoped operation are cancelled together. The
/// operation can publish updates while it runs, but only this function emits
/// the terminal outcome.
func withScope<L: ScopeLifecycle>(
    _ scope: L,
    mapError: @escaping @Sendable (any Error) -> ConversationFailure = { _ in
        ConversationFailure(
            kind: .unknown,
            message: "The operation could not be completed."
        )
    }
) async throws -> L.Result {
    await scope.start()

    let updates = PartialSink<L.Update> { update in
        await scope.update(update)
    }

    do {
        let result = try await withThrowingTaskGroup(of: L.Result.self) { group in
            group.addTask {
                try await scope.perform(using: updates)
            }
            group.addTask {
                for await _ in AsyncTimerSequence(
                    interval: .seconds(4),
                    clock: .continuous
                ) {
                    try Task.checkCancellation()
                    await scope.heartbeat()
                }
                throw ScopeError.heartbeatFinished
            }

            guard let result = try await group.next() else {
                throw ScopeError.operationFinishedWithoutResult
            }

            group.cancelAll()
            return result
        }

        await scope.finish(.completed(result))
        return result
    } catch is CancellationError {
        await scope.finish(.cancelled)
        throw CancellationError()
    } catch let failure as ConversationFailure {
        await scope.finish(.failed(failure))
        throw failure
    } catch {
        let failure = mapError(error)
        await scope.finish(.failed(failure))
        // Keep the original error for the caller and logs. The mapped value is
        // only the channel-facing lifecycle result.
        throw error
    }
}

private enum ScopeError: Error {
    case heartbeatFinished
    case operationFinishedWithoutResult
}
