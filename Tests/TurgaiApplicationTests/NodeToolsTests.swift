import DiscoverableActors
import Foundation
import Hail
import Testing
import TurgaiCalls
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
        // The tools are namespaces, never values code sends or takes.
        #expect(uses.interface.valueTypes.isDisjoint(with: ["Tools", "Tools.Http", "Tools.Search", "Tools.Chat"]))
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
        let ann = CallScope.member(UserID.ann, in: SpaceID())
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

    /// Code asks the model of the chat its call happens in, and gets its answer back: nothing is said
    /// in the chat. In no chat there's no model to ask.
    @Test func codeAsksTheModelOfTheChatItsCallHappensIn() async throws {
        let checker = """
            actor Checker {
                func isSpam(_ message: String) async throws -> Bool {
                    let answer = try await Tools.Chat.ask(ChatAsking(text: "Is this spam? \\(message)"))
                    return answer.text.lowercased().hasPrefix("yes")
                }
            }
            """
        #expect(await ScriptInstance.problems(in: try Script(code: checker, type: "Checker", uses: uses)).isEmpty)

        let said = Said()
        let chat = ConversationID(channel: ChannelID("test"), externalAddress: ExternalConversationAddress("c"))
        let ann = CallScope.member(UserID.ann, in: SpaceID())
        func ask(_ text: String, in place: ConversationID?) async throws -> ChatAnswer {
            try await withActorSystemDependency(said.dependency) {
                try await CallChain.$current.withValue(.start(ann, in: place)) {
                    try await withEffect(try Chat().ask(ChatAsking(text: text)), authority: TurgaiAuthority()) {
                        try await ChatAskEffect.run(in: $0)
                    }
                }
            }
        }

        #expect(try await ask("Is this spam?", in: chat).text == "yes")
        #expect(await said.asked == [Said.Message(chat: chat, text: "Is this spam?")])
        #expect(await said.messages.isEmpty)
        await #expect(throws: ChatAskEffect.Error.inNoChat) { try await ask("Is this spam?", in: nil) }
        #expect(throws: ChatAskEffect.Error.nothingToAsk) { try Chat().ask(ChatAsking(text: "  ")) }
        #expect(await said.asked.count == 1)
    }

    /// A request reaching outside runs as its call's scope allows, and is refused otherwise, saying
    /// exactly what it was, for whoever opened the scope to ask its space.
    @Test func anExactRequestRunsAsItsScopeAllows() async throws {
        let effect = try Http().send(
            HttpRequest(method: .get, url: "https://example.com/forecast", headers: nil, body: nil))
        let forecast = ExactRequest.http(method: "GET", url: "https://example.com/forecast", body: Data())
        let family = SpaceID()
        func decision(as scope: CallScope) async -> EffectDecision {
            await CallChain.$current.withValue(.start(scope, in: nil)) { await TurgaiAuthority().decision(on: effect) }
        }

        // Bob, with nothing shared: refused, as exactly that request.
        guard case .denied(let refusal) = await decision(as: CallScope.member(UserID.bob, in: family))
        else {
            Issue.record("a member's request ran without being shared")
            return
        }
        #expect(ExactRequest(refusal: refusal) == forecast)
        // Shared with Bob, or an admin's: it runs.
        #expect(await decision(as: CallScope.member(UserID.bob, in: family, allowed: [forecast])) == .granted)
        #expect(await decision(as: CallScope.admin(UserID.ann, in: family)) == .granted)
        // A call on behalf of no one: refused.
        guard case .denied = await TurgaiAuthority().decision(on: effect) else {
            Issue.record("a call on behalf of no one ran")
            return
        }
    }
}

/// What was said in chats, and asked of their models, standing in for the node's conversations.
private actor Said {
    struct Message: Equatable {
        let chat: ConversationID
        let text: String
    }

    private(set) var messages: [Message] = []
    private(set) var asked: [Message] = []

    func add(_ message: Message) { messages.append(message) }

    /// Each chat's model answers yes.
    func answer(_ question: Message) -> String {
        asked.append(question)
        return "yes"
    }

    /// The node, as far as saying and asking go: each chat's words and questions are kept here;
    /// nothing else is reached.
    nonisolated var dependency: ActorSystemDependency<ChatSayEffect> {
        struct Unreached: Error {}
        return ActorSystemDependency(
            virtualActors: VirtualActorActions(
                resolveUser: { _ in throw Unreached() },
                notify: { _, chat, text in await self.add(Message(chat: chat, text: text)) },
                ask: { _, chat, question in await self.answer(Message(chat: chat, text: question)) }))
    }
}
