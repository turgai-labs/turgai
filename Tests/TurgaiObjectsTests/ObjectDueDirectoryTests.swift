import DistributedCluster
import DurableWorkflows
import EventSourcing
import Foundation
import Testing
import TurgaiDomain

@testable import TurgaiApplication
@testable import TurgaiObjects

/// What the runtime keeps due for the objects of each space: read from the records of their
/// schedules and timers, and told to whoever follows as it changes.
@Suite(.serialized, .asAPerson)
struct ObjectDueDirectoryTests {
    private let space = SpaceID()

    private func firing(_ due: ObjectDue) -> ObjectFiring {
        ObjectFiring(
            object: ObjectIdentity(rawValue: "ticker"), property: "tick", maker: AsAPerson.person.person,
            space: space, due: due, place: nil)
    }

    /// A schedule's record keeps what's due from its making to its cancelling, a timer's from its
    /// start to its end; what else they say changes nothing.
    @Test func aRecordKeepsWhatsDueUntilItEnds() throws {
        let schedule = firing(.schedule(.every(minutes: 5)))
        let made = WorkflowSchedulerEvent.scheduled(
            ScheduledWorkflowRecord(
                id: "tick", recurrence: try Schedule.every(minutes: 5).rule(), startedAt: Date(),
                workflowType: ObjectScheduleWorkflow.name, inputData: try JSONEncoder().encode(schedule),
                retryPolicy: nil, lastFiredAt: nil))
        #expect(try ObjectDueChange(made, of: "a schedule") == .kept("a schedule", schedule))
        #expect(try ObjectDueChange(WorkflowSchedulerEvent.cancelled, of: "a schedule") == .ended("a schedule"))
        #expect(try ObjectDueChange(WorkflowSchedulerEvent.paused(reason: nil), of: "a schedule") == nil)

        let timer = firing(.timer(.at(Date(timeIntervalSince1970: 1_000))))
        let started = WorkflowEvent.executionStarted(inputData: try JSONEncoder().encode(timer))
        #expect(try ObjectDueChange(started, of: "a timer") == .kept("a timer", timer))
        let ended = WorkflowEvent.executionCompleted(outputData: Data())
        #expect(try ObjectDueChange(ended, of: "a timer") == .ended("a timer"))
        #expect(try ObjectDueChange(WorkflowEvent.timerFired(sequence: 0), of: "a timer") == nil)
    }

    /// An object's schedule is due in its space while its code holds one: one set before the
    /// directory starts is read from the journal as it starts, and whoever follows is told as that
    /// changes.
    @Test(.timeLimit(.minutes(1)))
    func aSpacesDueWorkFollowsItsObjects() async throws {
        let store = MemoryEventStore()
        let workflows: @Sendable (inout ClusterSystemSettings) -> Void = {
            $0.plugins.install(plugin: DurableWorkflowsPlugin())
        }
        try await withClusterSystem("dues", store: store, hostsVirtualActors: true, installing: workflows) { node in
            let objects = try await DynamicObjects.resolve(on: node)
            let identity = try await objects.create(
                name: "Ticker",
                spec: .new(
                    try Script(code: ObjectScheduleTests.ticker, type: "Ticker", uses: ObjectScheduleTests.uses)))
            let ticker = try await objects.held(identity)
            let space = try await ticker.maker.space
            try await eventually("scheduled") {
                try await node.workflows.describeSchedule(
                    id: ObjectFiring.scheduleID(of: identity, "tick"), workflow: ObjectScheduleWorkflow.self) != nil
            }

            // Started after it was scheduled: it reads what's due from the beginning.
            let directory = try await node.singleton.host(
                ObjectDueDirectory.self, name: ObjectDueDirectory.singletonName
            ) {
                ObjectDueDirectory(actorSystem: $0, journal: store, refreshInterval: .milliseconds(10))
            }
            let due = [ObjectDueListing(object: identity, property: "tick", due: .schedule(.every(minutes: 5)))]
            try await eventually("due") { try await directory.dues(in: space) == due }
            #expect(try await directory.dues(in: SpaceID()).isEmpty)

            // Only its own space's followers are told.
            let (told, telling) = AsyncStream<SpaceID>.makeStream()
            try await directory.follow(space, with: ObjectDueListener(actorSystem: node) { telling.yield(space) })
            let elsewhere = SpaceID()
            let other = ObjectDueListener(actorSystem: node) { telling.yield(elsewhere) }
            try await directory.follow(elsewhere, with: other)
            _ = try await ticker.respond("stop", arguments: [:])
            try await eventually("no longer due") { try await directory.dues(in: space).isEmpty }
            telling.finish()
            var changes: [SpaceID] = []
            for await change in told { changes.append(change) }
            #expect(changes == [space])
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
