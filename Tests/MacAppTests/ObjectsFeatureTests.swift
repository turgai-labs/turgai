import ComposableArchitecture
import Testing
import TurgaiModels

@testable import MacApp

@MainActor
struct ObjectsFeatureTests {
    let mac = ObjectRow(
        id: "mac",
        title: "Mac",
        made: nil,
        summary: "This computer.",
        actions: ["status"],
        events: [],
        node: "127.0.0.1:52034"
    )
    let reminders = ObjectRow(
        id: "reminders",
        title: "Reminders",
        made: nil,
        summary: nil,
        actions: ["add", "list"],
        events: ["ReminderAdded"],
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

    @Test
    func aRefusedShareSaysWhoMayShare() async {
        struct Refused: Error {}
        let store = TestStore(initialState: ObjectsFeature.State()) {
            ObjectsFeature()
        } withDependencies: {
            $0.objects.share = { _, _ in throw Refused() }
        }

        await store.send(.share(MadeObjectID(rawValue: "tally"), .read))
        await store.receive(\.shareRefused) { $0.refusal = "Only someone who may change it can share it." }
        await store.send(.refusalDismissed) { $0.refusal = nil }
    }
}
