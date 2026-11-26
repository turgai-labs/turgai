import ComposableArchitecture
import Foundation
import Testing
import TurgaiModels

@testable import PhoneApp
@testable import TurgaiClient

/// Where things are on a phone, as its state says: whether what's open is over the spaces, where
/// the two don't fit side by side. What's open, the app keeps.
@MainActor
struct PhoneFeatureTests {
    private let space = SpaceID(rawValue: "family")
    private let dinner = ConversationID(rawValue: "dinner")

    private func store(_ state: PhoneFeature.State = PhoneFeature.State(app: AppFeature.State(server: nil)))
        -> TestStoreOf<PhoneFeature>
    {
        let store = TestStore(initialState: state) {
            PhoneFeature()
        } withDependencies: {
            // A page opened, or what's remembered, shows nothing yet.
            $0.chat.events = { AsyncStream { _ in } }
            $0.chat.ask = { _ in .ok }
        }
        // The app's own features answer the actions passed on to them; only the phone's part is
        // checked here.
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    /// A page comes over the spaces, and the app opens it; back to the spaces, it's closed.
    @Test
    func aPageComesOverTheSpaces() async {
        let store = store()
        let page = PageAddress(space: space, page: MadeObjectID(rawValue: "menu"))
        await store.send(.pageTapped(page)) { $0.showsOpen = true }
        await store.receive(\.app.pageOpened) { $0.app.openPage = PageFeature.State(address: page) }
        await store.send(.openClosed) { $0.showsOpen = false }
        await store.receive(\.app.pageClosed) { $0.app.openPage = nil }
    }

    /// The account's sheet follows what's remembered while it's up.
    @Test
    func theAccountFollowsTheirMemoryWhileItsUp() async {
        let store = store()
        await store.send(.accountTapped) { $0.accountShown = true }
        await store.receive(\.app.profile.shown)
        await store.send(.accountClosed) { $0.accountShown = false }
        await store.receive(\.app.profile.hidden)
    }

    /// A conversation comes over the spaces, and the sidebar selects it.
    @Test
    func aConversationComesOverTheSpaces() async {
        let store = store()
        await store.send(.conversationTapped(dinner)) { $0.showsOpen = true }
        await store.receive(\.app.sidebar.selected)
    }

    /// Another space shown: its spaces' side first.
    @Test
    func switchingSpacesGoesBackToTheSpaces() async {
        var state = PhoneFeature.State(app: AppFeature.State(server: nil))
        state.showsOpen = true
        let store = store(state)
        await store.send(.app(.sidebar(.spaceSwitched(SpaceID(rawValue: "work"))))) { $0.showsOpen = false }
    }

    /// Signed out, the phone's as it was.
    @Test
    func signingOutClosesEverything() async {
        var state = PhoneFeature.State(app: AppFeature.State(server: nil))
        state.showsOpen = true
        state.accountShown = true
        let store = store(state)
        await store.send(.app(.profile(.signOutTapped))) {
            $0.showsOpen = false
            $0.accountShown = false
        }
    }
}
