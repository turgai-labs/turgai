import ComposableArchitecture
import Mosaic
import MosaicSwiftUI
import SwiftUI
import TurgaiModels

/// A page's content, as its widget says, pressed where it can be: or that it's loading, or can't be
/// shown.
package struct PageContentView: View {
    package let content: PageFeature.State.Content
    package let press: @MainActor (PiecePath) -> Void

    package init(content: PageFeature.State.Content, press: @escaping @MainActor (PiecePath) -> Void) {
        self.content = content
        self.press = press
    }

    package var body: some View {
        switch content {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let reason):
            ContentUnavailableView(
                "This page can't be shown", systemImage: "rectangle.slash", description: Text(verbatim: reason))
        case .shown(let shown):
            ScrollView {
                WidgetView(shown.widget, press: press).padding().frame(maxWidth: .infinity, alignment: .top)
            }
            .animation(.smooth, value: shown)
        }
    }
}

/// The shown space's pages, as widgets, row by row: a medium one the row's whole width, small ones
/// two to a row; each opening by `open`, and, where the app has windows, in one of its own from its
/// menu. Nothing while there are none.
package struct PageTiles: View {
    let store: StoreOf<PagesFeature>
    let open: (PageAddress) -> Void
    let openInWindow: ((PageAddress) -> Void)?

    package init(
        store: StoreOf<PagesFeature>, open: @escaping (PageAddress) -> Void,
        openInWindow: ((PageAddress) -> Void)? = nil
    ) {
        self.store = store
        self.open = open
        self.openInWindow = openInWindow
    }

    package var body: some View {
        Grid(horizontalSpacing: Self.gap, verticalSpacing: Self.gap) {
            ForEach(store.rows) { row in
                TileRowView(row: row, address: store.state.address(of:), open: open, openInWindow: openInWindow)
            }
        }
        .padding(.top, 12)
    }

    /// How far apart tiles are, across and down.
    nonisolated static let gap: CGFloat = 10
}

/// One row of tiles.
private struct TileRowView: View {
    let row: TileRow
    let address: (PageListing) -> PageAddress?
    let open: (PageAddress) -> Void
    let openInWindow: ((PageAddress) -> Void)?

    var body: some View {
        GridRow {
            switch row {
            case .medium(let tile):
                PageTile(tile: tile, address: address(tile.page), open: open, openInWindow: openInWindow)
                    .gridCellColumns(2)
            case .small(let left, let right):
                PageTile(tile: left, address: address(left.page), open: open, openInWindow: openInWindow)
                if let right {
                    PageTile(tile: right, address: address(right.page), open: open, openInWindow: openInWindow)
                } else {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
        }
    }
}

/// One page's widget, its name under it: pressed, it opens.
private struct PageTile: View {
    let tile: Tile
    let address: PageAddress?
    let open: (PageAddress) -> Void
    let openInWindow: ((PageAddress) -> Void)?

    var body: some View {
        Button {
            if let address { open(address) }
        } label: {
            VStack(spacing: 4) {
                TileCard(tile: tile)
                Text(tile.page.title).font(.caption).foregroundStyle(Color.turgaiMuted).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let address, let openInWindow {
                Button("Open in New Window") { openInWindow(address) }
            }
        }
    }
}

/// What a tile draws on its card, only to see: a preview laid out at the card's own size, inside
/// its margins, what doesn't fit cut off, as a widget is; or, for a page that gives none, what the
/// page is.
private struct TileCard: View {
    let tile: Tile

    var body: some View {
        Group {
            switch tile.preview {
            case .small(let widget):
                Drawn(widget: widget).aspectRatio(1, contentMode: .fit)
            case .medium(let widget):
                TwoTilesWide { Drawn(widget: widget) }
            case nil:
                Plain(summary: tile.page.summary).aspectRatio(1, contentMode: .fit)
            }
        }
        .clipped()
        .contentShape(.rect(cornerRadius: 16, style: .continuous))
        .background(.background, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

/// `widget`, laid out in what it's offered, inside its margins.
private struct Drawn: View {
    let widget: Mosaic.Widget

    var body: some View {
        WidgetView(widget) { _ in }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }
}

/// A page that gives no preview: what it is, when it says, or that it's a page.
private struct Plain: View {
    let summary: String?

    var body: some View {
        if let summary {
            Text(verbatim: summary)
                .font(.caption)
                .foregroundStyle(Color.turgaiMuted)
                .lineLimit(6)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Image(systemName: "doc.text")
                .font(.title2)
                .foregroundStyle(Color.turgaiMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Its content as wide as it's offered, two tiles and the gap between them, and as high as one
/// tile is wide.
private struct TwoTilesWide: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        return CGSize(width: width, height: (width - PageTiles.gap) / 2)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}
