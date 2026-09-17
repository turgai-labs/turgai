import Foundation
import Testing

@testable import TurgaiApplication

struct WebSearchBackendTests {
    private let duckDuckGoHTML = """
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage">Example &amp; Page</a>
        <a class="result__snippet">A <b>useful</b> example page</a>
        <a class="result__a" href="https://direct.example/post">Direct post</a>
        """

    private let jsonResults = #"""
        {"results":[
            {"url":"https://a.example","title":"Result A","content":"Snippet A"},
            {"url":"https://b.example","title":"Result B","content":null},
            {"title":"No URL, dropped"}
        ]}
        """#

    @Test func duckDuckGoParsesTitlesSnippetsAndRedirectTargets() throws {
        let results = try WebSearchBackend.duckDuckGo.parseSearchResults(duckDuckGoHTML)
        #expect(results.count == 2)
        #expect(results[0].title == "Example & Page")
        #expect(results[0].url.absoluteString == "https://example.com/page")
        #expect(results[0].snippet == "A useful example page")
        #expect(results[1].url.absoluteString == "https://direct.example/post")
        #expect(results[1].snippet == "")
    }

    @Test func searxngParsesJSONResults() throws {
        let results = try WebSearchBackend.searxng(baseURL: URL(string: "http://127.0.0.1:8080")!)
            .parseSearchResults(jsonResults)
        #expect(results.count == 2)
        #expect(results[0].title == "Result A")
        #expect(results[0].snippet == "Snippet A")
        #expect(results[1].snippet == "")
    }

    @Test func ollamaParsesJSONResults() throws {
        let results = try WebSearchBackend.ollama(baseURL: URL(string: "https://ollama.com")!, apiKey: "k")
            .parseSearchResults(jsonResults)
        #expect(results.count == 2)
        #expect(results[0].url.absoluteString == "https://a.example")
    }

    @Test func searxngBuildsJSONSearchRequest() throws {
        let effect = try WebSearchBackend.searxng(baseURL: URL(string: "http://127.0.0.1:8080")!)
            .searchEffect(for: "berlin weather")
        #expect(effect.host == "127.0.0.1")
        #expect(effect.request.method == "GET")
        #expect(effect.request.url.hasPrefix("http://127.0.0.1:8080/search?"))
        #expect(effect.request.url.contains("format=json"))
        #expect(effect.request.url.contains("q=berlin%20weather"))
        #expect(effect.request.headers["Accept"] == "application/json")
    }

    @Test func searxngKeepsAPathPrefix() throws {
        let effect = try WebSearchBackend.searxng(baseURL: URL(string: "https://search.example.com/internal")!)
            .searchEffect(for: "q")
        #expect(effect.request.url.hasPrefix("https://search.example.com/internal/search?"))
    }

    @Test func ollamaBuildsAuthenticatedPost() throws {
        let effect = try WebSearchBackend.ollama(
            baseURL: URL(string: "https://ollama.com")!, apiKey: "secret"
        ).searchEffect(for: "berlin")
        #expect(effect.host == "ollama.com")
        #expect(effect.request.method == "POST")
        #expect(effect.request.url == "https://ollama.com/api/web_search")
        #expect(effect.request.headers["Authorization"] == "Bearer secret")
        let body = String(decoding: effect.request.body ?? Data(), as: UTF8.self)
        #expect(body.contains("berlin"))
    }

    @Test func jsonBackendsRejectInvalidJSON() {
        #expect(throws: WebSearchTool.Error.invalidResponse) {
            try WebSearchBackend.searxng(baseURL: URL(string: "http://127.0.0.1:8080")!)
                .parseSearchResults("not json")
        }
    }

    @Test func searchResultRenderStaysBounded() {
        let results = (1...8).map {
            WebSearchResult(
                title: "Result \($0)",
                url: URL(string: "https://example.com/\($0)")!,
                snippet: String(repeating: "word ", count: 100)
            )
        }
        let text = WebSearchTool.searchResult(query: "q", results: results)
        #expect(text.hasPrefix("Web results for \"q\":"))
        #expect(!text.contains("6. Result"))
        #expect(text.count <= 1_200)
    }
}
