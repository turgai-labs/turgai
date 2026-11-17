import ComposableArchitecture
import Foundation
import SwiftUI
import TurgaiModels

extension SidebarFeature {
    /// A space's connections, as whoever may configure them sees them: each running or not, and why
    /// it stopped; one added, one changed, one removed; the form open while one's written.
    @Reducer
    struct SpaceConnections {
        /// A connection as it's written: what it's called, whether it's on, the chats that reach it,
        /// and a token typed now.
        @ObservableState
        struct Form: Equatable {
            /// The connection it changes, when it changes one.
            let saved: SpaceConnection?
            var label = ""
            var enabled = false
            /// The chats that reach it, comma-separated: empty is every chat.
            var chatIDs = ""
            /// A token typed now: empty keeps the saved one.
            var token = ""

            init(changing saved: SpaceConnection? = nil) {
                self.saved = saved
                guard let saved else { return }
                label = saved.label
                enabled = saved.enabled
                switch saved.platform {
                case .telegram(let chats): chatIDs = chats.map(String.init).joined(separator: ", ")
                }
            }

            /// The chats written: none when one isn't a chat's id.
            var chats: [Int64]? {
                let written = chatIDs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let chats = written.compactMap(Int64.init)
                return chats.count == written.count ? chats : nil
            }
            var canSave: Bool { !label.trimmingCharacters(in: .whitespaces).isEmpty && chats != nil }
            /// What an empty token means.
            var tokenPrompt: String { saved?.hasToken == true ? "Keep the saved token" : "Its bot's token" }

            /// The connection, as it's written.
            var settings: ConnectionSettings {
                ConnectionSettings(
                    label: label.trimmingCharacters(in: .whitespaces), enabled: enabled,
                    platform: .telegram(chatIDs: chats ?? []),
                    token: token.trimmingCharacters(in: .whitespaces).isEmpty ? nil : token)
            }
        }

        @ObservableState
        struct State: Equatable {
            /// Who configures them.
            let session: Session
            let space: SpaceSummary
            var connections: [SpaceConnection] = []
            /// The connection being written, while one is.
            var form: Form?
            var saving = false
            /// What went wrong, when something did.
            var problem: String?

            var canSave: Bool { !saving && form?.canSave == true }
            var formTitle: String { form?.saved == nil ? "New Telegram connection" : "Change connection" }
        }

        enum Action: BindableAction {
            case binding(BindingAction<State>)
            case shown
            case read([SpaceConnection])
            case addTapped
            case changeTapped(SpaceConnection)
            case removeTapped(SpaceConnection)
            case formCancelled
            case saveTapped
            case saved
            /// Something failed, and why.
            case failed(String)
        }

        @Dependency(\.server) var server

        var body: some ReducerOf<Self> {
            BindingReducer()
            Reduce { state, action in
                switch action {
                case .binding:
                    return .none

                case .shown, .saved:
                    state.form = nil
                    state.saving = false
                    return read(state)

                case .read(let connections):
                    state.connections = connections
                    return .none

                case .addTapped:
                    state.problem = nil
                    state.form = Form()
                    return .none

                case .changeTapped(let connection):
                    state.problem = nil
                    state.form = Form(changing: connection)
                    return .none

                case .formCancelled:
                    state.form = nil
                    state.problem = nil
                    return .none

                case .saveTapped:
                    guard state.canSave, let form = state.form else { return .none }
                    state.saving = true
                    state.problem = nil
                    let settings = form.settings
                    return run(state, otherwise: "Couldn't save the connection.") { session, space in
                        if let saved = form.saved {
                            try await server.changeConnection(session, space, saved.id, settings)
                        } else {
                            try await server.addConnection(session, space, settings)
                        }
                    }

                case .removeTapped(let connection):
                    state.problem = nil
                    return run(state, otherwise: "Couldn't remove the connection.") { session, space in
                        try await server.removeConnection(session, space, connection.id)
                    }

                case .failed(let why):
                    state.problem = why
                    state.saving = false
                    return .none
                }
            }
        }

        /// Its connections read again.
        private func read(_ state: State) -> Effect<Action> {
            .run { [session = state.session, space = state.space.id] send in
                do {
                    await send(.read(try await server.connections(session, space)))
                } catch {
                    await send(.failed("Couldn't read the space's connections."))
                }
            }
        }

        /// `change` made, then its connections read again; why it failed when it did, the server's
        /// words when it says, `otherwise` when it doesn't.
        private func run(
            _ state: State, otherwise: String, _ change: @escaping @Sendable (Session, SpaceID) async throws -> Void
        ) -> Effect<Action> {
            .run { [session = state.session, space = state.space.id] send in
                do {
                    try await change(session, space)
                    await send(.saved)
                } catch let refusal as ServerRefusal {
                    await send(.failed(refusal.error.message))
                } catch {
                    await send(.failed(otherwise))
                }
            }
        }
    }
}

/// A space's connections, each with whether it runs, or the form while one's written.
struct SpaceConnectionsSheet: View {
    @Bindable var store: StoreOf<SidebarFeature.SpaceConnections>
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.form != nil {
                Text(store.formTitle).font(.headline)
                ConnectionFields(store: store)
            } else {
                Text("Connections of \(store.space.name)").font(.headline)
                if store.connections.isEmpty {
                    Text("None yet: a Telegram bot added here lets its chats talk to this space's main bot.")
                        .foregroundStyle(Color.turgaiMuted)
                }
                ForEach(store.connections) { connection in ConnectionRow(store: store, connection: connection) }
            }
            if let problem = store.problem {
                Text(problem).font(.callout).foregroundStyle(Color.turgaiAccent)
            }
            ConnectionsButtons(store: store, done: done)
        }
        .padding(20)
        .frame(width: 440)
        .task { store.send(.shown) }
    }
}

/// A connection's fields: what it's called, whether it's on, who reaches it, and its token.
private struct ConnectionFields: View {
    @Bindable var store: StoreOf<SidebarFeature.SpaceConnections>

    var body: some View {
        if let form = Binding($store.form) {
            Form {
                TextField("Label", text: form.label)
                Toggle("On", isOn: form.enabled)
                SecureField("Bot token", text: form.token, prompt: Text(form.wrappedValue.tokenPrompt))
                TextField("Chats", text: form.chatIDs, prompt: Text("Every chat"))
            }
            .formStyle(.columns)
        }
    }
}

/// One of a space's connections: what it's called, whether it runs, and its menu.
private struct ConnectionRow: View {
    let store: StoreOf<SidebarFeature.SpaceConnections>
    let connection: SpaceConnection

    var body: some View {
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
private struct ConnectionsButtons: View {
    let store: StoreOf<SidebarFeature.SpaceConnections>
    let done: () -> Void

    var body: some View {
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
