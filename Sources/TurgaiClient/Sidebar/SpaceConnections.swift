import ComposableArchitecture
import Foundation
import TurgaiModels

extension SidebarFeature {
    /// A space's connections, as whoever may configure them sees them: each running or not, and why
    /// it stopped; one added, one changed, one removed; the form open while one's written.
    @Reducer
    package struct SpaceConnections {
        package init() {}

        /// A connection as it's written: what it's called, whether it's on, the chats that reach it,
        /// and a token typed now.
        @ObservableState
        package struct Form: Equatable {
            /// The connection it changes, when it changes one.
            package let saved: SpaceConnection?
            package var label = ""
            package var enabled = false
            /// The chats that reach it, comma-separated: empty is every chat.
            package var chatIDs = ""
            /// A token typed now: empty keeps the saved one.
            package var token = ""

            package init(changing saved: SpaceConnection? = nil) {
                self.saved = saved
                guard let saved else { return }
                label = saved.label
                enabled = saved.enabled
                switch saved.platform {
                case .telegram(let chats): chatIDs = chats.map(String.init).joined(separator: ", ")
                }
            }

            /// The chats written: none when one isn't a chat's id.
            package var chats: [Int64]? {
                let written = chatIDs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let chats = written.compactMap(Int64.init)
                return chats.count == written.count ? chats : nil
            }
            package var canSave: Bool { !label.trimmingCharacters(in: .whitespaces).isEmpty && chats != nil }
            /// What an empty token means.
            package var tokenPrompt: String { saved?.hasToken == true ? "Keep the saved token" : "Its bot's token" }

            /// The connection, as it's written.
            package var settings: ConnectionSettings {
                ConnectionSettings(
                    label: label.trimmingCharacters(in: .whitespaces), enabled: enabled,
                    platform: .telegram(chatIDs: chats ?? []),
                    token: token.trimmingCharacters(in: .whitespaces).isEmpty ? nil : token)
            }
        }

        @ObservableState
        package struct State: Equatable {
            /// Who configures them.
            package let session: Session
            package let space: SpaceSummary
            package var connections: [SpaceConnection] = []
            /// The connection being written, while one is.
            package var form: Form?
            package var saving = false
            /// What went wrong, when something did.
            package var problem: String?

            package var canSave: Bool { !saving && form?.canSave == true }
            package var formTitle: String { form?.saved == nil ? "New Telegram connection" : "Change connection" }
            /// What its sheet is called: the connection being written, or the space's connections.
            package var title: String { form == nil ? "Connections of \(space.name)" : formTitle }
        }

        package enum Action: BindableAction {
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

        @Dependency(\.server) package var server

        package var body: some ReducerOf<Self> {
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
