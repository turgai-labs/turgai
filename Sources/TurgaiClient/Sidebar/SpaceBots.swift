import ComposableArchitecture
import Foundation
import TurgaiModels

extension SidebarFeature {
    /// A space's bots, as whoever may configure them sees them: one added, one changed, one removed,
    /// and which is the main one; the bot form open while one's written.
    @Reducer
    package struct SpaceBots {
        package init() {}

        @ObservableState
        package struct State: Equatable {
            /// Who configures them.
            package let session: Session
            package let space: SpaceSummary
            /// Its bots, the main first: none until they're read.
            package var bots: [SpaceBot] = []
            /// The bot being written, while one is: new, or one of its bots changed.
            package var form: BotForm.State?
            /// While a bot is saved.
            package var saving = false
            /// What went wrong, when something did.
            package var problem: String?

            package var canSave: Bool { !saving && form?.canSave == true }
            /// What the form saves: a new bot, or the one it changes.
            package var formTitle: String { form?.saved == nil ? "New bot" : "Change bot" }
            /// What its sheet is called: the bot being written, or the space's bots.
            package var title: String { form == nil ? "Bots of \(space.name)" : formTitle }
        }

        package enum Action {
            case shown
            case read([SpaceBot])
            case addTapped
            case changeTapped(SpaceBot)
            case removeTapped(SpaceBot)
            case mainTapped(SpaceBot)
            case form(BotForm.Action)
            case formCancelled
            case saveTapped
            case saved
            /// Something failed, and why.
            case failed(String)
        }

        @Dependency(\.server) package var server

        package var body: some ReducerOf<Self> {
            Reduce { state, action in
                switch action {
                case .shown, .saved:
                    state.form = nil
                    state.saving = false
                    return read(state)

                case .read(let bots):
                    state.bots = bots
                    return .none

                case .addTapped:
                    state.problem = nil
                    state.form = BotForm.State(session: state.session)
                    return .none

                case .changeTapped(let bot):
                    state.problem = nil
                    state.form = BotForm.State(session: state.session, changing: bot, in: state.space.id)
                    return .none

                case .formCancelled:
                    state.form = nil
                    state.problem = nil
                    return .none

                case .form:
                    return .none

                case .saveTapped:
                    guard state.canSave, let form = state.form else { return .none }
                    state.saving = true
                    state.problem = nil
                    let bot = form.configuration
                    return run(state, otherwise: "Couldn't save the bot.") { session, space in
                        if let saved = form.saved {
                            _ = try await server.changeBot(session, space, saved.bot, bot)
                        } else {
                            _ = try await server.addBot(session, space, bot)
                        }
                    }

                case .removeTapped(let bot):
                    state.problem = nil
                    return run(state, otherwise: "Couldn't remove the bot.") { session, space in
                        try await server.removeBot(session, space, bot.id)
                    }

                case .mainTapped(let bot):
                    state.problem = nil
                    return run(state, otherwise: "Couldn't make it the main bot.") { session, space in
                        try await server.chooseMainBot(session, space, bot.id)
                    }

                case .failed(let why):
                    state.problem = why
                    state.saving = false
                    return .none
                }
            }
            .ifLet(\.form, action: \.form) { BotForm() }
        }

        /// Its bots read again.
        private func read(_ state: State) -> Effect<Action> {
            .run { [session = state.session, space = state.space.id] send in
                do {
                    await send(.read(try await server.bots(session, space)))
                } catch {
                    await send(.failed("Couldn't read the space's bots."))
                }
            }
        }

        /// `change` made, then its bots read again; why it failed when it did, the server's words
        /// when it says, `otherwise` when it doesn't.
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
