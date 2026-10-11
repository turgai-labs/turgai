import AnyLanguageModel
import DiscoverableActors
import Foundation
import Testing

@testable import TurgaiObjects

struct BehaviorTests {
    static let refundManager = """
        fields:
          approveBelow: 50
          reviewing: []
          approved: 0
        receive:
          - on: refundRequested(order: integer, total: number)
            when: total < approveBelow
            do:
              - send: shop.refundApproved(order)
              - add: 1 to approved
          - on: refundRequested(order: integer, total: number)
            do:
              - append: order to reviewing
          - on: approve(number: integer)
            when: reviewing contains number
            do:
              - remove: number from reviewing
              - send: shop.refundApproved(order: number)
              - add: 1 to approved
          - on: pending()
            reply: reviewing
        """

    /// The first clause whose guards hold handles the message, as Erlang's `receive` does.
    @Test
    func theFirstMatchingClauseHandlesTheMessage() throws {
        let behavior = try Behavior(name: "refund manager", yaml: YAML(Self.refundManager))
        let fields = behavior.fields.mapValues(\.initial)

        let small = try behavior.handle(
            "refundRequested", arguments: ["order": 1, "total": 25], fields: fields)
        #expect(small.fields["approved"] == 1)
        #expect(small.sends == [.init(recipient: .named("shop"), message: "refundApproved", arguments: ["order": 1])])

        let big = try behavior.handle(
            "refundRequested", arguments: ["order": 2, "total": 80], fields: small.fields)
        #expect(big.fields["reviewing"] == [2])
        #expect(big.sends.isEmpty)

        let approved = try behavior.handle("approve", arguments: ["number": 2], fields: big.fields)
        #expect(approved.fields["reviewing"] == [])
        #expect(approved.fields["approved"] == 2)
        #expect(try behavior.handle("pending", arguments: nil, fields: big.fields).reply == [2])
    }

    /// A message nothing takes is refused, saying why, and a guard that fails shows its values.
    @Test
    func refusalsSayWhy() throws {
        let behavior = try Behavior(name: "refund manager", yaml: YAML(Self.refundManager))
        let fields = behavior.fields.mapValues(\.initial)
        #expect(throws: BehaviorError("`approve` was refused: `reviewing contains number` was false ([], 7).")) {
            try behavior.handle("approve", arguments: ["number": 7], fields: fields)
        }
        #expect(throws: BehaviorError("It has no message `teleport`. It takes `refundRequested`, `approve`, `pending`.")) {
            try behavior.handle("teleport", arguments: nil, fields: fields)
        }
        #expect(throws: BehaviorError("`approve` needs `number`. It's `approve(number: integer)`.")) {
            try behavior.handle("approve", arguments: [:], fields: fields)
        }
        #expect(throws: BehaviorError("`number` is `two`, but `approve` takes an integer there.")) {
            try behavior.handle("approve", arguments: ["number": "two"], fields: fields)
        }
    }

    /// States, written with `in` and `then`, are a field: a clause handles a message only while
    /// the field says its state, and `then` sets it.
    @Test
    func statesDecideWhatIsTaken() throws {
        let door = try Behavior(
            name: "door",
            yaml: YAML("""
                fields:
                  opened: 0
                initial: closed
                receive:
                  - in: closed
                    on: open()
                    do:
                      - add: 1 to opened
                    then: open
                  - in: open
                    on: close()
                    then: closed
                """))
        let fields = door.fields.mapValues(\.initial)
        #expect(fields["state"] == "closed")
        let opened = try door.handle("open", arguments: nil, fields: fields)
        #expect(opened.fields["state"] == "open")
        #expect(opened.fields["opened"] == 1)
        #expect(throws: BehaviorError.self) {
            try door.handle("open", arguments: nil, fields: opened.fields)
        }
    }

    /// The mistakes a 9B model made writing its first refund manager, each with an error that
    /// says how to fix it.
    @Test
    func aSmallModelsMistakesAreExplained() {
        func error(_ yaml: String) -> String {
            do {
                _ = try Behavior(name: "refund manager", yaml: YAML(yaml))
                return "accepted"
            } catch {
                return error.description
            }
        }
        // The name inside the YAML.
        #expect(error("behavior: refund manager\nreceive:\n  - on: x()").contains("The name is given on its own"))
        // A record as a value.
        #expect(
            error("fields:\n  reviewed: []\nreceive:\n  - on: x(number: integer)\n    do:\n      - append: '{number: number} to reviewed'")
                .contains("Values are single"))
        // Actions as a mapping: shown back as the list, with `reply` next to `do`.
        let mapping = error("fields:\n  count: 0\nreceive:\n  - on: x()\n    do:\n      add: 1 to count\n      reply: count")
        #expect(mapping.contains("do is a mapping, but it's a list"))
        #expect(mapping.contains("      - add: 1 to count\n    reply: count"))
        // A message written as words: the example is made from them.
        #expect(error("receive:\n  - on: add cup\n    do:\n      - set: x to 1").contains("`addCup()`, or `addCup(amount: number)`"))
        // An untyped parameter.
        #expect(error("receive:\n  - on: approve(number)").contains("`approve()`, or `approve(amount: number)` with one"))
        // A field that doesn't exist.
        #expect(error("receive:\n  - on: x()\n    do:\n      - add: 1 to count").contains("`count`, which isn't data it holds"))
        // Text used as a name.
        #expect(error("receive:\n  - on: x()\n    reply: done").contains("names `done`, which isn't one of the event's values or its data. To mean the words themselves, give them as text."))
        // Quoted text stays text, however YAML would read it.
        #expect(error("fields:\n  names: []\nreceive:\n  - on: x(name: string)\n    when: names contains name\n    reply: 'already there'") == "accepted")
        // `reply` next to `do` is fine.
        #expect(error("fields:\n  count: 0\nreceive:\n  - on: howMany()\n    reply: count") == "accepted")
    }

    /// A message's reply type is what its clauses reply, and they must agree.
    @Test
    func repliesAreTypedByTheirClauses() throws {
        let behavior = try Behavior(name: "refund manager", yaml: YAML(Self.refundManager))
        #expect(behavior.messages.first { $0.name == "pending" }?.reply == .list)
        #expect(behavior.messages.first { $0.name == "approve" }?.reply == nil)

        func error(_ yaml: String) -> String {
            do {
                _ = try Behavior(name: "x", yaml: YAML(yaml))
                return "accepted"
            } catch {
                return String(describing: error)
            }
        }
        let some = "fields:\n  count: 0\nreceive:\n  - on: x()\n    when: count > 0\n    reply: count\n  - on: x()\n    do:\n      - add: 1 to count"
        #expect(error(some).contains("`x` replies in one clause and not in another"))
        let differently = "fields:\n  count: 0\nreceive:\n  - on: x()\n    when: count > 0\n    reply: count\n  - on: x()\n    reply: 'none'"
        #expect(error(differently).contains("in one clause and"))
    }

    // MARK: Protocols

    /// What an object running `yaml` takes, by its name and handle, the way the objects here
    /// know each other.
    static func object(_ name: String, _ yaml: String) throws -> [String: MessageProtocol] {
        let messages = MessageProtocol(name: name, messages: try Behavior(name: name, yaml: YAML(yaml)).messages)
        return [name: messages, ObjectNames.handle(for: name): messages]
    }

    static let manager = """
        fields:
          remaining: 1000
        receive:
          - on: raiseRequested(amount: number, worker: bob)
            when: amount <= remaining
            do:
              - subtract: amount from remaining
              - send: worker.raiseApproved(amount)
          - on: raiseRequested(amount: number, worker: bob)
            do:
              - send: worker.raiseDenied(reason: 'over budget')
        """

    static let worker = """
        fields:
          salary: 3000
          manager: {object: Ann}
          lastAnswer: ''
        receive:
          - on: askForRaise(amount: number)
            do:
              - send: manager.raiseRequested(amount, worker: self)
          - on: raiseApproved(amount: number)
            do:
              - add: amount to salary
              - set: lastAnswer to 'approved'
          - on: raiseDenied(reason: string)
            do:
              - set: lastAnswer to reason
          - on: salary()
            reply: salary
        """

    /// The manager and the worker link: each send to the other is a message the other takes,
    /// `self` included. Ann's `worker: bob` is an object like Bob: it runs his behavior.
    @Test
    func aManagerAndAWorkerLink() throws {
        let bob = try Self.object("Bob", Self.worker)
        let manager = try Behavior(name: "Ann", yaml: YAML(Self.manager), objects: bob)
        let worker = try Behavior(name: "Bob", yaml: YAML(Self.worker), objects: try Self.object("Ann", Self.manager))
        #expect(manager.messages.map(\.written) == ["raiseRequested(amount: number, worker: like bob)"])
        #expect(worker.fields["manager"] == .object("Ann"))
        let approved = try manager.handle(
            "raiseRequested", arguments: ["amount": 200, "worker": ["id": "bob"]],
            fields: manager.fields.mapValues(\.initial))
        #expect(approved.fields["remaining"] == 800)
        #expect(approved.sends == [.init(recipient: .reference(["id": "bob"]), message: "raiseApproved", arguments: ["amount": 200])])
    }

    /// Types are sets: integer is in number, an object taking more is in one taking less, and an
    /// object not defined yet is checked when a message reaches it.
    @Test
    func typesAreSets() throws {
        var known = try Self.object("Bob", Self.worker)
        known.merge(try Self.object("Polite", Self.worker + "\n  - on: thanks()\n    reply: 'welcome'")) { _, new in new }
        let types = Types(protocols: known)
        #expect(types.isSubtype(.integer, of: .number))
        #expect(!types.isSubtype(.number, of: .integer))
        #expect(types.isSubtype(.like("polite"), of: .like("bob")))
        #expect(!types.isSubtype(.like("bob"), of: .like("polite")))
        #expect(types.isSubtype(.like("bob"), of: .object))
        #expect(types.isSubtype(.like("nobody yet"), of: .like("bob")))
    }

    /// Each linking mistake, with the error a model reads.
    @Test
    func linkingMistakesAreExplained() throws {
        let bob = try Self.object("Bob", Self.worker)
        let ann = try Self.object("Ann", Self.manager)
        func error(_ yaml: String, knowing objects: [String: MessageProtocol]) -> String {
            do {
                _ = try Behavior(name: "X", yaml: YAML(yaml), objects: objects)
                return "accepted"
            } catch {
                return error.description
            }
        }
        // Forgetting an argument Bob needs.
        #expect(
            error(Self.manager.replacingOccurrences(of: "worker.raiseApproved(amount)", with: "worker.raiseApproved()"), knowing: bob)
                == "`raiseRequested` sends `raiseApproved` with nothing, but it's `raiseApproved(amount: number)`.")
        // Answering with a message Bob doesn't take.
        #expect(
            error(Self.manager.replacingOccurrences(of: "worker.raiseApproved(amount)", with: "worker.raiseGranted(amount)"), knowing: bob)
                .hasPrefix("`raiseRequested` sends `raiseGranted` to `Bob`, which doesn't take it."))
        // Passing itself where an object like Bob is asked for, without taking what he takes.
        #expect(
            error(
                """
                receive:
                  - on: ask(manager: ann)
                    do:
                      - send: manager.raiseRequested(amount: 1, worker: self)
                """, knowing: bob.merging(ann) { _, new in new })
                .hasPrefix("`ask` sends `raiseRequested` with `worker` as itself, but `raiseRequested(amount: number, worker: like bob)` takes an object like bob there"))
        // `speaks` is gone: an object's type is its behavior.
        #expect(error("speaks: [payroll]\nreceive:\n  - on: x()", knowing: [:]).contains("An object's type is its behavior"))
    }

    // MARK: What small models write

    /// Text with values in it, written the ways a model writes it, is filled in when it runs.
    @Test
    func textCarriesValues() throws {
        let behavior = try Behavior(
            name: "cups",
            yaml: """
                fields:
                  count: 2
                receive:
                  - on: howMany()
                    reply: 'You have had {count} cups'
                  - on: again()
                    reply: 'Still {{count}}, or #{count}'
                  - on: more()
                    reply: 'And ${count}, or \\(count)'
                """)
        let fields = behavior.fields.mapValues(\.initial)
        #expect(try behavior.handle("howMany", arguments: nil, fields: fields).reply == "You have had 2 cups")
        #expect(try behavior.handle("again", arguments: nil, fields: fields).reply == "Still 2, or 2")
        #expect(try behavior.handle("more", arguments: nil, fields: fields).reply == "And 2, or 2")
        #expect(throws: BehaviorError.self) {
            try Behavior(name: "cups", yaml: "receive:\n  - on: x()\n    reply: 'You have {nothing}'")
        }
    }

    /// A spec as a model writes it, the arguments of objects_define: each value and action an
    /// object whose `type` says what it is. It runs, and is kept and shown back the same.
    @Test
    func typedSpecsReadFromWhatAModelWrites() throws {
        let written = try Behavior.Written(
            GeneratedContent(
                json: """
                    {"fields": [
                       {"name": "count", "start": {"type": "number", "value": 0}},
                       {"name": "items", "start": {"type": "list", "value": ["milk"]}}],
                     "receive": [
                       {"on": "add", "actions": [{"type": "add", "value": {"type": "number", "value": 1}, "to": "count"}]},
                       {"on": "crossOff", "actions": [{"type": "remove", "value": {"type": "text", "value": "milk"}, "from": "items"}]},
                       {"on": "howMany", "actions": [{"type": "reply", "value": {"type": "name", "value": "count"}}]},
                       {"on": "say", "actions": [{"type": "reply", "value": {"type": "text", "value": "You have {count} cups"}}]}]}
                    """))
        let behavior = try Behavior(name: "cups", written: written)
        let added = try behavior.handle("add", arguments: nil, fields: behavior.fields.mapValues(\.initial))
        #expect(try behavior.handle("howMany", arguments: nil, fields: added.fields).reply == 1)
        #expect(try behavior.handle("say", arguments: nil, fields: added.fields).reply == "You have 1 cups")
        // Kept as the content a model writes, and read back the same.
        #expect(try JSONDecoder().decode(Behavior.Written.self, from: JSONEncoder().encode(written)) == written)
        #expect(try Behavior.Written(yaml: written.yaml) == written)
        #expect(throws: BehaviorError("`how many` isn't a valid message name: use letters and digits, with no spaces, such as `howMany`.")) {
            try Behavior(
                name: "cups",
                written: .init(fields: [], receive: [.init(on: "how many", parameters: nil, when: nil, actions: [])]))
        }
    }

    /// A clause with a condition goes first among its message's, the newest first: a later one
    /// refines what's there. One without a condition goes last.
    @Test
    func theNewestConditionComesFirst() throws {
        let message = Signature(name: "refundRequested", parameters: [Parameter(name: "total", type: .number)])
        let spec = Behavior.Written(fields: [], receive: [])
            .receiving(.on("refundRequested", taking: nil, when: nil, doing: [.reply(.text("kept"))]), as: message)
            .receiving(.on("refundRequested", taking: nil, when: [.comparing(.name("total"), .atMost, .number(50))], doing: [.reply(.text("approved"))]), as: message)
            .receiving(.on("refundRequested", taking: nil, when: [.comparing(.name("total"), .greaterThan, .number(200))], doing: [.reply(.text("denied"))]), as: message)
        let behavior = try Behavior(name: "manager", written: spec)
        func reply(_ total: Int) throws -> DiscoverableActors.JSONValue {
            try behavior.handle("refundRequested", arguments: ["total": .integer(Int64(total))], fields: [:]).reply
        }
        #expect(try reply(300) == "denied")
        #expect(try reply(40) == "approved")
        #expect(try reply(100) == "kept")
    }
}
