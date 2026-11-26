import Foundation
import Mosaic
import Testing

@testable import TurgaiModels

struct LiveTests {
    @Test
    func messageRequestRoundTrip() throws {
        let messageID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let request = ChatMessageRequest(
            id: MessageID(rawValue: messageID),
            text: "Hello"
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ChatMessageRequest.self, from: data)

        #expect(decoded == request)
    }

    @Test
    func eventEncodesConversationAndMessage() throws {
        let conversationID = ConversationID(rawValue: "bot-default-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        let event = LiveEvent(
            payload: .messageAccepted(
                conversationID: conversationID,
                turnID: nil,
                message: Message(
                    id: MessageID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
                    role: .user,
                    text: "Hello",
                    at: Date(timeIntervalSince1970: 1_000)
                )
            )
        )

        let data = try JSONEncoder().encode(event)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["type"] as? String == "message.accepted")
        #expect(json["conversationID"] as? String == conversationID.rawValue)
        let message = try #require(json["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        #expect(message["text"] as? String == "Hello")
        #expect(try JSONDecoder().decode(LiveEvent.self, from: data) == event)
    }

    /// A reply being typed goes as what's written so far, apart from a message said.
    @Test
    func replySoFarGoesApartFromAMessage() throws {
        let event = LiveEvent(
            payload: .turnPartial(
                conversationID: ConversationID(rawValue: "bot-default"),
                turnID: TurnID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
                reply: ReplySoFar(
                    id: MessageID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!), text: "Here")
            )
        )

        let data = try JSONEncoder().encode(event)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["type"] as? String == "turn.partial")
        #expect((json["reply"] as? [String: Any])?["text"] as? String == "Here")
        #expect(try JSONDecoder().decode(LiveEvent.self, from: data) == event)
    }

    @Test
    func eventEncodesTurnPhase() throws {
        let event = LiveEvent(
            payload: .turnPhase(
                conversationID: ConversationID(rawValue: "bot-default"),
                turnID: TurnID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
                phase: .thinking
            )
        )

        let data = try JSONEncoder().encode(event)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["type"] as? String == "turn.phase")
        #expect(json["phase"] as? String == "thinking")
    }

    /// A push names what it asks, and its ref; its reply carries the ref back, with how it went.
    @Test
    func pushesAndRepliesRoundTrip() throws {
        let ref = PushRef(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        let dinner = ConversationID(rawValue: "dinner")
        let family = SpaceID(rawValue: "family")
        for ask in [
            LiveAsk.join(.memory), .leave(.memory), .join(.tasks(space: family)), .leave(.tasks(space: family)),
            .memory, .forgetMemory, .setRemembering(.off),
            .archiveSpace(family), .unarchiveSpace(family), .leaveConversation(dinner, of: family),
            .deleteConversation(dinner, of: family),
            .changeSchedule(in: TaskListing.Chat(rawValue: "turgai:dinner"), of: family, named: "news", .pause),
            .cancelReminder(in: TaskListing.Chat(rawValue: "turgai:dinner"), of: family, named: "tea"),
        ] {
            let push = LiveCommand.push(ref: ref, ask: ask)
            #expect(try JSONDecoder().decode(LiveCommand.self, from: JSONEncoder().encode(push)) == push)
        }
        let json = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(LiveCommand.push(ref: ref, ask: .setRemembering(.off)))) as? [String: Any])
        #expect(json["type"] as? String == "push")
        #expect(json["ask"] as? String == "memory.remembering")
        #expect(json["remembering"] as? String == "off")

        let memory = MemorySummary(nodes: [.init(name: "home", said: "Haar", children: [])], remembering: .on)
        // A join answers with what its topic is now.
        let remembered = LiveEvent(payload: .memory(memory))
        for reply in [
            LiveReply.ok, .memory(memory), .joined(remembered), .failed(ChatError(code: "push_failed", message: "No")),
        ] {
            let event = LiveEvent(payload: .reply(ref: ref, reply: reply))
            #expect(try JSONDecoder().decode(LiveEvent.self, from: JSONEncoder().encode(event)) == event)
        }
        #expect(try JSONDecoder().decode(LiveEvent.self, from: JSONEncoder().encode(remembered)) == remembered)
        #expect(remembered.type.rawValue == "memory")
        // A space's tasks come as they are, then each change.
        let news = TaskListing(
            id: TaskListing.ID(rawValue: "news"), title: "news", does: "asks for the news",
            when: .repeating("daily at 08:00 (Europe/Berlin)"), paused: false,
            kind: .schedule(in: TaskListing.Chat(rawValue: "turgai:dinner"), named: "news"))
        let alarm = TaskListing(
            id: TaskListing.ID(rawValue: "alarm"), title: "ticker · alarm", does: nil,
            when: .once(Date(timeIntervalSince1970: 60)),
            paused: false, kind: .object)
        for (payload, type) in [
            (LiveEvent.Payload.tasks(space: family, tasks: [news, alarm]), "tasks"),
            (.taskKept(space: family, task: news), "task.kept"),
            (.taskEnded(space: family, id: alarm.id), "task.ended"),
        ] {
            let event = LiveEvent(payload: payload)
            #expect(try JSONDecoder().decode(LiveEvent.self, from: JSONEncoder().encode(event)) == event)
            #expect(event.type.rawValue == type)
        }
        let deleted = LiveEvent(payload: .conversationDeleted(conversationID: dinner))
        #expect(try JSONDecoder().decode(LiveEvent.self, from: JSONEncoder().encode(deleted)) == deleted)
        #expect(deleted.type.rawValue == "conversation.deleted")
    }
    /// A space's objects and pages come as they are, then again as they change; a page comes as
    /// what it shows, or why it can't be shown; a press goes with the layout it was pressed on.
    @Test
    func objectsAndPagesRoundTrip() throws {
        let ref = PushRef(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        let family = SpaceID(rawValue: "family")
        let menu = MadeObjectID(rawValue: "menu")
        let order = try #require(PiecePath("page/order"))
        for ask in [
            LiveAsk.join(.objects(space: family)), .join(.pages(space: family)), .leave(.pages(space: family)),
            .join(.page(space: family, page: menu)), .pressPage(space: family, page: menu, path: order, version: 7),
        ] {
            let push = LiveCommand.push(ref: ref, ask: ask)
            #expect(try JSONDecoder().decode(LiveCommand.self, from: JSONEncoder().encode(push)) == push)
        }
        let widget = Widget.text(try Text("count", "3 ordered"))
        let mac = ObjectListing(
            id: "mac", title: "Mac", summary: nil, actions: ["status"], events: [], node: "127.0.0.1:2550", made: nil)
        for (payload, type) in [
            (LiveEvent.Payload.objects(space: family, objects: [mac]), "objects"),
            (
                .pages(
                    space: family, pages: [PageListing(id: menu, title: "Menu", summary: nil, preview: .medium(widget))]
                ),
                "pages"
            ),
            (
                .page(space: family, page: menu, shown: PageShown(widget: widget, version: 7, preview: .small(widget))),
                "page"
            ),
            (.pageFailed(space: family, page: menu, reason: "two pieces are called order"), "page.failed"),
        ] {
            let event = LiveEvent(payload: payload)
            #expect(try JSONDecoder().decode(LiveEvent.self, from: JSONEncoder().encode(event)) == event)
            #expect(event.type.rawValue == type)
        }
    }
    /// Their spaces and conversations are topics too: each join named, and each answered with
    /// the whole list.
    @Test
    func spacesAndConversationsRoundTrip() throws {
        let ref = PushRef(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        for ask in [LiveAsk.join(.spaces), .leave(.spaces), .join(.conversations), .leave(.conversations)] {
            let push = LiveCommand.push(ref: ref, ask: ask)
            #expect(try JSONDecoder().decode(LiveCommand.self, from: JSONEncoder().encode(push)) == push)
        }
        // As the web's spaces page writes it.
        let written =
            #"{"type":"push","ref":{"rawValue":"00000000-0000-0000-0000-000000000001"},"ask":"join","topic":"spaces"}"#
        #expect(
            try JSONDecoder().decode(LiveCommand.self, from: Data(written.utf8))
                == .push(
                    ref: PushRef(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
                    ask: .join(.spaces)))
        let family = SpaceSummary(
            id: SpaceID(rawValue: "family"), name: "Family",
            permissions: SpacePermissions(
                people: .see, bots: .use, requests: nil, tasks: nil, connections: false, deleteConversations: false,
                configureSpace: false),
            status: .active)
        let dinner = Conversation(
            id: ConversationID(rawValue: "dinner"), botID: BotID(rawValue: "conversation"), title: "plan dinner",
            spaceID: family.id, people: 2)
        for (payload, type) in [
            (LiveEvent.Payload.spaces(spaces: [family]), "spaces"),
            (.conversations(conversations: [dinner]), "conversations"),
        ] {
            let joined = LiveEvent(payload: .reply(ref: ref, reply: .joined(LiveEvent(payload: payload))))
            #expect(try JSONDecoder().decode(LiveEvent.self, from: JSONEncoder().encode(joined)) == joined)
            #expect(LiveEvent(payload: payload).type.rawValue == type)
        }
    }
}
