import Testing
import TurgaiDomain
import TurgaiObjects

/// A test's calls, made as one person, in a group of their own: every call is on behalf of
/// someone.
struct AsAPerson: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    @concurrent func provideScope(
        for test: Testing.Test, testCase: Testing.Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        try await CallChain.$current.withValue(.start(Self.person, in: nil)) { try await function() }
    }

    /// Whom a test's calls are on behalf of.
    static let person = CallScope(UserID("tester"), in: SpaceID(), as: .admin, allowed: [])
}

extension Trait where Self == AsAPerson {
    static var asAPerson: Self { Self() }
}
