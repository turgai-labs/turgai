import AnyLanguageModel
import Hail
import Testing
import TurgaiDomain
import TurgaiTelegram

@testable import TurgaiApplication
@testable import TurgaiHail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct HailAdapterTests {
    @Test
    func modelTransportFailureHasHumanFacingMessage() {
        let message = HailAgentAdapter.userFacingMessage(
            for: AgentRuntimeError.modelMisbehavior(
                "internal detail"
            )
        )

        #expect(
            message == "I couldn’t complete that request. Please try again."
        )
    }

    @Test
    func modelUnavailableHasHumanFacingMessage() {
        let message = HailAgentAdapter.userFacingMessage(
            for: AgentRuntimeError.modelUnavailable
        )

        #expect(
            message == "I’m having trouble reaching my main systems right now. Please try again in a moment."
        )
    }

    @Test
    func emptyResponsesCannotCrossTheHailBoundary() {
        #expect(throws: HailAdapterError.emptyResponse) { try HailResponse(AgentReply(text: "   ")) }
        #expect(
            HailAgentAdapter.userFacingMessage(for: HailAdapterError.emptyResponse)
                == "I couldn’t produce a reply to that message. Please try again."
        )
    }

    @Test
    func mapsTheReplySoFarWithoutLeakingHailValues() throws {
        let update = AgentRunEvent<AgentReply>.modelOutputPartialUpdated(
            content: try AgentReply.PartiallyGenerated(try GeneratedContent(json: #"{"text":"hel"}"#)),
            at: Date(timeIntervalSince1970: 1)
        )

        let events = HailRunMapper.map(update)
        try #require(events.count == 1)
        guard case .reply(let text) = events[0] else {
            Issue.record("Expected the reply so far, got \(events)")
            return
        }
        #expect(text == "hel")
    }

    @Test
    func stableAgentIdentityUsesConversationAddress() {
        let conversationID = ConversationID(
            channel: ChannelID("telegram"),
            externalAddress: ExternalConversationAddress("chat-42")
        )

        let agentID = HailAgentAdapter.agentID(for: conversationID)

        #expect(agentID.role.rawValue == "conversation")
        #expect(agentID.contextID.rawValue == "telegram:chat-42")
        #expect(agentID.rawValue == "conversation-telegram:chat-42")
    }

    @Test
    func runtimeInstallsContextCompactor() async throws {
        let configuration = HailRuntimeConfiguration(
            contextWindow: 131_072
        )
        let plugin = try configuration.makeAgentRuntimePlugin(
            workspaceRoot: "/tmp/turgai-test-workspace",
            spawnConfigProvider: { AgentSpawnConfig(agentID: $0) },
            modelSelectionProvider: { _ in
                ModelConfiguration(model: try AgentModel("ollama/test"))
            },
            authority: { _ in TurgaiAuthority() }
        )

        guard let compactor = await plugin.contextCompactor as? SlidingWindowCompactor else {
            Issue.record("Expected the runtime to install a sliding-window context compactor")
            return
        }

        _ = compactor
    }

    @Test
    func weatherCarriesGeocodingAndHorizon() throws {
        let effect = try Weather.effect("London", nil, nil, .hourly)

        #expect(effect.geocoding.query == "London")
        #expect(effect.geocoding.network.host == "geocoding-api.open-meteo.com")
        #expect(effect.geocoding.network.operation == "geocode")
        #expect(effect.horizon == .hourly)
    }

    @Test
    func weatherCarriesAdministrativeRegion() throws {
        let effect = try Weather.effect("Haar", "Landkreis München", "Germany", .hourly)

        #expect(effect.geocoding.query == "Haar")
        #expect(effect.geocoding.region == "Landkreis München")
        #expect(effect.geocoding.country == "Germany")
    }

    @Test
    func peerBoundaryCanBeTestedWithoutACluster() async throws {
        let conversationID = ConversationID(
            channel: ChannelID("test"),
            externalAddress: ExternalConversationAddress("chat")
        )
        let peer = HailConversationPeer(
            run: { request, events in
                await events(.reply("partial"))
                return try HailResponse(AgentReply(text: request.message.text))
            }
        )
        let request = ConversationTurnRequest(
            conversationID: conversationID,
            turnID: TurnID(rawValue: UUID()),
            message: InboundMessage(
                id: MessageID(rawValue: UUID()),
                conversationID: conversationID,
                participantID: ParticipantID("user"),
                text: "hello",
                receivedAt: Date(timeIntervalSince1970: 1)
            ),
            agentRole: "test"
        )

        let received = Received()
        let response = try await peer.run(to: request) { event in await received.append(event) }
        #expect(response.content == "hello")
        let events = await received.events
        try #require(events.count == 1)
        guard case .reply(let text) = events[0] else {
            Issue.record("Expected the reply so far, got \(events)")
            return
        }
        #expect(text == "partial")
    }

    @Test
    func searchAndHttpUseTheNetworkEffectAndValidateTargets() throws {
        let searchEffect = try Search().web(WebSearch(query: "weather in Munich"))
        #expect(searchEffect.request.host == "html.duckduckgo.com")
        #expect(searchEffect.request.operation == "search")

        let sendEffect = try Http().send(HttpRequest(method: .get, url: "https://example.com", headers: nil, body: nil))
        #expect(sendEffect.request.host == "example.com")
        #expect(sendEffect.request.operation == "http_get")
        #expect(sendEffect.request.request.method == "GET")

        #expect(throws: HttpEffect.Error.unsupportedURLScheme) {
            try Http().send(HttpRequest(method: .get, url: "file:///tmp/secrets", headers: nil, body: nil))
        }
        // Credentials are never a request's own.
        #expect(throws: HttpEffect.Error.headerNotAllowed("Authorization")) {
            try Http().send(
                HttpRequest(
                    method: .get, url: "https://example.com",
                    headers: [HttpHeader(name: "Authorization", value: "Bearer x")], body: nil))
        }
    }

    @Test
    func aPageIsGivenAsItsBoundedReadableText() {
        let overflowing = String(repeating: "word ", count: 1_000)
        let page = HttpResponse(
            status: 200, headers: [HttpHeader(name: "Content-Type", value: "text/html; charset=utf-8")],
            body: Data("<p>\(overflowing)</p>".utf8), url: URL(string: "https://example.com/article")!)
        guard case .text(let text) = Http().render(page) else {
            Issue.record("a page wasn't given as text")
            return
        }
        #expect(text.hasPrefix("Page: https://example.com/article\n\n"))
        #expect(text.count <= 4_000 + "Page: https://example.com/article\n\n".count)
    }

    @Test
    func whatAnHttpResponseIsComesFromItsHeaderThenItsURL() {
        let imageURL = URL(string: "https://api.telegram.org/file/bot-redacted/photos/file_0.jpg")!
        func response(_ contentType: String) -> HttpResponse {
            HttpResponse(
                status: 200, headers: [HttpHeader(name: "content-type", value: contentType)], body: Data([1]),
                url: imageURL)
        }
        #expect(Http.contentType(of: response("application/octet-stream")) == "image/jpeg")
        #expect(Http.contentType(of: response("text/plain")) == "text/plain")
    }

    @Test
    func anAttachmentIsGotThroughTheBotTheChatIsWith() async throws {
        let chat = ChannelID(provider: "telegram", instanceID: "bot")
        let files = TelegramFiles()
        await files.register(chat) { fileID in
            #expect(fileID == "telegram-file-id")
            return TelegramFileData(body: Data([1, 2, 3]), contentType: "image/jpeg")
        }
        let tool = Telegram.Fetch_attachmentTool(owner: Telegram(chat: chat, files: files))

        let output = try await tool.runOutput(
            input: TelegramAttachment(attachmentID: "telegram-file-id"), authority: FullAuthority())

        guard case .data(let data) = output.result else {
            Issue.record("Expected binary tool data")
            return
        }
        #expect(data.body == Data([1, 2, 3]))
        #expect(data.contentType == "image/jpeg")
        #expect(data.source == nil)
    }
}

/// What a turn brought back, in the order it came.
private actor Received {
    private(set) var events: [HailModelEvent] = []

    func append(_ event: HailModelEvent) {
        events.append(event)
    }
}
