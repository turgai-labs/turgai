import Synchronization

/// Lets `value` holders in at once; whoever waits beyond them goes in as one leaves, first come,
/// first served.
public final class AsyncSemaphore: Sendable {
    private struct State {
        var value: Int
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>

    public init(value: Int) {
        state = Mutex(State(value: value))
    }

    /// Takes one of its places, waiting for one to be left when none is free.
    public func wait() async {
        let taken = state.withLock { state in
            guard state.value > 0 else { return false }
            state.value -= 1
            return true
        }
        guard !taken else { return }
        await withCheckedContinuation { continuation in
            let free = state.withLock { state in
                guard state.value > 0 else {
                    state.waiting.append(continuation)
                    return false
                }
                state.value -= 1
                return true
            }
            if free { continuation.resume() }
        }
    }

    /// Leaves a place: straight to the first waiting, when someone waits.
    public func signal() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiting.isEmpty else {
                state.value += 1
                return nil
            }
            return state.waiting.removeFirst()
        }
        next?.resume()
    }
}
