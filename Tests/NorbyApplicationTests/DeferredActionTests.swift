import NorbyApplication
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct DeferredActionTests {
    @Test
    func notifyPreservesTheFinalMessage() {
        let action = DeferredAction(kind: .notify, content: "Call mom")

        #expect(action == .notify(message: "Call mom"))
        #expect(action.content == "Call mom")
    }

    @Test
    func promptAgentPreservesTheInstruction() {
        let action = DeferredAction(kind: .promptAgent, content: "Check the weather")

        #expect(action == .promptAgent(instruction: "Check the weather"))
        #expect(action.content == "Check the weather")
    }

    @Test
    func timerCancellationDoesNotRequireCreationFields() throws {
        let input = try JSONDecoder().decode(
            TimerTool.Input.self,
            from: Data(
                #"{"operation":"cancel","timer_id":"norby-timer-123"}"#.utf8
            )
        )

        #expect(input.operation == .cancel)
        #expect(input.timerID == "norby-timer-123")
        #expect(input.action == nil)
        #expect(input.trigger == nil)
    }

    @Test
    func timerListDoesNotRequireCreationFields() throws {
        let input = try JSONDecoder().decode(
            TimerTool.Input.self,
            from: Data(#"{"operation":"list"}"#.utf8)
        )

        #expect(input.operation == .list)
        #expect(input.timerID == nil)
        #expect(input.trigger == nil)
    }

    @Test
    func timerAfterTriggerKeepsTheModelInputSemantic() throws {
        let input = try JSONDecoder().decode(
            TimerTool.Input.self,
            from: Data(
                #"{"operation":"create","action":"notify","message":"Eat","trigger":{"kind":"after","amount":5,"unit":"minutes"}}"#
                    .utf8
            )
        )

        guard case .after(let duration) = input.trigger else {
            Issue.record("Expected an after trigger")
            return
        }
        #expect(duration == .seconds(5 * 60))
    }

    @Test
    func timerOccurrenceKeepsCalendarComponentsTyped() throws {
        let input = try JSONDecoder().decode(
            TimerTool.Input.self,
            from: Data(
                #"{"operation":"create","action":"notify","message":"Check doors","trigger":{"kind":"at","at":{"components":{"day":9,"month":9,"year":2026,"hour":9,"minute":0},"time_zone":"Europe/Berlin"}}}"#
                    .utf8
            )
        )

        guard case .at(let occurrence) = input.trigger else {
            Issue.record("Expected an at trigger")
            return
        }
        #expect(occurrence.components.day == 9)
        #expect(occurrence.components.month == 9)
        #expect(occurrence.components.year == 2026)
        #expect(occurrence.components.hour == 9)
        #expect(occurrence.components.minute == 0)
        #expect(occurrence.timeZone.identifier == "Europe/Berlin")

        let encoded = try JSONEncoder().encode(input)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(json.contains(#""time_zone":"Europe\/Berlin""#))
        #expect(json.contains("\"day\":9"))
        #expect(json.contains("\"hour\":9"))
    }

    @Test
    func timerRejectsRelativeOffsetCalendarShape() throws {
        let invalid = Data(
            #"{"operation":"create","action":"notify","message":"Check doors","trigger":{"kind":"at","at":{"offset":{"day":2},"matching":{"hour":9},"time_zone":"Europe/Berlin"}}}"#
                .utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TimerTool.Input.self, from: invalid)
        }
    }

    @Test
    func timerOccurrenceResolvesAgainstItsTimezone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 9,
                    day: 7,
                    hour: 15,
                    minute: 30
                ))
        )
        let occurrence = Timer.Occurrence(
            components: DateComponents(
                year: 2026,
                month: 9,
                day: 9,
                hour: 9,
                minute: 0
            ),
            timeZone: calendar.timeZone
        )

        let fireAt = try Timer.fireAt(
            for: .at(occurrence),
            after: now
        )

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireAt
        )
        #expect(components.year == 2026)
        #expect(components.month == 9)
        #expect(components.day == 9)
        #expect(components.hour == 9)
        #expect(components.minute == 0)
    }

    @Test
    func timerOccurrenceFindsTheNextWeekday() throws {
        let timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 9,
                    day: 7,
                    hour: 10
                ))
        )
        let occurrence = Timer.Occurrence(
            components: DateComponents(hour: 8, minute: 0, weekday: 7),
            timeZone: timeZone
        )

        let fireAt = try Timer.fireAt(
            for: .at(occurrence),
            after: now
        )

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .weekday],
            from: fireAt
        )
        #expect(components.day == 12)
        #expect(components.hour == 8)
        #expect(components.minute == 0)
        #expect(components.weekday == 7)
    }

    @Test
    func scheduleTriggerOnlyRequiresTheScheduleID() throws {
        let input = try JSONDecoder().decode(
            ScheduleTool.Input.self,
            from: Data(#"{"operation":"trigger","schedule_id":"daily-report"}"#.utf8)
        )

        #expect(input.operation == .trigger)
        #expect(input.scheduleID == "daily-report")
        #expect(input.action == nil)
        #expect(input.recurrence == nil)
    }

    @Test
    func scheduleRecurrenceKeepsTimezoneTypedInternally() throws {
        let input = try JSONDecoder().decode(
            ScheduleTool.Input.self,
            from: Data(
                #"{"operation":"create","action":"notify","message":"Check doors","recurrence":{"frequency":"daily","interval":1,"time_zone":"Europe/Berlin","hour":22,"minute":0,"weekdays":[]}}"#
                    .utf8
            )
        )

        #expect(input.recurrence?.timeZone.identifier == "Europe/Berlin")
        let encoded = try JSONEncoder().encode(input)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"time_zone\":\"Europe\\/Berlin\""))
    }

}
