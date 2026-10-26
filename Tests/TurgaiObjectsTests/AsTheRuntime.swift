import Testing
import TurgaiDomain
import TurgaiObjects

/// A test's calls, made as Turgai itself: every call is on behalf of someone, and a test has no
/// person behind it.
struct AsTheRuntime: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    @concurrent func provideScope(
        for test: Testing.Test, testCase: Testing.Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        try await CallChain.$current.withValue(.start(.runtime)) { try await function() }
    }
}

extension Trait where Self == AsTheRuntime {
    static var asTheRuntime: Self { Self() }
}
