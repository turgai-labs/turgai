import ComposableArchitecture
import Foundation
import SwiftUI
import TurgaiModels

extension SidebarFeature {
    /// What's over the window: asking before a space is archived or a conversation deleted, or a
    /// dialog.
    @Reducer
    package enum Destination {
        @ReducerCaseIgnored case alert(AlertState<Alert>)
        /// A conversation's or a space's new name.
        case renaming(Renaming)
        /// A space to make, by its name, or to join, by an invite's link.
        case addingSpace(AddingSpace)
        /// An invite to a space, its link to give someone.
        case inviting(Inviting)
        /// Every space, to pick one.
        case choosingSpace(ChoosingSpace)
        /// The shown space's bots, to configure.
        case bots(SpaceBots)
        /// The shown space's connections, to configure.
        case connections(SpaceConnections)

        @CasePathable
        package enum Action {
            case alert(Alert)
            case renaming(Renaming.Action)
            case addingSpace(AddingSpace.Action)
            case inviting(Inviting.Action)
            case choosingSpace(ChoosingSpace.Action)
            case bots(SpaceBots.Action)
            case connections(SpaceConnections.Action)
        }

        @CasePathable
        package enum Alert: Equatable {
            case archiveConfirmed(SpaceID)
            case deleteConfirmed(ConversationID)
        }
    }

    /// A conversation's or a space's new name, being written.
    @Reducer
    package struct Renaming {
        package init() {}

        @ObservableState
        package struct State: Equatable {
            package enum Subject: Equatable {
                /// A conversation of the space.
                case conversation(ConversationID, in: SpaceID)
                case space(SpaceID)
            }

            package let subject: Subject
            package var name: String

            /// What its sheet is called.
            package var title: String {
                switch subject {
                case .conversation: "Rename conversation"
                case .space: "Rename space"
                }
            }
        }

        package enum Action: BindableAction {
            case binding(BindingAction<State>)
        }

        package var body: some ReducerOf<Self> {
            BindingReducer()
        }
    }

    /// A space being added: made, by the name written and then its first bot, or joined, by the
    /// invite's link pasted.
    @Reducer
    package struct AddingSpace {
        package init() {}

        @ObservableState
        package struct State: Equatable {
            /// Who adds it.
            package let session: Session
            package var name = ""
            package var link = ""
            /// Its first bot, once its name is written: none while it's named.
            package var bot: BotForm.State?
            /// While the space is being made.
            package var making = false
            /// What went wrong making or joining one, when something did.
            package var problem: String?

            /// The invite the link is: none while it isn't one.
            package var invite: SpaceInviteLink? { SpaceInviteLink(link) }
            package var canNext: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            package var canJoin: Bool { invite != nil }
            package var canMake: Bool { !making && bot?.canSave == true }
            /// What its sheet is called at its step: its name, then its bot.
            package var title: String { bot == nil ? "New space" : "Its bot" }
        }

        package enum Action: BindableAction {
            case binding(BindingAction<State>)
            case bot(BotForm.Action)
            case nextTapped
            case backTapped
            case makeTapped
            case joinTapped
            /// Making or joining it failed, and why.
            case failed(String)
            case delegate(Delegate)

            package enum Delegate: Equatable {
                /// A space made or joined.
                case added(SpaceSummary)
            }
        }

        @Dependency(\.server) package var server

        package var body: some ReducerOf<Self> {
            BindingReducer()
            Reduce { state, action in
                switch action {
                case .binding(\.link):
                    state.problem = nil
                    return .none

                case .binding, .bot, .delegate:
                    return .none

                case .nextTapped:
                    guard state.canNext else { return .none }
                    state.bot = BotForm.State(
                        session: state.session, name: state.name.trimmingCharacters(in: .whitespacesAndNewlines))
                    return .none

                case .backTapped:
                    state.bot = nil
                    state.problem = nil
                    return .none

                case .makeTapped:
                    guard state.canMake, let bot = state.bot?.configuration else { return .none }
                    state.making = true
                    state.problem = nil
                    let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    return .run { [session = state.session] send in
                        do {
                            await send(.delegate(.added(try await server.makeSpace(session, name, bot))))
                        } catch let refusal as ServerRefusal {
                            await send(.failed(refusal.error.message))
                        } catch {
                            await send(.failed("Couldn't make the space."))
                        }
                    }

                case .joinTapped:
                    guard let invite = state.invite else { return .none }
                    return .run { [session = state.session] send in
                        do {
                            await send(.delegate(.added(try await server.joinSpace(session, invite))))
                        } catch {
                            await send(.failed("That link didn't work: it may be used up or out of date."))
                        }
                    }

                case .failed(let why):
                    state.problem = why
                    state.making = false
                    return .none
                }
            }
            .ifLet(\.bot, action: \.bot) { BotForm() }
        }
    }

    /// An invite to a space, made as the dialog shows, its link copied.
    @Reducer
    package struct Inviting {
        package init() {}

        /// The invite: being made, made, with its link, or not made.
        package enum Invite: Equatable {
            case making
            case made(link: String)
            case failed
        }

        @ObservableState
        package struct State: Equatable {
            /// Who invites.
            package let session: Session
            package let space: SpaceSummary
            package var invite = Invite.making

            /// Whether there's a link to copy: once it's made.
            package var canCopy: Bool {
                if case .made = invite { true } else { false }
            }
        }

        package enum Action {
            /// The dialog is shown: the invite is made.
            case appeared
            case made(SpaceInviteOffer)
            case failed
            case copyTapped
        }

        @Dependency(\.server) package var server
        @Dependency(\.pasteboard) package var pasteboard

        package var body: some ReducerOf<Self> {
            Reduce { state, action in
                switch action {
                case .appeared:
                    return .run { [session = state.session, space = state.space.id] send in
                        do {
                            await send(.made(try await server.makeInvite(session, space)))
                        } catch {
                            await send(.failed)
                        }
                    }

                case .made(let offer):
                    state.invite = .made(link: offer.link)
                    return .none

                case .failed:
                    state.invite = .failed
                    return .none

                case .copyTapped:
                    guard case .made(let link) = state.invite else { return .none }
                    return .run { _ in await pasteboard.copy(link) }
                }
            }
        }
    }

    /// The Spaces list, with what's written to find one.
    @Reducer
    package struct ChoosingSpace {
        package init() {}

        @ObservableState
        package struct State: Equatable {
            package var search = ""
        }

        package enum Action: BindableAction {
            case binding(BindingAction<State>)
        }

        package var body: some ReducerOf<Self> {
            BindingReducer()
        }
    }
}

extension SidebarFeature.Destination.State: Equatable {}

extension AlertState where Action == SidebarFeature.Destination.Alert {
    package static func archive(_ space: SpaceSummary) -> Self {
        AlertState {
            TextState("Archive “\(space.name)”?")
        } actions: {
            ButtonState(role: .destructive, action: .archiveConfirmed(space.id)) { TextState("Archive") }
            ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
            TextState(
                "Its conversations can still be read, and nothing new is said in them. Its admins can unarchive it.")
        }
    }

    package static func delete(_ row: SidebarFeature.Row) -> Self {
        AlertState {
            TextState("Delete “\(row.shownTitle)”?")
        } actions: {
            ButtonState(role: .destructive, action: .deleteConfirmed(row.id)) { TextState("Delete") }
            ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
            TextState("It's deleted for everyone in it, and can't be brought back.")
        }
    }
}

@MainActor
extension Binding where Value == Store<SidebarFeature.Destination.State, SidebarFeature.Destination.Action>? {
    /// The alert over the window, for a view to show. TCA's `@Reducer` leaves an alert's case path
    /// internal when its action is declared apart, so it's handed out here.
    package var asking: Binding<Store<AlertState<SidebarFeature.Destination.Alert>, SidebarFeature.Destination.Alert>?> {
        self.alert
    }
}
