import ComposableArchitecture
import Foundation
import TurgaiModels

/// A Turgai server's HTTP endpoints: those before signing in at an address, the rest as a session,
/// at its server.
@DependencyClient
package struct TurgaiServerClient: Sendable {
    /// Throws when the server doesn't answer.
    package var status: @Sendable (ServerAddress) async throws -> TurgaiServerStatus
    package var signIn: @Sendable (ServerAddress, _ username: String, _ password: String) async throws -> Session
    /// Creates a chat account and signs in to it.
    /// A new account, its password typed twice, signed in to.
    package var register:
        @Sendable (ServerAddress, _ username: String, _ password: String, _ passwordAgain: String) async throws ->
            Session
    /// Who the account is.
    package var me: @Sendable (Session) async throws -> Me
    /// A new conversation, in the space `spaceID`, with its main bot.
    package var startConversation: @Sendable (Session, _ spaceID: SpaceID) async throws -> Conversation
    /// Who's in the conversation of the space: its bot and its people.
    package var participants: @Sendable (Session, SpaceID, ConversationID) async throws -> [ParticipantSummary]
    /// One of the agent's turns in the conversation of the space, step by step: the tools it called
    /// and what they gave back, read over HTTP as it's asked for.
    package var turn: @Sendable (Session, SpaceID, ConversationID, TurnID) async throws -> TurnRecord
    /// Who's in a space, as the account's person sees them.
    package var people: @Sendable (Session, _ spaceID: SpaceID) async throws -> [SpacePerson]
    /// The conversation of the space called `title` from now on.
    package var titleConversation: @Sendable (Session, SpaceID, ConversationID, _ title: String) async throws -> Void
    /// A new space called `name`, the account's person its admin, and `bot` its first bot.
    package var makeSpace: @Sendable (Session, _ name: String, _ bot: BotConfiguration) async throws -> SpaceSummary
    /// A space called `name` from now on.
    package var renameSpace: @Sendable (Session, _ spaceID: SpaceID, _ name: String) async throws -> SpaceSummary
    /// A new invite to a space, working until it's used.
    package var makeInvite: @Sendable (Session, _ spaceID: SpaceID) async throws -> SpaceInviteOffer
    /// The space `link` invites to, joined by the account's person.
    package var joinSpace: @Sendable (Session, SpaceInviteLink) async throws -> SpaceSummary
    /// What a provider offers, asked with what's chosen so far for a bot's model.
    package var models: @Sendable (Session, ModelsRequest) async throws -> ModelsAnswer
    /// A space's bots, the main first, as the account's person sees them.
    package var bots: @Sendable (Session, SpaceID) async throws -> [SpaceBot]
    /// A bot added to a space.
    package var addBot: @Sendable (Session, SpaceID, BotConfiguration) async throws -> SpaceBot
    /// A space's bot as it's configured from now on.
    package var changeBot: @Sendable (Session, SpaceID, BotID, BotConfiguration) async throws -> SpaceBot
    /// A bot removed from a space.
    package var removeBot: @Sendable (Session, SpaceID, BotID) async throws -> Void
    /// A bot its space's main one from now on.
    package var chooseMainBot: @Sendable (Session, SpaceID, BotID) async throws -> Void
    /// A space's connections, as the account's person, who may configure them, sees them.
    package var connections: @Sendable (Session, SpaceID) async throws -> [SpaceConnection]
    /// A connection added to a space.
    package var addConnection: @Sendable (Session, SpaceID, ConnectionSettings) async throws -> Void
    /// A space's connection as it's set up from now on.
    package var changeConnection: @Sendable (Session, SpaceID, _ id: String, ConnectionSettings) async throws -> Void
    /// A connection removed from a space.
    package var removeConnection: @Sendable (Session, SpaceID, _ id: String) async throws -> Void
}

/// What the server refused, and why, as it said it.
package struct ServerRefusal: Error, Equatable {
    package let error: ChatError
}

package enum AccountError: Error, Equatable {
    /// The server answered with its form again instead of a session.
    case rejected
    case unavailable(String)
}

extension TurgaiServerClient: DependencyKey {
    package static let liveValue: TurgaiServerClient = {
        let statusSession = URLSession(configuration: .ephemeral)
        return TurgaiServerClient(
            status: { server in
                var request = URLRequest(url: server.url.appending(path: "api/v1/status"))
                request.timeoutInterval = 2
                let (data, _) = try await statusSession.data(for: request)
                return try JSONDecoder().decode(TurgaiServerStatus.self, from: data)
            },
            signIn: { server, username, password in
                try await postCredentials(
                    [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)],
                    to: server, at: "login")
            },
            register: { server, username, password, passwordAgain in
                try await postCredentials(
                    [
                        URLQueryItem(name: "username", value: username),
                        URLQueryItem(name: "password", value: password),
                        URLQueryItem(name: "passwordAgain", value: passwordAgain),
                    ], to: server, at: "register")
            },
            me: { try await api("GET", "api/v1/me", as: $0) },
            startConversation: { session, space in
                try await api(
                    "POST", "api/v1/conversations", body: CreateConversationRequest(spaceID: space), as: session)
            },
            participants: { session, space, id in
                try await api(
                    "GET", "api/v1/spaces/\(space.rawValue)/conversations/\(id.rawValue)/participants", as: session)
            },
            turn: { session, space, id, turn in
                try await api(
                    "GET",
                    "api/v1/spaces/\(space.rawValue)/conversations/\(id.rawValue)/turns/\(turn.rawValue.uuidString)",
                    as: session)
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
    var request = account.request(path)
    request.httpMethod = method
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
private func postCredentials(_ fields: [URLQueryItem], to server: ServerAddress, at path: String) async throws
    -> Session
{
    let url = server.url.appending(path: path)
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
        let cookie = session.configuration.httpCookieStorage?.cookies(for: server.url)?
            .first(where: { $0.name == ServerAddress.sessionCookie }),
        let expiresAt = cookie.expiresDate
    else { throw AccountError.rejected }
    return Session(server: server, token: cookie.value, expiresAt: expiresAt)
}

extension DependencyValues {
    package var server: TurgaiServerClient {
        get { self[TurgaiServerClient.self] }
        set { self[TurgaiServerClient.self] = newValue }
    }
}
