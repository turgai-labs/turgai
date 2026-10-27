import DistributedCluster
import EventSourcing
import Foundation
import Testing
import TurgaiDomain

import struct AnyLanguageModel.GeneratedContent

@testable import TurgaiApplication
@testable import TurgaiObjects

/// An object is shared through share_object, with the chat the turn came in through, by whoever may
/// change it: anyone else is refused, as any change is.
@Suite(.serialized)
struct SharingTests {
    private let family = GroupID(rawValue: "family")
    private var ann: CallScope { CallScope(UserID("ann"), in: family, as: .member) }
    private var bob: CallScope { CallScope(UserID("bob"), in: family, as: .member) }
    private let counter =
        "actor Counter {\n    var count = 0\n\n    func add() -> Int {\n        count += 1\n        return count\n    }\n}"

    private func `as`<Value: Sendable>(_ scope: CallScope, _ body: () async throws -> Value) async throws -> Value {
        try await CallChain.$current.withValue(.start(scope)) { try await body() }
    }

    @Test
    func sharingIsWhomAndHowFarEachOneOffered() throws {
        func sharing(_ json: String) throws -> (SharingAudience, SharingLevel) {
            try ShareObjectTool.sharing(in: try GeneratedContent(json: json), for: "share_object")
        }

        #expect(
            try sharing(#"{"object": "tally", "with": "this chat's members", "level": "read"}"#) == (.members, .read))
        #expect(try sharing(#"{"object": "tally", "with": "everyone", "level": "none"}"#) == (.everyone, .none))
        #expect(throws: ObjectToolError.missingArguments("share_object", missing: ["level"], unexpected: [])) {
            try sharing(#"{"object": "tally", "with": "everyone"}"#)
        }
        #expect(throws: ObjectToolError.self) {
            try sharing(#"{"object": "tally", "with": "the family", "level": "read"}"#)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func whoeverMayChangeItSharesItWithTheirChat() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("sharing", store: store, hostsVirtualActors: true) { node in
            let objects = try await DynamicObjects.resolve(on: node)
            let id = try await self.as(ann) {
                try await objects.create(name: "Tally", spec: .new(try Script(code: counter, type: "Counter")))
            }
            let object = try await objects.held(id)
            let annSession = ObjectSession(actorSystem: node, objectCatalog: await ObjectCatalog(actorSystem: node))
            let tally = try await self.as(ann) { try await annSession.id(written: "tally") }

            // Shared with the family, the chat Ann's turn came in through: Bob uses it.
            _ = try await self.as(ann) { try await annSession.share(tally, with: .members, .read) }
            #expect(try await self.as(bob) { try await object.respond("add", arguments: [:]).reply } == .integer(1))

            // Bob reads it, and still can't change who may.
            let bobSession = ObjectSession(actorSystem: node, objectCatalog: await ObjectCatalog(actorSystem: node))
            let bobsTally = try await self.as(bob) { try await bobSession.id(written: "tally") }
            await #expect(throws: ObjectToolError.failed(NotAllowed(.write).description)) {
                try await self.as(bob) { _ = try await bobSession.share(bobsTally, with: .everyone, .write) }
            }

            // Taken back: Bob is refused again.
            _ = try await self.as(ann) { try await annSession.share(tally, with: .members, .none) }
            await #expect(throws: NotAllowed(.read)) {
                try await self.as(bob) { _ = try await object.respond("add", arguments: [:]) }
            }
        }
    }

    /// What an object's code makes is only its to use: sharing the object is enough for others to
    /// use what it holds through it, and never directly.
    @Test(.timeLimit(.minutes(1)))
    func sharingAnObjectSharesWhatItHoldsThroughIt() async throws {
        let drinks = """
            actor Drinks {
                private let tea = Counter(id: "tea")

                func addTea() async throws -> Int {
                    try await tea.add()
                }
            }
            """
        let uses = Uses(
            interface: ModuleInterface(
                name: Uses.module,
                source: "actor Counter {\n    init(id: String)\n    func add() async throws -> Int\n}"),
            objects: [:])
        try await withClusterSystem("sharing", store: MemoryEventStore(), hostsVirtualActors: true) { node in
            let objects = try await DynamicObjects.resolve(on: node)
            let drinksID = try await self.as(ann) {
                _ = try await objects.create(name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))
                return try await objects.create(
                    name: "Drinks", spec: .new(try Script(code: drinks, type: "Drinks", uses: uses)))
            }
            let desk = try await objects.held(drinksID)
            try await self.as(ann) { try await desk.share(with: .group(family), .read) }

            // Bob uses Drinks, and through it the tea it holds.
            #expect(try await self.as(bob) { try await desk.respond("addTea", arguments: [:]).reply } == .integer(1))
            // Not the tea itself, nor does Ann: it's what Drinks holds.
            let tea = try await DynamicObject.resolve(on: node, identity: ObjectIdentity(rawValue: "tea"))
            await #expect(throws: NotAllowed(.read)) {
                try await self.as(bob) { _ = try await tea.respond("add", arguments: [:]) }
            }
            await #expect(throws: NotAllowed(.read)) {
                try await self.as(ann) { _ = try await tea.respond("add", arguments: [:]) }
            }
        }
    }
}
