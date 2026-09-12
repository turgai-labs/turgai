import AnyLanguageModel
import Hail
import Testing

@testable import NorbyApplication

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The host-side validation of Hail's compaction report: the projection is
/// the semantic gate for what gets archived into future context.
struct CompactionProjectionTests {
    private let operation = NorbyCompactionOperation.make()

    private func report(_ json: String) throws -> GeneratedContent {
        try GeneratedContent(json: json)
    }

    @Test("a report with key points projects its summary text")
    func projectsSummaryText() throws {
        let projected = try operation.contextProjection(
            report(#"{"summary":{"keyPoints":["kept fact"],"openThreads":["open item"]},"memories":[]}"#),
            ContextProjectionBudget(availableTokens: 100, outputReserve: 512)
        )

        #expect(projected == GeneratedContent("kept fact\nopen item"))
    }

    @Test("open threads alone still carry the conversation forward")
    func openThreadsOnlyIsValid() throws {
        let projected = try operation.contextProjection(
            report(#"{"summary":{"keyPoints":[],"openThreads":["still pending"]},"memories":[]}"#),
            ContextProjectionBudget(availableTokens: 100, outputReserve: 512)
        )

        #expect(projected == GeneratedContent("still pending"))
    }

    @Test("an empty summary is refused instead of archived")
    func emptySummaryIsRefused() throws {
        do {
            _ = try operation.contextProjection(
                report(#"{"summary":{"keyPoints":[],"openThreads":[]},"memories":[]}"#),
                ContextProjectionBudget(availableTokens: 100, outputReserve: 512)
            )
            Issue.record("Expected the empty report to be rejected")
        } catch AgentRuntimeError.modelMisbehavior(let reason) {
            #expect(reason == "Compaction report carried an empty summary")
        }
    }

    @Test("a report that does not match the schema is refused")
    func mismatchedShapeIsRefused() throws {
        do {
            _ = try operation.contextProjection(
                report(#"{"summary":"a plain string summary","memories":[]}"#),
                ContextProjectionBudget(availableTokens: 100, outputReserve: 512)
            )
            Issue.record("Expected the mismatched report to be rejected")
        } catch AgentRuntimeError.modelMisbehavior {
            // Expected: the typed decode of ConversationCompactionReport fails.
        }
    }
}
