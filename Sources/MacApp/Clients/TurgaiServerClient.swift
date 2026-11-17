import ComposableArchitecture
import Foundation
import TurgaiModels

/// The local Turgai server's HTTP endpoints.
@DependencyClient
struct TurgaiServerClient: Sendable {
    /// Throws when the server doesn't answer.
    var status: @Sendable () async throws -> TurgaiServerStatus
    var signIn: @Sendable (_ username: String, _ password: String) async throws -> Session
    /// Creates a chat account and signs in to it.
    /// A new account, its password typed twice, signed in to.
    var register: @Sendable (_ username: String, _ password: String, _ passwordAgain: String) async throws -> Session
    /// Who the account is.
    var me: @Sendable (Session) async throws -> Me
    /// The spaces the account is in.
    var spaces: @Sendable (Session) async throws -> [SpaceSummary]
    /// The account's conversations, the one something was last said in first.
    var conversations: @Sendable (Session) async throws -> [Conversation]
    /// A new conversation, in the space `spaceID`, with its main bot.
    var startConversation: @Sendable (Session, _ spaceID: SpaceID) async throws -> Conversation
    /// Who's in the conversation of the space: its bot and its people.
    var participants: @Sendable (Session, SpaceID, ConversationID) async throws -> [ParticipantSummary]
    /// Who's in a space, as the account's person sees them.
    var people: @Sendable (Session, _ spaceID: SpaceID) async throws -> [SpacePerson]
    /// The conversation of the space called `title` from now on.
    var titleConversation: @Sendable (Session, SpaceID, ConversationID, _ title: String) async throws -> Void
    /// A new space called `name`, the account's person its admin, and `bot` its first bot.
    var makeSpace: @Sendable (Session, _ name: String, _ bot: BotConfiguration) async throws -> SpaceSummary
    /// A space called `name` from now on.
    var renameSpace: @Sendable (Session, _ spaceID: SpaceID, _ name: String) async throws -> SpaceSummary
    /// A new invite to a space, working until it's used.
    var makeInvite: @Sendable (Session, _ spaceID: SpaceID) async throws -> SpaceInviteOffer
    /// The space `link` invites to, joined by the account's person.
    var joinSpace: @Sendable (Session, SpaceInviteLink) async throws -> SpaceSummary
    /// What a provider offers, asked with what's chosen so far for a bot's model.
    var models: @Sendable (Session, ModelsRequest) async throws -> ModelsAnswer
    /// A space's bots, the main first, as the account's person sees them.
    var bots: @Sendable (Session, SpaceID) async throws -> [SpaceBot]
    /// A bot added to a space.
    var addBot: @Sendable (Session, SpaceID, BotConfiguration) async throws -> SpaceBot
    /// A space's bot as it's configured from now on.
    var changeBot: @Sendable (Session, SpaceID, BotID, BotConfiguration) async throws -> SpaceBot
    /// A bot removed from a space.
    var removeBot: @Sendable (Session, SpaceID, BotID) async throws -> Void
    /// A bot its space's main one from now on.
    var chooseMainBot: @Sendable (Session, SpaceID, BotID) async throws -> Void
    /// A space's connections, as the account's person, who may configure them, sees them.
    var connections: @Sendable (Session, SpaceID) async throws -> [SpaceConnection]
    /// A connection added to a space.
    var addConnection: @Sendable (Session, SpaceID, ConnectionSettings) async throws -> Void
    /// A space's connection as it's set up from now on.
    var changeConnection: @Sendable (Session, SpaceID, _ id: String, ConnectionSettings) async throws -> Void
    /// A connection removed from a space.
    var removeConnection: @Sendable (Session, SpaceID, _ id: String) async throws -> Void
}

/// What the server refused, and why, as it said it.
struct ServerRefusal: Error, Equatable {
    let error: ChatError
}

enum AccountError: Error, Equatable {
    /// The server answered with its form again instead of a session.
    case rejected
    case unavailable(String)
}

/// Where the local server is.
enum LocalServer {
    static let baseURL = URL(string: "http://127.0.0.1:3333")!
    /// The web app's session cookie.
    static let sessionCookieName = "turgai_auth"
}

extension TurgaiServerClient: DependencyKey {
    static let liveValue: TurgaiServerClient = {
        let baseURL = LocalServer.baseURL
        let statusSession = URLSession(configuration: .ephemeral)
        return TurgaiServerClient(
            status: {
                var request = URLRequest(url: baseURL.appending(path: "api/v1/status"))
                request.timeoutInterval = 2
                let (data, _) = try await statusSession.data(for: request)
                return try JSONDecoder().decode(TurgaiServerStatus.self, from: data)
            },
            signIn: { username, password in
                try await postCredentials(
                    [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)],
                    to: baseURL.appending(path: "login"))
            },
            register: { username, password, passwordAgain in
                try await postCredentials(
                    [
                        URLQueryItem(name: "username", value: username),
                        URLQueryItem(name: "password", value: password),
                        URLQueryItem(name: "passwordAgain", value: passwordAgain),
                    ], to: baseURL.appending(path: "register"))
            },
            me: { try await api("GET", "api/v1/me", as: $0) },
            spaces: { try await api("GET", "api/v1/spaces", as: $0) },
            conversations: { try await api("GET", "api/v1/conversations", as: $0) },
            startConversation: { session, space in
                try await api(
                    "POST", "api/v1/conversations", body: CreateConversationRequest(spaceID: space), as: session)
            },
            participants: { session, space, id in
                try await api(
                    "GET", "api/v1/spaces/\(space.rawValue)/conversations/\(id.rawValue)/participants", as: session)
            },
            people: { session, space in try await api("GET", "api/v1/spaces/\(space.rawValue)/people", as: session) },
            titleConversation: { session, space, id, title in
                _ = try await request(
                    "PATCH", "api/v1/spaces/\(space.rawValue)/conversations/\(id.rawValue)",
                    body: TitleConversationRequest(title: title), as: session)
            },
            makeSpace: { session, name, bot in
                try await api("POST", "api/v1/spaces", body: MakeSpaceRequest(name: name, bot: bot), as: session)
            },
            renameSpace: { session, space, name in
                try await api(
                    "PATCH", "api/v1/spaces/\(space.rawValue)", body: RenameSpaceRequest(name: name), as: session)
            },
            makeInvite: { session, space in
                try await api(
                    "POST", "api/v1/spaces/\(space.rawValue)/invites", body: MakeInviteRequest(validForDays: nil),
                    as: session)
            },
            joinSpace: { session, link in
                try await api(
                    "POST", "api/v1/spaces/\(link.spaceID.rawValue)/join", body: JoinSpaceRequest(token: link.token),
                    as: session)
            },
            models: { session, asked in try await api("POST", "api/v1/models", body: asked, as: session) },
            bots: { session, space in try await api("GET", "api/v1/spaces/\(space.rawValue)/bots", as: session) },
            addBot: { session, space, bot in
                try await api("POST", "api/v1/spaces/\(space.rawValue)/bots", body: bot, as: session)
            },
            changeBot: { session, space, id, bot in
                try await api(
                    "PATCH", "api/v1/spaces/\(space.rawValue)/bots/\(id.rawValue)", body: bot, as: session)
            },
            removeBot: { session, space, id in
                _ = try await request("DELETE", "api/v1/spaces/\(space.rawValue)/bots/\(id.rawValue)", as: session)
            },
            chooseMainBot: { session, space, id in
                _ = try await request(
                    "PUT", "api/v1/spaces/\(space.rawValue)/bots/\(id.rawValue)/main", as: session)
            },
            connections: { session, space in
                try await api("GET", "api/v1/spaces/\(space.rawValue)/connections", as: session)
            },
            addConnection: { session, space, settings in
                _ = try await request(
                    "POST", "api/v1/spaces/\(space.rawValue)/connections", body: settings, as: session)
            },
            changeConnection: { session, space, id, settings in
                _ = try await request(
                    "PATCH", "api/v1/spaces/\(space.rawValue)/connections/\(id)", body: settings, as: session)
            },
            removeConnection: { session, space, id in
                _ = try await request("DELETE", "api/v1/spaces/\(space.rawValue)/connections/\(id)", as: session)
            }
        )
    }()
}

/// The API's answer to `method` on `path`, asked as `account`: refused unless it succeeded.
private func api<Answer: Decodable>(
    _ method: String, _ path: String, body: (some Encodable)? = Optional<String>.none, as account: Session
) async throws -> Answer {
    try JSONDecoder().decode(Answer.self, from: try await request(method, path, body: body, as: account))
}

/// What the API answers to `method` on `path`, asked as `account`: refused unless it succeeded.
private func request(
    _ method: String, _ path: String, body: (some Encodable)? = Optional<String>.none, as account: Session
) async throws -> Data {
    var request = URLRequest(url: LocalServer.baseURL.appending(path: path))
    request.httpMethod = method
    request.setValue("\(LocalServer.sessionCookieName)=\(account.token)", forHTTPHeaderField: "Cookie")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        // A refusal the API explains says why.
        if let refused = try? JSONDecoder().decode(ChatError.self, from: data) { throw ServerRefusal(error: refused) }
        throw URLError(.badServerResponse)
    }
    return data
}

/// Posts the web app's credentials form and returns the session its redirect sets.
private func postCredentials(_ fields: [URLQueryItem], to url: URL) async throws -> Session {
    // A fresh cookie jar per attempt, so only this attempt's cookie is read.
    let session = URLSession(configuration: .ephemeral)
    var form = URLComponents()
    form.queryItems = fields
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    // The server reads "+" as a space, so a literal plus must be escaped.
    request.httpBody = Data((form.percentEncodedQuery ?? "").replacing("+", with: "%2B").utf8)

    let response: URLResponse
    do {
        (_, response) = try await session.data(for: request)
    } catch {
        throw AccountError.unavailable(error.localizedDescription)
    }
    if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
        throw AccountError.unavailable("status \(http.statusCode)")
    }
    // Success redirects with the session cookie; a refusal shows the form again.
    guard
        let cookie = session.configuration.httpCookieStorage?.cookies(for: LocalServer.baseURL)?
            .first(where: { $0.name == LocalServer.sessionCookieName }),
        let expiresAt = cookie.expiresDate
    else { throw AccountError.rejected }
    return Session(token: cookie.value, expiresAt: expiresAt)
}

extension DependencyValues {
    var server: TurgaiServerClient {
        get { self[TurgaiServerClient.self] }
        set { self[TurgaiServerClient.self] = newValue }
    }
}
