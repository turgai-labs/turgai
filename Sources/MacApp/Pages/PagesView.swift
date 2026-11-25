import ComposableArchitecture
import Mosaic
import MosaicSwiftUI
import SwiftUI
import TurgaiModels

/// The space's pages, as a grid of tiles: each opens the page in a window of its own.
struct PagesView: View {
    let store: StoreOf<PagesFeature>

    var body: some View {
        Group {
            switch store.listing {
            case .waiting:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .live(let pages) where pages.isEmpty:
                ContentUnavailableView(
                    "No pages yet", systemImage: "rectangle.grid.2x2",
                    description: Text("An object that conforms to Page shows up here."))
            case .live(let pages):
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 360), spacing: 20)], spacing: 20) {
                        ForEach(pages) { page in
                            PageTile(
                                page: page, preview: page.preview ?? store.previews[page.id]?.widget,
                                address: store.state.address(of: page))
                        }
                    }
                    .padding()
                }
            }
        }
        .task { store.send(.appeared) }
    }
}

/// One page's tile, as a widget is: what it shows, at its own size, on a card, then its name;
/// pressed, its window opens.
private struct PageTile: View {
    let page: PageListing
    /// Its own preview, or what it showed when it was listed, once that's read.
    let preview: Mosaic.Widget?
    let address: PageAddress?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            if let address { openWindow(id: WindowID.page, value: address) }
        } label: {
            VStack(spacing: 8) {
                PagePreview(preview: preview)
                Text(page.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A page's preview on its card, at the size it's drawn at, as far as the card goes: only to see,
/// not to press. What doesn't fit fades out at the card's edge.
private struct PagePreview: View {
    let preview: Mosaic.Widget?

    var body: some View {
        ZStack(alignment: .top) {
            if let preview {
                WidgetView(preview) { _ in }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 170, maxHeight: 170, alignment: .top)
        .clipped()
        .mask {
            LinearGradient(
                stops: [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                startPoint: .top, endPoint: .bottom)
        }
        .background(.background.secondary, in: .rect(cornerRadius: 22, style: .continuous))
        .contentShape(.rect(cornerRadius: 22, style: .continuous))
    }
}

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
            .task { store.send(.appeared) }
    }
}

private struct PageContentView: View {
    let content: PageFeature.State.Content
    let press: @MainActor (PiecePath) -> Void

    var body: some View {
        switch content {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            ContentUnavailableView("This page can't be shown", systemImage: "rectangle.slash")
        case .shown(let shown):
            ScrollView {
                WidgetView(shown.widget, press: press).padding().frame(maxWidth: .infinity, alignment: .top)
            }
            .animation(.smooth, value: shown)
        }
    }
}
