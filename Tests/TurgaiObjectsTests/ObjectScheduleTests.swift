import DistributedCluster
import DurableWorkflows
import EventSourcing
import Foundation
import Testing

@testable import TurgaiObjects

/// An object's `@Subscribed` `Schedule` and `Timer` properties are due as they say: kept durably
/// while it holds one, its `on<Property>Fired(at:)` called each time, and ended when it holds none.
@Suite(.serialized, .asAPerson)
struct ObjectScheduleTests {
    static let uses = Uses(interface: Uses.interface(of: []), objects: [:], lasting: [])

    static let ticker = """
        import Foundation

        actor Ticker {
            var count = 0
            @Subscribed var tick: Schedule? = Schedule.every(minutes: 5)

            func onTickFired(at time: Date) {
                count += 1
            }

            func stop() {
                tick = nil
            }
        }
        """

    private static func refusals(_ code: String) async throws -> [String] {
        await ScriptInstance.problems(in: try Script(code: code, type: "Ticker", uses: uses)).map(\.message)
    }

    /// A schedule it follows is handled by the function its property names, taking when it was due.
    /// One it doesn't follow is only a value it holds: nothing handles it.
    @Test func aScheduleIsHandledByTheFunctionItsPropertyNames() async throws {
        #expect(try await Self.refusals(Self.ticker).isEmpty)
        let unhandled = Self.ticker.replacingOccurrences(of: "func onTickFired(at time: Date)", with: "func tock()")
        #expect(
            try await Self.refusals(unhandled) == ["no function handles the events of tick: onTickFired(at: Date)"])
        let mistyped = Self.ticker.replacingOccurrences(
            of: "onTickFired(at time: Date)", with: "onTickFired(when: Date)")
        #expect(try await Self.refusals(mistyped) == ["the event of tick calls onTickFired(at: Date)"])
        // Made from its value, with no type written.
        let made = Self.ticker.replacingOccurrences(
            of: "@Subscribed var tick: Schedule? = Schedule.every(minutes: 5)",
            with: "@Subscribed var tick = Schedule.every(minutes: 5)"
        ).replacingOccurrences(of: "tick = nil", with: "tick = .every(minutes: 10)")
        #expect(try await Self.refusals(made).isEmpty)
        let madeUnhandled = made.replacingOccurrences(of: "func onTickFired(at time: Date)", with: "func tock()")
        #expect(
            try await Self.refusals(madeUnhandled) == [
                "no function handles the events of tick: onTickFired(at: Date)"
            ])
        // Kept, not followed.
        let kept = Self.ticker.replacingOccurrences(of: "@Subscribed var tick", with: "var tick")
            .replacingOccurrences(of: "func onTickFired(at time: Date)", with: "func tock()")
        #expect(try await Self.refusals(kept).isEmpty)
        #expect(try ObjectShape(try Script(code: Self.ticker, type: "Ticker", uses: Self.uses)).schedules == ["tick"])
        #expect(try ObjectShape(try Script(code: kept, type: "Ticker", uses: Self.uses)).schedules.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aScheduleThatsDueCallsItsHandlerAndEndsWhenItsPropertyHoldsNone() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem(
            "schedules", store: store, hostsVirtualActors: true,
            installing: { $0.plugins.install(plugin: DurableWorkflowsPlugin()) }
        ) { node in
            let worker = await DurableActivityDispatchWorker<ObjectScheduleWorkflow>(
                actorSystem: node, activities: ObjectScheduleActivities())
            defer { _ = worker }
            let (listener, heard) = try await listening(to: AsAPerson.person.space, on: node)
            defer { listener.cancel() }
            let objects = try await DynamicObjects.of(AsAPerson.person.space, on: node)
            let identity = try await objects.create(
                name: "Ticker", spec: .new(try Script(code: Self.ticker, type: "Ticker", uses: Self.uses)))
            let ticker = try await objects.held(identity)
            let id = ObjectFiring.scheduleID(of: identity, in: AsAPerson.person.space, "tick")
            func kept() async throws -> Bool {
                try await node.workflows.listSchedules(workflow: ObjectScheduleWorkflow.self).contains { $0.id == id }
            }
            // Kept durably as its property says.
            try await eventually("kept") { try await kept() }
            // Due: its handler runs as the object's own doing.
            _ = try await node.workflows.triggerSchedule(id: id, workflow: ObjectScheduleWorkflow.self)
            try await eventually("handled") { try await ticker.read(property: "count") == 1 }
            // Its property holding none ends it.
            _ = try await ticker.respond("stop", arguments: [:])
            try await eventually("ended") { try await !kept() }

            // Whoever follows its space's tasks is told it's kept, then that it isn't due any more.
            try await eventually("told") { await heard.notices.count == 2 }
            #expect(
                await heard.notices == [
                    .kept(
                        KeptTask(
                            id: .schedule(id), of: .object(identity, field: "tick"), due: .schedule(.every(minutes: 5)),
                            paused: false, maker: AsAPerson.person.person)),
                    .ended(.schedule(id)),
                ])
        }
    }

    static let reminder = """
        import Foundation

        actor Reminder {
            var count = 0
            @Subscribed var reminder = Timer.at(Date(timeIntervalSince1970: 0))

            func onReminderFired(at time: Date) {
                count += 1
            }

            func look() -> Int {
                count
            }

            func again() {
                reminder = Timer.at(Date.now)
            }
        }
        """

    /// A timer is due once, at its date: one already past fires now, then never again, and set to
    /// another date it's due again.
    @Test(.timeLimit(.minutes(1)))
    func aTimerIsDueOnceAtItsDateAndAgainWhenSetToAnother() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem(
            "timers", store: store, hostsVirtualActors: true,
            installing: { $0.plugins.install(plugin: DurableWorkflowsPlugin()) }
        ) { node in
            let worker = await DurableActivityDispatchWorker<ObjectTimerWorkflow>(
                actorSystem: node, activities: ObjectScheduleActivities())
            defer { _ = worker }
            let objects = try await DynamicObjects.of(AsAPerson.person.space, on: node)
            let identity = try await objects.create(
                name: "Reminder", spec: .new(try Script(code: Self.reminder, type: "Reminder", uses: Self.uses)))
            let reminder = try await objects.held(identity)
            try await eventually("fired") { try await reminder.read(property: "count") == 1 }
            // Another message keeps it as it was: it fired, and doesn't again.
            _ = try await reminder.respond("look", arguments: [:])
            try await Task.sleep(for: .milliseconds(500))
            #expect(try await reminder.read(property: "count") == 1)
            // Set to another date, it's due again.
            _ = try await reminder.respond("again", arguments: [:])
            try await eventually("fired again") { try await reminder.read(property: "count") == 2 }
        }
    }
}

private func eventually(_ what: String, _ condition: () async throws -> Bool) async throws {
    for _ in 0..<50 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("never \(what)")
}
