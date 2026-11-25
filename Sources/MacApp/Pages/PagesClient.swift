import ComposableArchitecture
import Foundation
import Mosaic
import TurgaiModels

/// A space's pages, as the server gives them on behalf of whoever's signed in.
@DependencyClient
struct PagesClient: Sendable {
    /// The space's pages as they are now: none when no one is signed in.
    var list: @Sendable (SpaceID) async -> [PageListing] = { _ in [] }
    /// What one of them shows now.
    var shown: @Sendable (SpaceID, MadeObjectID) async throws -> PageShown
    /// A press of the button at a path, on the layout shown as a version: whether it was taken.
    var press: @Sendable (SpaceID, MadeObjectID, PiecePath, Int) async throws -> Bool
}

/// A page that couldn't be had: no one signed in, or no page like it they may read.
struct PageMissing: Error {}

extension PagesClient: DependencyKey {
    static let testValue = PagesClient()

    static let liveValue = PagesClient(
        list: { space in
            guard let data = try? await request("api/v1/spaces/\(space.rawValue)/pages").data,
                let pages = try? JSONDecoder().decode([PageListing].self, from: data)
            else { return [] }
            return pages
        },
        shown: { space, page in
            let (data, status) = try await request("api/v1/spaces/\(space.rawValue)/pages/\(page.rawValue)")
            guard status == 200 else { throw PageMissing() }
            return try JSONDecoder().decode(PageShown.self, from: data)
        },
        press: { space, page, path, version in
            var components = URLComponents()
            components.queryItems = [
                URLQueryItem(name: "path", value: path.description), URLQueryItem(name: "page", value: "\(version)"),
            ]
            let (_, status) = try await request(
                "api/v1/spaces/\(space.rawValue)/pages/\(page.rawValue)/press", query: components.queryItems,
                method: "POST")
            return status == 204
        })

    /// The server's answer at `path`, asked as whoever's signed in: its body and status.
    private static func request(_ path: String, query: [URLQueryItem]? = nil, method: String = "GET") async throws
        -> (data: Data, status: Int)
    {
        guard let session = SessionStore.liveValue.load() else { throw PageMissing() }
        var url = LocalServer.baseURL.appending(path: path)
        if let query { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("\(LocalServer.sessionCookieName)=\(session.token)", forHTTPHeaderField: "Cookie")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

extension DependencyValues {
    var pages: PagesClient {
        get { self[PagesClient.self] }
        set { self[PagesClient.self] = newValue }
    }
}
