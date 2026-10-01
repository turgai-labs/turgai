import ComposableArchitecture
import SwiftUI

/// The machine's objects, live: they appear and leave as they check in with the
/// cluster and stop.
struct ObjectsView: View {
    let store: StoreOf<ObjectsFeature>

    var body: some View {
        Group {
            switch store.listing {
            case .waiting:
                placeholder("Waiting for Turgai", "Objects show up once the server has started.")
            case .live(let rows) where rows.isEmpty:
                placeholder("No objects yet", "Objects appear here as they join the cluster.")
            case .live(let rows):
                List(rows) { row in
                    ObjectRowView(row: row)
                }
                .animation(.smooth, value: rows)
            }
        }
        .frame(minWidth: 340, minHeight: 320)
        .background(Color.turgaiCanvas)
        .task { store.send(.appeared) }
    }

    private func placeholder(_ title: String, _ message: String) -> some View {
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
