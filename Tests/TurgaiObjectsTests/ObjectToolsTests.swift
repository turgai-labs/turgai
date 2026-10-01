import DiscoverableActors
import DistributedCluster
import Foundation
import Hail
import Testing
import TurgaiDomain

@testable import TurgaiApplication
@testable import TurgaiObjects

/// Reminders kept in memory, standing in for EventKit.
actor MemoryReminders {
    private var listRecords: [ReminderListRecord]
    private var records: [ReminderID: ReminderRecord] = [:]
    private var order: [ReminderID] = []

    init(lists: [ReminderListRecord]) {
        self.listRecords = lists
    }

    func lists() async throws -> [ReminderListRecord] { listRecords }

    func reminders(in list: ReminderListID, includeCompleted: Bool) async throws -> [ReminderRecord] {
        order.compactMap { records[$0] }.filter { $0.list == list && (includeCompleted || !$0.isCompleted) }
    }

    func add(title: String, notes: String?, due: Date?, to list: ReminderListID) async throws -> ReminderRecord {
        let record = ReminderRecord(
            id: ReminderID(rawValue: "r\(order.count + 1)"), list: list, title: title, notes: notes, due: due)
        records[record.id] = record
        order.append(record.id)
        return record
    }

    func setCompleted(_ id: ReminderID, _ isCompleted: Bool) async throws -> ReminderRecord {
        guard var record = records[id] else { throw ReminderError.unknownReminder(id) }
        record.isCompleted = isCompleted
        records[id] = record
        return record
    }

    func reschedule(_ id: ReminderID, to due: Date?) async throws -> ReminderRecord {
        guard var record = records[id] else { throw ReminderError.unknownReminder(id) }
        record.due = due
        records[id] = record
        return record
    }
}

private func makeClient(memory: MemoryReminders) -> RemindersClient {
    RemindersClient(
        lists: { try await memory.lists() },
        defaultList: {
            guard let first = try await memory.lists().first else { throw ReminderError.noDefaultList }
            return first
        },
        reminders: { list, includeCompleted in
            try await memory.reminders(in: list, includeCompleted: includeCompleted)
        },
        add: { title, notes, due, list in
            try await memory.add(title: title, notes: notes, due: due, to: list)
        },
        setCompleted: { id, isCompleted in try await memory.setCompleted(id, isCompleted) },
        reschedule: { id, due in try await memory.reschedule(id, to: due) }
    )
}

/// Objects live on the first node; the model's session runs on the second, so
/// every call goes through a remote reference.
func withObjectNodes(
    _ body: (_ objects: ClusterSystem, _ session: ClusterSystem) async throws -> Void
) async throws {
    func configure(_ settings: inout ClusterSystemSettings) {
        settings.bindHost = "127.0.0.1"
        settings.bindPort = PortFinder.findAvailablePort(host: "127.0.0.1")
    }
    let first = await ClusterSystem("objects", configuredWith: configure)
    let second = await ClusterSystem("session", configuredWith: configure)
    defer {
        _ = try? first.shutdown()
        _ = try? second.shutdown()
    }
    second.cluster.join(endpoint: first.cluster.endpoint)
    try await first.cluster.waitFor(second.cluster.node, .up, within: .seconds(10))
    try await body(first, second)
}

/// The receptionist spreads check-ins by gossip, so wait until the session's node sees them.
func waitForRoots(_ count: Int, in session: ObjectSession) async throws -> DiscoveryJSON {
    for _ in 0..<50 {
        let roots = try await session.list()
        if case .array(let entries) = roots, entries.count >= count { return roots }
        try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("Timed out waiting for \(count) roots")
    return try await session.list()
}

@Suite(.serialized)
struct ObjectToolsTests {
    @Test
    func modelWalksFromRootToReminderAndBack() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let memory = MemoryReminders(lists: [
                ReminderListRecord(id: .init(rawValue: "groceries"), title: "Groceries")
            ])
            let reminders = try await Reminders(actorSystem: objectsNode, client: makeClient(memory: memory))
            let session = ObjectSession(
                actorSystem: sessionNode, scopes: [.shared])

            let roots = try await waitForRoots(1, in: session)
            guard case .array(let entries) = roots, let root = entries.first else {
                Issue.record("Expected one root, got \(roots)")
                return
            }
            #expect(root["title"] == "Reminders")
            #expect(root["handle"] == "reminders")

            // Descriptions show references as handles, never as actor IDs.
            let described = try await session.describe("reminders")
            #expect(described["actions"]?["lists"]?["output"]?["items"]?["type"] == "string")
            #expect(described["actions"]?["lists"]?["safe"] == true)

            // The returned list becomes a handle.
            let lists = try await session.invoke("reminders", action: "lists", arguments: nil)
            #expect(lists == ["reminder-list"])
            #expect(try await session.read("reminder-list", property: "title") == "Groceries")

            // The new reminder comes back as a handle.
            let added = try await session.invoke("reminder-list", action: "add", arguments: #"{"title": "Milk"}"#)
            #expect(added == "reminder")
            #expect(try await session.read("reminder", property: "title") == "Milk")

            // Completing hides the action until the reminder is reopened.
            _ = try await session.invoke("reminder", action: "complete", arguments: nil)
            #expect(try await session.read("reminder", property: "isCompleted") == true)
            #expect(try await session.describe("reminder")["actions"]?["complete"] == nil)
            #expect(try await session.invoke("reminder-list", action: "reminders", arguments: nil) == [])
            #expect(
                try await session.invoke(
                    "reminder-list", action: "reminders", arguments: #"{"includeCompleted": true}"#)
                    == ["reminder"])
            _ = reminders
        }
    }

    @Test
    func callsNeedTheirArgumentsAndTakeABareValue() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let memory = MemoryReminders(lists: [ReminderListRecord(id: .init(rawValue: "work"), title: "Work")])
            let reminders = try await Reminders(actorSystem: objectsNode, client: makeClient(memory: memory))
            let session = ObjectSession(
                actorSystem: sessionNode, scopes: [.shared])
            _ = try await waitForRoots(1, in: session)
            _ = try await session.invoke("reminders", action: "lists", arguments: nil)

            await #expect(
                throws: ObjectToolError.missingArguments("ReminderList.add", missing: ["title"], unexpected: [])
            ) {
                try await session.invoke("reminder-list", action: "add", arguments: nil)
            }
            await #expect(
                throws: ObjectToolError.missingArguments("ReminderList.add", missing: ["title"], unexpected: [])
            ) {
                try await session.invoke("reminder-list", action: "add", arguments: #"{"title": null}"#)
            }
            // `reminders(includeCompleted?)` has one argument, so its value alone will do.
            _ = try await session.invoke("reminder-list", action: "add", arguments: #"{"title": "Report"}"#)
            _ = try await session.invoke("reminder", action: "complete", arguments: nil)
            #expect(try await session.invoke("reminder-list", action: "reminders", arguments: "true") == ["reminder"])
            #expect(
                try await session.invoke("reminder-list", action: "reminders", arguments: #"{"completed": true}"#) == [
                    "reminder"
                ])
            await #expect(
                throws: ObjectToolError.missingArguments("ReminderList.add", missing: ["title"], unexpected: ["name"])
            ) {
                try await session.invoke("reminder-list", action: "add", arguments: #"{"name": "Milk"}"#)
            }
            _ = reminders
        }
    }

    @Test
    func rootAddsToTheDefaultOrANamedList() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let memory = MemoryReminders(lists: [
                ReminderListRecord(id: .init(rawValue: "inbox"), title: "Inbox"),
                ReminderListRecord(id: .init(rawValue: "groceries"), title: "Groceries"),
            ])
            let reminders = try await Reminders(actorSystem: objectsNode, client: makeClient(memory: memory))
            let session = ObjectSession(actorSystem: sessionNode, scopes: [.shared])
            _ = try await waitForRoots(1, in: session)

            #expect(
                try await session.invoke("reminders", action: "add", arguments: #"{"title": "Call mum"}"#) == "reminder"
            )
            #expect(
                try await memory.reminders(in: .init(rawValue: "inbox"), includeCompleted: false).map(\.title) == [
                    "Call mum"
                ])

            _ = try await session.invoke(
                "reminders", action: "add", arguments: #"{"title": "Milk", "list": "groceries"}"#)
            #expect(
                try await memory.reminders(in: .init(rawValue: "groceries"), includeCompleted: false).map(\.title) == [
                    "Milk"
                ])

            await #expect(throws: ObjectToolError.self) {
                try await session.invoke("reminders", action: "add", arguments: #"{"title": "X", "list": "Work"}"#)
            }
            _ = reminders
        }
    }

    @Test
    func objectErrorsReachTheModelReadably() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let denied = RemindersClient(
                lists: { throw ReminderError.accessDenied },
                defaultList: { throw ReminderError.accessDenied },
                reminders: { _, _ in [] },
                add: { _, _, _, _ in throw ReminderError.accessDenied },
                setCompleted: { id, _ in throw ReminderError.unknownReminder(id) },
                reschedule: { id, _ in throw ReminderError.unknownReminder(id) }
            )
            let reminders = try await Reminders(actorSystem: objectsNode, client: denied)

            let session = ObjectSession(
                actorSystem: sessionNode, scopes: [.shared])
            _ = try await waitForRoots(1, in: session)

            await #expect(throws: ObjectToolError.failed(ReminderError.accessDenied.description)) {
                try await session.invoke("reminders", action: "lists", arguments: nil)
            }
            _ = reminders
        }
    }

    @Test
    func findRanksRootsByTheQuery() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let mac = try await Mac(actorSystem: objectsNode)
            let reminders = try await Reminders(
                actorSystem: objectsNode, client: makeClient(memory: MemoryReminders(lists: [])))

            let session = ObjectSession(
                actorSystem: sessionNode, scopes: [.shared])
            _ = try await waitForRoots(2, in: session)

            func titles(_ query: String) async throws -> [String] {
                guard case .array(let entries) = try await session.find(query) else { return [] }
                return entries.compactMap { if case .string(let title)? = $0["title"] { title } else { nil } }
            }
            #expect(try await titles("set a reminder") == ["Reminders"])
            #expect(try await titles("battery level") == ["Mac"])
            #expect(try await titles("weather").isEmpty)
            _ = (mac, reminders)
        }
    }

    @Test
    func turnsListRootsAndTheirHandlesWorkWithoutListing() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let mac = try await Mac(actorSystem: objectsNode)
            let reminders = try await Reminders(
                actorSystem: objectsNode, client: makeClient(memory: MemoryReminders(lists: [])))
            guard let conversation = TurgaiDomain.ConversationID(stableKey: "web:ada") else {
                Issue.record("Invalid conversation ID")
                return
            }

            // The runtime keeps one catalog following the receptionist, as here.
            let catalog = await ObjectCatalog(actorSystem: sessionNode)
            var lines: [String] = []
            for _ in 0..<50 {
                lines = await ObjectSession.turnContext(
                    actorSystem: sessionNode, objectCatalog: catalog, conversationID: conversation)
                if lines.count == 3 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(lines.first == "Objects you can use with the objects tool, by handle:")
            #expect(lines.contains { $0.hasPrefix("- `mac`, Mac: ") })
            #expect(lines.contains { $0.hasPrefix("- `reminders`, Reminders: ") })

            // A new session, as a later turn gets: the listed handle works straight away.
            let session = ObjectSession(
                actorSystem: sessionNode, objectCatalog: catalog, scopes: [.shared])
            #expect(try await session.describe("reminders")["title"] == "Reminders")
            _ = (mac, reminders)
        }
    }

    @Test
    func scopesLimitWhatIsListed() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let ada = try await Reminders(
                actorSystem: objectsNode, client: makeClient(memory: MemoryReminders(lists: [])),
                scope: .owned(by: .init(rawValue: "ada")))
            let grace = try await Reminders(
                actorSystem: objectsNode, client: makeClient(memory: MemoryReminders(lists: [])),
                scope: .owned(by: .init(rawValue: "grace")))

            let session = ObjectSession(
                actorSystem: sessionNode, scopes: ObjectScope.visible(to: .init(rawValue: "ada")))
            let roots = try await waitForRoots(1, in: session)
            try await Task.sleep(for: .milliseconds(500))
            #expect(try await session.list() == roots)
            _ = (ada, grace)
        }
    }

    @Test
    func handlesAreRequiredForObjectArguments() async throws {
        await #expect(throws: ObjectToolError.unknownHandle("h9")) {
            try await withObjectNodes { _, sessionNode in
                let session = ObjectSession(
                    actorSystem: sessionNode, scopes: [.shared])
                _ = try await session.describe("h9")
            }
        }
    }
}

@Test
func actionSignaturesNameTheirArguments() {
    let add: JSONValue = [
        "type": "object",
        "properties": ["title": ["type": "string"], "notes": ["type": "string"], "due": ["type": "string"]],
        "required": ["title"],
    ]
    #expect(ObjectCatalog.signature("add", input: add) == "add(title, due?, notes?)")
    #expect(
        ObjectCatalog.signature(
            "play", input: ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]])
            == "play(query)")
    #expect(ObjectCatalog.signature("pause", input: nil) == "pause()")
}
