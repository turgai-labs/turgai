import AnyLanguageModel
import DiscoverableActors
import Hail

import struct Hummingbird.MediaType
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// HTTP requests to the public web. Each request is an ``HttpEffect``, whose network request the
/// authority decides on; what comes back is its status, its headers and its body, whatever its
/// status is.
@Tool(
    "http",
    description: "Send HTTP requests to public http(s) URLs."
)
public struct Http: Sendable {
    public init() {}

    @Command(
        "send",
        description:
            "Send an HTTP request and get what comes back: a page's readable text, a file, or an API's answer."
    )
    public func send(_ request: HttpRequest) throws -> HttpEffect {
        try HttpEffect(request)
    }

    /// What came back: a page as its title and its readable text, other text as it is, both
    /// bounded, and anything else as it is; with its status, when it isn't a success.
    public func render(_ response: HttpResponse) -> ToolOutput {
        let contentType = Self.contentType(of: response)
        guard (200..<300).contains(response.status) else {
            let text = Self.text(of: response, contentType).map {
                "\n\n\(Self.bounded($0, to: Self.maximumPageCharacters))"
            }
            return .text("HTTP status \(response.status) from \(response.url.absoluteString)" + (text ?? ""))
        }
        guard !response.body.isEmpty else {
            return .text("HTTP status \(response.status) from \(response.url.absoluteString), with an empty body")
        }
        guard contentType == "text/html" else {
            let data = ToolData(body: response.body, contentType: contentType, source: response.url)
            guard data.isTextLike else { return .data(data) }
            let text = String(decoding: response.body, as: UTF8.self)
            return .text(
                "\(data.normalizedContentType) from \(response.url.absoluteString)\n\n"
                    + Self.bounded(text, to: Self.maximumPageCharacters))
        }
        let html = String(decoding: response.body, as: UTF8.self)
        let text = SearchHTML.text(html)
        guard !text.isEmpty else { return .text("The page has no readable text: \(response.url.absoluteString)") }
        // Its title is in its head, which is never read as its text.
        let named = SearchHTML.title(html).map { "Page: \($0)\nURL: \(response.url.absoluteString)" }
        return .text(
            (named ?? "Page: \(response.url.absoluteString)") + "\n\n"
                + Self.bounded(text, to: Self.maximumPageCharacters))
    }

    private static let maximumPageCharacters = 4_000

    /// What it is: as its `Content-Type` says, or else as its URL's extension says.
    static func contentType(of response: HttpResponse) -> String? {
        let declared = response.headers.first { $0.name.lowercased() == "content-type" }?
            .value.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmed().lowercased() }
        if let declared, declared != "application/octet-stream" { return declared }
        let pathExtension = response.url.pathExtension
        if !pathExtension.isEmpty, let inferred = MediaType.getMediaType(forExtension: pathExtension.lowercased()) {
            return inferred.description
        }
        return declared
    }

    /// Its body as text, a page's readable text, when it's text.
    private static func text(of response: HttpResponse, _ contentType: String?) -> String? {
        let body = String(decoding: response.body, as: UTF8.self)
        let text: String
        if contentType == "text/html" {
            text = SearchHTML.text(body)
        } else if ToolData(body: response.body, contentType: contentType).isTextLike {
            text = body
        } else {
            return nil
        }
        let trimmed = text.trimmed()
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bounded(_ value: String, to maximumCharacters: Int) -> String {
        let normalized = value.trimmed()
        guard normalized.count > maximumCharacters else { return normalized }
        return String(normalized.prefix(maximumCharacters - 1)) + "…"
    }
}

/// An HTTP request: what it asks, where, with which headers, and what it sends.
@Generable(description: "An HTTP request: what it asks, where, with which headers, and what it sends.")
@Describable
public struct HttpRequest: Sendable {
    /// What it asks.
    @Guide(description: "What it asks.")
    public var method: HttpMethod = .get
    /// The http(s) URL it goes to.
    @Guide(description: "The http(s) URL it goes to.")
    public var url: String
    /// Its headers, besides those the tool sets.
    @Guide(description: "Its headers, besides those the tool sets.")
    public var headers: [HttpHeader]?
    /// What it sends, as text.
    @Guide(description: "What it sends, as text.")
    public var body: String?
}

/// What a request asks: what's there, or to post, put, patch or delete it.
@Generable(description: "What a request asks: what's there, or to post, put, patch or delete it.")
@Describable
public enum HttpMethod: String, Sendable, Codable {
    case get
    case post
    case put
    case patch
    case delete
}

/// A header: its name, and its value.
@Generable(description: "A header: its name, and its value.")
@Describable
public struct HttpHeader: Sendable, Codable, Equatable {
    /// Its name.
    @Guide(description: "Its name.")
    public var name: String
    /// Its value.
    @Guide(description: "Its value.")
    public var value: String
}

/// What came back for a request: its status, its headers and its body, and the URL it was sent to.
@Describable
public struct HttpResponse: Sendable, Codable, Equatable {
    /// Its status code, 200 for a success.
    public let status: Int
    /// Its headers.
    public let headers: [HttpHeader]
    /// What it sent back.
    public let body: Data
    /// The URL the request was sent to.
    public let url: URL
}

/// One HTTP request: its one child is the network request, which the authority decides on. What
/// comes back is given whatever its status.
public struct HttpEffect: CompositeScopedEffect, Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidURL
        case unsupportedURLScheme
        /// A header that carries credentials, which a request never sets itself.
        case headerNotAllowed(String)
    }

    public let name = "http"
    public let url: URL
    public let request: NetworkEffect

    private static let maximumResponseBytes = 16 * 1024 * 1024

    /// The headers that carry credentials.
    private static let credentialHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie"]

    public init(_ request: HttpRequest) throws {
        let url = try Self.validated(request.url)
        let given = request.headers ?? []
        if let credential = given.first(where: { Self.credentialHeaders.contains($0.name.lowercased()) }) {
            throw Error.headerNotAllowed(credential.name)
        }
        let body = request.body.map { Data($0.utf8) }
        var headers = ["User-Agent": "Turgai/1.0 (+https://github.com/akbashev/turgai)", "Accept": "*/*"]
        if let body { headers["Content-Type"] = Self.contentType(of: body) }
        // Its own, in place of the tool's of the same name.
        for header in given {
            headers = headers.filter { $0.key.lowercased() != header.name.lowercased() }
            headers[header.name] = header.value
        }
        self.url = url
        self.request = NetworkEffect(
            host: url.host ?? "",
            operation: "http_\(request.method.rawValue)",
            request: NetworkRequest(
                url: url.absoluteString, method: request.method.rawValue.uppercased(), headers: headers, body: body,
                maximumResponseBytes: Self.maximumResponseBytes))
    }

    public var childEffects: [any ScopedEffect] { [request] }

    public static func run(in token: borrowing EffectToken<HttpEffect>) async throws -> HttpResponse {
        let configuration = token.withConfiguration { $0 }
        let response = try await token.run(configuration.request)
        return HttpResponse(
            status: response.statusCode,
            headers: response.headers.sorted { $0.key < $1.key }.map { HttpHeader(name: $0.key, value: $0.value) },
            body: response.body, url: configuration.url)
    }

    /// A body's content type: JSON when it reads as JSON, plain text otherwise.
    private static func contentType(of body: Data) -> String {
        switch try? JSONDecoder().decode(AnyLanguageModel.JSONValue.self, from: body) {
        case .object?, .array?: "application/json"
        default: "text/plain"
        }
    }

    /// An http(s) URL to the public web: never this machine, nor one with credentials in it.
    private static func validated(_ value: String) throws -> URL {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { throw Error.invalidURL }
        guard scheme == "http" || scheme == "https" else { throw Error.unsupportedURLScheme }
        guard url.user == nil, url.password == nil, let host = url.host, !host.isEmpty else { throw Error.invalidURL }
        guard !["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(host.lowercased()) else {
            throw Error.invalidURL
        }
        return url
    }
}
