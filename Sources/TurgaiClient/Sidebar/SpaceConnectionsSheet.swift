import ComposableArchitecture
import Foundation
import SwiftUI
import TurgaiModels

/// A space's connections, each with whether it runs, or the form while one's written.
package struct SpaceConnectionsSheet: View {
    @Bindable package var store: StoreOf<SidebarFeature.SpaceConnections>
    package let done: () -> Void

    package var body: some View {
        SheetFrame(store.title, width: 440, close: done) {
            if store.form != nil {
                ConnectionFields(store: store)
            } else {
                if store.connections.isEmpty {
                    Text("None yet: a Telegram bot added here lets its chats talk to this space's main bot.")
                        .foregroundStyle(Color.turgaiMuted)
                }
                ForEach(store.connections) { connection in ConnectionRow(store: store, connection: connection) }
            }
            if let problem = store.problem {
                Text(problem).font(.callout).foregroundStyle(Color.turgaiAccent)
            }
        } buttons: {
            ConnectionsButtons(store: store, done: done)
        } actions: {
            ConnectionsActions(store: store)
        }
        .task { store.send(.shown) }
    }
}

/// A connection's fields: what it's called, whether it's on, who reaches it, and its token.
private struct ConnectionFields: View {
    @Bindable package var store: StoreOf<SidebarFeature.SpaceConnections>

    package var body: some View {
        if let form = Binding($store.form) {
            Form {
                TextField("Label", text: form.label).typedVerbatim()
                Toggle("On", isOn: form.enabled)
                SecureField("Bot token", text: form.token, prompt: Text(form.wrappedValue.tokenPrompt))
                TextField("Chats", text: form.chatIDs, prompt: Text("Every chat")).typedVerbatim()
            }
            .columnsFormStyle()
        }
    }
}

/// One of a space's connections: what it's called, whether it runs, and its menu.
private struct ConnectionRow: View {
    package let store: StoreOf<SidebarFeature.SpaceConnections>
    package let connection: SpaceConnection

    package var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(connection.label)
                Text(connection.status).font(.callout).foregroundStyle(Color.turgaiMuted)
            }
            Spacer()
            Menu("Actions") {
                Button("Change…") { store.send(.changeTapped(connection)) }
                Button("Remove", role: .destructive) { store.send(.removeTapped(connection)) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

/// What the sheet can do: add a connection, or, while one's written, cancel or save it; and close.
/// What the sheet does besides closing, in a phone's navigation bar: add a Telegram connection;
/// or, while one's written, leave it or save it.
private struct ConnectionsActions: View {
    package let store: StoreOf<SidebarFeature.SpaceConnections>

    package var body: some View {
        if store.form == nil {
            Button("Add Telegram…") { store.send(.addTapped) }
        } else {
            Button("Cancel") { store.send(.formCancelled) }
            Button("Save") { store.send(.saveTapped) }.disabled(!store.canSave)
        }
    }
}

private struct ConnectionsButtons: View {
    package let store: StoreOf<SidebarFeature.SpaceConnections>
    package let done: () -> Void

    package var body: some View {
        HStack {
            if store.form == nil {
                Button("Add Telegram…") { store.send(.addTapped) }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            } else {
                Spacer()
                Button("Cancel") { store.send(.formCancelled) }.keyboardShortcut(.cancelAction)
                Button("Save") { store.send(.saveTapped) }.keyboardShortcut(.defaultAction).disabled(!store.canSave)
            }
        }
    }
}

extension SpaceConnection {
    /// Whether it runs, as its row says.
    fileprivate var status: String {
        if running { return "Telegram · running" }
        if let stopped { return "Telegram · stopped: \(stopped)" }
        if !enabled { return "Telegram · off" }
        return hasToken ? "Telegram · starting" : "Telegram · no token"
    }
}
