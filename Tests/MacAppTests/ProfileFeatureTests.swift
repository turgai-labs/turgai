import ComposableArchitecture
import Foundation
import Testing
import TurgaiModels

@testable import MacApp

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
        asked: LockIsolated<[ChatAsk]>, answer: @escaping @Sendable (ChatAsk) throws -> ChatReply
    ) -> @Sendable (ChatAsk) async throws -> ChatReply {
        { ask in
            asked.withValue { $0.append(ask) }
            return try answer(ask)
        }
    }

    /// Shown, the profile joins their memory and reads it, a line for each name under the names
    /// it's under; Forget Everything… asks again, and only a yes forgets it.
    @Test
    func everythingRememberedIsForgottenOnceTheySaySoAgain() async {
        let asked = LockIsolated<[ChatAsk]>([])
        let remembered = remembered
        let store = TestStore(initialState: ProfileFeature.State()) {
            ProfileFeature()
        } withDependencies: {
            $0.chat.ask = connection(asked: asked) { ask in ask == .memory ? .memory(remembered) : .ok }
        }

        await store.send(.shown) { $0.showing = .shown }
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
        #expect(asked.value == [.join(.memory), .memory, .forgetMemory])
        #expect(store.state.memoryShown == .note("Nothing is remembered about you yet."))
        #expect(!store.state.canForget)
    }

    /// While it's shown, a change to their memory, or the connection opening again, has it read
    /// again; closed, it leaves their memory and reads nothing more.
    @Test
    func whileShownItStaysCurrentAndClosedItLeaves() async {
        let asked = LockIsolated<[ChatAsk]>([])
        let remembered = remembered
        let forgotten = MemorySummary(nodes: [], remembering: .off)
        let current = LockIsolated(remembered)
        let store = TestStore(initialState: ProfileFeature.State()) {
            ProfileFeature()
        } withDependencies: {
            $0.chat.ask = connection(asked: asked) { ask in ask == .memory ? .memory(current.value) : .ok }
        }

        await store.send(.shown) { $0.showing = .shown }
        await store.receive(\.memoryLoaded) { $0.memory = .read(remembered) }
        current.setValue(forgotten)
        await store.send(.memoryChanged)
        await store.receive(\.memoryLoaded) { $0.memory = .read(forgotten) }
        await store.send(.connected)
        await store.receive(\.memoryLoaded)

        await store.send(.hidden) { $0.showing = .hidden }
        await store.send(.memoryChanged)
        await store.send(.connected)
        await store.finish()
        #expect(asked.value == [.join(.memory), .memory, .memory, .memory, .leave(.memory)])
    }

    /// The switch turns remembering off and on; one the connection refuses goes back, saying so.
    @Test
    func rememberingIsTurnedOffAndOn() async {
        let asked = LockIsolated<[ChatAsk]>([])
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
            $0.chat.ask = { _ in throw ChatSocketError.closed }
        }

        await store.send(.shown) { $0.showing = .shown }
        await store.receive(\.memoryFailed) { $0.memory = .failed("Couldn't read what's remembered.") }
        #expect(store.state.memoryShown == .note("Couldn't read what's remembered."))
        #expect(!store.state.canForget)
    }
}

extension ProfileFeature.MemoryShown {
    /// How far under the person each line is.
    fileprivate var depths: [Int] {
        if case .lines(let lines) = self { lines.map(\.depth) } else { [] }
    }
}
