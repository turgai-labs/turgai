import AnyLanguageModel
import NorbyApplication
import Testing

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

    @Test func timerCommandsHaveIndependentInputs() throws {
        let cancel = try TimerToolsCancelInput(
            GeneratedContent(json: #"{"timerID":"norby-timer-123"}"#)
        )
        #expect(cancel.timerID == "norby-timer-123")
        _ = try TimerToolsListInput(GeneratedContent(json: #"{}"#))
    }

    @Test func timerCreateRequiresItsFields() {
        #expect(throws: Error.self) {
            try TimerToolsCreateInput(
                GeneratedContent(json: #"{"action":"deliverPreparedMessage"}"#)
            )
        }
    }

    @Test func timerOccurrenceKeepsCalendarComponentsTyped() throws {
        let input = try TimerToolsOccurrenceInput(
            GeneratedContent(
                json: #"{"components":{"day":9,"month":9,"year":2026,"hour":9,"minute":0},"timeZone":"Europe/Berlin"}"#)
        )
        #expect(input.components.day == 9)
        #expect(input.timeZone == "Europe/Berlin")
    }

    @Test func timerRejectsRelativeOffsetCalendarShape() {
        #expect(throws: Error.self) {
            try TimerToolsOccurrenceInput(
                GeneratedContent(json: #"{"offset":{"day":2},"matching":{"hour":9},"timeZone":"Europe/Berlin"}"#)
            )
        }
    }

    @Test func scheduleCommandsHaveIndependentInputs() throws {
        let trigger = try ScheduleToolsTriggerInput(
            GeneratedContent(json: #"{"scheduleID":"daily-report"}"#)
        )
        #expect(trigger.scheduleID == "daily-report")

        let recurrence = try ScheduleToolsRecurrenceInput(
            GeneratedContent(
                json:
                    #"{"frequency":"daily","interval":1,"timeZone":"Europe/Berlin","hour":22,"minute":0,"weekdays":[]}"#
            )
        )
        #expect(recurrence.timeZone == "Europe/Berlin")
    }
}
