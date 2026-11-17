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

    private let family = SpaceID(rawValue: "family")

    /// The window lists the shown space's objects as it opens, having joined their topic, and again
    /// each time the server says they changed; closed, it leaves the topic.
    @Test
    func listFollowsTheObjectsAsTheyJoinAndLeave() async {
        let (events, heard) = AsyncStream.makeStream(of: ChatEvent.self)
        let asked = LockIsolated<[ChatAsk]>([])
        let lists = LockIsolated<[[ObjectRow]]>([[mac], [mac, reminders], [reminders]])
        let listedIn = LockIsolated<[SpaceID]>([])
        let store = TestStore(initialState: ObjectsFeature.State(space: family)) {
            ObjectsFeature()
        } withDependencies: {
            $0.chat.events = { events }
            $0.chat.ask = { ask in
                asked.withValue { $0.append(ask) }
                return .ok
            }
            $0.objects.list = { space in
                listedIn.withValue { $0.append(space) }
                return lists.withValue { $0.removeFirst() }
            }
        }

        let task = await store.send(.appeared)
        await store.receive(\.changed) { $0.listing = .live([self.mac]) }
        heard.yield(ChatEvent(payload: .objectsChanged))
        await store.receive(\.changed) { $0.listing = .live([self.mac, self.reminders]) }
        heard.yield(ChatEvent(payload: .objectsChanged))
        await store.receive(\.changed) { $0.listing = .live([self.reminders]) }
        heard.finish()
        await task.finish()
        #expect(asked.value == [.join(.objects(space: family)), .leave(.objects(space: family))])
        #expect(listedIn.value == [family, family, family])
    }

    /// Another space shown: its objects are listed instead; none are until a space is shown.
    @Test
    func anotherSpaceShownListsItsObjects() async {
        let work = SpaceID(rawValue: "work")
        let listedIn = LockIsolated<[SpaceID]>([])
        let store = TestStore(initialState: ObjectsFeature.State()) {
            ObjectsFeature()
        } withDependencies: {
            $0.chat.events = { AsyncStream { $0.finish() } }
            $0.chat.ask = { _ in .ok }
            $0.objects.list = { space in
                listedIn.withValue { $0.append(space) }
                return [self.mac]
            }
        }

        await store.send(.appeared)
        #expect(listedIn.value.isEmpty)
        await store.send(.spaceChanged(work)) { $0.space = work }
        await store.receive(\.changed) { $0.listing = .live([self.mac]) }
        await store.send(.spaceChanged(work))
        #expect(listedIn.value == [work])
    }

    @Test
    func aRefusedShareSaysWhoMayShare() async {
        struct Refused: Error {}
        let store = TestStore(initialState: ObjectsFeature.State(space: family)) {
            ObjectsFeature()
        } withDependencies: {
            $0.objects.share = { _, _, _ in throw Refused() }
        }

        await store.send(.share(MadeObjectID(rawValue: "tally"), .read))
        await store.receive(\.shareRefused) { $0.refusal = "Only someone who may change it can share it." }
        await store.send(.refusalPresented(false)) { $0.refusal = nil }
    }
}
