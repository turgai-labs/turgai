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
                            if let made = row.made { SharingMenu(made: made, store: store) }
                        }
                }
                .animation(.smooth, value: rows)
            }
        }
        .scrollContentBackground(.hidden)
        .task { store.send(.appeared) }
        .alert(store.refusal ?? "", isPresented: $store.isRefused.sending(\.refusalPresented)) {}
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
