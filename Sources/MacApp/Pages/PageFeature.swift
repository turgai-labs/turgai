import ComposableArchitecture
import Foundation
import Mosaic
import TurgaiModels

/// One page, in a window of its own: what it shows, read again each time it changes, and its
/// buttons' presses sent to it.
@Reducer
struct PageFeature {
    @ObservableState
    struct State: Equatable {
        enum Content: Equatable {
            case loading
            case shown(PageShown)
            case missing
        }

        let address: PageAddress
        var content = Content.loading
    }

    enum Action {
        /// The window appeared: what the page shows is read, and followed.
        case appeared
        case loaded(PageShown)
        case missing
        /// A button at this path was pressed.
        case pressed(PiecePath)
        /// The page changed: what it shows is read again.
        case changed
    }

    @Dependency(\.pages) var pages
    @Dependency(\.chat) var chat

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .appeared:
                let address = state.address
                return .merge(
                    load(address),
                    .run { send in
                        // Listened to before it's joined, so no change in between goes unheard.
                        let heard = await chat.events()
                        try? await chat.perform(.join(.page(space: address.space, page: address.page)))
                        for await event in heard {
                            if case .pageChanged(address.space, address.page) = event.payload { await send(.changed) }
                        }
                        try? await chat.perform(.leave(.page(space: address.space, page: address.page)))
                    })

            case .loaded(let shown):
                state.content = .shown(shown)
                return .none

            case .missing:
                state.content = .missing
                return .none

            case .pressed(let path):
                guard case .shown(let shown) = state.content else { return .none }
                let address = state.address
                return .run { send in
                    // Taken or not, what it shows now is read: a press on a layout since replaced
                    // finds the one that replaced it.
                    _ = try? await pages.press(address.space, address.page, path, shown.version)
                    await send(.changed)
                }

            case .changed:
                return load(state.address)
            }
        }
    }

    /// What the page at `address` shows now.
    private func load(_ address: PageAddress) -> Effect<Action> {
        .run { send in
            do {
                await send(.loaded(try await pages.shown(address.space, address.page)))
            } catch {
                await send(.missing)
            }
        }
    }
}
