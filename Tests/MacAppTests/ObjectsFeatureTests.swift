import ComposableArchitecture
import Testing

@testable import MacApp

@MainActor
struct ObjectsFeatureTests {
    let mac = ObjectRow(
        id: "mac",
        title: "Mac",
        summary: "This computer.",
        actions: ["status"],
        node: "127.0.0.1:52034"
    )
    let reminders = ObjectRow(
        id: "reminders",
        title: "Reminders",
        summary: nil,
        actions: ["add", "list"],
        node: "127.0.0.1:52034"
    )

    @Test
    func listFollowsTheCatalogAsObjectsJoinAndLeave() async {
        let (changes, continuation) = AsyncStream<[ObjectRow]>.makeStream()
        let store = TestStore(initialState: ObjectsFeature.State()) {
            ObjectsFeature()
        } withDependencies: {
            $0.objects.live = { changes }
        }

        let task = await store.send(.appeared)
        continuation.yield([mac])
        await store.receive(\.changed) { $0.listing = .live([self.mac]) }
        continuation.yield([mac, reminders])
        await store.receive(\.changed) { $0.listing = .live([self.mac, self.reminders]) }
        continuation.yield([reminders])
        await store.receive(\.changed) { $0.listing = .live([self.reminders]) }
        await task.cancel()
    }
}
