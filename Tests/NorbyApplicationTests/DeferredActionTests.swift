import NorbyApplication
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct DeferredActionTests {
    @Test func deliverPreparedMessagePreservesTheFinalMessage() {
        let action = DeferredAction(kind: .deliverPreparedMessage, content: "Call mom")
        #expect(action == .deliverPreparedMessage(message: "Call mom"))
        #expect(action.content == "Call mom")
    }

    @Test func performTaskPreservesTheInstruction() {
        let action = DeferredAction(kind: .performTask, content: "Check the weather")
        #expect(action == .performTask(instruction: "Check the weather"))
        #expect(action.content == "Check the weather")
    }

    @Test func timerOperationsHaveIndependentInputs() throws {
        let cancel = try JSONDecoder().decode(TimerTools.Cancel.Input.self, from: Data(#"{"timerID":"norby-timer-123"}"#.utf8))
        #expect(cancel.timerID == "norby-timer-123")
        _ = try JSONDecoder().decode(TimerTools.List.Input.self, from: Data(#"{}"#.utf8))
        let create = try JSONDecoder().decode(TimerTools.Create.Input.self, from: Data(#"{"action":"deliver_prepared_message","message":"Eat","trigger":{"kind":"after","amount":5,"unit":"minutes"}}"#.utf8))
        guard case .after(let duration) = create.trigger else { Issue.record("Expected after trigger"); return }
        #expect(duration == .seconds(300))
    }

    @Test func timerCreateRequiresItsFields() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TimerTools.Create.Input.self, from: Data(#"{"action":"deliver_prepared_message"}"#.utf8))
        }
    }

    @Test func timerOccurrenceKeepsCalendarComponentsTyped() throws {
        let input = try JSONDecoder().decode(TimerTools.Create.Input.self, from: Data(#"{"action":"deliver_prepared_message","message":"Check doors","trigger":{"kind":"at","at":{"components":{"day":9,"month":9,"year":2026,"hour":9,"minute":0},"time_zone":"Europe/Berlin"}}}"#.utf8))
        guard case .at(let occurrence) = input.trigger else { Issue.record("Expected at trigger"); return }
        #expect(occurrence.components.day == 9)
        #expect(occurrence.timeZone.identifier == "Europe/Berlin")
    }

    @Test func timerRejectsRelativeOffsetCalendarShape() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TimerTools.Create.Input.self, from: Data(#"{"action":"deliver_prepared_message","message":"Check doors","trigger":{"kind":"at","at":{"offset":{"day":2},"matching":{"hour":9},"time_zone":"Europe/Berlin"}}}"#.utf8))
        }
    }

    @Test func scheduleOperationsHaveIndependentInputs() throws {
        let trigger = try JSONDecoder().decode(ScheduleTools.Trigger.Input.self, from: Data(#"{"scheduleID":"daily-report"}"#.utf8))
        #expect(trigger.scheduleID == "daily-report")
        let input = try JSONDecoder().decode(ScheduleTools.Create.Input.self, from: Data(#"{"action":"deliver_prepared_message","message":"Check doors","recurrence":{"frequency":"daily","interval":1,"time_zone":"Europe/Berlin","hour":22,"minute":0,"weekdays":[]}}"#.utf8))
        #expect(input.recurrence.timeZone.identifier == "Europe/Berlin")
        let encoded = try JSONEncoder().encode(input)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"time_zone\":\"Europe\\/Berlin\""))
    }
}
