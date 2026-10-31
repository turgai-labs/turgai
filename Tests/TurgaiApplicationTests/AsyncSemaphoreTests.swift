import Testing
import TurgaiDomain

@Suite("Async semaphore")
struct AsyncSemaphoreTests {
    /// Who's in at once, and the most there ever were.
    private actor Inside {
        private(set) var now = 0
        private(set) var most = 0

        func enter() {
            now += 1
            most = max(most, now)
        }

        func leave() {
            now -= 1
        }
    }

    /// However many wait at once, no more than its value are in together, and every one gets in.
    @Test func letsInNoMoreThanItsValue() async {
        let semaphore = AsyncSemaphore(value: 2)
        let inside = Inside()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await semaphore.wait()
                    await inside.enter()
                    await Task.yield()
                    await inside.leave()
                    semaphore.signal()
                }
            }
        }
        #expect(await inside.most == 2)
        #expect(await inside.now == 0)
    }
}
