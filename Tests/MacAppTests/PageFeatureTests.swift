import ComposableArchitecture
import Mosaic
import Testing
import TurgaiModels

@testable import MacApp
@testable import TurgaiClient

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

    /// The page shows what the server tells it shows, having joined its topic, and again each
    /// time it tells it; a press goes with the layout it was pressed on; one that can't be shown
    /// says why; closed, it leaves the topic.
    @Test
    func aPageIsShownPressedAndFollowed() async throws {
        let (events, heard) = AsyncStream.makeStream(of: LiveEvent.self)
        let asked = LockIsolated<[LiveAsk]>([])
        let first = try shown(0, version: 7)
        let second = try shown(1, version: 8)
        let store = TestStore(initialState: PageFeature.State(address: address)) {
            PageFeature()
        } withDependencies: {
            $0.chat.events = { events }
            $0.chat.ask = { ask in
                asked.withValue { $0.append(ask) }
                return .ok
            }
        }

        let task = await store.send(.follow)
        heard.yield(LiveEvent(payload: .page(space: address.space, page: address.page, shown: first)))
        await store.receive(\.shown) { $0.content = .shown(first) }
        let order = try #require(PiecePath("page/order"))
        await store.send(.pressed(order))
        heard.yield(LiveEvent(payload: .page(space: address.space, page: address.page, shown: second)))
        await store.receive(\.shown) { $0.content = .shown(second) }
        // Another page's isn't taken.
        heard.yield(
            LiveEvent(payload: .page(space: address.space, page: MadeObjectID(rawValue: "other"), shown: first)))
        heard.yield(LiveEvent(payload: .pageFailed(space: address.space, page: address.page, reason: "broken")))
        await store.receive(\.failed) { $0.content = .failed("broken") }
        heard.finish()
        await task.finish()
        #expect(
            asked.value == [
                .join(.page(space: address.space, page: address.page)),
                .pressPage(space: address.space, page: address.page, path: order, version: 7),
                .leave(.page(space: address.space, page: address.page)),
            ])
    }

    /// The page shows what its join answers it shows now, as the chat shows the history its open
    /// answers: nothing has to be told after it.
    @Test
    func aPageShowsWhatItsJoinAnswers() async throws {
        let first = try shown(0, version: 7)
        let address = address
        let store = TestStore(initialState: PageFeature.State(address: address)) {
            PageFeature()
        } withDependencies: {
            $0.chat.events = { .never }
            $0.chat.ask = { ask in
                guard case .join = ask else { return .ok }
                return .joined(LiveEvent(payload: .page(space: address.space, page: address.page, shown: first)))
            }
        }

        let task = await store.send(.follow)
        await store.receive(\.shown) { $0.content = .shown(first) }
        await task.cancel()
    }

    /// Tiles go row by row in the order their pages are listed: a medium one takes a row of its
    /// own, small ones two to a row, as do pages with no preview.
    @Test
    func mediumTilesTakeARowAndSmallOnesPairUp() throws {
        let widget = Widget.text(try Text("degrees", "7°"))
        func page(_ name: String, _ preview: PagePreview?) -> PageListing {
            PageListing(id: MadeObjectID(rawValue: name), title: name, summary: nil, preview: preview)
        }
        let pages = [
            page("clock", .small(widget)), page("weather", .medium(widget)), page("menu", nil),
            page("timer", .small(widget)), page("notes", .small(widget)),
        ]
        var state = PagesFeature.State(space: address.space)
        state.listing = .live(IdentifiedArray(uniqueElements: pages))
        let tile = { (page: PageListing) in Tile(page: page, preview: page.preview) }
        #expect(
            state.rows == [
                .small(tile(pages[0]), nil), .medium(tile(pages[1])), .small(tile(pages[2]), tile(pages[3])),
                .small(tile(pages[4]), nil),
            ])
    }

    /// The pages list follows each page it lists: its tile draws the preview it gives now, as the
    /// server tells it; none while it gives none.
    @Test
    func eachTileIsDrawnAgainWhenItsPageChanges() async throws {
        let (events, heard) = AsyncStream.makeStream(of: LiveEvent.self)
        let asked = LockIsolated<[LiveAsk]>([])
        let first = try shown(0, version: 7)
        let small = Widget.text(try Text("small", "Small"))
        let second = PageShown(widget: first.widget, version: 8, preview: .small(small))
        let menu = PageListing(id: address.page, title: "Menu", summary: nil)
        let store = TestStore(initialState: PagesFeature.State()) {
            PagesFeature()
        } withDependencies: {
            $0.chat.events = { events }
            $0.chat.ask = { ask in
                asked.withValue { $0.append(ask) }
                return .ok
            }
        }

        let task = await store.send(.spaceChanged(address.space)) { $0.space = self.address.space }
        heard.yield(LiveEvent(payload: .pages(space: address.space, pages: [menu])))
        await store.receive(\.listed) {
            $0.listing = .live([menu])
            $0.followed = [menu.id]
        }
        heard.yield(LiveEvent(payload: .page(space: address.space, page: address.page, shown: first)))
        await store.receive(\.shown) { $0.shown[menu.id] = first }
        #expect(store.state.preview(of: menu) == nil)
        heard.yield(LiveEvent(payload: .page(space: address.space, page: address.page, shown: second)))
        await store.receive(\.shown) { $0.shown[menu.id] = second }
        #expect(store.state.preview(of: menu) == .small(small))
        heard.finish()
        await task.finish()
        #expect(asked.value.contains(.join(.pages(space: address.space))))
        #expect(asked.value.contains(.join(.page(space: address.space, page: address.page))))
    }
}
