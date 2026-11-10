import Foundation
import Testing

@testable import TurgaiModels

struct ChatTests {
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
        let event = ChatEvent(
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
        #expect(try JSONDecoder().decode(ChatEvent.self, from: data) == event)
    }

    /// A reply being typed goes as what's written so far, apart from a message said.
    @Test
    func replySoFarGoesApartFromAMessage() throws {
        let event = ChatEvent(
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
        #expect(try JSONDecoder().decode(ChatEvent.self, from: data) == event)
    }

    @Test
    func eventEncodesTurnPhase() throws {
        let event = ChatEvent(
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
            ChatAsk.join(.memory), .leave(.memory), .join(.tasks(space: family)), .leave(.tasks(space: family)),
            .memory, .forgetMemory, .setRemembering(.off),
            .archiveSpace(family), .unarchiveSpace(family), .leaveConversation(dinner), .deleteConversation(dinner),
            .changeSchedule(in: TaskListing.Chat(rawValue: "turgai:dinner"), named: "news", .pause),
            .cancelReminder(in: TaskListing.Chat(rawValue: "turgai:dinner"), named: "tea"),
        ] {
            let push = ChatCommand.push(ref: ref, ask: ask)
            #expect(try JSONDecoder().decode(ChatCommand.self, from: JSONEncoder().encode(push)) == push)
        }
        let json = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(ChatCommand.push(ref: ref, ask: .setRemembering(.off)))) as? [String: Any])
        #expect(json["type"] as? String == "push")
        #expect(json["ask"] as? String == "memory.remembering")
        #expect(json["remembering"] as? String == "off")

        let memory = MemorySummary(nodes: [.init(name: "home", said: "Haar", children: [])], remembering: .on)
        for reply in [ChatReply.ok, .memory(memory), .failed(ChatError(code: "push_failed", message: "No"))] {
            let event = ChatEvent(payload: .reply(ref: ref, reply: reply))
            #expect(try JSONDecoder().decode(ChatEvent.self, from: JSONEncoder().encode(event)) == event)
        }
        let changed = ChatEvent(payload: .memoryChanged)
        #expect(try JSONDecoder().decode(ChatEvent.self, from: JSONEncoder().encode(changed)) == changed)
        #expect(changed.type.rawValue == "memory.changed")
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
            (ChatEvent.Payload.tasks(space: family, tasks: [news, alarm]), "tasks"),
            (.taskKept(space: family, task: news), "task.kept"),
            (.taskEnded(space: family, id: alarm.id), "task.ended"),
        ] {
            let event = ChatEvent(payload: payload)
            #expect(try JSONDecoder().decode(ChatEvent.self, from: JSONEncoder().encode(event)) == event)
            #expect(event.type.rawValue == type)
        }
        let deleted = ChatEvent(payload: .conversationDeleted(conversationID: dinner))
        #expect(try JSONDecoder().decode(ChatEvent.self, from: JSONEncoder().encode(deleted)) == deleted)
        #expect(deleted.type.rawValue == "conversation.deleted")
    }
}
