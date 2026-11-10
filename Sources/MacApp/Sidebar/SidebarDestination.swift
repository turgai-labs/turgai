import ComposableArchitecture
import Foundation
import TurgaiModels

extension SidebarFeature {
    /// What's over the window: asking before a space is archived or a conversation deleted, or a
    /// dialog.
    @Reducer
    enum Destination {
        @ReducerCaseIgnored case alert(AlertState<Alert>)
        /// A conversation's or a space's new name.
        case renaming(Renaming)
        /// A space to make, by its name, or to join, by an invite's link.
        case addingSpace(AddingSpace)
        /// An invite to a space, its link to give someone.
        case inviting(Inviting)
        /// Every space, to pick one.
        case choosingSpace(ChoosingSpace)

        @CasePathable
        enum Action {
            case alert(Alert)
            case renaming(Renaming.Action)
            case addingSpace(AddingSpace.Action)
            case inviting(Inviting.Action)
            case choosingSpace(ChoosingSpace.Action)
        }

        @CasePathable
        enum Alert: Equatable {
            case archiveConfirmed(SpaceID)
            case deleteConfirmed(ConversationID)
        }
    }

    /// A conversation's or a space's new name, being written.
    @Reducer
    struct Renaming {
        @ObservableState
        struct State: Equatable {
            enum Subject: Equatable {
                case conversation(ConversationID)
                case space(SpaceID)
            }

            let subject: Subject
            var name: String
        }

        enum Action: BindableAction {
            case binding(BindingAction<State>)
        }

        var body: some ReducerOf<Self> {
            BindingReducer()
        }
    }

    /// A space being added: made, by the name written, or joined, by the invite's link pasted.
    @Reducer
    struct AddingSpace {
        @ObservableState
        struct State: Equatable {
            /// Who adds it.
            let session: Session
            var name = ""
            var link = ""
            /// What went wrong making or joining one, when something did.
            var problem: String?

            /// The invite the link is: none while it isn't one.
            var invite: SpaceInviteLink? { SpaceInviteLink(link) }
            var canMake: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            var canJoin: Bool { invite != nil }
        }

        enum Action: BindableAction {
            case binding(BindingAction<State>)
            case makeTapped
            case joinTapped
            /// Making or joining it failed, and why.
            case failed(String)
            case delegate(Delegate)

            enum Delegate: Equatable {
                /// A space made or joined.
                case added(SpaceSummary)
            }
        }

        @Dependency(\.server) var server

        var body: some ReducerOf<Self> {
            BindingReducer()
            Reduce { state, action in
                switch action {
                case .binding(\.link):
                    state.problem = nil
                    return .none

                case .binding, .delegate:
                    return .none

                case .makeTapped:
                    guard state.canMake else { return .none }
                    let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    return .run { [session = state.session] send in
                        do {
                            await send(.delegate(.added(try await server.makeSpace(session, name))))
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
                    return .none
                }
            }
        }
    }

    /// An invite to a space, made as the dialog shows, its link copied.
    @Reducer
    struct Inviting {
        /// The invite: being made, made, with its link, or not made.
        enum Invite: Equatable {
            case making
            case made(link: String)
            case failed
        }

        @ObservableState
        struct State: Equatable {
            /// Who invites.
            let session: Session
            let space: SpaceSummary
            var invite = Invite.making

            /// Whether there's a link to copy: once it's made.
            var canCopy: Bool {
                if case .made = invite { true } else { false }
            }
        }

        enum Action {
            /// The dialog is shown: the invite is made.
            case appeared
            case made(SpaceInviteOffer)
            case failed
            case copyTapped
        }

        @Dependency(\.server) var server
        @Dependency(\.pasteboard) var pasteboard

        var body: some ReducerOf<Self> {
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
    struct ChoosingSpace {
        @ObservableState
        struct State: Equatable {
            var search = ""
        }

        enum Action: BindableAction {
            case binding(BindingAction<State>)
        }

        var body: some ReducerOf<Self> {
            BindingReducer()
        }
    }
}

extension SidebarFeature.Destination.State: Equatable {}

extension AlertState where Action == SidebarFeature.Destination.Alert {
    static func archive(_ space: SpaceSummary) -> Self {
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

    static func delete(_ row: SidebarFeature.Row) -> Self {
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
