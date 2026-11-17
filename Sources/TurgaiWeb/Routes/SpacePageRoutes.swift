import Elementary
import Hummingbird
import HummingbirdElementary
import HummingbirdWebSocket
import TurgaiAgents
import TurgaiApplication
import TurgaiConversations
import TurgaiDomain
import TurgaiHail
import TurgaiSpaces

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension TurgaiMainWebApp {
    /// The web pages of spaces: making one, and each one's bots and chat. Its connections' pages
    /// are their own.
    func registerSpacePageRoutes(
        on router: Router<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        registerNewSpace(on: router.group("spaces/new"), dependencies: dependencies)
        registerSpaceBots(on: router.group("spaces/:space"), dependencies: dependencies)
        registerSpaceChat(on: router.group("spaces/:space/chat"), dependencies: dependencies)
    }

    /// Making a space: its name and its first bot, by whoever's signed in, its admin.
    private func registerNewSpace(
        on new: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        let agentCredentials = dependencies.agentCredentials
        let system = dependencies.system

        new.get { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            return HTMLResponse {
                NewSpacePage(user: user, name: "", draft: .new(named: ""))
            }.response(from: request, context: context)
        }

        new.post { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let written = form["spaceName"]?.first ?? ""
            let draft = AgentDraft(form: form, over: .new(named: ""))
            guard let name = SpaceName(written) else {
                return HTMLResponse {
                    NewSpacePage(user: user, name: written, draft: draft, error: "Give the space a name.")
                }.response(from: request, context: context)
            }
            var pendingCredential: AgentCredentialReference?
            do {
                let (bot, newKey) = try await draft.bot(over: nil, credentials: agentCredentials)
                if let newKey {
                    pendingCredential = newKey.reference
                    try await agentCredentials.save(newKey.value, for: newKey.reference)
                }
                let id = SpaceID()
                // It starts with its chats' reminders and schedules.
                try await Space.identified(by: id, on: system).make(
                    named: name, by: .account(user.id), bot: bot, installing: [Scheduler.kind, Timers.kind])
                pendingCredential = nil
                return TurgaiWebSupport.redirect(to: "/spaces/\(id.rawValue.uuidString)")
            } catch {
                if let pendingCredential { try? await agentCredentials.remove(pendingCredential) }
                return HTMLResponse {
                    NewSpacePage(
                        user: user, name: written, draft: draft, error: TurgaiWebSupport.profileErrorMessage(error))
                }.response(from: request, context: context)
            }
        }

        // The chosen provider's models, as the new space's form has it: no key is saved yet.
        new.post("models") { request, context in
            guard await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) != nil else {
                return Response(status: .unauthorized)
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let outcome = await ModelSearch.search(
                AgentDraft(form: form, over: .new(named: "")), saved: nil, credentials: agentCredentials)
            return HTMLResponse { ModelSearchAnswer(outcome: outcome) }.response(from: request, context: context)
        }

        new.post("models/window") { request, context in
            guard await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) != nil else {
                return Response(status: .unauthorized)
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let draft = AgentDraft(form: form, over: .new(named: ""))
            let model = await ModelWindow.ask(draft, saved: nil, credentials: agentCredentials)
            return HTMLResponse {
                ContextWindowField(
                    provider: draft.provider, tokens: draft.settings.contextWindow, model: model, replacing: true)
            }.response(from: request, context: context)
        }
    }

    /// A space's bots: looking at them, adding one, changing it, choosing the main one, and removing
    /// one; each by whoever's signed in, as the space allows them.
    private func registerSpaceBots(
        on space: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        let agentCredentials = dependencies.agentCredentials
        let requestLimits = dependencies.requestLimits
        let system = dependencies.system
        /// The space the path names, and how `user` sees it: none when they're not in it.
        @Sendable func reached(_ context: BasicWebSocketRequestContext, by user: AuthenticatedUser) async throws
            -> (Space, SpaceListing)?
        {
            guard let id = context.parameters.get("space").flatMap(UUID.init(uuidString:)).map(SpaceID.init) else {
                return nil
            }
            let space = try await Space.identified(by: id, on: system)
            guard let listing = try await space.listing(for: .account(user.id)) else { return nil }
            return (space, listing)
        }
        /// The bot `form` names, as `space` has it now.
        @Sendable func saved(_ form: [String: [String]], in space: Space) async throws -> Bot? {
            guard let id = form["id"]?.first.flatMap({ BotID($0) }) else { return nil }
            return try await space.bot(id)
        }
        /// The limit of `bot`'s provider account, if it has one.
        @Sendable func requestLimit(of bot: Bot) async throws -> Int? {
            guard let account = bot.model.location.account(for: try bot.model.agentModel) else { return nil }
            return try await requestLimits.limit(for: account)
        }
        /// Sets the limit `draft` gives for `bot`'s provider account: empty lifts it.
        @Sendable func saveRequestLimit(of draft: AgentDraft, for bot: Bot) async throws {
            guard let account = bot.model.location.account(for: try bot.model.agentModel) else { return }
            try await requestLimits.setLimit(Int(draft.settings.requestLimit), for: account)
        }
        /// `bot`'s page in `space` for `user`, its form showing `draft`, and `error` when saving failed.
        @Sendable func detail(
            _ bot: Bot, of space: (Space, SpaceListing), for user: AuthenticatedUser, draft: AgentDraft? = nil,
            error: String? = nil, _ request: Request, _ context: BasicWebSocketRequestContext
        ) async throws -> Response {
            let (reached, listing) = space
            let runtime = await dependencies.runtimeSnapshots(of: listing.id, for: .account(user.id)).filter {
                $0.profileID == bot.id.description
            }
            let placement: AgentDetailPage.Placement =
                try await reached.mainBot().id == bot.id ? .main : .additional
            let shown = if let draft { draft } else { AgentDraft(bot, requestLimit: try await requestLimit(of: bot)) }
            return HTMLResponse {
                AgentDetailPage(
                    user: user, space: listing, bot: bot, draft: shown, runtime: runtime, placement: placement,
                    error: error)
            }.response(from: request, context: context)
        }
        /// Its bots' page.
        @Sendable func path(of listing: SpaceListing) -> String {
            "/spaces/\(listing.id.rawValue.uuidString)"
        }

        space.get { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            guard let (reached, listing) = try await reached(context, by: user) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            let bots = (try? await reached.bots(for: .account(user.id))) ?? []
            let runtime = await dependencies.runtimeSnapshots(of: listing.id, for: .account(user.id))
            return HTMLResponse {
                SpacePage(user: user, space: listing, profiles: bots.map(TurgaiWebSupport.botCard), runtime: runtime)
            }.response(from: request, context: context)
        }

        // What each of its bots is doing now, for its page to refresh.
        space.get("runtime") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return Response(status: .unauthorized)
            }
            guard let (reached, listing) = try await reached(context, by: user) else {
                return Response(status: .notFound)
            }
            let bots = (try? await reached.bots(for: .account(user.id))) ?? []
            let runtime = await dependencies.runtimeSnapshots(of: listing.id, for: .account(user.id))
            return try TurgaiWebSupport.jsonResponse(
                TurgaiDashboardSnapshot(
                    profiles: bots.map {
                        BotSummary(id: $0.id.description, name: $0.name.rawValue, model: $0.modelIdentifier)
                    },
                    runtime: runtime))
        }

        space.get("bots/new") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            guard let (_, listing) = try await reached(context, by: user) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            guard listing.permissions.bots == .configure else {
                return TurgaiWebSupport.redirect(to: path(of: listing))
            }
            return HTMLResponse {
                NewAgentPage(user: user, space: listing, draft: .new(named: ""))
            }.response(from: request, context: context)
        }

        space.get("bots/:id") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            guard let (reached, listing) = try await reached(context, by: user) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            guard let id = context.parameters.get("id").flatMap({ BotID($0) }),
                let bot = try await reached.bot(id)
            else {
                return TurgaiWebSupport.redirect(to: path(of: listing))
            }
            return try await detail(bot, of: (reached, listing), for: user, request, context)
        }

        // The chosen provider's models, as the form has it, while it's filled in: answered under the
        // model field, its models in place of the field's suggestions.
        space.post("bots/models") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return Response(status: .unauthorized)
            }
            guard let (reached, listing) = try await reached(context, by: user), listing.permissions.bots == .configure
            else { return Response(status: .notFound) }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let outcome = await ModelSearch.search(
                AgentDraft(form: form, over: .new(named: "")),
                saved: try await saved(form, in: reached)?.model.location, credentials: agentCredentials)
            return HTMLResponse { ModelSearchAnswer(outcome: outcome) }.response(from: request, context: context)
        }

        // The chosen model's window, as the form has it: in place of its provider's context window
        // field.
        space.post("bots/models/window") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return Response(status: .unauthorized)
            }
            guard let (reached, listing) = try await reached(context, by: user), listing.permissions.bots == .configure
            else { return Response(status: .notFound) }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let draft = AgentDraft(form: form, over: .new(named: ""))
            let model = await ModelWindow.ask(
                draft, saved: try await saved(form, in: reached)?.model.location, credentials: agentCredentials)
            return HTMLResponse {
                ContextWindowField(
                    provider: draft.provider, tokens: draft.settings.contextWindow, model: model, replacing: true)
            }.response(from: request, context: context)
        }

        space.post("bots/update") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            guard let (reached, listing) = try await reached(context, by: user) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            guard let existing = try await saved(form, in: reached) else {
                return TurgaiWebSupport.redirect(to: path(of: listing))
            }
            let draft = AgentDraft(
                form: form, over: AgentDraft(existing, requestLimit: try await requestLimit(of: existing)))
            var pendingCredential: AgentCredentialReference?
            do {
                let (bot, newKey) = try await draft.bot(over: existing, credentials: agentCredentials)
                if let newKey {
                    pendingCredential = newKey.reference
                    try await agentCredentials.save(newKey.value, for: newKey.reference)
                }
                try await reached.changeBot(bot, by: .account(user.id))
                try await saveRequestLimit(of: draft, for: bot)
                pendingCredential = nil
                if let old = existing.model.location.credentialReference,
                    old != bot.model.location.credentialReference
                {
                    try? await agentCredentials.remove(old)
                }
                return TurgaiWebSupport.redirect(to: path(of: listing) + "/bots/\(bot.id)")
            } catch {
                if let pendingCredential { try? await agentCredentials.remove(pendingCredential) }
                return try await detail(
                    existing, of: (reached, listing), for: user, draft: draft,
                    error: TurgaiWebSupport.profileErrorMessage(error), request, context)
            }
        }

        // The bot the form names, the main one from now on.
        space.post("bots/main") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            guard let (reached, listing) = try await reached(context, by: user) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            guard let bot = try await saved(form, in: reached) else {
                return TurgaiWebSupport.redirect(to: path(of: listing))
            }
            do {
                try await reached.chooseMain(bot.id, by: .account(user.id))
                return TurgaiWebSupport.redirect(to: path(of: listing) + "/bots/\(bot.id)")
            } catch {
                return try await detail(
                    bot, of: (reached, listing), for: user, error: TurgaiWebSupport.profileErrorMessage(error),
                    request, context)
            }
        }

        space.post("bots/create") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            guard let (reached, listing) = try await reached(context, by: user) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let draft = AgentDraft(form: form, over: .new(named: ""))
            var pendingCredential: AgentCredentialReference?
            do {
                let (bot, newKey) = try await draft.bot(over: nil, credentials: agentCredentials)
                if let newKey {
                    pendingCredential = newKey.reference
                    try await agentCredentials.save(newKey.value, for: newKey.reference)
                }
                try await reached.addBot(bot, by: .account(user.id))
                try await saveRequestLimit(of: draft, for: bot)
                pendingCredential = nil
                return TurgaiWebSupport.redirect(to: path(of: listing) + "/bots/\(bot.id)")
            } catch {
                if let pendingCredential { try? await agentCredentials.remove(pendingCredential) }
                return HTMLResponse {
                    NewAgentPage(
                        user: user, space: listing, draft: draft, error: TurgaiWebSupport.profileErrorMessage(error))
                }.response(from: request, context: context)
            }
        }

        space.post("bots/delete") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            guard let (reached, listing) = try await reached(context, by: user) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            guard let bot = try await saved(form, in: reached) else {
                return TurgaiWebSupport.redirect(to: path(of: listing))
            }
            do {
                try await reached.removeBot(bot.id, by: .account(user.id))
                if let reference = bot.model.location.credentialReference {
                    try? await agentCredentials.remove(reference)
                }
                return TurgaiWebSupport.redirect(to: path(of: listing))
            } catch {
                return try await detail(
                    bot, of: (reached, listing), for: user, error: TurgaiWebSupport.profileErrorMessage(error),
                    request, context)
            }
        }
    }

    /// Chatting in a space: in the conversation the address names; without one, in the person's
    /// latest there, with the bot chosen or any, or a new one with it, or the space's main.
    private func registerSpaceChat(
        on chat: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        let system = dependencies.system
        /// The page of the conversation `request` names in the space the path names, as `user` reads
        /// it; without one, a redirect to `path` naming the conversation to show: their latest there
        /// answered by `bot`, or by any bot when none is chosen, or else a new one with `bot`, or the
        /// main.
        @Sendable func page(
            _ request: Request, _ context: BasicWebSocketRequestContext, for user: AuthenticatedUser,
            bot written: BotID?, at path: String
        ) async throws -> Response {
            let person = TurgaiDomain.UserID.account(user.id)
            guard let id = context.parameters.get("space").flatMap(UUID.init(uuidString:)).map(SpaceID.init) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            let space = try await Space.identified(by: id, on: system)
            guard try await space.listing(for: person) != nil else { return TurgaiWebSupport.redirect(to: "/") }
            let bot: Bot?
            if let written {
                guard let found = try await space.bot(written) else { return TurgaiWebSupport.redirect(to: path) }
                bot = found
            } else {
                bot = nil
            }
            guard let conversationAddress = request.uri.queryParameters["conversation"].map(String.init) else {
                let directory = try await system.singleton
                    .proxy(ConversationDirectory.self, name: ConversationDirectory.singletonName)
                let listed: [ConversationListing] = try await directory.conversations(of: person)
                let latest = listed.first { (listing: ConversationListing) -> Bool in
                    guard listing.space == id, listing.id.channel == turgaiChannel, let answering = listing.bot
                    else { return false }
                    return bot.map { $0.id == answering } ?? true
                }
                if let latest {
                    return TurgaiWebSupport.redirect(to: "\(path)?conversation=\(latest.id.externalAddress.rawValue)")
                }
                let answering = if let bot { bot } else { try await space.mainBot() }
                let started = TurgaiDomain.ConversationID(
                    channel: turgaiChannel, externalAddress: .init(UUID().uuidString))
                try await space.start(started, with: answering.id, by: person)
                return TurgaiWebSupport.redirect(to: "\(path)?conversation=\(started.externalAddress.rawValue)")
            }
            guard let minted = UUID(uuidString: conversationAddress) else { return TurgaiWebSupport.redirect(to: path) }
            let conversation = TurgaiDomain.ConversationID(
                channel: turgaiChannel, externalAddress: .init(minted.uuidString))
            do {
                _ = try await space.reading(conversation, by: person)
            } catch is ConversationRefusal {
                return TurgaiWebSupport.redirect(to: path)
            } catch is SpaceRefusal {
                return TurgaiWebSupport.redirect(to: path)
            }
            guard let answering = try await space.answeringBot(of: conversation) else {
                return TurgaiWebSupport.redirect(to: "/spaces/\(id.rawValue.uuidString)")
            }
            return HTMLResponse {
                ChatPage(
                    user: user, bot: answering, space: id.rawValue.uuidString, conversationID: minted.uuidString)
            }.response(from: request, context: context)
        }

        chat.get { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            return try await page(request, context, for: user, bot: nil, at: request.uri.path)
        }

        chat.get(":bot") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            guard let bot = context.parameters.get("bot").flatMap({ BotID($0) }) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            return try await page(request, context, for: user, bot: bot, at: request.uri.path)
        }
    }
}
