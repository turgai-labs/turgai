import Foundation
import Testing
import TurgaiModels

@testable import TurgaiClient

/// What the connection hears is read one message at a time: one that can't be read is skipped,
/// failing only the push it replies to, so the connection goes on.
struct HeardTests {
    private let ref = PushRef(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)

    @Test
    func anEventReadsAsItself() throws {
        let event = LiveEvent(payload: .memory(MemorySummary(nodes: [], remembering: .on)))
        let text = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(Heard(text) == .event(event))
    }

    @Test
    func aReplyThatCantBeReadFailsOnlyItsPush() {
        let text =
            #"{"type":"reply","ref":{"rawValue":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"},"status":"ok","state":{"type":"page.zoomed"}}"#
        #expect(Heard(text) == .unreadable(reply: ref))
    }

    @Test
    func anythingElseThatCantBeReadIsSkipped() {
        #expect(Heard(#"{"type":"page.zoomed"}"#) == .unreadable(reply: nil))
        #expect(Heard("not json") == .unreadable(reply: nil))
    }
}
