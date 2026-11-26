import ComposableArchitecture
import Testing
import TurgaiModels

@testable import MacApp
@testable import TurgaiClient

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

    /// What `row` is, as the connection lists it.
    private func listing(_ row: ObjectRow) -> ObjectListing {
        ObjectListing(
            id: row.id, title: row.title, summary: row.summary, actions: row.actions, events: row.events,
            node: row.node, made: row.made)
    }

    /// The window lists the shown space's objects as the server tells them, having joined their
    /// topic, and again each time it tells them; another space's aren't taken; closed, it leaves.
    @Test
    func listFollowsTheObjectsAsTheyJoinAndLeave() async {
        let (events, heard) = AsyncStream.makeStream(of: LiveEvent.self)
        let asked = LockIsolated<[LiveAsk]>([])
        let store = TestStore(initialState: ObjectsFeature.State()) {
            ObjectsFeature()
        } withDependencies: {
            $0.chat.events = { events }
            $0.chat.ask = { ask in
                asked.withValue { $0.append(ask) }
                return .ok
            }
        }

        let task = await store.send(.spaceChanged(family)) { $0.space = self.family }
        heard.yield(LiveEvent(payload: .objects(space: family, objects: [listing(mac)])))
        await store.receive(\.changed) { $0.listing = .live([self.mac]) }
        heard.yield(LiveEvent(payload: .objects(space: SpaceID(rawValue: "work"), objects: [listing(reminders)])))
        heard.yield(LiveEvent(payload: .objects(space: family, objects: [listing(mac), listing(reminders)])))
        await store.receive(\.changed) { $0.listing = .live([self.mac, self.reminders]) }
        heard.finish()
        await task.finish()
        #expect(asked.value == [.join(.objects(space: family)), .leave(.objects(space: family))])
    }

    /// Another space shown: its objects' topic is joined instead; none is until a space is shown,
    /// and none once none is.
    @Test
    func anotherSpaceShownListsItsObjects() async {
        let work = SpaceID(rawValue: "work")
        let asked = LockIsolated<[LiveAsk]>([])
        let store = TestStore(initialState: ObjectsFeature.State()) {
            ObjectsFeature()
        } withDependencies: {
            $0.chat.events = { AsyncStream { $0.finish() } }
            $0.chat.ask = { ask in
                asked.withValue { $0.append(ask) }
                return .ok
            }
        }

        await store.send(.spaceChanged(work)) { $0.space = work }
        await store.send(.spaceChanged(work))
        await store.send(.spaceChanged(nil)) { $0.space = nil }
        await store.finish()
        #expect(asked.value == [.join(.objects(space: work)), .leave(.objects(space: work))])
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

    /// An object's card window asks the server for the card by the handle it's listed by, and
    /// shows its heading, text and blocks of code as the card says them.
    @Test
    func anObjectsCardShowsWhatItIs() async {
        let asked = LockIsolated<[String]>([])
        let store = TestStore(
            initialState: ObjectCardFeature.State(address: ObjectCardAddress(space: family, handle: "Mac"))
        ) {
            ObjectCardFeature()
        } withDependencies: {
            $0.objects.card = { _, handle in
                asked.withValue { $0.append(handle) }
                return ObjectCard(markdown: "# Mac\n\nThis computer.\n\n```yaml\ntakes:\n- status()\n```\n")
            }
        }

        await store.send(.appeared)
        await store.receive(\.loaded) {
            $0.content = .shown([
                .heading("Mac"), .text("This computer."), .code(language: "yaml", "takes:\n- status()"),
            ])
        }
        #expect(asked.value == ["Mac"])
    }
}
