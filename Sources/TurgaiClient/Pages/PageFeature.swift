import ComposableArchitecture
import Foundation
import Mosaic
import OSLog
import TurgaiModels

/// What an open page hears, as Console shows it.
private let log = Logger(subsystem: "Turgai", category: "page")

/// One page, open: what it shows, as the server tells it now and each time it changes, and its
/// buttons' presses sent to it.
@Reducer
package struct PageFeature {
    package init() {}

    @ObservableState
    package struct State: Equatable {
        package enum Content: Equatable {
            case loading
            case shown(PageShown)
            /// It can't be shown now, and why.
            case failed(String)
        }

        package let address: PageAddress
        package var content = Content.loading

        package init(address: PageAddress) {
            self.address = address
        }
    }

    package enum Action {
        /// It's open: what it shows is followed until it's closed, as its state is let go of, or as
        /// what follows it is cancelled.
        case follow
        case shown(PageShown)
        case failed(String)
        /// A button at this path was pressed.
        case pressed(PiecePath)
    }

    @Dependency(\.chat) package var chat

    private enum CancelID { case following }

    package var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .follow:
                let address = state.address
                return .run { send in
                    await chat.following(.page(space: address.space, page: address.page)) { heard in
                        for await event in heard {
                            switch event.payload {
                            case .page(address.space, address.page, let shown):
                                log.info(
                                    "Shown \(address.page.rawValue, privacy: .public), version \(shown.version, privacy: .public)"
                                )
                                await send(.shown(shown))
                            case .pageFailed(address.space, address.page, let reason):
                                log.info(
                                    "Failed \(address.page.rawValue, privacy: .public): \(reason, privacy: .public)")
                                await send(.failed(reason))
                            default: break
                            }
                        }
                    }
                }
                .cancellable(id: CancelID.following, cancelInFlight: true)

            case .shown(let shown):
                state.content = .shown(shown)
                return .none

            case .failed(let reason):
                state.content = .failed(reason)
                return .none

            case .pressed(let path):
                guard case .shown(let shown) = state.content else { return .none }
                let address = state.address
                // Taken or not, what it shows then is told: a press on a layout since replaced
                // finds the one that replaced it.
                return .run { _ in
                    try? await chat.perform(
                        .pressPage(space: address.space, page: address.page, path: path, version: shown.version))
                }
            }
        }
    }
}
