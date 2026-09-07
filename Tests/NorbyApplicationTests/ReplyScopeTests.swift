import NorbyDomain
import Testing

@testable import NorbyApplication

struct ReplyScopeTests {
    @Test
    func successfulOperationHasOneStartedAndOneFinishedOutcome() async throws {
        let scope = ScopeRecorder { _ in
            "answer"
        }

        let result = try await withScope(scope)

        #expect(result == "answer")
        #expect(await scope.events == ["started", "finished:answer"])
    }

    @Test
    func failedOperationFinishesTheReplyWithTheDomainFailure() async {
        let scope = ScopeRecorder { _ in
            throw ConversationFailure(
                kind: .model,
                message: "model unavailable"
            )
        }

        do {
            _ = try await withScope(scope)
            Issue.record("Expected the reply operation to fail")
        } catch let actual as ConversationFailure {
            #expect(actual.message == "model unavailable")
        } catch {
            Issue.record("Expected ConversationFailure, got \(error)")
        }

        #expect(await scope.events == ["started", "failed:model unavailable"])
    }

    @Test
    func unexpectedOperationErrorsAreMappedForLifecycleButPreservedForCaller() async {
        let scope = ScopeRecorder { _ in
            throw InternalScopeError.secret
        }

        do {
            _ = try await withScope(scope)
            Issue.record("Expected the reply operation to fail")
        } catch let error as InternalScopeError {
            #expect(error == .secret)
        } catch {
            Issue.record("Expected InternalScopeError, got \(error)")
        }

        #expect(
            await scope.events == [
                "started",
                "failed:The operation could not be completed.",
            ])
    }

    @Test
    func operationCanPublishPartialUpdatesThroughTheScope() async throws {
        let scope = ScopeRecorder { updates in
            await updates.send("partial")
            return "answer"
        }

        _ = try await withScope(scope)

        #expect(
            await scope.events == [
                "started",
                "partial:partial",
                "finished:answer",
            ])
    }
}

private enum InternalScopeError: Error, Equatable {
    case secret
}

private actor ScopeRecorder: ScopeLifecycle {
    typealias Result = String
    typealias Update = String

    private(set) var events: [String] = []
    private let operation: @Sendable (PartialSink<String>) async throws -> String

    init(
        operation: @escaping @Sendable (PartialSink<String>) async throws -> String
    ) {
        self.operation = operation
    }

    func start() {
        events.append("started")
    }

    func perform(using updates: PartialSink<String>) async throws -> String {
        try await operation(updates)
    }

    func update(_ update: String) {
        events.append("partial:\(update)")
    }

    func heartbeat() {
        events.append("heartbeat")
    }

    func finish(_ outcome: ScopeOutcome<String>) {
        switch outcome {
        case .completed(let text):
            events.append("finished:\(text)")
        case .failed(let failure):
            events.append("failed:\(failure.message)")
        case .cancelled:
            events.append("cancelled")
        }
    }
}
