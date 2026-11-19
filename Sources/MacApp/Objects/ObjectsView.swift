import ComposableArchitecture
import SwiftUI
import TurgaiModels

/// The objects the person may see, live: they appear and leave as they check in with the
/// cluster and stop.
struct ObjectsView: View {
    @Bindable var store: StoreOf<ObjectsFeature>

    var body: some View {
        Group {
            switch store.listing {
            case .waiting:
                Placeholder(title: "Waiting for Turgai", message: "Objects show up once the server has started.")
            case .live(let rows) where rows.isEmpty:
                Placeholder(title: "No objects yet", message: "Objects appear here as they join the cluster.")
            case .live(let rows):
                List(rows) { row in
                    ObjectRowView(row: row)
                        .contextMenu {
                            Button("Show Card…") { store.send(.cardTapped(row)) }
                            if let made = row.made { SharingMenu(made: made, store: store) }
                        }
                }
                .animation(.smooth, value: rows)
            }
        }
        .scrollContentBackground(.hidden)
        .task { store.send(.appeared) }
        .alert(store.refusal ?? "", isPresented: $store.isRefused.sending(\.refusalPresented)) {}
        .sheet(isPresented: $store.isShowingCard.sending(\.cardPresented)) {
            if let card = store.card {
                CardView(card: card) { store.send(.cardPresented(false)) }
            }
        }
    }
}

/// What the panel says while there are no objects to list.
private struct Placeholder: View {
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                Image.skylark
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .foregroundStyle(Color.turgaiAccent)
            }
        } description: {
            Text(message)
        }
    }
}

/// Who else may use an object made here: everyone, to use it or to change it too, or no one
/// it isn't shared with otherwise.
private struct SharingMenu: View {
    let made: MadeObjectID
    let store: StoreOf<ObjectsFeature>

    var body: some View {
        Button("Let everyone use it") { store.send(.share(made, .read)) }
        Button("Let everyone use and change it") { store.send(.share(made, .write)) }
        Button("Stop sharing it with everyone") { store.send(.share(made, .none)) }
    }
}

private struct ObjectRowView: View {
    let row: ObjectRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(.headline)
                    .foregroundStyle(Color.turgaiInk)
                Spacer()
                Text(row.node)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.turgaiMuted)
            }
            if let summary = row.summary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(Color.turgaiMuted)
            }
            if !row.actions.isEmpty {
                Text(row.actions.joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.signalBlue)
            }
            if !row.events.isEmpty {
                Label(row.events.joined(separator: " · "), systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.turgaiAccent)
            }
        }
        .padding(.vertical, 4)
    }
}

/// An object's card: its title, then its parts as the card says them, each block of code in a
/// scrollable monospaced box of its own.
private struct CardView: View {
    let card: ObjectsFeature.Card
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(card.title).font(.title2.weight(.semibold)).foregroundStyle(Color.turgaiInk)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            switch card.content {
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
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 420, idealHeight: 560)
    }
}

/// One part of a card.
private struct CardBlockView: View {
    let block: ObjectsFeature.CardBlock

    var body: some View {
        switch block {
        case .heading(let text):
            Text(text).font(.headline).foregroundStyle(Color.turgaiInk)
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
