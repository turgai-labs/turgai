import DiscoverableActors
import Foundation
import Hail
import Testing
import TurgaiDomain
import TurgaiObjects

@testable import TurgaiApplication

/// The tools every node has, as object code meets them: Swift written from the tools' own types.
struct NodeToolsTests {
    private var uses: Uses {
        Uses(
            interface: Uses.interface(of: [], tools: NodeTools(authority: { _ in TurgaiAuthority() }).api.tools),
            objects: [:])
    }

    /// Code sends a request and searches as the tools' Swift says, and can't call what isn't there.
    @Test func codeCallsEachToolAsItsSwiftSays() async throws {
        let reader = """
            actor Reader {
                func status(of page: String) async throws -> Int {
                    let response = try await Tools.Http.send(HttpRequest(url: page))
                    return String(data: response.body, encoding: .utf8) == nil ? 0 : response.status
                }

                func first(_ query: String) async throws -> String {
                    let found = try await Tools.Search.web(WebSearch(query: query))
                    return found.results.first?.url.absoluteString ?? "nothing"
                }
            }
            """
        #expect(await ScriptInstance.problems(in: try Script(code: reader, type: "Reader", uses: uses)).isEmpty)
        let getting = reader.replacingOccurrences(
            of: "Tools.Http.send(HttpRequest(url: page))", with: "Tools.Http.get(url: page)")
        #expect(!(await ScriptInstance.problems(in: try Script(code: getting, type: "Reader", uses: uses))).isEmpty)
    }

    /// A request reaching outside runs as its call's scope allows, and is refused otherwise, saying
    /// exactly what it was, for whoever opened the scope to ask its group.
    @Test func anExactRequestRunsAsItsScopeAllows() throws {
        let effect = try Http().send(
            HttpRequest(method: .get, url: "https://example.com/forecast", headers: nil, body: nil))
        let forecast = ExactRequest.http(method: "GET", url: "https://example.com/forecast", body: Data())
        let family = GroupID(rawValue: "family")
        func decision(as scope: CallScope) -> EffectDecision {
            CallChain.$current.withValue(.start(scope)) { TurgaiAuthority().decision(on: effect) }
        }

        // Bob, with nothing shared: refused, as exactly that request.
        guard case .denied(let refusal) = decision(as: CallScope(UserID("bob"), in: family, as: .member, allowed: []))
        else {
            Issue.record("a member's request ran without being shared")
            return
        }
        #expect(ExactRequest(refusal: refusal) == forecast)
        // Shared with Bob, or an admin's: it runs.
        #expect(decision(as: CallScope(UserID("bob"), in: family, as: .member, allowed: [forecast])) == .granted)
        #expect(decision(as: CallScope(UserID("ann"), in: family, as: .admin, allowed: [])) == .granted)
        // A call on behalf of no one: refused.
        guard case .denied = TurgaiAuthority().decision(on: effect) else {
            Issue.record("a call on behalf of no one ran")
            return
        }
    }
}
