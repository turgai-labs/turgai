import DiscoverableActors
import DistributedCluster
import EventSourcing
import Foundation
import Hail
import Testing
import TurgaiDomain
import VirtualActors

import struct AnyLanguageModel.GeneratedContent

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

/// Objects live on the first node, which also hosts the objects made here, as a runtime's does;
/// the model's session runs on the second, so every call goes through a remote reference.
func withObjectNodes(
    _ body: (_ objects: ClusterSystem, _ session: ClusterSystem) async throws -> Void
) async throws {
    let store = MemoryEventStore()
    try await withClusterSystem("objects", store: store, hostsVirtualActors: true) { objects in
        try await withClusterSystem("session", store: store, joining: objects, hostsVirtualActors: false) { session in
            try await body(objects, session)
        }
    }
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

@Suite(.serialized, .asTheRuntime)
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
            #expect(root["type"] == "Reminders")
            #expect(root["object_id"] == "reminders")

            // Descriptions show references as handles, never as actor IDs.
            let described = try await session.describe(try await session.id(written: "reminders"))
            #expect(described["actions"]?["lists"]?["output"]?["items"]?["type"] == "string")
            #expect(described["actions"]?["lists"]?["safe"] == true)

            // The returned list comes back as the id the system has for it, never a made-up one.
            let lists = try await session.invoke(try await session.id(written: "reminders"), action: "lists", arguments: nil)
            let list = try #require(try await ids(in: session, lists).first)
            #expect(try await ids(in: session, lists).count == 1 && list.name != "reminder-list")
            #expect(try await session.read(list, property: "title") == "Groceries")

            // The new reminder comes back by its id too.
            let reminder = try await id(
                in: session, try await session.invoke(list, action: "add", arguments: #"{"title": "Milk"}"#))
            #expect(try await session.read(reminder, property: "title") == "Milk")

            // Completing hides the action until the reminder is reopened.
            _ = try await session.invoke(reminder, action: "complete", arguments: nil)
            #expect(try await session.read(reminder, property: "isCompleted") == true)
            #expect(try await session.describe(reminder)["actions"]?["complete"] == nil)
            #expect(try await session.invoke(list, action: "reminders", arguments: nil) == [])
            #expect(
                try await ids(
                    in: session,
                    try await session.invoke(list, action: "reminders", arguments: #"{"includeCompleted": true}"#)) == [
                        reminder
                    ])
            _ = reminders
        }
    }

    /// An object an action returned is used through its type's tools, which take which one as a
    /// typed `object`, among those there are; one listed here keeps tools named by its id.
    @Test
    func returnedObjectsAreUsedThroughTheirTypesTools() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let memory = MemoryReminders(lists: [
                ReminderListRecord(id: .init(rawValue: "work"), title: "Work"),
                ReminderListRecord(id: .init(rawValue: "home"), title: "Home"),
            ])
            let reminders = try await Reminders(actorSystem: objectsNode, client: makeClient(memory: memory))
            let session = ObjectSession(actorSystem: sessionNode, scopes: [.shared])
            _ = try await waitForRoots(1, in: session)
            #expect(await session.actionTools(of: try await session.id(written: "reminders")).map(\.name).contains("reminders_lists"))

            let lists = try await ids(
                in: session, try await session.invoke(try await session.id(written: "reminders"), action: "lists", arguments: nil))
            #expect(lists.count == 2)
            let tools = await session.actionTools(of: lists[0])
            let add = try #require(tools.first { $0.name == "ReminderList_add" } as? ObjectActionTool)
            // Which list is chosen among those there are, never written freely.
            let schema = try JSONDecoder().decode(DiscoveryJSON.self, from: JSONEncoder().encode(add.schema.parameters))
            #expect(schema["properties"]?["object"]?["enum"] == .array(lists.map { .string($0.description) }))
            #expect(schema["required"]?.arrayValue?.first == "object")
            // Calling it runs on the list chosen, with its own arguments.
            let arguments = try GeneratedContent(json: #"{"object": "\#(lists[1])", "title": "Milk"}"#)
            let effect = try add.effect(for: arguments)
            #expect(effect.handle == lists[1])
            #expect(effect.arguments == #"{"title":"Milk"}"#)
            await #expect(throws: ObjectToolError.self) {
                try add.effect(for: try GeneratedContent(json: #"{"object": "home", "title": "Milk"}"#))
            }
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
            let list = try #require(
                try await ids(
                    in: session, try await session.invoke(try await session.id(written: "reminders"), action: "lists", arguments: nil)
                ).first)

            await #expect(
                throws: ObjectToolError.missingArguments("ReminderList.add", missing: ["title"], unexpected: [])
            ) {
                try await session.invoke(list, action: "add", arguments: nil)
            }
            await #expect(
                throws: ObjectToolError.missingArguments("ReminderList.add", missing: ["title"], unexpected: [])
            ) {
                try await session.invoke(list, action: "add", arguments: #"{"title": null}"#)
            }
            // `reminders(includeCompleted?)` has one argument, so its value alone will do.
            let reminder = try await id(
                in: session, try await session.invoke(list, action: "add", arguments: #"{"title": "Report"}"#))
            _ = try await session.invoke(reminder, action: "complete", arguments: nil)
            #expect(
                try await ids(in: session, try await session.invoke(list, action: "reminders", arguments: "true")) == [
                    reminder
                ])
            #expect(
                try await ids(
                    in: session, try await session.invoke(list, action: "reminders", arguments: #"{"completed": true}"#)
                ) == [reminder])
            await #expect(
                throws: ObjectToolError.missingArguments("ReminderList.add", missing: ["title"], unexpected: ["name"])
            ) {
                try await session.invoke(list, action: "add", arguments: #"{"name": "Milk"}"#)
            }
            _ = reminders
        }
    }

    /// Each action is a tool of its own, with typed arguments, and a result that hands the model an
    /// object links to that object's tools.
    @Test
    func actionsAreToolsOfTheirOwn() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let memory = MemoryReminders(lists: [ReminderListRecord(id: .init(rawValue: "work"), title: "Work")])
            let reminders = try await Reminders(actorSystem: objectsNode, client: makeClient(memory: memory))
            let session = ObjectSession(actorSystem: sessionNode, scopes: [.shared])
            _ = try await waitForRoots(1, in: session)

            // Finding an object links to its first page, which links to its actions.
            let find = try #require(
                try await ObjectTools(session: session).tools().first { $0.name == "search_objects" })
            let described = try await AnyTool(find).runOutput(
                generatedContent: GeneratedContent(properties: ["query": "reminders"]), authority: FullAuthority())
            let remindersPage = try #require(
                try await next(described, in: session).first { $0.name == "object_reminders" })
            let openedReminders = try await AnyTool(remindersPage).runOutput(
                generatedContent: GeneratedContent(properties: [:]), authority: FullAuthority())
            let lists = try #require(
                try await next(openedReminders, in: session).first { $0.name == "reminders_lists" })
            #expect(lists.description.hasPrefix("lists on Reminders `reminders`"))

            let found = try await AnyTool(lists).runOutput(
                generatedContent: GeneratedContent(properties: [:]), authority: FullAuthority())
            #expect(found.result.textRepresentation.contains("ReminderList"))

            // The list it was handed is an object of its type: its type's tools take which one.
            let reminderList = try #require(
                try await next(found, in: session).first { $0.name == "object_ReminderList" })
            let readSchema = try JSONDecoder().decode(
                DiscoveryJSON.self, from: JSONEncoder().encode(reminderList.schema.parameters))
            guard case .array(let ids)? = readSchema["properties"]?["object"]?["enum"],
                case .string(let id)? = ids.first
            else {
                Issue.record("The list's id isn't offered: \(readSchema)")
                return
            }
            let openedList = try await AnyTool(reminderList).runOutput(
                generatedContent: GeneratedContent(properties: ["object": id]), authority: FullAuthority())
            let add = try #require(try await next(openedList, in: session).first { $0.name == "ReminderList_add" })
            let schema = try JSONDecoder().decode(DiscoveryJSON.self, from: JSONEncoder().encode(add.schema.parameters))
            #expect(schema["properties"]?["title"]?["type"] == "string")
            _ = try await AnyTool(add).runOutput(
                generatedContent: GeneratedContent(properties: ["object": id, "title": "Milk"]),
                authority: FullAuthority())
            #expect(
                try await memory.reminders(in: .init(rawValue: "work"), includeCompleted: false).map(\.title) == [
                    "Milk"
                ])
            _ = reminders
        }
    }

    /// A YAML mistake is explained, Elm-style: the line, a caret under the spot, why, and the fix.
    @Test
    func yamlMistakesAreExplained() {
        func explanation(_ text: String) -> String {
            do {
                _ = try ObjectSession.parse(text)
                return "parsed"
            } catch {
                return String(describing: error)
            }
        }
        let colon = explanation("actions:\n  - startShift: call the shop (from: self).")
        #expect(colon.contains("I couldn't read line 2:"))
        #expect(colon.contains("has a second \": \" in it"))
        #expect(colon.contains(#"- startShift: "call the shop (from: self).""#))
        #expect(explanation("name: Ann\n\tshop: shop").contains("indented with a tab"))
        #expect(
            explanation("name: Ann\nproperties:\n  pending: {value: []}\n shop: {object: shop}").contains(
                "isn't indented like the lines around it"))
    }

    /// Results are YAML; reading one back gives the same value, even text that looks like
    /// something else.
    @Test
    func resultsAreYAMLThatReadsBackTheSame() throws {
        let value: DiscoveryJSON = [
            "flag": "true", "number": "1", "time": "08:30", "answer": "no", "empty": "",
            "missing": nil, "count": 3, "price": 2.5, "done": false,
            "items": [["title": "Milk", "list": "Groceries"]],
        ]
        let text = try ObjectSession.text(value)
        #expect(!text.contains("{\""))
        #expect(try ObjectSession.parse(text) == value)
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

            _ = try await id(
                in: session,
                try await session.invoke(try await session.id(written: "reminders"), action: "add", arguments: #"{"title": "Call mum"}"#))
            #expect(
                try await memory.reminders(in: .init(rawValue: "inbox"), includeCompleted: false).map(\.title) == [
                    "Call mum"
                ])

            _ = try await session.invoke(
                try await session.id(written: "reminders"), action: "add", arguments: #"{"title": "Milk", "list": "groceries"}"#)
            #expect(
                try await memory.reminders(in: .init(rawValue: "groceries"), includeCompleted: false).map(\.title) == [
                    "Milk"
                ])

            await #expect(throws: ObjectToolError.self) {
                try await session.invoke(
                    try await session.id(written: "reminders"), action: "add", arguments: #"{"title": "X", "list": "Work"}"#)
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
                try await session.invoke(try await session.id(written: "reminders"), action: "lists", arguments: nil)
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

            func found(_ query: String) async throws -> [String] {
                guard case .array(let entries) = try await session.find(query) else { return [] }
                return entries.compactMap { if case .string(let id)? = $0["object_id"] { id } else { nil } }
            }
            #expect(try await found("set a reminder") == ["reminders"])
            #expect(try await found("battery level") == ["mac"])
            #expect(try await found("weather").isEmpty)
            _ = (mac, reminders)
        }
    }

    @Test
    func theObjectsPageListsRootsAndTheirHandlesWorkWithoutListing() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let mac = try await Mac(actorSystem: objectsNode)
            let reminders = try await Reminders(
                actorSystem: objectsNode, client: makeClient(memory: MemoryReminders(lists: [])))

            // The runtime keeps one catalog following the receptionist, as here. The objects page
            // says what objects are for, lists the roots by handle, and links them directly.
            let catalog = await ObjectCatalog(actorSystem: sessionNode)
            let listing = ObjectSession(actorSystem: sessionNode, objectCatalog: catalog, scopes: [.shared])
            var lines: [String] = []
            var links: [String] = []
            for _ in 0..<50 {
                let page = try await listing.open(ObjectAddress.objects.address)
                lines = (page.output.textValue ?? "").split(separator: "\n").map(String.init)
                links = page.links.map(\.name)
                if lines.contains(where: { $0.hasPrefix("- id: `reminders`; type: `Reminders`") }),
                    lines.contains(where: { $0.hasPrefix("- id: `mac`; type: `Mac`") })
                {
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(lines.first == ObjectTools.description)
            #expect(lines.contains("Available objects:"))
            #expect(lines.contains { $0.hasPrefix("- id: `mac`; type: `Mac`") })
            #expect(lines.contains { $0.hasPrefix("- id: `reminders`; type: `Reminders`") })
            #expect(Set(links).isSuperset(of: ["create_object", "search_objects", "list_objects"]))
            #expect(Set(links).isSuperset(of: ["object_mac", "object_reminders"]))
            #expect(!links.contains("use_object"))
            // Its link says what objects are for in a sentence.
            #expect(ObjectTools.link.description == ObjectTools.description)

            // A new session, as a later turn gets: the listed handle works straight away.
            let session = ObjectSession(
                actorSystem: sessionNode, objectCatalog: catalog, scopes: [.shared])
            #expect(try await session.describe(try await session.id(written: "reminders"))["type"] == "Reminders")
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
                _ = try await session.describe(try await session.id(written: "h9"))
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
    #expect(ObjectCatalog.signature("add", input: add) == "add(title: String, due: String?, notes: String?)")
    #expect(
        ObjectCatalog.signature(
            "play", input: ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]])
            == "play(query: String)")
    #expect(ObjectCatalog.signature("pause", input: nil) == "pause()")
}

/// What comes after a call: its links, or the tools of the page it landed on, opened now.
private func next(_ returned: CallReturn, in session: ObjectSession) async throws -> [any HailCore.Tool] {
    switch returned.next {
    case .links(let links): links
    case .page(let address): try await session.open(address).links
    }
}

extension ToolOutput {
    /// Its text, for a text output.
    var textValue: String? {
        if case .text(let text) = self { text } else { nil }
    }
}

/// The id a result names an object by.
private func id(in session: ObjectSession, _ result: DiscoveryJSON) async throws -> ObjectID {
    guard case .string(let written) = result else { throw ObjectToolError.failed("\(result) names no object") }
    return try await session.id(written: written)
}

/// The ids a result names objects by, in order.
private func ids(in session: ObjectSession, _ result: DiscoveryJSON) async throws -> [ObjectID] {
    guard case .array(let items) = result else { throw ObjectToolError.failed("\(result) names no objects") }
    var ids: [ObjectID] = []
    for item in items { ids.append(try await id(in: session, item)) }
    return ids
}
