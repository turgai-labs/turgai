import ComposableArchitecture
import Foundation
import TurgaiModels

/// The pages of the space the sidebar shows, live: listed again whenever its objects change, and
/// each one's tile drawn again whenever that page changes.
@Reducer
struct PagesFeature {
    @ObservableState
    struct State: Equatable {
        enum Listing: Equatable {
            case waiting
            case live(IdentifiedArrayOf<PageListing>)
        }

        var space: SpaceID?
        var listing = Listing.waiting
        /// What each page without a preview of its own shows now: its tile, drawn small.
        var previews: [MadeObjectID: PageShown] = [:]
        /// The pages whose changes are followed: those listed.
        var followed: Set<MadeObjectID> = []

        /// Where a page's window opens: its space, and the page.
        func address(of page: PageListing) -> PageAddress? {
            space.map { PageAddress(space: $0, page: page.id) }
        }
    }

    enum Action {
        case appeared
        /// The sidebar shows another space: its pages are listed instead.
        case spaceChanged(SpaceID)
        case changed([PageListing])
        /// What one of them shows now, for its tile.
        case previewLoaded(MadeObjectID, PageShown)
        /// One of them changed: its tile is drawn again.
        case pageChanged(MadeObjectID)
    }

    @Dependency(\.pages) var pages
    @Dependency(\.chat) var chat

    fileprivate enum CancelID { case live }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .appeared:
                return follow(state.space)
            case .spaceChanged(let space):
                guard space != state.space else { return .none }
                let left = state.space.map { old in state.followed.map { PageAddress(space: old, page: $0) } } ?? []
                state.space = space
                state.listing = .waiting
                state.previews = [:]
                state.followed = []
                return .merge(leave(left), follow(space))
            case .changed(let listed):
                state.listing = .live(IdentifiedArray(uniqueElements: listed))
                let ids = Set(listed.map(\.id))
                state.previews = state.previews.filter { ids.contains($0.key) }
                guard let space = state.space else { return .none }
                let joined = ids.subtracting(state.followed).map { PageAddress(space: space, page: $0) }
                let left = state.followed.subtracting(ids).map { PageAddress(space: space, page: $0) }
                state.followed = ids
                // A page with no preview of its own is drawn small instead: what it shows now.
                return .merge(
                    [join(joined), leave(left)] + listed.filter { $0.preview == nil }.map { load($0.id, in: space) })

            case .previewLoaded(let page, let shown):
                state.previews[page] = shown
                return .none

            case .pageChanged(let page):
                guard let space = state.space, case .live(let listed) = state.listing, let listing = listed[id: page]
                else { return .none }
                // Its own preview is read with the list; otherwise, what it shows now.
                guard listing.preview == nil else {
                    return .run { send in await send(.changed(await pages.list(space))) }
                }
                return load(page, in: space)
            }
        }
    }

    /// `space`'s pages followed: listed now, and again each time its objects change, since that's
    /// when one may become a page or stop being one.
    private func follow(_ space: SpaceID?) -> Effect<Action> {
        guard let space else { return .none }
        return .run { send in
            let heard = await chat.events()
            try? await chat.perform(.join(.objects(space: space)))
            await send(.changed(await pages.list(space)))
            for await event in heard {
                switch event.payload {
                case .objectsChanged: await send(.changed(await pages.list(space)))
                case .pageChanged(space, let page): await send(.pageChanged(page))
                default: break
                }
            }
            try? await chat.perform(.leave(.objects(space: space)))
        }
        .cancellable(id: CancelID.live, cancelInFlight: true)
    }

    /// What `page` shows now, for its tile.
    private func load(_ page: MadeObjectID, in space: SpaceID) -> Effect<Action> {
        .run { send in
            if let shown = try? await pages.shown(space, page) { await send(.previewLoaded(page, shown)) }
        }
    }

    /// These pages' changes heard from now on: each comes as `pageChanged`.
    private func join(_ pages: [PageAddress]) -> Effect<Action> {
        pages.isEmpty
            ? .none
            : .run { _ in
                for page in pages { try? await chat.perform(.join(.page(space: page.space, page: page.page))) }
            }
    }

    /// These pages' changes no longer heard.
    private func leave(_ pages: [PageAddress]) -> Effect<Action> {
        pages.isEmpty
            ? .none
            : .run { _ in
                for page in pages { try? await chat.perform(.leave(.page(space: page.space, page: page.page))) }
            }
    }
}

/// Which page a window shows: the space it's in, and the page.
struct PageAddress: Codable, Hashable, Sendable {
    let space: SpaceID
    let page: MadeObjectID
}
