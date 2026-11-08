import ComposableArchitecture
import Foundation
import Testing
import TurgaiModels

@testable import MacApp

@MainActor
struct ProfileFeatureTests {
    let session = Session(token: "token", expiresAt: Date(timeIntervalSince1970: 2_000_000))
    let remembered = MemorySummary(nodes: [
        .init(
            name: "Food", said: nil,
            children: [.init(name: "Pasta", said: "carbonara · cacio e pepe", children: [])]),
        .init(name: "City", said: "Berlin", children: []),
    ])

    /// Shown, the profile reads what's remembered, a line for each name under the names it's under;
    /// Forget Everything… asks again, and only a yes forgets it.
    @Test
    func everythingRememberedIsForgottenOnceTheySaySoAgain() async {
        let forgot = LockIsolated(0)
        var state = ProfileFeature.State()
        state.session = session
        let store = TestStore(initialState: state) {
            ProfileFeature()
        } withDependencies: {
            $0.server.memory = { _ in self.remembered }
            $0.server.forgetMemory = { _ in forgot.withValue { $0 += 1 } }
        }

        await store.send(.shown)
        await store.receive(\.memoryLoaded) { $0.memory = .read(self.remembered) }
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
        #expect(forgot.value == 0)

        await store.send(.forgetTapped) { $0.alert = .forgetEverything }
        await store.send(.alert(.presented(.forgetConfirmed))) { $0.alert = nil }
        await store.receive(\.forgotten) { $0.memory = .read(MemorySummary(nodes: [])) }
        #expect(forgot.value == 1)
        #expect(store.state.memoryShown == .note("Nothing is remembered about you yet."))
        #expect(!store.state.canForget)
    }

    /// What's remembered that can't be read says so, and there's nothing to forget.
    @Test
    func memoryThatCantBeReadSaysSo() async {
        var state = ProfileFeature.State()
        state.session = session
        let store = TestStore(initialState: state) {
            ProfileFeature()
        } withDependencies: {
            $0.server.memory = { _ in throw URLError(.badServerResponse) }
        }

        await store.send(.shown)
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
