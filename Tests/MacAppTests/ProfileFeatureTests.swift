import ComposableArchitecture
import Foundation
import Testing
import TurgaiModels

@testable import MacApp
@testable import TurgaiClient

@MainActor
struct ProfileFeatureTests {
    let remembered = MemorySummary(
        nodes: [
            .init(
                name: "Food", said: nil,
                children: [.init(name: "Pasta", said: "carbonara · cacio e pepe", children: [])]),
            .init(name: "City", said: "Berlin", children: []),
        ],
        remembering: .on)

    /// What's asked on the app's connection: each push, in order, answered by `answer`.
    private func connection(
        asked: LockIsolated<[LiveAsk]>, answer: @escaping @Sendable (LiveAsk) throws -> LiveReply
    ) -> @Sendable (LiveAsk) async throws -> LiveReply {
        { ask in
            asked.withValue { $0.append(ask) }
            return try answer(ask)
        }
    }

    /// Shown, the profile joins their memory and reads it, a line for each name under the names
    /// it's under; Forget Everything… asks again, and only a yes forgets it.
    @Test
    func everythingRememberedIsForgottenOnceTheySaySoAgain() async {
        let asked = LockIsolated<[LiveAsk]>([])
        let remembered = remembered
        let store = TestStore(initialState: ProfileFeature.State()) {
            ProfileFeature()
        } withDependencies: {
            $0.chat.ask = connection(asked: asked) { ask in
                ask == .join(.memory) ? .joined(LiveEvent(payload: .memory(remembered))) : .ok
            }
            $0.chat.events = { .never }
        }

        await store.send(.shown)
        await store.receive(\.memoryLoaded) { $0.memory = .read(remembered) }
        #expect(
            store.state.memoryShown
                == .lines([
                    .init(path: ["Food"], said: nil), .init(path: ["Food", "Pasta"], said: "carbonara · cacio e pepe"),
                    .init(path: ["City"], said: "Berlin"),
                ]))
        #expect(store.state.memoryShown.depths == [0, 1, 0])
        #expect(store.state.canForget)

        await store.send(.forgetTapped) { $0.alert = .forgetEverything }
        await store.send(.alert(.dismiss)) { $0.alert = nil }
        await store.send(.forgetTapped) { $0.alert = .forgetEverything }
        await store.send(.alert(.presented(.forgetConfirmed))) { $0.alert = nil }
        await store.receive(\.forgotten) { $0.memory = .read(MemorySummary(nodes: [], remembering: .on)) }
        #expect(store.state.memoryShown == .note("Nothing is remembered about you yet."))
        #expect(!store.state.canForget)
        await store.send(.hidden)
        await store.finish()
        #expect(asked.value == [.join(.memory), .forgetMemory, .leave(.memory)])
    }

    /// Shown, it's what its join answers; while it's shown, each change comes with what's
    /// remembered then; closed, it leaves their memory and hears nothing more.
    @Test
    func whileShownItStaysCurrentAndClosedItLeaves() async {
        let asked = LockIsolated<[LiveAsk]>([])
        let remembered = remembered
        let forgotten = MemorySummary(nodes: [], remembering: .off)
        let (events, heard) = AsyncStream.makeStream(of: LiveEvent.self)
        let store = TestStore(initialState: ProfileFeature.State()) {
            ProfileFeature()
        } withDependencies: {
            $0.chat.ask = connection(asked: asked) { ask in
                ask == .join(.memory) ? .joined(LiveEvent(payload: .memory(remembered))) : .ok
            }
            $0.chat.events = { events }
        }

        await store.send(.shown)
        await store.receive(\.memoryLoaded) { $0.memory = .read(remembered) }
        heard.yield(LiveEvent(payload: .memory(forgotten)))
        await store.receive(\.memoryLoaded) { $0.memory = .read(forgotten) }

        await store.send(.hidden)
        heard.yield(LiveEvent(payload: .memory(remembered)))
        await store.finish()
        #expect(asked.value == [.join(.memory), .leave(.memory)])
    }

    /// The switch turns remembering off and on; one the connection refuses goes back, saying so.
    @Test
    func rememberingIsTurnedOffAndOn() async {
        let asked = LockIsolated<[LiveAsk]>([])
        var state = ProfileFeature.State()
        state.memory = .read(remembered)
        let store = TestStore(initialState: state) {
            ProfileFeature()
        } withDependencies: {
            $0.chat.ask = connection(asked: asked) { ask in
                ask == .setRemembering(.on) ? .failed(ChatError(code: "push_failed", message: "No")) : .ok
            }
        }
        #expect(store.state.remembers)

        await store.send(.rememberingToggled(false)) {
            $0.memory = .read(MemorySummary(nodes: self.remembered.nodes, remembering: .off))
        }
        #expect(!store.state.remembers)
        await store.send(.rememberingToggled(false))
        await store.send(.rememberingToggled(true)) { $0.memory = .read(self.remembered) }
        await store.receive(\.rememberingFailed) {
            $0.memory = .read(MemorySummary(nodes: self.remembered.nodes, remembering: .off))
            $0.rememberingProblem = "Couldn't change it. Try again."
        }
        #expect(asked.value == [.setRemembering(.off), .setRemembering(.on)])
    }

    /// What's remembered that can't be read says so, and there's nothing to forget.
    @Test
    func memoryThatCantBeReadSaysSo() async {
        let store = TestStore(initialState: ProfileFeature.State()) {
            ProfileFeature()
        } withDependencies: {
            $0.chat.ask = { _ in throw LiveSocketError.closed }
            $0.chat.events = { .never }
        }

        await store.send(.shown)
        await store.receive(\.memoryFailed) { $0.memory = .failed("Couldn't read what's remembered.") }
        #expect(store.state.memoryShown == .note("Couldn't read what's remembered."))
        #expect(!store.state.canForget)
        await store.send(.hidden)
    }
}

extension ProfileFeature.MemoryShown {
    /// How far under the person each line is.
    fileprivate var depths: [Int] {
        if case .lines(let lines) = self { lines.map(\.depth) } else { [] }
    }
}
