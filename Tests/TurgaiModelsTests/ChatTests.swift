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
}
