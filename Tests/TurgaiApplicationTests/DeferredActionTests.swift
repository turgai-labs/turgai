import AnyLanguageModel
import Foundation
import Hail
import Testing
import TurgaiApplication
import TurgaiDomain

private func diagnosticsContext() -> AgentTurnContext {
    AgentTurnContext(
        agentID: AgentID(
            role: Role("conversation"),
            contextID: AgentContextID("telegram:10499752")
        ),
        turnID: TurnID(rawValue: UUID().uuidString),
        input: AgentHistory.Input(
            from: .user(id: "participant:telegram:10499752"), content: GeneratedContent("test"), at: Date())
    )
}

private func requiredFields(of schema: GenerationSchema) throws -> Set<String> {
    let data = try JSONEncoder().encode(schema)
    let json = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let definitions = json["$defs"] as? [String: Any] ?? [:]
    func resolve(_ value: Any?) throws -> [String: Any] {
        let object = try #require(value as? [String: Any])
        if let reference = object["$ref"] as? String {
            let key = try #require(reference.split(separator: "/").last)
            return try resolve(definitions[String(key)])
        }
        return object
    }
    let root = try resolve(json)
    return Set(root["required"] as? [String] ?? [])
}

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
            GeneratedContent(json: #"{"timerID":"turgai-timer-123"}"#)
        )
        #expect(cancel.timerID == "turgai-timer-123")
        _ = try TimerToolsListInput(GeneratedContent(json: #"{}"#))
    }

    @Test func timerCreateAfterDecodesWithRequiredFields() throws {
        let input = try TimerToolsCreateAfterInput(
            GeneratedContent(
                json: #"{"action":"deliverPreparedMessage","message":"Call mom","amount":80,"unit":"minutes"}"#
            )
        )
        #expect(input.amount == 80)
        #expect(input.unit == .minutes)
    }

    @Test func timerCreateAfterMarksAmountAndUnitRequired() throws {
        // Required in the schema, so the provider grammar enforces presence.
        // Decode itself is lenient about missing scalars (they default to 0);
        // a zero delay is rejected at execution with a descriptive error.
        let required = try requiredFields(of: TimerToolsCreateAfterInput.generationSchema)
        #expect(required.contains("amount"))
        #expect(required.contains("unit"))

        let input = try TimerToolsCreateAfterInput(
            GeneratedContent(json: #"{"action":"deliverPreparedMessage","unit":"minutes"}"#)
        )
        #expect(input.amount == 0)
    }

    @Test func timerCreateAfterRejectsNegativeAmount() throws {
        let tools = TimerTools(context: diagnosticsContext())
        let input = try TimerToolsCreateAfterInput(
            GeneratedContent(
                json: #"{"action":"deliverPreparedMessage","message":"x","amount":-5,"unit":"minutes"}"#
            )
        )
        #expect(throws: TimerTools.Error.negativeAmount(-5)) {
            try tools.createAfter(input)
        }
    }

    @Test func timerCreateAtDecodesWithRequiredClockFields() throws {
        let input = try TimerToolsCreateAtInput(
            GeneratedContent(
                json: #"""
                    {"action":"deliverPreparedMessage","message":"Call mom",
                     "hour":21,"minute":32,"timeZone":"Europe/Berlin"}
                    """#
            )
        )
        #expect(input.hour == 21)
        #expect(input.minute == 32)
        #expect(input.timeZone == "Europe/Berlin")
        #expect(input.year == nil)
    }

    @Test func timerCreateAtMarksClockFieldsRequired() throws {
        let required = try requiredFields(of: TimerToolsCreateAtInput.generationSchema)
        #expect(required.contains("hour"))
        #expect(required.contains("minute"))
        #expect(required.contains("timeZone"))
    }

    @Test func timerCreateAtBuildsOccurrenceEffect() throws {
        let tools = TimerTools(context: diagnosticsContext())
        let input = try TimerToolsCreateAtInput(
            GeneratedContent(
                json: #"""
                    {"action":"deliverPreparedMessage","message":"Call mom",
                     "hour":21,"minute":32,"timeZone":"Europe/Berlin"}
                    """#
            )
        )
        let effect = try tools.createAt(input)
        guard case .at(let occurrence) = effect.trigger else {
            Issue.record("expected an at trigger, got \(effect.trigger)")
            return
        }
        #expect(occurrence.components.hour == 21)
        #expect(occurrence.components.minute == 32)
        #expect(occurrence.components.day == nil)
        #expect(occurrence.timeZone.identifier == "Europe/Berlin")
    }

    @Test func timerCreateAtRejectsUnknownTimeZone() throws {
        let tools = TimerTools(context: diagnosticsContext())
        let input = try TimerToolsCreateAtInput(
            GeneratedContent(
                json: #"""
                    {"action":"deliverPreparedMessage","message":"Call mom",
                     "hour":21,"minute":32,"timeZone":"Mars/Olympus"}
                    """#
            )
        )
        #expect(throws: TimerTools.Error.unknownTimeZone("Mars/Olympus")) {
            try tools.createAt(input)
        }
    }

    @Test func timerValidationErrorsDescribeTheExpectedShape() {
        #expect(TimerTools.Error.unknownTimeZone("X").description.contains("Europe/Berlin"))
        #expect(TimerTools.Error.negativeAmount(-1).description.contains("zero or positive"))
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
