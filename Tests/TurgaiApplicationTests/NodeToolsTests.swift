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
            objects: [:], lasting: [])
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

    /// Code says something in the chat its call happens in, and nowhere when it happens in none.
    @Test func codeSaysInTheChatItsCallHappensIn() async throws {
        let speaker = """
            actor Speaker {
                func remind() async throws {
                    _ = try await Tools.Chat.say(ChatSaying(text: "Call mum"))
                }
            }
            """
        #expect(await ScriptInstance.problems(in: try Script(code: speaker, type: "Speaker", uses: uses)).isEmpty)

        let said = Said()
        let chat = ConversationID(channel: ChannelID("test"), externalAddress: ExternalConversationAddress("c"))
        let ann = CallScope(UserID("ann"), in: GroupID(chat), as: .member, allowed: [])
        func say(_ text: String, in place: ConversationID?) async throws -> ChatSaid {
            try await withActorSystemDependency(said.dependency) {
                try await CallChain.$current.withValue(.start(ann, in: place)) {
                    try await withEffect(try Chat().say(ChatSaying(text: text)), authority: TurgaiAuthority()) {
                        try await ChatSayEffect.run(in: $0)
                    }
                }
            }
        }

        #expect(try await say("Call mum", in: chat).text == "Call mum")
        #expect(await said.messages == [Said.Message(chat: chat, text: "Call mum")])
        await #expect(throws: ChatSayEffect.Error.inNoChat) { try await say("Call mum", in: nil) }
        #expect(throws: ChatSayEffect.Error.nothingToSay) { try Chat().say(ChatSaying(text: "  ")) }
        #expect(await said.messages.count == 1)
    }

    /// A request reaching outside runs as its call's scope allows, and is refused otherwise, saying
    /// exactly what it was, for whoever opened the scope to ask its group.
    @Test func anExactRequestRunsAsItsScopeAllows() throws {
        let effect = try Http().send(
            HttpRequest(method: .get, url: "https://example.com/forecast", headers: nil, body: nil))
        let forecast = ExactRequest.http(method: "GET", url: "https://example.com/forecast", body: Data())
        let family = GroupID(rawValue: "family")
        func decision(as scope: CallScope) -> EffectDecision {
            CallChain.$current.withValue(.start(scope, in: nil)) { TurgaiAuthority().decision(on: effect) }
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


/// What was said in chats, standing in for the node's conversations.
private actor Said {
    struct Message: Equatable {
        let chat: ConversationID
        let text: String
    }

    private(set) var messages: [Message] = []

    func add(_ message: Message) { messages.append(message) }

    /// The node, as far as saying goes: each chat's words are kept here; nothing else is reached.
    nonisolated var dependency: ActorSystemDependency<ChatSayEffect> {
        struct Unreached: Error {}
        return ActorSystemDependency(
            workflows: WorkflowActions(
                startTimer: { _, _, _ in throw Unreached() }, cancelTimer: { _ in throw Unreached() },
                listTimers: { throw Unreached() }, schedule: { _, _, _, _, _ in throw Unreached() },
                cancelSchedule: { _ in throw Unreached() }, triggerSchedule: { _ in throw Unreached() },
                listSchedules: { throw Unreached() }),
            virtualActors: VirtualActorActions(
                resolveUser: { _ in throw Unreached() },
                notify: { chat, text in await self.add(Message(chat: chat, text: text)) }))
    }
}
