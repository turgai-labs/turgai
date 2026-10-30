import Testing
import TurgaiMemory

@testable import TurgaiApplication

/// A memory pass waits for its author to go quiet, then extracts: tried again after each failure,
/// and noting only what was kept.
struct MemoryPassTests {
    private struct Unreachable: Error {}

    /// How many times it was asked to extract.
    private actor Tries {
        private(set) var count = 0

        func next() -> Int {
            count += 1
            return count
        }
    }

    @Test
    func aFailedExtractionIsTriedAgainUntilItKeepsSomething() async {
        let tries = Tries()
        let noted = await MemoryPass.run(
            after: .zero, retries: [.zero, .zero],
            extract: {
                guard await tries.next() == 3 else { throw Unreachable() }
                return .committed(MemoryUpdate(factChanges: [.accepted]))
            },
            failed: { _ in }
        )
        #expect(noted)
        #expect(await tries.count == 3)
    }

    @Test
    func nothingIsNotedWhenNothingWasKeptOrItRanOutOfTries() async {
        #expect(!(await MemoryPass.run(after: .zero, retries: [], extract: { .alreadyHandled }, failed: { _ in })))
        #expect(
            !(await MemoryPass.run(
                after: .zero, retries: [], extract: { .committed(MemoryUpdate(factChanges: [])) }, failed: { _ in })))
        #expect(!(await MemoryPass.run(after: .zero, retries: [.zero], extract: { throw Unreachable() }, failed: { _ in })))
    }

    /// Another message while it waits cancels it: it extracts nothing, and the next pass does.
    @Test
    func aCancelledPassExtractsNothing() async {
        let tries = Tries()
        let pass = Task {
            await MemoryPass.run(
                after: .seconds(60), retries: [],
                extract: {
                    _ = await tries.next()
                    return .committed(MemoryUpdate(factChanges: [.accepted]))
                },
                failed: { _ in }
            )
        }
        pass.cancel()
        #expect(!(await pass.value))
        #expect(await tries.count == 0)
    }
}
