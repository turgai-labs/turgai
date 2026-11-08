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
    var register: @Sendable (_ username: String, _ password: String) async throws -> Session
    /// The spaces the account is in.
    var spaces: @Sendable (Session) async throws -> [SpaceSummary]
    /// The account's conversations, the one something was last said in first.
    var conversations: @Sendable (Session) async throws -> [Conversation]
    /// A new conversation, in the space `spaceID`, or Turgai's own, with the default bot.
    var startConversation: @Sendable (Session, _ spaceID: String?) async throws -> Conversation
    /// Who's in a conversation: its agent and its people.
    var participants: @Sendable (Session, ConversationID) async throws -> [ParticipantSummary]
    /// Someone added to a conversation by the account's person.
    var addParticipant: @Sendable (Session, ConversationID, ParticipantRef) async throws -> Void
    /// Who's in a space, as the account's person sees them.
    var people: @Sendable (Session, _ spaceID: String) async throws -> [SpacePerson]
    /// A conversation called `title` from now on.
    var titleConversation: @Sendable (Session, ConversationID, _ title: String) async throws -> Void
    /// A new space called `name`, the account's person its admin.
    var makeSpace: @Sendable (Session, _ name: String) async throws -> SpaceSummary
    /// A space called `name` from now on.
    var renameSpace: @Sendable (Session, _ spaceID: String, _ name: String) async throws -> SpaceSummary
    /// The space `link` invites to, joined by the account's person.
    var joinSpace: @Sendable (Session, SpaceInviteLink) async throws -> SpaceSummary
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

/// Where the Website object serves its page, on this machine.
enum LocalWebsite {
    static let port = 3334
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
            signIn: { try await postCredentials($0, $1, to: baseURL.appending(path: "login")) },
            register: { try await postCredentials($0, $1, to: baseURL.appending(path: "register")) },
            spaces: { try await api("GET", "api/v1/spaces", as: $0) },
            conversations: { try await api("GET", "api/v1/conversations", as: $0) },
            startConversation: { session, space in
                try await api("POST", "api/v1/conversations", body: CreateConversationRequest(spaceID: space), as: session)
            },
            participants: { session, id in
                try await api("GET", "api/v1/conversations/\(id.rawValue)/participants", as: session)
            },
            addParticipant: { session, id, participant in
                _ = try await request(
                    "POST", "api/v1/conversations/\(id.rawValue)/participants", body: participant, as: session)
            },
            people: { session, space in try await api("GET", "api/v1/spaces/\(space)/people", as: session) },
            titleConversation: { session, id, title in
                _ = try await request(
                    "PATCH", "api/v1/conversations/\(id.rawValue)", body: TitleConversationRequest(title: title),
                    as: session)
            },
            makeSpace: { session, name in
                try await api("POST", "api/v1/spaces", body: MakeSpaceRequest(name: name), as: session)
            },
            renameSpace: { session, space, name in
                try await api("PATCH", "api/v1/spaces/\(space)", body: RenameSpaceRequest(name: name), as: session)
            },
            joinSpace: { session, link in
                try await api(
                    "POST", "api/v1/spaces/\(link.spaceID)/join", body: JoinSpaceRequest(token: link.token),
                    as: session)
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
        throw URLError(.badServerResponse)
    }
    return data
}

/// Posts the web app's credentials form and returns the session its redirect sets.
private func postCredentials(_ username: String, _ password: String, to url: URL) async throws -> Session {
    // A fresh cookie jar per attempt, so only this attempt's cookie is read.
    let session = URLSession(configuration: .ephemeral)
    var form = URLComponents()
    form.queryItems = [
        URLQueryItem(name: "username", value: username),
        URLQueryItem(name: "password", value: password),
    ]
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
