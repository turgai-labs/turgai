import ComposableArchitecture
import Mosaic
import Testing
import TurgaiModels

@testable import MacApp

@MainActor
struct PageFeatureTests {
    private let address = PageAddress(space: SpaceID(rawValue: "family"), page: MadeObjectID(rawValue: "menu"))

    private func shown(_ count: Int, version: Int) throws -> PageShown {
        PageShown(
            widget: .stack(
                try Stack(
                    "page", .vertical(),
                    [.text(try Text("count", "\(count) ordered")), .button(try Button("order", "Order"))])),
            version: version)
    }

    /// The window shows what the page shows, having joined its topic; a press goes to it with the
    /// layout it was pressed on, and what it shows is read again, as it is each time it changes.
    @Test
    func aPageIsShownPressedAndFollowed() async throws {
        let (events, heard) = AsyncStream.makeStream(of: ChatEvent.self)
        let asked = LockIsolated<[ChatAsk]>([])
        let pressed = LockIsolated<[(PiecePath, Int)]>([])
        let first = try shown(0, version: 7)
        let second = try shown(1, version: 8)
        let third = try shown(2, version: 9)
        let reads = LockIsolated<[PageShown]>([first, second, third])
        let store = TestStore(initialState: PageFeature.State(address: address)) {
            PageFeature()
        } withDependencies: {
            $0.chat.events = { events }
            $0.chat.ask = { ask in
                asked.withValue { $0.append(ask) }
                return .ok
            }
            $0.pages.shown = { _, _ in reads.withValue { $0.removeFirst() } }
            $0.pages.press = { _, _, path, version in
                pressed.withValue { $0.append((path, version)) }
                return true
            }
        }

        let task = await store.send(.appeared)
        await store.receive(\.loaded) { $0.content = .shown(first) }
        let order = try #require(PiecePath("page/order"))
        await store.send(.pressed(order))
        await store.receive(\.changed)
        await store.receive(\.loaded) { $0.content = .shown(second) }
        #expect(pressed.value.map(\.1) == [7])
        #expect(pressed.value.map(\.0) == [order])
        // Changed elsewhere: what it shows is read again.
        heard.yield(ChatEvent(payload: .pageChanged(space: address.space, page: address.page)))
        await store.receive(\.changed)
        await store.receive(\.loaded) { $0.content = .shown(third) }
        heard.finish()
        await task.finish()
        #expect(
            asked.value == [
                .join(.page(space: address.space, page: address.page)),
                .leave(.page(space: address.space, page: address.page)),
            ])
    }

    /// The pages window follows each page it lists: when one changes, its tile is drawn again from
    /// what it shows now.
    @Test
    func eachTileIsDrawnAgainWhenItsPageChanges() async throws {
        let (events, heard) = AsyncStream.makeStream(of: ChatEvent.self)
        let asked = LockIsolated<[ChatAsk]>([])
        let first = try shown(0, version: 7)
        let second = try shown(1, version: 8)
        let reads = LockIsolated<[PageShown]>([first, second])
        let menu = PageListing(id: address.page, title: "Menu", summary: nil)
        let store = TestStore(initialState: PagesFeature.State(space: address.space)) {
            PagesFeature()
        } withDependencies: {
            $0.chat.events = { events }
            $0.chat.ask = { ask in
                asked.withValue { $0.append(ask) }
                return .ok
            }
            $0.pages.list = { _ in [menu] }
            $0.pages.shown = { _, _ in reads.withValue { $0.removeFirst() } }
        }

        let task = await store.send(.appeared)
        await store.receive(\.changed) {
            $0.listing = .live([menu])
            $0.followed = [menu.id]
        }
        await store.receive(\.previewLoaded) { $0.previews[menu.id] = first }
        heard.yield(ChatEvent(payload: .pageChanged(space: address.space, page: address.page)))
        await store.receive(\.pageChanged)
        await store.receive(\.previewLoaded) { $0.previews[menu.id] = second }
        #expect(asked.value.contains(.join(.page(space: address.space, page: address.page))))
        heard.finish()
        await task.finish()
    }
}
