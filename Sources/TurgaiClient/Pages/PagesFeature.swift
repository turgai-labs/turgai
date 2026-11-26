import ComposableArchitecture
import Foundation
import Mosaic
import TurgaiModels

/// The pages of the space the sidebar shows, live, as the server tells them: listed again whenever
/// its objects change, and each one's tile drawn again whenever that page changes.
@Reducer
package struct PagesFeature {
    package init() {}

    @ObservableState
    package struct State: Equatable {
        package enum Listing: Equatable {
            case waiting
            case live(IdentifiedArrayOf<PageListing>)
        }

        package var space: SpaceID?
        package var listing = Listing.waiting

        /// The pages listed so far: none while they're read.
        package var listed: IdentifiedArrayOf<PageListing> {
            switch listing {
            case .waiting: []
            case .live(let pages): pages
            }
        }
        /// What each page shows now, as it was last told: for its tile.
        package var shown: [MadeObjectID: PageShown] = [:]
        /// The pages whose changes are followed: those listed.
        package var followed: Set<MadeObjectID> = []

        /// Where a page's window opens: its space, and the page.
        package func address(of page: PageListing) -> PageAddress? {
            space.map { PageAddress(space: $0, page: page.id) }
        }

        /// What `page`'s tile draws: its own preview, as it was last told, or as listed until it's
        /// told; none when it gives none.
        package func preview(of page: PageListing) -> PagePreview? {
            shown[page.id].map(\.preview) ?? page.preview
        }

        /// The tiles, row by row, in the order the pages are listed: a medium one on a row of its
        /// own, small ones two to a row.
        package var rows: [TileRow] {
            var rows: [TileRow] = []
            var waiting: Tile?
            for page in listed {
                let tile = Tile(page: page, preview: preview(of: page))
                if case .medium = tile.preview {
                    if let left = waiting { rows.append(.small(left, nil)) }
                    waiting = nil
                    rows.append(.medium(tile))
                } else if let left = waiting {
                    rows.append(.small(left, tile))
                    waiting = nil
                } else {
                    waiting = tile
                }
            }
            if let left = waiting { rows.append(.small(left, nil)) }
            return rows
        }
    }

    package enum Action {
        /// The sidebar shows another space: its pages are listed instead; none while it shows none.
        case spaceChanged(SpaceID?)
        case listed([PageListing])
        /// What one of them shows now, for its tile.
        case shown(MadeObjectID, PageShown)
    }

    @Dependency(\.chat) package var chat

    fileprivate enum CancelID { case live }

    package var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .spaceChanged(let space):
                guard space != state.space else { return .none }
                let left = state.space.map { old in state.followed.map { PageAddress(space: old, page: $0) } } ?? []
                state.space = space
                state.listing = .waiting
                state.shown = [:]
                state.followed = []
                return .merge(leave(left), follow(space))

            case .listed(let listed):
                state.listing = .live(IdentifiedArray(uniqueElements: listed))
                let ids = Set(listed.map(\.id))
                state.shown = state.shown.filter { ids.contains($0.key) }
                guard let space = state.space else { return .none }
                let joined = ids.subtracting(state.followed).map { PageAddress(space: space, page: $0) }
                let left = state.followed.subtracting(ids).map { PageAddress(space: space, page: $0) }
                state.followed = ids
                return .merge(join(joined), leave(left))

            case .shown(let page, let shown):
                guard state.followed.contains(page) else { return .none }
                state.shown[page] = shown
                return .none
            }
        }
    }

    /// `space`'s pages followed: as the server tells them now, and again each time its objects
    /// change, with what each followed page shows each time that changes, until another space is
    /// shown.
    private func follow(_ space: SpaceID?) -> Effect<Action> {
        guard let space else { return .cancel(id: CancelID.live) }
        return .run { send in
            await chat.following(.pages(space: space)) { heard in
                for await event in heard {
                    switch event.payload {
                    case .pages(space, let listed): await send(.listed(listed))
                    case .page(space, let page, let shown): await send(.shown(page, shown))
                    default: break
                    }
                }
            }
        }
        .cancellable(id: CancelID.live, cancelInFlight: true)
    }

    /// These pages followed: what each shows now, as its join answers, then each change, each as
    /// `shown`.
    private func join(_ pages: [PageAddress]) -> Effect<Action> {
        pages.isEmpty
            ? .none
            : .run { send in
                for page in pages {
                    if let now = try? await chat.join(.page(space: page.space, page: page.page)),
                        case .page(_, let id, let shown) = now.payload
                    {
                        await send(.shown(id, shown))
                    }
                }
            }
    }

    /// These pages' changes no longer told.
    private func leave(_ pages: [PageAddress]) -> Effect<Action> {
        pages.isEmpty
            ? .none
            : .run { _ in
                for page in pages { try? await chat.perform(.leave(.page(space: page.space, page: page.page))) }
            }
    }
}

/// Which page a window shows: the space it's in, and the page.
package struct PageAddress: Codable, Hashable, Sendable {
    package let space: SpaceID
    package let page: MadeObjectID
}

/// One page's tile: the page, and its preview, when it gives one.
package struct Tile: Equatable, Identifiable {
    package let page: PageListing
    package let preview: PagePreview?

    package var id: MadeObjectID { page.id }
}

/// One row of tiles.
package enum TileRow: Equatable, Identifiable {
    /// A medium preview, the row's whole width.
    case medium(Tile)
    /// Small ones, the second when there's one.
    case small(Tile, Tile?)

    package var id: MadeObjectID {
        switch self {
        case .medium(let tile), .small(let tile, _): tile.id
        }
    }
}
