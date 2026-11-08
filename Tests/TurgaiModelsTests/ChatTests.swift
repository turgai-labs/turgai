import Foundation
import XCTest

@testable import TurgaiModels

final class ChatTests: XCTestCase {
    func testMessageRequestRoundTrip() throws {
        let messageID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let request = ChatMessageRequest(
            id: MessageID(rawValue: messageID),
            text: "Hello"
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ChatMessageRequest.self, from: data)

        XCTAssertEqual(decoded, request)
    }

    func testEventEncodesConversationAndMessage() throws {
        let conversationID = ConversationID(rawValue: "bot-default-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        let event = ChatEvent(
            payload: .messageAccepted(
                conversationID: conversationID,
                turnID: nil,
                message: Message(
                    id: MessageID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
                    role: .user,
                    text: "Hello"
                )
            )
        )

        let data = try JSONEncoder().encode(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "message.accepted")
        XCTAssertEqual(json["conversationID"] as? String, conversationID.rawValue)
        let message = try XCTUnwrap(json["message"] as? [String: Any])
        XCTAssertEqual(message["role"] as? String, "user")
        XCTAssertEqual(message["text"] as? String, "Hello")
    }

    func testEventEncodesTurnPhase() throws {
        let event = ChatEvent(
            payload: .turnPhase(
                conversationID: ConversationID(rawValue: "bot-default"),
                turnID: TurnID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
                phase: .thinking
            )
        )

        let data = try JSONEncoder().encode(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "turn.phase")
        XCTAssertEqual(json["phase"] as? String, "thinking")
    }

    /// A push names what it asks, and its ref; its reply carries the ref back, with how it went.
    func testPushesAndRepliesRoundTrip() throws {
        let ref = PushRef(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        for ask in [ChatAsk.join(.memory), .leave(.memory), .memory, .forgetMemory, .setRemembering(.off)] {
            let push = ChatCommand.push(ref: ref, ask: ask)
            XCTAssertEqual(try JSONDecoder().decode(ChatCommand.self, from: JSONEncoder().encode(push)), push)
        }
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(ChatCommand.push(ref: ref, ask: .setRemembering(.off)))) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "push")
        XCTAssertEqual(json["ask"] as? String, "memory.remembering")
        XCTAssertEqual(json["remembering"] as? String, "off")

        let memory = MemorySummary(nodes: [.init(name: "home", said: "Haar", children: [])], remembering: .on)
        for reply in [ChatReply.ok, .memory(memory), .failed(ChatError(code: "push_failed", message: "No"))] {
            let event = ChatEvent(payload: .reply(ref: ref, reply: reply))
            XCTAssertEqual(try JSONDecoder().decode(ChatEvent.self, from: JSONEncoder().encode(event)), event)
        }
        let changed = ChatEvent(payload: .memoryChanged)
        XCTAssertEqual(try JSONDecoder().decode(ChatEvent.self, from: JSONEncoder().encode(changed)), changed)
        XCTAssertEqual(changed.type.rawValue, "memory.changed")
    }
}
