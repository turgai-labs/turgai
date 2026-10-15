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
            register: { try await postCredentials($0, $1, to: baseURL.appending(path: "register")) }
        )
    }()
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
