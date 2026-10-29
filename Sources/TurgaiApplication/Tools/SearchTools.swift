import AnyLanguageModel
import DiscoverableActors
import Hail
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

private let maximumSearchResponseBytes = 512 * 1024

/// One result a search found: its title, its URL, and a snippet of what's there.
@Describable
public struct WebSearchResult: Sendable, Hashable, Codable {
    /// Its title.
    public let title: String
    /// Where it is.
    public let url: URL
    /// A snippet of what's there.
    public let snippet: String

    public init(title: String, url: URL, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

/// The search backend behind ``Search``. The choice is made at
/// composition time — from Turgai's environment configuration — never by the
/// model: the tool's model-facing schema is identical for every backend.
public enum WebSearchBackend: Sendable, Hashable {
    /// DuckDuckGo's HTML endpoint: keyless and zero-config, but fragile —
    /// it rate-limits and drops programmatic clients.
    case duckDuckGo
    /// A self-hosted SearXNG metasearch instance, queried through its JSON API.
    case searxng(baseURL: URL)
    /// Ollama's hosted web search API.
    case ollama(baseURL: URL, apiKey: String)

    private static let userAgent = "Turgai/1.0 (+https://github.com/akbashev/turgai)"

    func searchEffect(for query: String) throws -> NetworkEffect {
        switch self {
        case .duckDuckGo:
            var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "kl", value: "wt-wt"),
            ]
            guard let url = components.url else {
                throw Search.Error.invalidURL
            }
            return NetworkEffect(
                host: "html.duckduckgo.com",
                operation: "search",
                request: NetworkRequest(
                    url: url.absoluteString,
                    headers: [
                        "User-Agent": Self.userAgent,
                        "Accept": "text/html",
                    ],
                    maximumResponseBytes: maximumSearchResponseBytes
                )
            )
        case .searxng(let baseURL):
            var components = try Self.components(appendingPath: "search", to: baseURL)
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "format", value: "json"),
            ]
            guard let url = components.url else {
                throw Search.Error.invalidURL
            }
            return NetworkEffect(
                host: components.host ?? "searxng",
                operation: "search",
                request: NetworkRequest(
                    url: url.absoluteString,
                    headers: [
                        "User-Agent": Self.userAgent,
                        "Accept": "application/json",
                    ],
                    maximumResponseBytes: maximumSearchResponseBytes
                )
            )
        case .ollama(let baseURL, let apiKey):
            let components = try Self.components(appendingPath: "api/web_search", to: baseURL)
            guard let url = components.url else {
                throw Search.Error.invalidURL
            }
            let body = try JSONEncoder().encode(["query": query])
            return NetworkEffect(
                host: components.host ?? "ollama",
                operation: "search",
                request: NetworkRequest(
                    url: url.absoluteString,
                    method: "POST",
                    headers: [
                        "User-Agent": Self.userAgent,
                        "Authorization": "Bearer \(apiKey)",
                        "Content-Type": "application/json",
                        "Accept": "application/json",
                    ],
                    body: body,
                    maximumResponseBytes: maximumSearchResponseBytes
                )
            )
        }
    }

    func parseSearchResults(_ body: String) throws -> [WebSearchResult] {
        switch self {
        case .duckDuckGo:
            return parseDuckDuckGoResults(body)
        case .searxng, .ollama:
            return try parseJSONResults(body)
        }
    }

    private static func components(
        appendingPath path: String,
        to baseURL: URL
    ) throws -> URLComponents {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw Search.Error.invalidURL
        }
        let basePath = components.path.trimmed(while: { $0 == "/" })
        components.path =
            "/"
            + ([basePath] + path.split(separator: "/").map(String.init))
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        return components
    }

    // MARK: - DuckDuckGo (HTML scraping)

    private func parseDuckDuckGoResults(_ html: String) -> [WebSearchResult] {
        let linkPattern = #"(?is)<a[^>]*class=["'][^"']*result__a[^"']*["'][^>]*href=["']([^"']+)["'][^>]*>(.*?)</a>"#
        let snippetPattern = #"(?is)<a[^>]*class=["'][^"']*result__snippet[^"']*["'][^>]*>(.*?)</a>"#
        let links = SearchHTML.captures(in: html, pattern: linkPattern)
        let snippets = SearchHTML.captures(in: html, pattern: snippetPattern)

        return links.enumerated().compactMap { index, capture in
            // Each capture is [whole match, href, inner text]; the whole
            // match is not part of the result. Snippets pair positionally:
            // DuckDuckGo emits one snippet anchor per result anchor.
            guard capture.count >= 3,
                let url = URL(string: duckDuckGoResultURL(from: capture[1]))
            else {
                return nil
            }
            let title = SearchHTML.text(capture[2])
            let snippet =
                index < snippets.count && snippets[index].count >= 2
                ? SearchHTML.text(snippets[index][1])
                : ""
            return WebSearchResult(title: title, url: url, snippet: snippet)
        }
    }

    private func duckDuckGoResultURL(from href: String) -> String {
        guard let url = URL(string: href), href.hasPrefix("/") else {
            return SearchHTML.decodeEntities(href)
        }
        if let encoded = URLComponents(url: url, resolvingAgainstBaseURL: true)?
            .queryItems?
            .first(where: { $0.name == "uddg" })?
            .value,
            let decoded = encoded.percentDecoded
        {
            return decoded
        }
        return "https://html.duckduckgo.com\(href)"
    }

    // MARK: - JSON backends (SearXNG, Ollama)

    private struct JSONResultEnvelope: Decodable {
        struct Entry: Decodable {
            let title: String?
            let url: String?
            let content: String?
        }

        let results: [Entry]
    }

    private func parseJSONResults(_ body: String) throws -> [WebSearchResult] {
        guard let data = body.data(using: .utf8) else {
            throw Search.Error.invalidUTF8
        }
        let envelope: JSONResultEnvelope
        do {
            envelope = try JSONDecoder().decode(JSONResultEnvelope.self, from: data)
        } catch {
            throw Search.Error.invalidResponse
        }
        return envelope.results.compactMap { entry in
            guard let url = entry.url.flatMap(URL.init(string:)) else { return nil }
            return WebSearchResult(
                title: entry.title ?? "",
                url: url,
                snippet: entry.content ?? ""
            )
        }
    }
}

/// Small HTML reader shared by search-result parsing and page extraction.
/// It keeps semantic article text while discarding common site chrome.
enum SearchHTML {
    private enum Child {
        case text(String)
        case element(Element)
    }

    private final class Element {
        let name: String
        let attributes: [String: String]
        var children: [Child] = []

        init(name: String, attributes: [String: String] = [:]) {
            self.name = name
            self.attributes = attributes
        }
    }

    private struct Candidate {
        let score: Int
        let text: String
    }

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
        "source", "track", "wbr",
    ]

    private static let ignoredElements: Set<String> = [
        "aside", "button", "canvas", "dialog", "footer", "form", "head", "iframe", "menu", "nav",
        "noscript", "script", "select", "style", "svg", "template", "textarea", "video", "audio",
    ]

    private static let blockElements: Set<String> = [
        "address", "article", "blockquote", "br", "dd", "div", "dl", "dt", "figcaption", "h1", "h2",
        "h3", "h4", "h5", "h6", "li", "main", "ol", "p", "pre", "section", "table", "td", "th",
        "tr", "ul",
    ]

    private static let boilerplateClasses: Set<String> = [
        "breadcrumb", "comment", "consent", "cookie", "menu", "navigation", "pagination", "promo",
        "related", "share", "social", "subscribe", "toolbar",
    ]

    /// Each match of `pattern` in `text`: the whole match, then each group that took part in it.
    static func captures(in text: String, pattern: String) -> [[String]] {
        guard let expression = try? Regex(pattern) else {
            return []
        }
        return text.matches(of: expression).map { match in
            match.output.compactMap { $0.substring.map(String.init) }
        }
    }

    static func text(_ html: String) -> String {
        let root = Element(name: "#document")
        var stack = [root]
        var cursor = html.startIndex

        while cursor < html.endIndex {
            guard let open = html[cursor...].firstIndex(of: "<") else {
                stack[stack.count - 1].children.append(.text(String(html[cursor...])))
                break
            }
            if cursor < open {
                stack[stack.count - 1].children.append(.text(String(html[cursor..<open])))
            }

            if html[open...].hasPrefix("<!--"),
                let end = html[open...].firstRange(of: "-->")?.upperBound
            {
                cursor = end
                continue
            }
            guard let tagEnd = tagEnd(in: html, from: open) else {
                stack[stack.count - 1].children.append(.text(String(html[open...])))
                break
            }
            let next = html.index(after: tagEnd)
            let rawTag = String(html[html.index(after: open)..<tagEnd])
            cursor = next

            guard let tag = parseTag(rawTag) else { continue }
            if tag.closing {
                if let index = stack.lastIndex(where: { $0.name == tag.name }), index > 0 {
                    stack.removeSubrange(index..<stack.endIndex)
                }
                continue
            }

            if tag.name == "li" && stack.last?.name == "li"
                || tag.name == "p" && stack.last?.name == "p"
                || tag.name == "option" && stack.last?.name == "option"
            {
                stack.removeLast()
            }
            let element = Element(name: tag.name, attributes: tag.attributes)
            stack[stack.count - 1].children.append(.element(element))
            if !tag.selfClosing && !voidElements.contains(tag.name) {
                stack.append(element)
            }
        }

        var candidates: [Candidate] = []
        let fallback = renderedText(root, candidates: &candidates)
        return candidates.max(by: { $0.score < $1.score })?.text ?? fallback
    }

    private static func tagEnd(in html: String, from open: String.Index) -> String.Index? {
        var quote: Character?
        var cursor = html.index(after: open)
        while cursor < html.endIndex {
            let character = html[cursor]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return cursor
            }
            cursor = html.index(after: cursor)
        }
        return nil
    }

    private static func parseTag(_ source: String) -> (
        name: String, attributes: [String: String], closing: Bool, selfClosing: Bool
    )? {
        var value = source.trimmed()
        guard !value.isEmpty, !value.hasPrefix("!") && !value.hasPrefix("?") else { return nil }
        let closing = value.hasPrefix("/")
        if closing { value.removeFirst() }
        let nameEnd = value.firstIndex(where: { $0.isWhitespace || $0 == "/" }) ?? value.endIndex
        let name = String(value[..<nameEnd]).lowercased()
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == ":" }) else {
            return nil
        }

        let remainder = String(value[nameEnd...])
        let selfClosing = remainder.trimmed().hasSuffix("/")
        var attributes: [String: String] = [:]
        guard !closing else {
            return (name, attributes, closing, selfClosing)
        }
        let attribute = #/(?is)([a-z_:][a-z0-9_:.-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/#
        for match in remainder.matches(of: attribute) {
            let (_, key, doubleQuoted, singleQuoted, bare) = match.output
            attributes[key.lowercased()] = (doubleQuoted ?? singleQuoted ?? bare).map(String.init) ?? ""
        }
        return (name, attributes, closing, selfClosing)
    }

    private static func renderedText(_ element: Element, candidates: inout [Candidate]) -> String {
        guard element.name == "#document" || isVisible(element) else { return "" }
        var pieces: [String] = []
        for child in element.children {
            switch child {
            case .text(let text):
                pieces.append(decodeEntities(text))
            case .element(let nested):
                let value = renderedText(nested, candidates: &candidates)
                guard !value.isEmpty else { continue }
                if blockElements.contains(nested.name) {
                    pieces.append("\n\(value)\n")
                } else {
                    pieces.append(value)
                }
            }
        }
        let value = normalizedText(pieces.joined())
        if !value.isEmpty, let priority = contentPriority(of: element) {
            let paragraphCount = value.split(separator: "\n").count
            candidates.append(
                Candidate(
                    score: priority * 1_000_000 + min(value.count, 100_000) + min(paragraphCount, 100) * 500,
                    text: value
                )
            )
        }
        return value
    }

    private static func isVisible(_ element: Element) -> Bool {
        guard !ignoredElements.contains(element.name), element.attributes["hidden"] == nil,
            element.attributes["aria-hidden"]?.lowercased() != "true"
        else { return false }
        let style = (element.attributes["style"] ?? "").lowercased()
            .filter { !$0.isWhitespace }
        guard !style.contains("display:none"), !style.contains("visibility:hidden") else { return false }

        let classes = [element.attributes["class"] ?? "", element.attributes["id"] ?? ""]
            .joined(separator: " ")
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        return !classes.contains(where: { boilerplateClasses.contains($0) || $0.hasPrefix("advert") })
    }

    private static func contentPriority(of element: Element) -> Int? {
        let itemProperties = (element.attributes["itemprop"] ?? "").lowercased()
            .split(whereSeparator: { $0.isWhitespace })
        if itemProperties.contains("articlebody") { return 7 }

        let identifiers = "\(element.attributes["class"] ?? "") \(element.attributes["id"] ?? "")"
            .lowercased()
            .replacing("_", with: "-")
        if [
            "article-body", "article-content", "post-content", "story-body", "story-content", "entry-content",
            "content-body",
        ]
        .contains(where: { identifiers.contains($0) }) {
            return 6
        }
        if element.name == "article" { return 5 }
        if element.name == "main" || element.attributes["role"]?.lowercased() == "main" { return 4 }
        return nil
    }

    private static func normalizedText(_ value: String) -> String {
        value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func decodeEntities(_ value: String) -> String {
        let decoded =
            value
            .replacing("&quot;", with: "\"")
            .replacing("&#39;", with: "'")
            .replacing("&#x27;", with: "'")
            .replacing("&lt;", with: "<")
            .replacing("&gt;", with: ">")
            .replacing("&nbsp;", with: " ")
            .replacing("&rsquo;", with: "’")
            .replacing("&lsquo;", with: "‘")
            .replacing("&rdquo;", with: "”")
            .replacing("&ldquo;", with: "“")
            .replacing("&mdash;", with: "—")
            .replacing("&ndash;", with: "–")
            .replacing("&hellip;", with: "…")
            .replacing("&amp;", with: "&")

        // A numeric entity is the character it names; one naming none stays as it's written.
        return decoded.replacing(#/&#(?:x([0-9a-fA-F]+)|([0-9]+));/#) { match in
            let (entity, hex, decimal) = match.output
            let value = hex.flatMap { UInt32($0, radix: 16) } ?? decimal.flatMap { UInt32($0) }
            return value.flatMap(Unicode.Scalar.init).map { String($0) } ?? String(entity)
        }
    }
}

/// Searching: the public web, for now. Each search is a ``SearchWebEffect``, whose network request
/// the authority decides on, with the results it found, bounded and in plain text.
@Tool(
    "search",
    description: "Search the public web."
)
public struct Search: Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidURL
        case invalidResponse
        case httpStatus(Int)
        case invalidUTF8
    }

    private static let maximumSearchResults = 5
    private static let maximumSnippetCharacters = 320
    private static let maximumSearchOutputCharacters = 1_200

    private let backend: WebSearchBackend

    public init(backend: WebSearchBackend = .duckDuckGo) {
        self.backend = backend
    }

    @Command(
        "web",
        description: "Search the public web."
    )
    public func web(_ search: WebSearch) throws -> SearchWebEffect {
        try SearchWebEffect(query: search.query, backend: backend)
    }

    /// The results, each with its title, its URL and its snippet.
    public func render(_ found: WebSearchFound) -> ToolOutput {
        .text(Self.searchResult(query: found.query, results: found.results))
    }

    static func searchResult(query: String, results: [WebSearchResult]) -> String {
        guard !results.isEmpty else {
            return "No web results found for: \(query)"
        }

        let output =
            ([
                "Web results for \"\(query)\":",
                "Choose a result and get its page with http_send if the snippets are insufficient.",
            ]
            + results.prefix(Self.maximumSearchResults).enumerated().map { index, result in
                "\(index + 1). \(bounded(result.title, to: 160))\nURL: \(bounded(result.url.absoluteString, to: 512))\n\(bounded(result.snippet, to: Self.maximumSnippetCharacters))"
            }).joined(separator: "\n\n")
        return bounded(output, to: Self.maximumSearchOutputCharacters)
    }

    private static func bounded(_ value: String, to maximumCharacters: Int) -> String {
        let normalized = value.trimmed()
        guard normalized.count > maximumCharacters else { return normalized }
        guard maximumCharacters > 1 else { return String(normalized.prefix(maximumCharacters)) }
        return String(normalized.prefix(maximumCharacters - 1)) + "…"
    }
}

/// A search of the public web: what it's for.
@Generable(description: "A search of the public web: what it's for.")
@Describable
public struct WebSearch: Sendable {
    /// What to search for.
    @Guide(description: "What to search for.")
    public var query: String
}

/// One web search: its one child is the backend's network request, which the authority decides
/// on. What came back is read as the backend writes its results.
public struct SearchWebEffect: CompositeScopedEffect, Sendable {
    public let name = "search_web"
    public let query: String
    public let backend: WebSearchBackend
    public let request: NetworkEffect

    public init(query written: String, backend: WebSearchBackend) throws {
        let query = written.trimmed()
        guard !query.isEmpty else { throw ToolError.invalidArgument("query", value: written) }
        guard query.count <= 512 else { throw ToolError.invalidArgument("query", value: "query is too long") }
        self.query = query
        self.backend = backend
        self.request = try backend.searchEffect(for: query)
    }

    public var childEffects: [any ScopedEffect] { [request] }

    public static func run(in token: borrowing EffectToken<SearchWebEffect>) async throws -> WebSearchFound {
        let configuration = token.withConfiguration { $0 }
        let response = try await token.withChild(configuration.request) { networkToken in
            try await NetworkEffect.run(in: networkToken)
        }
        guard (200..<300).contains(response.statusCode) else { throw Search.Error.httpStatus(response.statusCode) }
        let text = String(decoding: response.body, as: UTF8.self)
        guard !text.isEmpty else { throw Search.Error.invalidUTF8 }
        return WebSearchFound(query: configuration.query, results: try configuration.backend.parseSearchResults(text))
    }
}

/// What a web search found, for what.
@Describable
public struct WebSearchFound: Sendable, Codable {
    /// What it searched for.
    public let query: String
    /// What it found, best first.
    public let results: [WebSearchResult]
}
