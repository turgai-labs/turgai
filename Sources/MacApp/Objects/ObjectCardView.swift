import ComposableArchitecture
import SwiftUI

/// An object's card in a window of its own: its parts as the card says them, each block of code in
/// a monospaced box of its own.
struct ObjectCardWindow: View {
    @State private var store: StoreOf<ObjectCardFeature>

    init(address: ObjectCardAddress) {
        _store = State(
            initialValue: Store(initialState: ObjectCardFeature.State(address: address)) {
                ObjectCardFeature()
            })
    }

    var body: some View {
        ObjectCardView(content: store.content)
            .navigationTitle(store.address.handle)
            .task { store.send(.appeared) }
    }
}

private struct ObjectCardView: View {
    let content: ObjectCardFeature.State.Content

    var body: some View {
        switch content {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            Text("This object's card can't be shown.")
                .font(.callout)
                .foregroundStyle(Color.turgaiMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .shown(let blocks):
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(blocks.indices, id: \.self) { index in
                        CardBlockView(block: blocks[index])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
    }
}

/// One part of a card.
private struct CardBlockView: View {
    let block: ObjectCardFeature.CardBlock

    var body: some View {
        switch block {
        case .heading(let text):
            Text(text).font(.title2.weight(.semibold)).foregroundStyle(Color.turgaiInk)
        case .text(let text):
            Text(LocalizedStringKey(text)).font(.body).foregroundStyle(Color.turgaiMuted).textSelection(.enabled)
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                Text(language.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Color.turgaiMuted)
                ScrollView(.horizontal) {
                    Text(code)
                        .font(.callout.monospaced())
                        .foregroundStyle(Color.turgaiInk)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(Color.turgaiInk.opacity(0.05), in: .rect(cornerRadius: 8))
            }
        }
    }
}
