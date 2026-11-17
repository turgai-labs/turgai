import Elementary
import Hummingbird
import HummingbirdElementary
import HummingbirdWebSocket
import TurgaiApplication
import TurgaiDomain
import TurgaiSpaces
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension TurgaiMainWebApp {
    func registerConnectionRoutes(on router: Router<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies) {
        registerConnections(on: router.group("spaces/:space/connections"), dependencies: dependencies)
    }

    /// A space's connections, for whoever may configure them: adding one, changing it, and removing
    /// it, each through the space.
    private func registerConnections(
        on connections: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        let channelSecrets = dependencies.channelSecrets
        let system = dependencies.system
        /// The space the path names, and how `user` sees it: none unless they may configure its
        /// connections.
        @Sendable func reached(_ context: BasicWebSocketRequestContext, by user: AuthenticatedUser) async throws
            -> (Space, SpaceListing)?
        {
            guard let id = context.parameters.get("space").flatMap(UUID.init(uuidString:)).map(SpaceID.init) else {
                return nil
            }
            let space = try await Space.identified(by: id, on: system)
            guard let listing = try await space.listing(for: .account(user.id)), listing.permissions.connections else {
                return nil
            }
            return (space, listing)
        }
        /// The connection the path names, of `space`.
        @Sendable func named(in context: BasicWebSocketRequestContext, of space: Space) async throws -> Connection? {
            guard let id = context.parameters.get("id").flatMap(ConnectionID.init) else { return nil }
            return try await space.connection(id)
        }
        /// Its connections' page.
        @Sendable func path(of listing: SpaceListing) -> String {
            "/spaces/\(listing.id.rawValue.uuidString)/connections"
        }

        connections.get { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            guard let (space, listing) = try await reached(context, by: user) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            var items: [ConnectionListItem] = []
            for connection in try await space.connections(for: .account(user.id)) {
                let status = try await ConnectionRun.of(connection.id, in: listing.id, on: system).status
                items.append(
                    ConnectionListItem(
                        id: connection.id, label: connection.label.rawValue, enabled: connection.enabled,
                        hasToken: try await channelSecrets.hasToken(for: connection.id.rawValue),
                        stopped: status.stopped?.description))
            }
            return HTMLResponse {
                ConnectionsPage(user: user, space: listing, connections: items)
            }.response(from: request, context: context)
        }

        connections.get("new") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            guard let (_, listing) = try await reached(context, by: user) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            return HTMLResponse {
                NewConnectionPage(user: user, space: listing)
            }.response(from: request, context: context)
        }

        // A new connection, off until it has a token and is turned on.
        connections.post("create") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            guard let (space, listing) = try await reached(context, by: user) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let values = ConnectionCreateFormValues(form: form)
            do {
                guard values.kind == "telegram" else { throw ConnectionFormError.unsupportedChannel }
                guard let label = ConnectionLabel(values.label) else { throw ConnectionFormError.invalidLabel }
                let connection = Connection(label: label, enabled: false, platform: .telegram(TelegramAccess()))
                try await space.addConnection(connection, by: .account(user.id))
                return TurgaiWebSupport.redirect(to: path(of: listing) + "/\(connection.id)")
            } catch {
                return HTMLResponse {
                    NewConnectionPage(user: user, space: listing, error: TurgaiWebSupport.connectionErrorMessage(error))
                }.response(from: request, context: context)
            }
        }

        connections.get(":id") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            guard let (space, listing) = try await reached(context, by: user) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            guard let connection = try await named(in: context, of: space) else {
                return TurgaiWebSupport.redirect(to: path(of: listing))
            }
            let draft = ConnectionDraft(
                connection, hasToken: try await channelSecrets.hasToken(for: connection.id.rawValue))
            return HTMLResponse {
                ConnectionEditPage(user: user, space: listing, connection: draft)
            }.response(from: request, context: context)
        }

        // The connection as the form says from now on: a new token checked with Telegram before
        // anything's saved.
        connections.post(":id/update") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            guard let (space, listing) = try await reached(context, by: user) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            guard let existing = try await named(in: context, of: space) else {
                return TurgaiWebSupport.redirect(to: path(of: listing))
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let id = existing.id.rawValue
            let draft = ConnectionDraft(
                form: form, over: ConnectionDraft(existing, hasToken: try await channelSecrets.hasToken(for: id)))
            do {
                let chatIDs = try OnboardingInput.chatIDs(from: draft.chatIDs)
                guard let label = ConnectionLabel(draft.label) else { throw ConnectionFormError.invalidLabel }
                let newToken = draft.token.isEmpty ? nil : draft.token
                if let newToken {
                    // The token checked before either part is saved: the secret and the space are
                    // kept apart, so the two can't be saved at once.
                    try await TelegramAPIClient.live(token: newToken).validateToken()
                }
                var updated = existing
                updated.label = label
                updated.enabled = draft.enabled
                updated.platform = .telegram(TelegramAccess(chatIDs: chatIDs))
                let previousToken = newToken == nil ? nil : try await channelSecrets.token(for: id)
                do {
                    if let newToken { try await channelSecrets.setToken(for: id, token: newToken) }
                    try await space.changeConnection(updated, by: .account(user.id))
                } catch {
                    if newToken != nil {
                        if let previousToken {
                            try? await channelSecrets.setToken(for: id, token: previousToken)
                        } else {
                            try? await channelSecrets.remove(for: id)
                        }
                    }
                    throw error
                }
                return TurgaiWebSupport.redirect(to: path(of: listing) + "/\(existing.id)")
            } catch {
                var shown = draft
                shown.hasToken = try await channelSecrets.hasToken(for: id)
                shown.token = ""
                return HTMLResponse {
                    ConnectionEditPage(
                        user: user, space: listing, connection: shown,
                        error: TurgaiWebSupport.connectionErrorMessage(error))
                }.response(from: request, context: context)
            }
        }

        // The connection removed from its space, which stops it, and its token let go.
        connections.post(":id/delete") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            guard let (space, listing) = try await reached(context, by: user) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            if let connection = try await named(in: context, of: space) {
                try await space.removeConnection(connection.id, by: .account(user.id))
                try? await channelSecrets.remove(for: connection.id.rawValue)
            }
            return TurgaiWebSupport.redirect(to: path(of: listing))
        }
    }
}
