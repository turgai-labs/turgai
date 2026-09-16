import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import NIOCore
import NorbyApplication
import NorbyHail
import NorbyPersistence
import NorbyTelegram
import ServiceLifecycle

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct TurgaiWebConfiguration: Sendable {
    public let storage: NorbyStorageConfiguration?
    public let postgresPassword: String?
    public let telegramToken: String?
    public let telegramChatIDs: [Int64]
    public let complete: Bool

    public var isReady: Bool {
        guard complete,
            let storage,
            telegramToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return false
        }
        if case .postgres = storage {
            return postgresPassword?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        return true
    }

    public static func load(directory: URL) throws -> Self {
        let stateURL = directory.appendingPathComponent("setup.json")
        let secretURL = directory.appendingPathComponent("telegram-token")
        let postgresPasswordURL = directory.appendingPathComponent("postgres-password")
        let state =
            try (try? Data(contentsOf: stateURL)).map {
                try JSONDecoder().decode(TurgaiSetupStore.State.self, from: $0)
            } ?? TurgaiSetupStore.State()
        let token = try? String(contentsOf: secretURL, encoding: .utf8)
        let postgresPassword = try? String(contentsOf: postgresPasswordURL, encoding: .utf8)
        return Self(
            storage: state.storage,
            postgresPassword: postgresPassword,
            telegramToken: token,
            telegramChatIDs: state.telegramChatIDs,
            complete: state.complete
        )
    }

    private init(
        storage: NorbyStorageConfiguration?,
        postgresPassword: String?,
        telegramToken: String?,
        telegramChatIDs: [Int64],
        complete: Bool
    ) {
        self.storage = storage
        self.postgresPassword = postgresPassword
        self.telegramToken = telegramToken
        self.telegramChatIDs = telegramChatIDs
        self.complete = complete
    }
}

/// Read-only runtime data supplied by the executable's Hail integration.
/// TurgaiWeb deliberately does not depend on the cluster runtime directly.
public struct TurgaiAgentRuntimeSnapshot: Codable, Sendable, Equatable {
    public let profileID: String
    public let contextID: String
    public let phase: String
    public let currentTool: String?
    public let contextUsedTokens: Int?
    public let contextLimitTokens: Int?
    public let conversationMessageCount: Int
    public let totalTokens: Int?

    public init(
        profileID: String,
        contextID: String,
        phase: String,
        currentTool: String? = nil,
        contextUsedTokens: Int? = nil,
        contextLimitTokens: Int? = nil,
        conversationMessageCount: Int = 0,
        totalTokens: Int? = nil
    ) {
        self.profileID = profileID
        self.contextID = contextID
        self.phase = phase
        self.currentTool = currentTool
        self.contextUsedTokens = contextUsedTokens
        self.contextLimitTokens = contextLimitTokens
        self.conversationMessageCount = conversationMessageCount
        self.totalTokens = totalTokens
    }
}

public struct TurgaiDashboardSnapshot: Codable, Sendable, Equatable {
    public let profiles: [NorbyAgentProfile]
    public let runtime: [TurgaiAgentRuntimeSnapshot]

    public init(
        profiles: [NorbyAgentProfile],
        runtime: [TurgaiAgentRuntimeSnapshot]
    ) {
        self.profiles = profiles
        self.runtime = runtime
    }
}

/// Minimal localhost dashboard. Onboarding is intentionally ordinary HTML
/// forms first; live HTMX screens can be added once configuration is complete.
public actor TurgaiWebApp: Service {
    private static let sessionCookieName = "turgai_auth"
    private static let bootstrapChallengeCookieName = "turgai_bootstrap"

    private let port: Int
    private let directory: URL
    private let auth: NorbyAuth
    private let setup: TurgaiSetupStore
    private let agentProfiles: NorbyAgentProfileStore
    private let runtimeSnapshots: @Sendable () async -> [TurgaiAgentRuntimeSnapshot]

    public init(
        port: Int = 3333,
        auth: NorbyAuth,
        directory: URL,
        agentProfiles: NorbyAgentProfileStore,
        runtimeSnapshots: @escaping @Sendable () async -> [TurgaiAgentRuntimeSnapshot] = { [] }
    ) throws {
        self.port = port
        self.directory = directory
        self.auth = auth
        self.setup = try TurgaiSetupStore(directory: directory)
        self.agentProfiles = agentProfiles
        self.runtimeSnapshots = runtimeSnapshots
    }

    public func run() async throws {
        try await runServer()
    }

    /// Waits for the setup forms served by this app to mark onboarding complete.
    /// The HTTP server itself remains alive while the application runtime starts.
    public func waitUntilComplete() async {
        await setup.waitUntilComplete()
    }

    private func runServer() async throws {
        let auth = self.auth
        let setup = self.setup
        let agentProfiles = self.agentProfiles
        let defaultFileDirectory = self.directory
        let runtimeSnapshots = self.runtimeSnapshots
        let userToolRegistry = UserToolRegistry(
            directory: self.directory.appendingPathComponent("tools", isDirectory: true)
        )
        let router = Router()
        router.addMiddleware {
            FileMiddleware(TurgaiWebAssets.publicRoot, searchForIndexHtml: false)
        }
        router.get { request, context in
            guard await auth.hasAdmin() else {
                return Self.redirect(to: "/onboarding")
            }
            guard let username = await Self.authenticatedAdmin(from: request, auth: auth) else {
                return Self.redirect(to: "/login")
            }
            let isComplete = await setup.isComplete
            let isReady = await setup.isReady
            let hasDefaultProfile = await agentProfiles.defaultProfile() != nil
            if isComplete && isReady && hasDefaultProfile {
                let profiles = await agentProfiles.profiles()
                let runtime = await runtimeSnapshots()
                return HTMLResponse {
                    TurgaiPage(
                        title: "Turgai",
                        username: username,
                        profiles: profiles,
                        runtime: runtime
                    )
                }.response(from: request, context: context)
            }
            return Self.redirect(to: "/onboarding/model")
        }
        router.get("/api/agents") { request, _ in
            guard await Self.authenticatedAdmin(from: request, auth: auth) != nil else {
                return Response(status: .unauthorized)
            }
            let profiles = await agentProfiles.profiles()
            let runtime = await runtimeSnapshots()
            return try Self.jsonResponse(
                TurgaiDashboardSnapshot(profiles: profiles, runtime: runtime)
            )
        }
        router.get("/tools") { request, context in
            guard let username = await Self.authenticatedAdmin(from: request, auth: auth) else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            return HTMLResponse {
                TurgaiToolsPage(
                    username: username,
                    documents: userToolRegistry.documents()
                )
            }.response(from: request, context: context)
        }
        router.get("/tools/new") { request, context in
            guard let username = await Self.authenticatedAdmin(from: request, auth: auth) else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            return HTMLResponse {
                TurgaiToolEditorPage(
                    username: username,
                    draft: TurgaiToolDraft.new(fileName: Self.newToolFileName())
                )
            }.response(from: request, context: context)
        }
        router.get("/tools/:file") { request, context in
            guard let username = await Self.authenticatedAdmin(from: request, auth: auth) else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            guard let fileName = context.parameters.get("file"),
                let document = userToolRegistry.document(named: fileName)
            else {
                return Self.redirect(to: "/tools")
            }
            return HTMLResponse {
                TurgaiToolEditorPage(
                    username: username,
                    draft: TurgaiToolDraft(document: document),
                    issue: document.issue
                )
            }.response(from: request, context: context)
        }
        router.post("/tools/save") { request, context in
            guard let username = await Self.authenticatedAdmin(from: request, auth: auth) else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await Self.decodeForm(from: request, context: context)
            let isNew = form["isNew"]?.first == "true"
            let submittedFileName = form["fileName"]?.first ?? ""
            let fileName =
                isNew
                ? Self.newToolFileName()
                : submittedFileName
            let draft = TurgaiToolDraft(form: form, fileName: fileName, isNew: isNew)
            do {
                try userToolRegistry.save(
                    named: fileName,
                    contents: try draft.encodedDefinition()
                )
                return Self.redirect(to: "/tools")
            } catch {
                return HTMLResponse {
                    TurgaiToolEditorPage(
                        username: username,
                        draft: draft,
                        error: Self.userToolErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
        router.post("/tools/delete") { request, context in
            guard let username = await Self.authenticatedAdmin(from: request, auth: auth) else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await Self.decodeForm(from: request, context: context)
            let fileName = form["fileName"]?.first ?? ""
            do {
                try userToolRegistry.delete(named: fileName)
                return Self.redirect(to: "/tools")
            } catch {
                return HTMLResponse {
                    TurgaiToolsPage(
                        username: username,
                        documents: userToolRegistry.documents(),
                        error: Self.userToolErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
        router.get("/agents/new") { request, context in
            guard let username = await Self.authenticatedAdmin(from: request, auth: auth) else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let profiles = await agentProfiles.profiles()
            let modelCatalog = await Self.modelCatalog(for: profiles)
            return HTMLResponse {
                NewAgentPage(username: username, modelCatalog: modelCatalog)
            }.response(from: request, context: context)
        }
        router.get("/agents/:id") { request, context in
            guard let username = await Self.authenticatedAdmin(from: request, auth: auth) else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            guard let id = context.parameters.get("id"),
                let profile = await agentProfiles.profile(id: id)
            else {
                return Self.redirect(to: "/")
            }
            let profiles = await agentProfiles.profiles()
            let modelCatalog = await Self.modelCatalog(for: profiles)
            let runtime = await runtimeSnapshots().filter { $0.profileID == profile.id }
            let isDefaultProfile = await agentProfiles.isDefaultProfile(id: profile.id)
            return HTMLResponse {
                AgentDetailPage(
                    username: username,
                    profile: profile,
                    modelCatalog: modelCatalog,
                    runtime: runtime,
                    isDefaultProfile: isDefaultProfile
                )
            }.response(from: request, context: context)
        }
        router.post("/agents/update") { request, context in
            guard let username = await Self.authenticatedAdmin(from: request, auth: auth) else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await Self.decodeForm(from: request, context: context)
            let id = form["id"]?.first ?? ""
            guard let existingProfile = await agentProfiles.profile(id: id) else {
                return Self.redirect(to: "/")
            }
            do {
                var profile = existingProfile
                profile.name = form["name"]?.first ?? profile.name
                let model = try Self.model(from: form)
                profile.model = model
                profile.ollamaBaseURL = try Self.ollamaBaseURL(from: form, for: model)
                profile.contextWindow = try Self.parsePositiveInteger(
                    form["contextWindow"]?.first,
                    field: "context window"
                )
                profile.persona = form["persona"]?.first
                profile.instructions = form["instructions"]?.first ?? profile.instructions
                profile.telegramChatIDs = try Self.parseChatIDs(form["telegramChatIDs"]?.first)
                try await agentProfiles.update(profile)
                return Self.redirect(to: "/agents/\(profile.id)")
            } catch {
                let profiles = await agentProfiles.profiles()
                let modelCatalog = await Self.modelCatalog(for: profiles)
                let runtime = await runtimeSnapshots().filter { $0.profileID == existingProfile.id }
                let isDefaultProfile = await agentProfiles.isDefaultProfile(id: existingProfile.id)
                return HTMLResponse {
                    AgentDetailPage(
                        username: username,
                        profile: existingProfile,
                        modelCatalog: modelCatalog,
                        runtime: runtime,
                        isDefaultProfile: isDefaultProfile,
                        error: Self.profileErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
        router.post("/agents/create") { request, context in
            guard let username = await Self.authenticatedAdmin(from: request, auth: auth) else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await Self.decodeForm(from: request, context: context)
            do {
                let name = form["name"]?.first ?? ""
                let model = try Self.model(from: form)
                let ollamaBaseURL = try Self.ollamaBaseURL(from: form, for: model)
                let contextWindow = try Self.parsePositiveInteger(
                    form["contextWindow"]?.first,
                    field: "context window"
                )
                let profile = try await agentProfiles.create(
                    name: name,
                    model: model,
                    ollamaBaseURL: ollamaBaseURL,
                    contextWindow: contextWindow,
                    persona: form["persona"]?.first,
                    instructions: form["instructions"]?.first ?? "",
                    telegramChatIDs: try Self.parseChatIDs(form["telegramChatIDs"]?.first)
                )
                return Self.redirect(to: "/agents/\(profile.id)")
            } catch {
                let profiles = await agentProfiles.profiles()
                let modelCatalog = await Self.modelCatalog(for: profiles)
                return HTMLResponse {
                    NewAgentPage(
                        username: username,
                        modelCatalog: modelCatalog,
                        error: Self.profileErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
        router.post("/agents/delete") { request, context in
            guard let username = await Self.authenticatedAdmin(from: request, auth: auth) else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await Self.decodeForm(from: request, context: context)
            let id = form["id"]?.first ?? ""
            guard let profile = await agentProfiles.profile(id: id) else {
                return Self.redirect(to: "/")
            }
            do {
                try await agentProfiles.delete(id: id)
                return Self.redirect(to: "/")
            } catch {
                let profiles = await agentProfiles.profiles()
                let modelCatalog = await Self.modelCatalog(for: profiles)
                let runtime = await runtimeSnapshots().filter { $0.profileID == profile.id }
                let isDefaultProfile = await agentProfiles.isDefaultProfile(id: profile.id)
                return HTMLResponse {
                    AgentDetailPage(
                        username: username,
                        profile: profile,
                        modelCatalog: modelCatalog,
                        runtime: runtime,
                        isDefaultProfile: isDefaultProfile,
                        error: Self.profileErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
        router.get("/login") { request, context in
            guard await auth.hasAdmin() else {
                return Self.redirect(to: "/onboarding")
            }
            if await Self.authenticatedAdmin(from: request, auth: auth) != nil {
                let isComplete = await setup.isComplete
                let isReady = await setup.isReady
                let hasDefaultProfile = await agentProfiles.defaultProfile() != nil
                return Self.redirect(
                    to: isComplete && isReady && hasDefaultProfile ? "/" : "/onboarding/model"
                )
            }
            return HTMLResponse { LoginPage() }.response(from: request, context: context)
        }
        router.post("/login") { request, context in
            let form = try await Self.decodeForm(from: request, context: context)
            let username = form["username"]?.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let password = form["password"]?.first ?? ""
            do {
                let session = try await auth.signIn(username: username, password: password)
                guard await auth.isAdmin(username) else {
                    return HTMLResponse { LoginPage(error: "Only an administrator can use this dashboard.") }
                        .response(from: request, context: context)
                }
                let isComplete = await setup.isComplete
                let isReady = await setup.isReady
                let hasDefaultProfile = await agentProfiles.defaultProfile() != nil
                let destination = isComplete && isReady && hasDefaultProfile ? "/" : "/onboarding/model"
                return Self.redirect(to: destination, settingCookie: Self.sessionCookie(session.token))
            } catch {
                return HTMLResponse { LoginPage(error: "Invalid username or password.") }
                    .response(from: request, context: context)
            }
        }
        router.get("/logout") { _, _ in
            Self.redirect(to: "/login", settingCookie: Self.expiredSessionCookie())
        }
        router.post("/logout") { _, _ in
            Self.redirect(to: "/login", settingCookie: Self.expiredSessionCookie())
        }
        router.get("/onboarding") { request, context in
            if await auth.hasAdmin() {
                guard await Self.authenticatedAdmin(from: request, auth: auth) != nil else {
                    return Self.redirect(to: "/login")
                }
                return Self.redirect(to: "/onboarding/model")
            }
            return HTMLResponse { OnboardingPage() }.response(from: request, context: context)
        }
        router.get("/onboarding/register") { request, context in
            guard !(await auth.hasAdmin()) else {
                return Self.redirect(to: "/login")
            }
            let challenge = await auth.issueBootstrapChallenge()
            var response = HTMLResponse {
                RegisterPage(challenge: challenge)
            }.response(from: request, context: context)
            response.setCookie(Self.bootstrapChallengeCookie(challenge))
            return response
        }
        router.post("/onboarding/register") { request, context in
            guard !(await auth.hasAdmin()) else {
                return Self.redirect(to: "/login")
            }
            let form = try await Self.decodeForm(from: request, context: context)
            let challenge = form["challenge"]?.first ?? ""
            let confirmation = request.cookies[Self.bootstrapChallengeCookieName]?.value ?? ""
            let username = form["username"]?.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let password = form["password"]?.first ?? ""
            do {
                _ = try await auth.bootstrap(
                    username: username,
                    password: password,
                    challenge: challenge,
                    confirmation: confirmation
                )
                let session = try await auth.signIn(username: username, password: password)
                var response = Self.redirect(
                    to: "/onboarding/model",
                    settingCookie: Self.sessionCookie(session.token)
                )
                response.setCookie(Self.expiredBootstrapChallengeCookie())
                return response
            } catch {
                let challenge = await auth.issueBootstrapChallenge()
                var response = HTMLResponse {
                    RegisterPage(
                        challenge: challenge,
                        error: "Could not create the administrator: \(error)"
                    )
                }.response(from: request, context: context)
                response.setCookie(Self.bootstrapChallengeCookie(challenge))
                return response
            }
        }
        router.get("/onboarding/model") { request, context in
            guard await Self.authenticatedAdmin(from: request, auth: auth) != nil else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let profiles = await agentProfiles.profiles()
            let modelCatalog = await Self.modelCatalog(for: profiles)
            let profile = await agentProfiles.defaultProfile()
            return HTMLResponse {
                ModelPage(modelCatalog: modelCatalog, profile: profile)
            }.response(from: request, context: context)
        }
        router.post("/onboarding/model") { request, context in
            guard await Self.authenticatedAdmin(from: request, auth: auth) != nil else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await Self.decodeForm(from: request, context: context)
            do {
                let model = try Self.model(from: form)
                let ollamaBaseURL = try Self.ollamaBaseURL(from: form, for: model)
                let name = form["agentName"]?.first ?? ""
                let contextWindow = try Self.parsePositiveInteger(
                    form["contextWindow"]?.first,
                    field: "context window"
                )
                let persona = form["persona"]?.first
                let instructions = form["instructions"]?.first ?? ""
                if var profile = await agentProfiles.defaultProfile() {
                    profile.model = model
                    profile.ollamaBaseURL = ollamaBaseURL
                    profile.name = name
                    profile.persona = persona
                    profile.instructions = instructions
                    profile.contextWindow = contextWindow
                    try await agentProfiles.update(profile)
                } else {
                    _ = try await agentProfiles.create(
                        name: name,
                        model: model,
                        ollamaBaseURL: ollamaBaseURL,
                        contextWindow: contextWindow,
                        persona: persona,
                        instructions: instructions
                    )
                }
                return Response(status: .seeOther, headers: [.location: "/onboarding/storage"])
            } catch {
                let profiles = await agentProfiles.profiles()
                let modelCatalog = await Self.modelCatalog(for: profiles)
                let profile = await agentProfiles.defaultProfile()
                return HTMLResponse {
                    ModelPage(
                        modelCatalog: modelCatalog,
                        profile: profile,
                        error: Self.profileErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
        router.get("/onboarding/storage") { request, context in
            guard await Self.authenticatedAdmin(from: request, auth: auth) != nil else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let storage = await setup.storageConfiguration
            return HTMLResponse {
                StoragePage(
                    storage: storage,
                    defaultFileDirectory: defaultFileDirectory
                )
            }.response(from: request, context: context)
        }
        router.post("/onboarding/storage") { request, context in
            guard await Self.authenticatedAdmin(from: request, auth: auth) != nil else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await Self.decodeForm(from: request, context: context)
            let values = StorageFormValues(form: form, defaultFileDirectory: defaultFileDirectory)
            do {
                let storage = try Self.storageConfiguration(
                    from: form,
                    defaultFileDirectory: defaultFileDirectory
                )
                try await setup.setStorage(
                    storage,
                    postgresPassword: form["postgresPassword"]?.first
                )
                return Response(status: .seeOther, headers: [.location: "/onboarding/telegram"])
            } catch {
                return HTMLResponse {
                    StoragePage(
                        values: values,
                        defaultFileDirectory: defaultFileDirectory,
                        error: Self.storageErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
        router.get("/onboarding/telegram") { request, context in
            guard await Self.authenticatedAdmin(from: request, auth: auth) != nil else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let chatIDs = await setup.telegramChatIDs
            return HTMLResponse {
                TelegramPage(chatIDs: chatIDs)
            }.response(from: request, context: context)
        }
        router.post("/onboarding/telegram") { request, context in
            guard await Self.authenticatedAdmin(from: request, auth: auth) != nil else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await Self.decodeForm(from: request, context: context)
            guard let token = form["token"]?.first?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
            else {
                return HTMLResponse { TelegramPage(error: "A Telegram bot token is required.") }
                    .response(from: request, context: context)
            }
            let chatIDs: [Int64]
            do {
                chatIDs = try Self.parseChatIDs(form["chatIDs"]?.first)
            } catch {
                return HTMLResponse {
                    TelegramPage(error: Self.telegramErrorMessage(error))
                }.response(from: request, context: context)
            }
            do {
                let telegramClient = try TelegramAPIClient.live(token: token)
                try await telegramClient.validateToken()
                try await setup.setTelegramToken(token, chatIDs: chatIDs)
            } catch {
                return HTMLResponse {
                    TelegramPage(chatIDs: chatIDs, error: Self.telegramErrorMessage(error))
                }.response(from: request, context: context)
            }
            return Response(status: .seeOther, headers: [.location: "/onboarding/finish"])
        }
        router.get("/onboarding/finish") { request, context in
            guard await Self.authenticatedAdmin(from: request, auth: auth) != nil else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            guard await setup.isReady, await agentProfiles.defaultProfile() != nil else {
                return Self.redirect(to: "/onboarding/model")
            }
            guard !(await setup.isComplete) else {
                return Self.redirect(to: "/")
            }
            return HTMLResponse { FinishPage() }
                .response(from: request, context: context)
        }
        router.post("/onboarding/finish") { request, context in
            guard await Self.authenticatedAdmin(from: request, auth: auth) != nil else {
                return Self.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            guard await setup.isReady, await agentProfiles.defaultProfile() != nil else {
                return Self.redirect(to: "/onboarding/model")
            }
            try await setup.complete()
            return Self.redirect(to: "/")
        }

        let application = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port))
        )
        try await application.run()
    }

    private static func modelCatalog(
        for profiles: [NorbyAgentProfile]
    ) async -> TurgaiModelCatalog {
        await TurgaiModelCatalogLoader.load(profiles: profiles)
    }

    private static func model(from form: [String: [String]]) throws -> AgentModel {
        let providerValue =
            form["provider"]?.first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelValue =
            form["modelID"]?.first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !providerValue.isEmpty, !modelValue.isEmpty else {
            throw TurgaiFormError.invalidValue("model")
        }

        let provider = AgentModelProvider(rawValue: providerValue)
        if modelValue.contains("/") {
            guard let fullModel = try? AgentModel(modelValue), fullModel.provider == provider else {
                throw TurgaiFormError.invalidValue("model")
            }
            return fullModel
        }
        guard
            let model = try? AgentModel(
                provider: provider,
                id: AgentModelID(rawValue: modelValue)
            )
        else {
            throw TurgaiFormError.invalidValue("model")
        }
        return model
    }

    private static func ollamaBaseURL(
        from form: [String: [String]],
        for model: AgentModel
    ) throws -> URL? {
        guard model.provider == .ollama else { return nil }
        let rawValue = form["ollamaBaseURL"]?.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawValue, !rawValue.isEmpty else {
            return OllamaConfiguration.defaultBaseURL
        }
        guard let url = URL(string: rawValue),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil
        else {
            throw TurgaiFormError.invalidValue("Ollama server URL")
        }
        return url
    }

    private static func storageConfiguration(
        from form: [String: [String]],
        defaultFileDirectory: URL
    ) throws -> NorbyStorageConfiguration {
        let backend =
            form["backend"]?.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "file"

        switch backend {
        case "file":
            let value = form["fileURL"]?.first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let url = value.flatMap(URL.init(string:)) ?? defaultFileDirectory
            guard url.isFileURL else {
                throw TurgaiFormError.invalidValue("file store URL")
            }
            return try NorbyStorageConfiguration.fileStore(directory: url)

        case "postgres":
            guard
                let rawURL = form["postgresURL"]?.first?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                let url = URL(string: rawURL)
            else {
                throw TurgaiFormError.invalidValue("PostgreSQL URL")
            }
            let username = form["postgresUsername"]?.first ?? ""
            return try NorbyStorageConfiguration.postgresStore(
                url: url,
                username: username
            )

        default:
            throw TurgaiFormError.invalidValue("storage backend")
        }
    }

    private static func parsePositiveInteger(_ value: String?, field: String) throws -> Int {
        guard let value, let integer = Int(value), integer > 0 else {
            throw TurgaiFormError.invalidValue(field)
        }
        return integer
    }

    private static func parseChatIDs(_ value: String?) throws -> [Int64] {
        guard let value else { return [] }
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty else { return [] }

        var result: [Int64] = []
        var seen = Set<Int64>()
        for value in normalizedValue.split(separator: ",", omittingEmptySubsequences: false) {
            let rawValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawValue.isEmpty, let id = Int64(rawValue), id != 0 else {
                throw TurgaiFormError.invalidValue("Telegram chat ID")
            }
            guard seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }

    private static func storageErrorMessage(_ error: Error) -> String {
        switch error {
        case TurgaiFormError.invalidValue(let field):
            "Enter a valid \(field)."
        case NorbyStorageConfigurationError.invalidFileURL:
            "File storage needs a file:// URL."
        case NorbyStorageConfigurationError.invalidPostgresURL:
            "PostgreSQL URL must look like postgres://host:5432/database."
        case NorbyStorageConfigurationError.invalidPostgresUsername:
            "A PostgreSQL username is required."
        case NorbyStorageConfigurationError.invalidPostgresPassword:
            "A PostgreSQL password is required."
        default:
            "Could not save storage configuration."
        }
    }

    private static func telegramErrorMessage(_ error: Error) -> String {
        switch error {
        case TurgaiFormError.invalidValue(let field):
            "Enter a valid \(field)."
        case TelegramAPIError.httpStatus(401), TelegramAPIError.api(code: 401, message: _):
            "Telegram rejected this bot token. Check it with BotFather and try again."
        case TelegramAPIError.rateLimited:
            "Telegram is temporarily rate-limiting validation. Wait a moment and try again."
        default:
            "Could not validate the Telegram token. Check your connection and try again."
        }
    }

    private static func profileErrorMessage(_ error: Error) -> String {
        switch error {
        case TurgaiFormError.invalidValue(let field):
            "Enter a valid \(field)."
        case NorbyAgentProfileError.invalidOllamaBaseURL:
            "Ollama server URL must be an http(s) URL with a host."
        case NorbyAgentProfileError.invalidContextWindow:
            "Context window must be a positive number."
        case NorbyAgentProfileError.duplicateTelegramChatID(let id):
            "Telegram chat ID \(id) is already assigned to another agent."
        case NorbyAgentProfileError.invalidName:
            "Give the agent a name and keep it under 120 characters."
        case NorbyAgentProfileError.invalidID(let id):
            "Invalid agent identifier: \(id)."
        case NorbyAgentProfileError.unknownProfile(let id):
            "Agent \(id) no longer exists."
        case NorbyAgentProfileError.cannotDeleteDefaultProfile:
            "The default agent cannot be deleted."
        default:
            "Could not save the agent configuration."
        }
    }

    private static func userToolErrorMessage(_ error: Error) -> String {
        if let error = error as? UserToolRegistryError {
            return error.description
        }
        if let error = error as? TurgaiToolDraftError {
            return error.description
        }
        return "Could not save the tool."
    }

    private static func newToolFileName() -> String {
        "tool-\(UUID().uuidString.lowercased()).json"
    }

    private static func jsonResponse<T: Encodable>(_ value: T) throws -> Response {
        Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: try JSONEncoder().encode(value)))
        )
    }

    private static func authenticatedAdmin(from request: Request, auth: NorbyAuth) async -> String? {
        guard let cookie = request.cookies[sessionCookieName],
            let username = try? await auth.authenticate(cookie.value),
            await auth.isAdmin(username)
        else { return nil }
        return username
    }

    private static func sessionCookie(_ token: String) -> Cookie {
        Cookie(
            name: sessionCookieName,
            value: token,
            maxAge: Int(NorbyAuth.sessionLifetime),
            path: "/",
            httpOnly: true,
            sameSite: .lax
        )
    }

    private static func expiredSessionCookie() -> Cookie {
        Cookie(
            name: sessionCookieName,
            value: "",
            expires: Date(timeIntervalSince1970: 0),
            maxAge: 0,
            path: "/",
            httpOnly: true,
            sameSite: .lax
        )
    }

    private static func bootstrapChallengeCookie(_ challenge: String) -> Cookie {
        Cookie(
            name: bootstrapChallengeCookieName,
            value: challenge,
            maxAge: Int(NorbyAuth.bootstrapChallengeLifetime),
            path: "/onboarding/register",
            httpOnly: true,
            sameSite: .strict
        )
    }

    private static func expiredBootstrapChallengeCookie() -> Cookie {
        Cookie(
            name: bootstrapChallengeCookieName,
            value: "",
            expires: Date(timeIntervalSince1970: 0),
            maxAge: 0,
            path: "/onboarding/register",
            httpOnly: true,
            sameSite: .strict
        )
    }

    private static func redirect(to location: String, settingCookie cookie: Cookie? = nil) -> Response {
        var response = Response(status: .seeOther, headers: [.location: location])
        if let cookie { response.setCookie(cookie) }
        return response
    }

    private static func decodeForm(from request: Request, context: BasicRequestContext) async throws -> [String:
        [String]]
    {
        let buffer = try await request.body.collect(upTo: context.maxUploadSize)
        let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) ?? Data()
        let body = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
        guard let components = URLComponents(string: "?\(body)") else { return [:] }
        return components.queryItems?.reduce(into: [String: [String]]()) { result, item in
            result[item.name, default: []].append(item.value ?? "")
        } ?? [:]
    }
}

private enum TurgaiFormError: Error {
    case invalidValue(String)
}

private actor TurgaiSetupStore {
    fileprivate struct State: Codable {
        var storage: NorbyStorageConfiguration?
        var telegramChatIDs: [Int64] = []
        var telegramConfigured = false
        var complete = false
    }
    private let stateURL: URL
    private let secretURL: URL
    private let postgresPasswordURL: URL
    private let completionStream: AsyncStream<Void>
    private let completionContinuation: AsyncStream<Void>.Continuation
    private var state: State

    init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        stateURL = directory.appendingPathComponent("setup.json")
        secretURL = directory.appendingPathComponent("telegram-token")
        postgresPasswordURL = directory.appendingPathComponent("postgres-password")
        let completion = AsyncStream<Void>.makeStream()
        completionStream = completion.stream
        completionContinuation = completion.continuation
        state = try (try? Data(contentsOf: stateURL)).map { try JSONDecoder().decode(State.self, from: $0) } ?? State()
        if state.complete {
            completionContinuation.yield(())
            completionContinuation.finish()
        }
    }

    var isComplete: Bool { state.complete }
    var storageConfiguration: NorbyStorageConfiguration? { state.storage }
    var telegramChatIDs: [Int64] { state.telegramChatIDs }

    func waitUntilComplete() async {
        guard !state.complete else { return }
        for await _ in completionStream {
            return
        }
    }

    var isReady: Bool {
        guard state.storage != nil, state.telegramConfigured,
            let token = try? String(contentsOf: secretURL, encoding: .utf8)
        else { return false }
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setStorage(
        _ storage: NorbyStorageConfiguration,
        postgresPassword: String?
    ) throws {
        if case .postgres = storage {
            guard let postgresPassword,
                !postgresPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw NorbyStorageConfigurationError.invalidPostgresPassword
            }
            try Data(postgresPassword.utf8).write(to: postgresPasswordURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: postgresPasswordURL.path
            )
        } else if FileManager.default.fileExists(atPath: postgresPasswordURL.path) {
            try FileManager.default.removeItem(at: postgresPasswordURL)
        }
        state.storage = storage
        try persist()
    }

    func setTelegramToken(_ token: String, chatIDs: [Int64]) throws {
        try Data(token.utf8).write(to: secretURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretURL.path)
        state.telegramChatIDs = chatIDs
        state.telegramConfigured = true
        try persist()
    }

    func complete() throws {
        guard !state.complete else { return }
        state.complete = true
        try persist()
        completionContinuation.yield(())
        completionContinuation.finish()
    }

    private func persist() throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
}

/// The setup phase of Turgai. The shared web app is started for the whole
/// process lifetime; this service only waits for its setup state to complete.
public struct TurgaiOnboardingService: Service, Sendable {
    private let webApp: TurgaiWebApp

    public init(webApp: TurgaiWebApp) {
        self.webApp = webApp
    }

    public func run() async throws {
        await self.webApp.waitUntilComplete()
    }
}

private struct TurgaiPage: HTMLDocument, Sendable {
    let title: String
    let username: String
    let profiles: [NorbyAgentProfile]
    let runtime: [TurgaiAgentRuntimeSnapshot]
    let error: String?

    init(
        title: String,
        username: String,
        profiles: [NorbyAgentProfile],
        runtime: [TurgaiAgentRuntimeSnapshot] = [],
        error: String? = nil
    ) {
        self.title = title
        self.username = username
        self.profiles = profiles
        self.runtime = runtime
        self.error = error
    }

    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("app-page")) {
            div(.class("app-shell")) {
                AppHeader(username: username)
                section(.class("page-intro")) {
                    div {
                        p(.class("eyebrow")) { "Your sky" }
                        h1 { "Bots" }
                        p(.class("lede")) { "Choose a bot to see its conversations and settings." }
                    }
                    a(.href("/agents/new"), .class("button button-accent")) { "+ New bot" }
                }
                if let error { p(.class("error page-error")) { error } }
                if profiles.isEmpty {
                    div(.class("empty-state")) {
                        p(.class("eyebrow")) { "Nothing here yet" }
                        h2 { "Create your first bot." }
                        a(.href("/agents/new"), .class("text-link")) { "+ New bot" }
                    }
                } else {
                    section(.class("bot-grid")) {
                        for profile in profiles {
                            AgentTile(
                                profile: profile,
                                runtime: runtime.filter { $0.profileID == profile.id }
                            )
                        }
                    }
                }
            }
            HTMLRaw(
                """
                <script>
                (() => {
                    const refreshAgents = async () => {
                        try {
                            const response = await fetch("/api/agents", {
                                credentials: "same-origin",
                                headers: { "Accept": "application/json" }
                            });
                            if (!response.ok) return;
                            const snapshot = await response.json();
                            for (const card of document.querySelectorAll("[data-agent-id]")) {
                                const profileID = card.dataset.agentId;
                                const active = snapshot.runtime.find(item => item.profileID === profileID);
                                const status = card.querySelector("[data-runtime-status]");
                                if (status) status.textContent = active ? active.phase : "idle";
                            }
                        } catch (_) {
                            // A status refresh must never disturb the agent.
                        }
                    };
                    refreshAgents();
                    window.setInterval(refreshAgents, 5000);
                })();
                </script>
                """
            )
        }
    }
}

struct AppHeader: HTML, Sendable {
    let username: String

    var body: some HTML {
        header(.class("app-header")) {
            a(.href("/"), .class("wordmark")) {
                img(.src("/skylark.svg"), .alt(""), .class("wordmark-logo"))
                span(.class("wordmark-text")) { "turgai" }
            }
            nav(.class("app-nav")) {
                div(.class("app-nav-links")) {
                    a(.href("/"), .class("nav-link")) { "Bots" }
                    a(.href("/tools"), .class("nav-link")) { "Tools" }
                }
                label(.class("theme-switch")) {
                    input(
                        .type(.checkbox),
                        .class("theme-switch-input"),
                        .init(name: "data-theme-toggle", value: ""),
                        .init(name: "role", value: "switch"),
                        .init(name: "aria-label", value: "Switch to dark theme"),
                        .init(name: "aria-checked", value: "false")
                    )
                    span(
                        .class("theme-switch-track"),
                        .init(name: "aria-hidden", value: "true")
                    ) {
                        span(.class("theme-switch-icon")) { "☀" }
                        span(.class("theme-switch-thumb")) {}
                        span(.class("theme-switch-icon")) { "☾" }
                    }
                }
                details(.class("account-menu")) {
                    summary(
                        .class("account-summary"),
                        .init(name: "aria-label", value: "Account menu")
                    ) {
                        span(.class("account-name")) { username }
                        span(.class("account-chevron")) { "▾" }
                    }
                    div(.class("account-dropdown")) {
                        form(.method(.post), .action("/logout"), .class("account-logout-form")) {
                            button(
                                .type(.submit),
                                .class("account-menu-item account-menu-item-danger")
                            ) {
                                "Sign out"
                            }
                        }
                    }
                }
            }
        }
    }
}

struct TurgaiBreadcrumb: HTML, Sendable {
    let parentTitle: String
    let parentHref: String
    let currentTitle: String

    var body: some HTML {
        nav(
            .class("breadcrumb"),
            .init(name: "aria-label", value: "Breadcrumb")
        ) {
            a(.href(parentHref), .class("breadcrumb-parent")) {
                "← \(parentTitle)"
            }
            span(
                .class("breadcrumb-separator"),
                .init(name: "aria-hidden", value: "true")
            ) {
                "/"
            }
            span(
                .class("breadcrumb-current"),
                .init(name: "aria-current", value: "page")
            ) {
                currentTitle
            }
        }
    }
}

private struct AgentTile: HTML, Sendable {
    let profile: NorbyAgentProfile
    let runtime: [TurgaiAgentRuntimeSnapshot]

    private var initial: String {
        profile.name.first.map { String($0).uppercased() } ?? "?"
    }

    var body: some HTML {
        a(.href("/agents/\(profile.id)"), .class("bot-tile"), .init(name: "data-agent-id", value: profile.id)) {
            div(.class("bot-tile-top")) {
                span(.class("bot-mark")) { initial }
                span(.class("bot-status"), .init(name: "data-runtime-status", value: "")) {
                    profile.enabled ? (runtime.isEmpty ? "idle" : "active") : "paused"
                }
            }
            h2 { profile.name }
            p(.class("bot-model")) { profile.model.identifier }
            div(.class("bot-tile-bottom")) {
                span {
                    profile.telegramChatIDs.isEmpty
                        ? "Telegram · default"
                        : "Telegram · \(profile.telegramChatIDs.count) chat(s)"
                }
                span(.class("tile-arrow")) { "→" }
            }
        }
    }
}

private struct AgentDetailPage: HTMLDocument, Sendable {
    let username: String
    let profile: NorbyAgentProfile
    let modelCatalog: TurgaiModelCatalog
    let runtime: [TurgaiAgentRuntimeSnapshot]
    let isDefaultProfile: Bool
    let error: String?

    init(
        username: String,
        profile: NorbyAgentProfile,
        modelCatalog: TurgaiModelCatalog,
        runtime: [TurgaiAgentRuntimeSnapshot] = [],
        isDefaultProfile: Bool,
        error: String? = nil
    ) {
        self.username = username
        self.profile = profile
        self.modelCatalog = modelCatalog
        self.runtime = runtime
        self.isDefaultProfile = isDefaultProfile
        self.error = error
    }

    var title: String { "Turgai — \(profile.name)" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("app-page")) {
            div(.class("app-shell")) {
                AppHeader(username: username)
                section(.class("page-intro detail-page-intro")) {
                    div {
                        TurgaiBreadcrumb(
                            parentTitle: "Bots",
                            parentHref: "/",
                            currentTitle: "Edit bot"
                        )
                        h1 { profile.name }
                        p(.class("lede")) { profile.model.identifier }
                    }
                    span(.class("detail-status")) {
                        profile.enabled ? (runtime.isEmpty ? "idle" : "active") : "paused"
                    }
                }
                if let error { p(.class("error page-error")) { error } }
                div(.class("detail-layout")) {
                    section(.class("detail-main")) {
                        h2 { "Configuration" }
                        p(.class("section-intro")) { "This bot's voice, model, and Telegram routing." }
                        p(.class("detail-note")) {
                            "Changes take effect the next time this bot is activated. Conversations already running keep their current agent."
                        }
                        AgentConfigurationForm(
                            action: "/agents/update",
                            profile: profile,
                            modelCatalog: modelCatalog,
                            submitLabel: "Save changes"
                        )
                        if !isDefaultProfile {
                            form(.method(.post), .action("/agents/delete"), .class("delete-form")) {
                                input(.type(.hidden), .name("id"), .value(profile.id))
                                button(.type(.submit), .class("text-button text-button-danger")) { "Delete bot" }
                            }
                        }
                    }
                    AgentRuntimeSummary(profile: profile, runtime: runtime)
                }
            }
        }
    }
}

private struct AgentRuntimeSummary: HTML, Sendable {
    let profile: NorbyAgentProfile
    let runtime: [TurgaiAgentRuntimeSnapshot]

    var body: some HTML {
        aside(.class("detail-aside")) {
            h2 { "Live" }
            if let active = runtime.first {
                div(.class("live-state")) {
                    span(.class("live-dot")) {}
                    strong { active.phase }
                }
                div(.class("detail-facts")) {
                    p {
                        span(.class("fact-label")) { "Context" }
                        active.contextID
                    }
                    if let currentTool = active.currentTool {
                        p {
                            span(.class("fact-label")) { "Tool" }
                            currentTool
                        }
                    }
                    if let used = active.contextUsedTokens, let limit = active.contextLimitTokens {
                        p {
                            span(.class("fact-label")) { "Window" }
                            "\(used.formatted()) / \(limit.formatted())"
                        }
                    }
                    p {
                        span(.class("fact-label")) { "Messages" }
                        active.conversationMessageCount.formatted()
                    }
                }
            } else {
                div(.class("live-state live-state-idle")) {
                    span(.class("live-dot")) {}
                    strong { "idle" }
                }
                p(.class("section-intro")) { "No active conversation." }
            }
            div(.class("detail-facts detail-facts-bottom")) {
                p {
                    span(.class("fact-label")) { "Telegram" }
                    profile.telegramChatIDs.isEmpty
                        ? "default route"
                        : "\(profile.telegramChatIDs.count) chat(s)"
                }
                p {
                    span(.class("fact-label")) { "Context limit" }
                    "\(profile.contextWindow.formatted()) tokens"
                }
            }
        }
    }
}

private struct ModelPicker: HTML, Sendable {
    let catalog: TurgaiModelCatalog
    let selectedModel: AgentModel?

    private static let providerFieldID = "turgai-model-provider"
    private static let modelFieldID = "turgai-model-id"
    private static let noticeID = "turgai-model-notice"

    private var selectedProviderIndex: Int {
        guard let selectedProvider else { return 0 }
        return catalog.providers.firstIndex { $0.provider == selectedProvider } ?? 0
    }

    private var selectedProvider: AgentModelProvider? {
        if let provider = selectedModel?.provider { return provider }
        if catalog.providers.contains(where: { $0.provider == .ollama }) { return .ollama }
        return catalog.providers.first?.provider
    }

    private func suggestionListID(for index: Int) -> String {
        "turgai-model-suggestions-\(index)"
    }

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Provider" }
            select(
                .name("provider"),
                .id(Self.providerFieldID),
                .required,
                .init(
                    name: "onchange",
                    value:
                        "document.getElementById('\(Self.modelFieldID)').setAttribute('list', this.options[this.selectedIndex].dataset.modelList); document.getElementById('\(Self.noticeID)').textContent = this.options[this.selectedIndex].dataset.modelNotice"
                )
            ) {
                for (index, provider) in catalog.providers.enumerated() {
                    let notice =
                        catalog.notice(for: provider.provider)
                        ?? "Enter a model ID manually if the provider has no discovery service."
                    if provider.provider == selectedProvider {
                        option(
                            .value(provider.id),
                            .selected,
                            .init(name: "data-model-list", value: suggestionListID(for: index)),
                            .init(name: "data-model-notice", value: notice)
                        ) { provider.name }
                    } else {
                        option(
                            .value(provider.id),
                            .init(name: "data-model-list", value: suggestionListID(for: index)),
                            .init(name: "data-model-notice", value: notice)
                        ) { provider.name }
                    }
                }
            }
            p(.class("hint")) { "Suggestions are scoped to the selected provider." }
        }
        label(.class("form-field")) {
            span(.class("field-label")) { "Model ID" }
            input(
                .type(.text),
                .name("modelID"),
                .id(Self.modelFieldID),
                .value(selectedModel?.id.rawValue ?? ""),
                .init(name: "list", value: suggestionListID(for: selectedProviderIndex)),
                .placeholder("Enter a model ID"),
                .required
            )
            for (index, provider) in catalog.providers.enumerated() {
                datalist(.id(suggestionListID(for: index))) {
                    for choice in catalog.choices(for: provider.provider) {
                        option(
                            .value(choice.model.id.rawValue),
                            .init(
                                name: "label",
                                value: "\(provider.name) · \(choice.displayName)"
                            )
                        )
                    }
                }
            }
            p(.class("hint"), .id(Self.noticeID)) {
                catalog.notice(for: selectedProvider ?? .ollama)
                    ?? "Enter a model ID manually if the provider has no discovery service."
            }
        }
    }
}

private struct AgentConfigurationForm: HTML, Sendable {
    let action: String
    let profile: NorbyAgentProfile?
    let modelCatalog: TurgaiModelCatalog
    let submitLabel: String

    private var selectedModel: AgentModel? { profile?.model }

    private var chatIDs: String {
        profile?.telegramChatIDs.map(String.init).joined(separator: ", ") ?? ""
    }

    var body: some HTML {
        form(.method(.post), .action(action), .class("config-form")) {
            if let profile { input(.type(.hidden), .name("id"), .value(profile.id)) }
            section(.class("config-group")) {
                h3 { "Identity" }
                label(.class("form-field")) {
                    span(.class("field-label")) { "Name" }
                    input(
                        .type(.text), .name("name"), .value(profile?.name ?? ""), .placeholder("A name for this bot"),
                        .required)
                }
            }
            section(.class("config-group")) {
                h3 { "Model" }
                ModelPicker(catalog: modelCatalog, selectedModel: selectedModel)
                label(.class("form-field")) {
                    span(.class("field-label")) { "Ollama server URL" }
                    input(
                        .type(.url), .name("ollamaBaseURL"),
                        .value(profile?.ollamaBaseURL?.absoluteString ?? ""),
                        .placeholder(OllamaConfiguration.defaultBaseURL.absoluteString)
                    )
                    p(.class("hint")) { "Used when this bot uses an Ollama model." }
                }
                label(.class("form-field")) {
                    span(.class("field-label")) { "Context window" }
                    input(
                        .type(.number), .name("contextWindow"),
                        .value(String(profile?.contextWindow ?? NorbyAgentProfileStore.defaultContextWindow)),
                        .required
                    )
                    p(.class("hint")) { "Maximum context passed to the model." }
                }
            }
            section(.class("config-group")) {
                h3 { "Telegram" }
                label(.class("form-field")) {
                    span(.class("field-label")) { "Telegram chats" }
                    input(
                        .type(.text), .name("telegramChatIDs"), .value(chatIDs),
                        .placeholder("Optional chat IDs, separated by commas")
                    )
                    p(.class("hint")) { "Leave empty for the default route." }
                }
            }
            section(.class("config-group")) {
                h3 { "Behavior" }
                label(.class("form-field")) {
                    span(.class("field-label")) { "Persona" }
                    textarea(
                        .name("persona"), .init(name: "rows", value: "6"), .placeholder("How should this bot speak?")
                    ) {
                        profile?.persona ?? ""
                    }
                }
                label(.class("form-field")) {
                    span(.class("field-label")) { "Instructions" }
                    textarea(
                        .name("instructions"), .init(name: "rows", value: "5"),
                        .placeholder("What should this bot know or do?")
                    ) {
                        profile?.instructions ?? ""
                    }
                }
            }
            div(.class("form-actions")) {
                button(.type(.submit), .class("button button-accent")) { submitLabel }
                a(
                    .href(profile == nil ? "/" : "/agents/\(profile!.id)"),
                    .class("button button-secondary")
                ) { "Cancel" }
            }
        }
    }
}

private struct NewAgentPage: HTMLDocument, Sendable {
    let username: String
    let modelCatalog: TurgaiModelCatalog
    let error: String?

    init(username: String, modelCatalog: TurgaiModelCatalog, error: String? = nil) {
        self.username = username
        self.modelCatalog = modelCatalog
        self.error = error
    }

    var title: String { "Turgai — New bot" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("app-page")) {
            div(.class("app-shell")) {
                AppHeader(username: username)
                section(.class("page-intro detail-page-intro")) {
                    div {
                        TurgaiBreadcrumb(
                            parentTitle: "Bots",
                            parentHref: "/",
                            currentTitle: "New bot"
                        )
                        h1 { "Add a bot" }
                        p(.class("lede")) { "Give it a voice, a model, and a route." }
                    }
                }
                if let error { p(.class("error page-error")) { error } }
                section(.class("detail-main new-bot-main")) {
                    AgentConfigurationForm(
                        action: "/agents/create",
                        profile: nil,
                        modelCatalog: modelCatalog,
                        submitLabel: "Create bot"
                    )
                }
            }
        }
    }
}

private struct SetupHeader: HTML, Sendable {
    var body: some HTML {
        header(.class("setup-header")) {
            a(.href("/"), .class("wordmark")) {
                img(.src("/skylark.svg"), .alt(""), .class("wordmark-logo"))
                span(.class("wordmark-text")) { "turgai" }
            }
        }
    }
}

private struct SetupProgress: HTML, Sendable {
    let step: Int

    var body: some HTML {
        div(
            .class("setup-progress"),
            .init(name: "role", value: "progressbar"),
            .init(name: "aria-label", value: "Step \(step) of 6"),
            .init(name: "aria-valuemin", value: "1"),
            .init(name: "aria-valuemax", value: "6"),
            .init(name: "aria-valuenow", value: String(step))
        ) {
            for segment in 1...6 {
                span(.class("setup-progress-line \(segment <= step ? "is-filled" : "")")) {}
            }
        }
    }
}

private struct SetupArrow: HTML, Sendable {
    let href: String
    let label: String
    let isBack: Bool

    var body: some HTML {
        a(.href(href), .class("setup-arrow \(isBack ? "setup-arrow-back" : "setup-arrow-forward")")) {
            if isBack {
                span(.class("arrow-glyph arrow-glyph-back")) { "←" }
                span { label }
            } else {
                span { label }
                span(.class("arrow-glyph arrow-glyph-long")) { "──────→" }
                span(.class("arrow-glyph arrow-glyph-short")) { "──→" }
            }
        }
    }
}

private struct SetupSubmit: HTML, Sendable {
    let formID: String
    let label: String

    var body: some HTML {
        button(.type(.submit), .form(formID), .class("setup-arrow setup-arrow-forward setup-submit")) {
            span { label }
            span(.class("arrow-glyph arrow-glyph-long")) { "──────→" }
            span(.class("arrow-glyph arrow-glyph-short")) { "──→" }
        }
    }
}

private struct SetupFooter: HTML, Sendable {
    let step: Int?
    let backHref: String?
    let forwardHref: String?
    let forwardLabel: String?
    let submitFormID: String?
    let submitLabel: String?

    init(
        step: Int?,
        backHref: String? = nil,
        forwardHref: String? = nil,
        forwardLabel: String? = nil,
        submitFormID: String? = nil,
        submitLabel: String? = nil
    ) {
        self.step = step
        self.backHref = backHref
        self.forwardHref = forwardHref
        self.forwardLabel = forwardLabel
        self.submitFormID = submitFormID
        self.submitLabel = submitLabel
    }

    var body: some HTML {
        nav(.class("setup-footer")) {
            div(.class("setup-footer-actions")) {
                if let backHref {
                    SetupArrow(href: backHref, label: "Back", isBack: true)
                } else {
                    span(.class("setup-footer-spacer")) {}
                }
                if let forwardHref, let forwardLabel {
                    SetupArrow(href: forwardHref, label: forwardLabel, isBack: false)
                } else if let submitFormID, let submitLabel {
                    SetupSubmit(formID: submitFormID, label: submitLabel)
                }
            }
            if let step { SetupProgress(step: step) }
        }
    }
}

private struct LoginPage: HTMLDocument, Sendable {
    let error: String?

    init(error: String? = nil) { self.error = error }

    var title: String { "Turgai — Sign in" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("setup-page")) {
            div(.class("setup-shell")) {
                SetupHeader()
                section(.class("setup-content setup-content-compact")) {
                    div(.class("setup-copy")) {
                        p(.class("eyebrow")) { "Turgai" }
                        h1 { "Welcome back." }
                        p(.class("lede")) { "Sign in to continue shaping your sky." }
                    }
                    div(.class("setup-form-area")) {
                        if let error { p(.class("error")) { error } }
                        form(
                            .method(.post), .action("/login"),
                            .init(name: "id", value: "login-form")
                        ) {
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Username" }
                                input(.type(.text), .name("username"), .autocomplete("username"), .required)
                            }
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Password" }
                                input(.type(.password), .name("password"), .autocomplete("current-password"), .required)
                            }
                        }
                    }
                }
                SetupFooter(step: nil, submitFormID: "login-form", submitLabel: "Sign in")
            }
        }
    }
}

private struct OnboardingPage: HTMLDocument, Sendable {
    var title: String { "Turgai — Welcome" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("setup-page")) {
            div(.class("setup-shell")) {
                SetupHeader()
                section(.class("setup-content")) {
                    div(.class("setup-copy")) {
                        p(.class("eyebrow")) { "Welcome" }
                        h1 { "Welcome to your sky." }
                        p(.class("lede")) {
                            "Let’s prepare Norby in a few quiet steps. Nothing is sent anywhere until you choose a provider."
                        }
                    }
                    div(.class("setup-form-area setup-welcome-area")) {
                        div(.class("setup-note")) {
                            p(.class("field-label")) { "Local setup" }
                            p {
                                "Your browser will claim this local installation before the first administrator is created."
                            }
                            p(.class("hint")) { "Nothing leaves this device during registration." }
                        }
                    }
                }
                SetupFooter(step: 1, forwardHref: "/onboarding/register", forwardLabel: "Begin setup")
            }
        }
    }
}

private struct RegisterPage: HTMLDocument, Sendable {
    let challenge: String
    let error: String?

    init(challenge: String, error: String? = nil) {
        self.challenge = challenge
        self.error = error
    }
    var title: String { "Turgai — Create administrator" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("setup-page")) {
            div(.class("setup-shell")) {
                SetupHeader()
                section(.class("setup-content")) {
                    div(.class("setup-copy")) {
                        p(.class("eyebrow")) { "Register" }
                        h1 { "Make this sky yours." }
                        p(.class("lede")) { "Create the local administrator account for your dashboard." }
                    }
                    div(.class("setup-form-area")) {
                        if let error { p(.class("error")) { error } }
                        form(
                            .method(.post), .action("/onboarding/register"),
                            .init(name: "id", value: "register-form")
                        ) {
                            input(.type(.hidden), .name("challenge"), .value(challenge))
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Username" }
                                input(.type(.text), .name("username"), .autocomplete("username"), .required)
                            }
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Password" }
                                input(.type(.password), .name("password"), .autocomplete("new-password"), .required)
                            }
                        }
                    }
                }
                SetupFooter(
                    step: 2,
                    backHref: "/onboarding",
                    submitFormID: "register-form",
                    submitLabel: "Create administrator"
                )
            }
        }
    }
}

private struct ModelPage: HTMLDocument, Sendable {
    let modelCatalog: TurgaiModelCatalog
    let profile: NorbyAgentProfile?
    let error: String?

    init(
        modelCatalog: TurgaiModelCatalog,
        profile: NorbyAgentProfile? = nil,
        error: String? = nil
    ) {
        self.modelCatalog = modelCatalog
        self.profile = profile
        self.error = error
    }
    var title: String { "Turgai — Model" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("setup-page")) {
            div(.class("setup-shell")) {
                SetupHeader()
                section(.class("setup-content")) {
                    div(.class("setup-copy")) {
                        p(.class("eyebrow")) { "Model" }
                        h1 { "Choose the mind." }
                        p(.class("lede")) {
                            "Choose a provider and model. Suggestions come from the selected provider when available."
                        }
                    }
                    div(.class("setup-form-area")) {
                        if let error { p(.class("error")) { error } }
                        form(
                            .method(.post), .action("/onboarding/model"),
                            .init(name: "id", value: "model-form")
                        ) {
                            ModelPicker(
                                catalog: modelCatalog,
                                selectedModel: Self.selectedModel(from: profile)
                            )
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Ollama server URL" }
                                input(
                                    .type(.url), .name("ollamaBaseURL"),
                                    .value(
                                        profile?.ollamaBaseURL?.absoluteString
                                            ?? OllamaConfiguration.defaultBaseURL.absoluteString
                                    ),
                                    .placeholder(OllamaConfiguration.defaultBaseURL.absoluteString)
                                )
                                p(.class("hint")) { "Used when the selected bot uses an Ollama model." }
                            }
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Default bot name" }
                                input(
                                    .type(.text), .name("agentName"), .value(profile?.name ?? "Conversation"),
                                    .required
                                )
                            }
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Persona" }
                                textarea(.name("persona"), .init(name: "rows", value: "6")) {
                                    profile?.persona ?? ""
                                }
                                p(.class("hint")) {
                                    "Describe how Norby should speak. Leave it empty for the built-in voice."
                                }
                            }
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Context window" }
                                input(
                                    .type(.number), .name("contextWindow"),
                                    .value(
                                        String(
                                            profile?.contextWindow ?? NorbyAgentProfileStore.defaultContextWindow)),
                                    .required
                                )
                            }
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Instructions" }
                                textarea(.name("instructions"), .init(name: "rows", value: "4")) {
                                    profile?.instructions ?? ""
                                }
                            }
                        }
                    }
                }
                SetupFooter(
                    step: 3,
                    backHref: "/onboarding/register",
                    submitFormID: "model-form",
                    submitLabel: "Continue"
                )
            }
        }
    }

    private static func selectedModel(from profile: NorbyAgentProfile?) -> AgentModel? {
        profile?.model
    }
}

private struct StorageFormValues: Sendable {
    let backend: String
    let fileURL: String
    let postgresURL: String
    let postgresUsername: String

    init(storage: NorbyStorageConfiguration?, defaultFileDirectory: URL) {
        let backend: String
        let fileURL: String
        let postgresURL: String
        let postgresUsername: String
        switch storage {
        case .file(let directory):
            backend = "file"
            fileURL = directory.absoluteString
            postgresURL = "postgres://localhost:5432/norby"
            postgresUsername = ""
        case .postgres(let url, let username):
            backend = "postgres"
            postgresURL = url.absoluteString
            postgresUsername = username
            fileURL = defaultFileDirectory.absoluteString
        case nil:
            backend = "file"
            fileURL = defaultFileDirectory.absoluteString
            postgresURL = "postgres://localhost:5432/norby"
            postgresUsername = ""
        }
        self.backend = backend
        self.fileURL = fileURL
        self.postgresURL = postgresURL
        self.postgresUsername = postgresUsername
    }

    init(form: [String: [String]], defaultFileDirectory: URL) {
        self.backend = form["backend"]?.first ?? "file"
        self.fileURL = form["fileURL"]?.first ?? defaultFileDirectory.absoluteString
        self.postgresURL = form["postgresURL"]?.first ?? ""
        self.postgresUsername = form["postgresUsername"]?.first ?? ""
    }
}

private struct StoragePage: HTMLDocument, Sendable {
    let values: StorageFormValues
    let defaultFileDirectory: URL
    let error: String?

    init(
        storage: NorbyStorageConfiguration?,
        defaultFileDirectory: URL,
        error: String? = nil
    ) {
        self.values = StorageFormValues(
            storage: storage,
            defaultFileDirectory: defaultFileDirectory
        )
        self.defaultFileDirectory = defaultFileDirectory
        self.error = error
    }

    init(
        values: StorageFormValues,
        defaultFileDirectory: URL,
        error: String
    ) {
        self.values = values
        self.defaultFileDirectory = defaultFileDirectory
        self.error = error
    }

    var title: String { "Turgai — Storage" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("setup-page")) {
            div(.class("setup-shell")) {
                SetupHeader()
                section(.class("setup-content")) {
                    div(.class("setup-copy")) {
                        p(.class("eyebrow")) { "Storage" }
                        h1 { "Choose where memory lives." }
                        p(.class("lede")) {
                            "Events and snapshots use the same backend. The local file store is the quiet default."
                        }
                    }
                    div(.class("setup-form-area")) {
                        if let error { p(.class("error")) { error } }
                        form(
                            .method(.post), .action("/onboarding/storage"),
                            .init(name: "id", value: "storage-form")
                        ) {
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Backend" }
                                select(
                                    .name("backend"),
                                    .id("turgai-storage-backend"),
                                    .init(
                                        name: "onchange",
                                        value:
                                            "document.querySelectorAll('[data-storage-panel]').forEach((panel) => panel.hidden = panel.dataset.storagePanel !== this.value)"
                                    )
                                ) {
                                    if values.backend == "file" {
                                        option(.value("file"), .selected) { "File store" }
                                    } else {
                                        option(.value("file")) { "File store" }
                                    }
                                    if values.backend == "postgres" {
                                        option(.value("postgres"), .selected) { "PostgreSQL" }
                                    } else {
                                        option(.value("postgres")) { "PostgreSQL" }
                                    }
                                }
                            }
                            div(
                                .class("storage-panel"),
                                .init(name: "data-storage-panel", value: "file"),
                                values.backend == "file" ? .init(name: "data-active", value: "true") : .hidden
                            ) {
                                label(.class("form-field")) {
                                    span(.class("field-label")) { "File store URL" }
                                    input(
                                        .type(.url), .name("fileURL"), .value(values.fileURL),
                                        .placeholder("file:///path/to/turgai")
                                    )
                                    p(.class("hint")) {
                                        "Default: \(defaultFileDirectory.absoluteString)"
                                    }
                                }
                            }
                            div(
                                .class("storage-panel"),
                                .init(name: "data-storage-panel", value: "postgres"),
                                values.backend == "postgres" ? .init(name: "data-active", value: "true") : .hidden
                            ) {
                                label(.class("form-field")) {
                                    span(.class("field-label")) { "PostgreSQL URL" }
                                    input(
                                        .type(.url), .name("postgresURL"), .value(values.postgresURL),
                                        .placeholder("postgres://localhost:5432/norby")
                                    )
                                }
                                label(.class("form-field")) {
                                    span(.class("field-label")) { "Username" }
                                    input(
                                        .type(.text), .name("postgresUsername"),
                                        .value(values.postgresUsername), .autocomplete("username")
                                    )
                                }
                                label(.class("form-field")) {
                                    span(.class("field-label")) { "Password" }
                                    input(
                                        .type(.password), .name("postgresPassword"),
                                        .autocomplete("new-password")
                                    )
                                    p(.class("hint")) {
                                        "Stored separately from the connection settings."
                                    }
                                }
                            }
                        }
                        p(.class("hint storage-restart-note")) {
                            "The selected backend is initialized when setup finishes."
                        }
                    }
                }
                SetupFooter(
                    step: 4,
                    backHref: "/onboarding/model",
                    submitFormID: "storage-form",
                    submitLabel: "Save storage"
                )
            }
        }
    }
}

private struct TelegramPage: HTMLDocument, Sendable {
    let chatIDs: [Int64]
    let error: String?

    init(chatIDs: [Int64] = [], error: String? = nil) {
        self.chatIDs = chatIDs
        self.error = error
    }
    var title: String { "Turgai — Telegram" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("setup-page")) {
            div(.class("setup-shell")) {
                SetupHeader()
                section(.class("setup-content")) {
                    div(.class("setup-copy")) {
                        p(.class("eyebrow")) { "Telegram" }
                        h1 { "Choose a voice." }
                        p(.class("lede")) {
                            "Connect Telegram with a bot token from BotFather. A chat allow-list is optional."
                        }
                    }
                    div(.class("setup-form-area")) {
                        if let error { p(.class("error")) { error } }
                        form(
                            .method(.post), .action("/onboarding/telegram"),
                            .init(name: "id", value: "telegram-form")
                        ) {
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Telegram bot token" }
                                input(.type(.password), .name("token"), .autocomplete("off"), .required)
                            }
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Allowed chat IDs" }
                                input(
                                    .type(.text), .name("chatIDs"),
                                    .value(chatIDs.map(String.init).joined(separator: ",")),
                                    .placeholder("Optional, comma-separated")
                                )
                                p(.class("hint")) {
                                    "Leave empty to accept messages from every chat."
                                }
                            }
                        }
                    }
                }
                SetupFooter(
                    step: 5,
                    backHref: "/onboarding/storage",
                    submitFormID: "telegram-form",
                    submitLabel: "Save Telegram"
                )
            }
        }
    }
}

private struct FinishPage: HTMLDocument, Sendable {
    var title: String { "Turgai — Ready" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("setup-page")) {
            div(.class("setup-shell")) {
                SetupHeader()
                section(.class("setup-content")) {
                    div(.class("setup-copy")) {
                        p(.class("eyebrow")) { "Ready" }
                        h1 { "The skylark is ready." }
                        p(.class("lede")) {
                            "Everything is saved. Finish setup when you are ready."
                        }
                    }
                    div(.class("setup-form-area setup-welcome-area")) {
                        form(
                            .method(.post), .action("/onboarding/finish"),
                            .init(name: "id", value: "finish-form")
                        ) {}
                    }
                }
                SetupFooter(
                    step: 6,
                    backHref: "/onboarding/telegram",
                    submitFormID: "finish-form",
                    submitLabel: "Finish setup"
                )
            }
        }
    }
}

struct TurgaiHead: HTML, Sendable {
    var body: some HTML {
        meta(.charset(.utf8))
        meta(.name(.viewport), .content("width=device-width, initial-scale=1, viewport-fit=cover"))
        link(.href("/turgai.css"), .rel(.stylesheet))
        HTMLRaw(
            """
            <script>
            (() => {
                const root = document.documentElement;
                const themeStorageKey = "turgai-theme";
                const systemTheme = window.matchMedia("(prefers-color-scheme: dark)");

                const readSavedTheme = () => {
                    try {
                        const savedTheme = window.localStorage.getItem(themeStorageKey);
                        return savedTheme === "dark" || savedTheme === "light" ? savedTheme : null;
                    } catch (_) {
                        return null;
                    }
                };

                const syncThemeToggle = () => {
                    const toggle = document.querySelector("input[data-theme-toggle]");
                    if (!toggle) return;
                    const dark = root.dataset.theme === "dark";
                    toggle.checked = dark;
                    toggle.setAttribute(
                        "aria-label",
                        dark ? "Switch to light theme" : "Switch to dark theme"
                    );
                    toggle.setAttribute("aria-checked", String(dark));
                };

                const applyTheme = (theme) => {
                    root.dataset.theme = theme;
                    syncThemeToggle();
                };

                const applySystemTheme = () => {
                    try {
                        window.localStorage.removeItem(themeStorageKey);
                    } catch (_) {
                        // Continue with the system theme when storage is unavailable.
                    }
                    applyTheme(systemTheme.matches ? "dark" : "light");
                };

                applyTheme(readSavedTheme() || (systemTheme.matches ? "dark" : "light"));
                if (systemTheme.addEventListener) {
                    systemTheme.addEventListener("change", applySystemTheme);
                } else {
                    systemTheme.addListener(applySystemTheme);
                }

                const bindThemeToggle = () => {
                    const toggle = document.querySelector("input[data-theme-toggle]");
                    if (!toggle || toggle.dataset.themeBound === "true") return;
                    toggle.dataset.themeBound = "true";
                    syncThemeToggle();
                    toggle.addEventListener("change", () => {
                        const theme = toggle.checked ? "dark" : "light";
                        applyTheme(theme);
                        try {
                            window.localStorage.setItem(themeStorageKey, theme);
                        } catch (_) {
                            // Keep the current theme for this page when storage is unavailable.
                        }
                    });
                };
                if (document.readyState === "loading") {
                    document.addEventListener("DOMContentLoaded", bindThemeToggle);
                } else {
                    bindThemeToggle();
                }

                window.addEventListener("storage", (event) => {
                    if (event.key !== themeStorageKey) return;
                    if (event.newValue === "dark" || event.newValue === "light") {
                        applyTheme(event.newValue);
                    } else {
                        applyTheme(systemTheme.matches ? "dark" : "light");
                    }
                });

                const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
                let leaving = false;

                const shouldSkip = (event) => {
                    if (event.defaultPrevented || event.button !== 0) return true;
                    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return true;
                    return false;
                };

                const leave = (continueNavigation) => {
                    if (reducedMotion.matches || leaving) return false;
                    leaving = true;
                    root.classList.add("turgai-page-leaving");
                    window.setTimeout(continueNavigation, 160);
                    return true;
                };

                document.addEventListener("click", (event) => {
                    if (shouldSkip(event)) return;
                    if (!document.querySelector(".setup-page")) return;
                    if (reducedMotion.matches || leaving) return;
                    const link = event.target.closest("a[href]");
                    if (!link || link.hasAttribute("download")) return;
                    if (link.target && link.target !== "_self") return;

                    const destination = new URL(link.href, window.location.href);
                    if (destination.origin !== window.location.origin) return;
                    if (destination.protocol !== window.location.protocol) return;
                    if (
                        destination.pathname === window.location.pathname &&
                        destination.search === window.location.search &&
                        destination.hash
                    ) return;
                    if (destination.href === window.location.href) return;

                    event.preventDefault();
                    leave(() => { window.location.assign(destination.href); });
                });

                document.addEventListener("submit", (event) => {
                    if (event.defaultPrevented) return;
                    if (!document.querySelector(".setup-page")) return;
                    const form = event.target;
                    if (!(form instanceof HTMLFormElement)) return;
                    if (form.target && form.target !== "_self") return;
                    if (reducedMotion.matches || leaving) return;

                    event.preventDefault();
                    leave(() => { HTMLFormElement.prototype.submit.call(form); });
                });

                window.addEventListener("pageshow", () => {
                    leaving = false;
                    root.classList.remove("turgai-page-leaving");
                });
            })();
            </script>
            """
        )
    }
}
