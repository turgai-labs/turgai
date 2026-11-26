import ComposableArchitecture
import Mosaic
import MosaicSwiftUI
import SwiftUI
import TurgaiClient
import TurgaiModels

/// One page, in a window of its own, drawn as its widget says.
struct PageWindow: View {
    @State private var store: StoreOf<PageFeature>

    init(address: PageAddress) {
        _store = State(
            initialValue: Store(initialState: PageFeature.State(address: address)) {
                PageFeature()
            })
    }

    var body: some View {
        PageContentView(content: store.content) { store.send(.pressed($0)) }
            .navigationTitle(store.address.page.rawValue)
            .task { await store.send(.follow).finish() }
    }
}
