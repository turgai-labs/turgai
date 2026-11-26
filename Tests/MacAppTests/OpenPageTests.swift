import ComposableArchitecture
import Foundation
import Mosaic
import Testing
import TurgaiModels

@testable import TurgaiClient

/// What's open beside the spaces: a page opened from their pages, or else the conversation.
@MainActor
struct OpenPageTests {
    private let family = SpaceID(rawValue: "family")
    private let permissions = SpacePermissions(
        people: .see, bots: .use, requests: nil, tasks: nil, connections: false, deleteConversations: false,
        configureSpace: false)
    private var menu: PageAddress { PageAddress(space: family, page: MadeObjectID(rawValue: "menu")) }
    private var dinner: Conversation {
        Conversation(
            id: ConversationID(rawValue: "dinner"), botID: BotID(rawValue: "conversation"), title: "Dinner",
            spaceID: family, people: 1)
    }

    private func store(open page: PageAddress? = nil) -> TestStoreOf<AppFeature> {
        var state = AppFeature.State(server: nil)
        state.sidebar.spaces = [SpaceSummary(id: family, name: "Family", permissions: permissions, status: .active)]
        state.sidebar.conversations = [SidebarFeature.Row(dinner)]
        state.openPage = page.map { PageFeature.State(address: $0) }
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            // What the chat says to open a conversation goes nowhere here, and a page opened shows
            // nothing yet.
            $0.chat.send = { _ in }
            $0.chat.events = { AsyncStream { _ in } }
            $0.chat.ask = { _ in .ok }
        }
        // The sidebar and the chat answer what's passed on to them; only what's open is checked.
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    /// A page opens in place of the conversation.
    @Test
    func aPageOpensInPlaceOfTheConversation() async {
        let store = store()
        await store.send(.pageOpened(menu)) { $0.openPage = PageFeature.State(address: menu) }
    }

    /// A page opened is followed until it's closed, whatever draws it: opened, its page is joined
    /// and what it shows now is shown; opened again, nothing more is joined; closed, it's left.
    @Test
    func anOpenPageIsFollowedUntilItsClosed() async throws {
        let asked = LockIsolated<[LiveAsk]>([])
        let menu = menu
        let shown = PageShown(widget: .text(try Text("title", "Menu")), version: 1)
        let store = TestStore(initialState: AppFeature.State(server: nil)) {
            AppFeature()
        } withDependencies: {
            $0.chat.events = { AsyncStream { _ in } }
            $0.chat.ask = { ask in
                asked.withValue { $0.append(ask) }
                guard case .join = ask else { return .ok }
                return .joined(LiveEvent(payload: .page(space: menu.space, page: menu.page, shown: shown)))
            }
        }

        await store.send(.pageOpened(menu)) { $0.openPage = PageFeature.State(address: menu) }
        await store.receive(\.openPage.follow)
        await store.receive(\.openPage.shown) { $0.openPage?.content = .shown(shown) }
        await store.send(.pageOpened(menu))
        await store.send(.pageClosed) { $0.openPage = nil }
        await store.finish()
        let page = LiveTopic.page(space: menu.space, page: menu.page)
        #expect(asked.value == [.join(page), .leave(page)])
    }

    /// The page that's open, opened again, stays as it is: what it shows isn't thrown away.
    @Test
    func theOpenPageOpenedAgainStaysAsItIs() async {
        var state = AppFeature.State(server: nil)
        var open = PageFeature.State(address: menu)
        open.content = .failed("broken")
        state.openPage = open
        let store = TestStore(initialState: state) { AppFeature() }
        await store.send(.pageOpened(menu))
    }

    /// A conversation opened closes the page that was open.
    @Test
    func aConversationOpenedClosesThePage() async {
        let store = store(open: menu)
        await store.send(.sidebar(.delegate(.open(dinner.id)))) { $0.openPage = nil }
        await store.receive(\.chat.open)
    }

    /// Another space shown: its conversation is open, not the last one's page.
    @Test
    func anotherSpaceClosesThePage() async {
        let store = store(open: menu)
        let work = SpaceSummary(
            id: SpaceID(rawValue: "work"), name: "Work", permissions: permissions, status: .active)
        await store.send(.sidebar(.delegate(.spaceChanged(work)))) { $0.openPage = nil }
    }
}
