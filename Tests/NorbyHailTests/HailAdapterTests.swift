import AnyLanguageModel
import Hail
import NorbyDomain
import Testing

@testable import NorbyApplication
@testable import NorbyHail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

private actor HailModelEventCollector {
    private(set) var events: [HailModelEvent] = []

    func append(_ event: HailModelEvent) {
        events.append(event)
    }
}

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
        #expect(HailResponse(content: "   ") == nil)
        #expect(
            HailAgentAdapter.userFacingMessage(for: HailAdapterError.emptyResponse)
                == "I couldn’t produce a reply to that message. Please try again."
        )
    }

    @Test
    func mapsTypedPartialAndCompletionUpdates() {
        let partial = "hel"
        let timestamp = Date(timeIntervalSince1970: 1)
        let partialUpdate = AgentRunEvent<String>.modelOutputPartialUpdated(
            content: partial,
            at: timestamp
        )
        let completedUpdate = AgentRunEvent<String>.responseRecorded(
            content: "hello",
            at: timestamp
        )

        let partialEvents = HailStructuredUpdateMapper.map(partialUpdate)
        let completedEvents = HailStructuredUpdateMapper.map(completedUpdate)

        guard case .partial(let partialValue)? = partialEvents.first else {
            Issue.record("Expected a typed partial event")
            return
        }
        guard case .completed(let completedValue)? = completedEvents.first else {
            Issue.record("Expected a typed completed event")
            return
        }
        #expect(partialValue == partial)
        #expect(completedValue == "hello")
    }

    @Test
    func mapsHailProgressWithoutLeakingHailValues() throws {
        let activity = AgentActivity.turn(
            .progress(.narration(GeneratedContent("partial"))),
            at: Date(timeIntervalSince1970: 1)
        )

        let events = HailActivityMapper.map(activity)
        try #require(events.count == 1)
        guard case .text(let fragment) = events[0] else {
            Issue.record("Expected a text event, got \(events)")
            return
        }
        #expect(fragment == "partial")
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
        let configuration = HailRuntimeConfiguration(contextWindow: 131_072)
        let plugin = try configuration.makeAgentRuntimePlugin(
            workspaceRoot: "/tmp/norby-test-workspace"
        )

        guard let compactor = await plugin.contextCompactor as? SlidingWindowCompactor else {
            Issue.record("Expected the runtime to install a sliding-window context compactor")
            return
        }

        _ = compactor
    }

    @Test
    func runtimeDefaultsToFrequentSnapshotsAndSnapshotsAfterCompaction() {
        #expect(
            HailRuntimeConfiguration().snapshotPolicy
                == .periodicOrWhenCompacted(every: 50, retention: .keepLast(2))
        )
    }

    @Test
    func weatherCommandsCarryGeocodingAndHorizon() throws {
        let effect = try WeatherTools().hourly(
            .init(place: "London", region: nil, country: nil)
        )

        #expect(effect.geocoding.query == "London")
        #expect(effect.geocoding.network.host == "geocoding-api.open-meteo.com")
        #expect(effect.geocoding.network.operation == "geocode")
        #expect(effect.horizon == .hourly)
    }

    @Test
    func weatherCommandCarriesAdministrativeRegion() throws {
        let effect = try WeatherTools().hourly(
            .init(place: "Haar", region: "Landkreis München", country: "Germany")
        )

        #expect(effect.geocoding.query == "Haar")
        #expect(effect.geocoding.region == "Landkreis München")
        #expect(effect.geocoding.country == "Germany")
    }

    @Test
    func weatherRejectsInvalidCommandArguments() {
        #expect(throws: ToolError.invalidArgument("days", value: "0")) {
            try WeatherTools().daily(.init(place: "London", region: nil, country: nil, days: 0))
        }
    }

    @Test
    func weatherCommandInputsRoundTripThroughGeneratedContent() throws {
        let hourlyJSON = WeatherTools.HourlyInput(
            place: "London", region: nil, country: nil
        ).generatedContent.jsonString
        #expect(hourlyJSON.contains("\"place\":\"London\""))
        let decodedHourly = try WeatherTools.HourlyInput(
            GeneratedContent(json: #"{"place":"London","country":null}"#)
        )
        #expect(decodedHourly.place == "London")
        #expect(decodedHourly.country == nil)

        let dailyJSON = WeatherTools.DailyInput(
            place: "London", region: nil, country: nil, days: 7
        ).generatedContent.jsonString
        #expect(dailyJSON.contains("\"days\":7"))
        let decodedDaily = try WeatherTools.DailyInput(
            GeneratedContent(json: #"{"place":"London","days":7}"#)
        )
        #expect(decodedDaily.place == "London")
        #expect(decodedDaily.days == 7)
    }

    @Test
    func peerBoundaryCanBeTestedWithoutACluster() async throws {
        let conversationID = ConversationID(
            channel: ChannelID("test"),
            externalAddress: ExternalConversationAddress("chat")
        )
        let collector = HailModelEventCollector()
        let peer = HailConversationPeer(run: { request, onActivity in
            try await onActivity(.text("partial"))
            guard let response = HailResponse(content: request.message.text) else {
                throw HailAdapterError.emptyResponse
            }
            return response
        })
        let request = ConversationTurnRequest(
            conversationID: conversationID,
            turnID: TurnID(rawValue: UUID()),
            message: InboundMessage(
                id: MessageID(rawValue: UUID()),
                conversationID: conversationID,
                participantID: ParticipantID("user"),
                text: "hello",
                receivedAt: Date(timeIntervalSince1970: 1)
            )
        )

        let response = try await peer.run(to: request) { event in
            await collector.append(event)
        }
        #expect(response.content == "hello")
        let events = await collector.events
        try #require(events.count == 1)
        guard case .text(let fragment) = events[0] else {
            Issue.record("Expected a text event, got \(events)")
            return
        }
        #expect(fragment == "partial")
    }

    @Test
    func webSearchUsesTheNetworkEffectAndValidatesTargets() throws {
        let tool = WebSearchTool()

        let searchEffect = try tool.effect(
            for: WebSearchTool.Input(action: .search, query: "weather in Munich", url: nil)
        )
        #expect(searchEffect.host == "html.duckduckgo.com")
        #expect(searchEffect.operation == "search")

        let openEffect = try tool.effect(
            for: WebSearchTool.Input(action: .open, query: nil, url: "https://example.com")
        )
        #expect(openEffect.host == "example.com")
        #expect(openEffect.operation == "open")

        #expect(throws: WebSearchTool.Error.unsupportedURLScheme) {
            try tool.effect(
                for: WebSearchTool.Input(action: .open, query: nil, url: "file:///tmp/secrets")
            )
        }
    }

    @Test
    func webSearchLiveOutputIsCapped() {
        let overflowing = String(repeating: "word ", count: 1_000)
        #expect(overflowing.count > 3_000)

        let searchOutput = WebSearchTool.searchResult(
            query: "terms",
            html: """
                <a class="result__a" href="https://example.com/article">Title</a>
                <a class="result__snippet">\(overflowing)</a>
                """
        )
        #expect(searchOutput.count <= 3_000)

        let pageOutput = WebSearchTool.openResult(
            for: URL(string: "https://example.com/article")!,
            page: "<p>\(overflowing)</p>"
        )
        #expect(pageOutput.count <= 3_000 + "Page: https://example.com/article\n\n".count)
    }

    @Test
    func fetchURLUsesSpecificMetadataOverGenericTransportType() {
        let imageURL = URL(string: "https://api.telegram.org/file/bot-redacted/photos/file_0.jpg")!

        #expect(
            FetchURLTool.resolvedContentType(
                response: "application/octet-stream",
                hint: "image/jpeg",
                url: imageURL
            ) == "image/jpeg"
        )
        #expect(
            FetchURLTool.resolvedContentType(
                response: "application/octet-stream",
                hint: nil,
                url: imageURL
            ) == "image/jpeg"
        )
        #expect(
            FetchURLTool.resolvedContentType(
                response: "text/plain",
                hint: "image/jpeg",
                url: imageURL
            ) == "text/plain"
        )
    }

    @Test
    func fetchAttachmentRoutesOpaqueIDThroughOwningChannel() async throws {
        let resolver = AttachmentResolver()
        await resolver.register(channel: AttachmentChannel("telegram")) {
            externalID,
            expectedContentType in
            #expect(externalID == "telegram-file-id")
            #expect(expectedContentType == "image/jpeg")
            return ToolData(
                body: Data([1, 2, 3]),
                contentType: expectedContentType
            )
        }
        let tool = FetchAttachmentTool(resolver: resolver)

        let output = try await tool.runOutput(
            input: .init(
                attachmentID: "telegram:telegram-file-id",
                mimeType: "image/jpeg"
            ),
            authority: FullAuthority()
        )

        guard case .data(let data) = output else {
            Issue.record("Expected binary tool data")
            return
        }
        #expect(data.body == Data([1, 2, 3]))
        #expect(data.contentType == "image/jpeg")
        #expect(data.source == nil)
    }
}
