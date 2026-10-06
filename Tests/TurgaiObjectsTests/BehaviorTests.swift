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
          - on: refundRequested(number: integer, total: number)
            when: total < approveBelow
            do:
              - send: shop.refundApproved(number)
              - add: 1 to approved
          - on: refundRequested(number: integer, total: number)
            do:
              - append: number to reviewing
          - on: approve(number: integer)
            when: reviewing contains number
            do:
              - remove: number from reviewing
              - send: shop.refundApproved(number)
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
            "refundRequested", arguments: ["number": 1, "total": 25], state: nil, fields: fields)
        #expect(small.fields["approved"] == 1)
        #expect(small.sends == [.init(recipient: .named("shop"), message: "refundApproved", arguments: ["number": 1])])

        let big = try behavior.handle(
            "refundRequested", arguments: ["number": 2, "total": 80], state: nil, fields: small.fields)
        #expect(big.fields["reviewing"] == [2])
        #expect(big.sends.isEmpty)

        let approved = try behavior.handle("approve", arguments: ["number": 2], state: nil, fields: big.fields)
        #expect(approved.fields["reviewing"] == [])
        #expect(approved.fields["approved"] == 2)
        #expect(try behavior.handle("pending", arguments: nil, state: nil, fields: big.fields).reply == [2])
    }

    /// A message nothing takes is refused, saying why, and a guard that fails shows its values.
    @Test
    func refusalsSayWhy() throws {
        let behavior = try Behavior(name: "refund manager", yaml: YAML(Self.refundManager))
        let fields = behavior.fields.mapValues(\.initial)
        #expect(throws: BehaviorError("`approve` was refused: `reviewing contains number` was false ([], 7).")) {
            try behavior.handle("approve", arguments: ["number": 7], state: nil, fields: fields)
        }
        #expect(throws: BehaviorError("It has no message `teleport`. It takes `refundRequested`, `approve`, `pending`.")) {
            try behavior.handle("teleport", arguments: nil, state: nil, fields: fields)
        }
        #expect(throws: BehaviorError("`approve` needs `number`. It's `approve(number: integer)`.")) {
            try behavior.handle("approve", arguments: [:], state: nil, fields: fields)
        }
        #expect(throws: BehaviorError("`number` is `two`, but `approve` takes an integer there.")) {
            try behavior.handle("approve", arguments: ["number": "two"], state: nil, fields: fields)
        }
    }

    /// States: a clause handles a message only in its state, and `then` moves on.
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
        #expect(door.initial == "closed")
        let fields = door.fields.mapValues(\.initial)
        let opened = try door.handle("open", arguments: nil, state: "closed", fields: fields)
        #expect(opened.state == "open")
        #expect(throws: BehaviorError("It doesn't take `open` in `open`. It takes `close` now.")) {
            try door.handle("open", arguments: nil, state: "open", fields: opened.fields)
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
        // An untyped parameter.
        #expect(error("receive:\n  - on: approve(number)").contains("Write it `name(parameter: type, …)`"))
        // A field that doesn't exist.
        #expect(error("receive:\n  - on: x()\n    do:\n      - add: 1 to count").contains("`count`, which isn't a field"))
        // Text used as a name.
        #expect(error("receive:\n  - on: x()\n    reply: done").contains("names `done`, which isn't a parameter or a field. To mean the words themselves, give them as text."))
        // Quoted text stays text, however YAML would read it.
        #expect(error("fields:\n  names: []\nreceive:\n  - on: x(name: string)\n    when: names contains name\n    reply: 'already there'") == "accepted")
        // `reply` next to `do` is fine.
        #expect(error("fields:\n  count: 0\nreceive:\n  - on: howMany()\n    reply: count") == "accepted")
    }

    // MARK: Protocols

    /// Protocols written as YAML, by name.
    static func protocols(_ yaml: String, known: [String: MessageProtocol]) throws -> [String: MessageProtocol] {
        let read = try MessageProtocol.read(try MessageProtocol.Written.read(yaml: YAML(yaml)), known: known)
        return Dictionary(uniqueKeysWithValues: read.map { ($0.name, $0) })
    }

    static func protocols() throws -> [String: MessageProtocol] {
        let written = try MessageProtocol.Written.read(
            yaml: """
                salary answers:
                  - raiseApproved(amount: number)
                  - raiseDenied(reason: string)
                salary review:
                  - raiseRequested(amount: number, worker: salary answers)
                """)
        return Dictionary(uniqueKeysWithValues: try MessageProtocol.read(written, known: [:]).map { ($0.name, $0) })
    }

    static let manager = """
        speaks: [salary review]
        fields:
          remaining: 1000
        receive:
          - on: raiseRequested
            when: amount <= remaining
            do:
              - subtract: amount from remaining
              - send: worker.raiseApproved(amount)
          - on: raiseRequested
            do:
              - send: worker.raiseDenied(reason: 'over budget')
        """

    static let worker = """
        speaks: [salary answers]
        fields:
          salary: 3000
          manager: {object: Ann}
          lastAnswer: ''
        receive:
          - on: askForRaise(amount: number)
            do:
              - send: manager.raiseRequested(amount, worker: self)
          - on: raiseApproved
            do:
              - add: amount to salary
              - set: lastAnswer to 'approved'
          - on: raiseDenied
            do:
              - set: lastAnswer to reason
          - on: salary()
            reply: salary
        """

    /// The manager and the worker link: each handles what it speaks, and each send through a typed
    /// reference is a message the other accepts, `self` included.
    @Test
    func aManagerAndAWorkerLink() throws {
        let known = try Self.protocols()
        let manager = try Behavior(name: "manager", yaml: YAML(Self.manager), protocols: known)
        let worker = try Behavior(name: "worker", yaml: YAML(Self.worker), protocols: known)
        #expect(manager.messages.map(\.written) == ["raiseRequested(amount: number, worker: salary answers)"])
        #expect(worker.fields["manager"] == .object("Ann"))

        let approved = try manager.handle(
            "raiseRequested", arguments: ["amount": 200, "worker": ["id": "bob"]], state: nil,
            fields: manager.fields.mapValues(\.initial))
        #expect(approved.fields["remaining"] == 800)
        #expect(approved.sends == [.init(recipient: .reference(["id": "bob"]), message: "raiseApproved", arguments: ["amount": 200])])
    }

    /// Types are sets: integer is in number, a protocol accepting more is in one accepting less,
    /// and protocols that mention each other are checked without looping.
    @Test
    func typesAreSets() throws {
        var known = try Self.protocols()
        known.merge(
            try Self.protocols(
                "polite answers:\n  - raiseApproved(amount: number)\n  - raiseDenied(reason: string)\n  - thanks()\nping:\n  - ping(back: ping)",
                known: known)
        ) { _, new in new }
        let types = Types(protocols: known)
        #expect(types.isSubtype(.integer, of: .number))
        #expect(!types.isSubtype(.number, of: .integer))
        #expect(types.isSubtype(.speaks("polite answers"), of: .speaks("salary answers")))
        #expect(!types.isSubtype(.speaks("salary answers"), of: .speaks("polite answers")))
        #expect(types.isSubtype(.speaks("ping"), of: .speaks("ping")))
        #expect(types.isSubtype(.speaks("salary answers"), of: .object))
        #expect(throws: BehaviorError.self) {
            try Self.protocols("x:\n  - go(to: nowhere)", known: known)
        }
    }

    /// Each linking mistake, with the error a model reads.
    @Test
    func linkingMistakesAreExplained() throws {
        let known = try Self.protocols()
        func error(_ yaml: String) -> String {
            do {
                _ = try Behavior(name: "worker", yaml: YAML(yaml), protocols: known)
                return "accepted"
            } catch {
                return error.description
            }
        }
        func managerError(_ yaml: String) -> String {
            do {
                _ = try Behavior(name: "manager", yaml: YAML(yaml), protocols: known)
                return "accepted"
            } catch {
                return error.description
            }
        }
        // Forgetting an argument the worker's protocol needs.
        #expect(
            managerError(Self.manager.replacingOccurrences(of: "worker.raiseApproved(amount)", with: "worker.raiseApproved()"))
                == "`raiseRequested` sends `raiseApproved` with nothing, but it's `raiseApproved(amount: number)`.")
        // Answering with a message the worker's protocol doesn't have.
        #expect(
            managerError(Self.manager.replacingOccurrences(of: "worker.raiseApproved(amount)", with: "worker.raiseGranted(amount)"))
                .hasPrefix("`raiseRequested` sends `raiseGranted` to `salary answers`, which doesn't take it."))
        // Passing itself where its kind of answers is asked, without speaking them.
        #expect(
            error("""
                receive:
                  - on: ask(manager: salary review)
                    do:
                      - send: manager.raiseRequested(amount: 1, worker: self)
                """)
                == "`ask` sends `raiseRequested` with `worker` as itself, but `raiseRequested(amount: number, worker: salary answers)` takes an object that speaks salary answers there: it doesn't take `raiseApproved(amount: number)`.")
        // Speaking a protocol without handling all of it.
        #expect(
            error(Self.worker.replacingOccurrences(of: "  - on: raiseDenied\n    do:\n      - set: lastAnswer to reason\n", with: ""))
                .hasPrefix("It speaks `salary answers`, but it doesn't take `raiseDenied(reason: string)`."))
        // An unknown protocol.
        #expect(error("speaks: [payroll]\nreceive:\n  - on: x()").hasPrefix("speaks[0] is `payroll`, which isn't a protocol"))
    }

    /// A new version keeps speaking what the old one did.
    @Test
    func aNewVersionKeepsItsProtocols() throws {
        let known = try Self.protocols()
        let old = try Behavior(name: "manager", yaml: YAML(Self.manager), protocols: known)
        let new = try Behavior(name: "manager", yaml: "receive:\n  - on: hello()", protocols: known)
        #expect(throws: BehaviorError.self) { try new.check(replacing: old) }
        try old.check(replacing: old)
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
        #expect(try behavior.handle("howMany", arguments: nil, state: nil, fields: fields).reply == "You have had 2 cups")
        #expect(try behavior.handle("again", arguments: nil, state: nil, fields: fields).reply == "Still 2, or 2")
        #expect(try behavior.handle("more", arguments: nil, state: nil, fields: fields).reply == "And 2, or 2")
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
                    {"fields": [{"name": "count", "start": {"type": "number", "value": 0}}],
                     "receive": [
                       {"on": "add", "actions": [{"type": "add", "value": {"type": "number", "value": 1}, "to": "count"}]},
                       {"on": "howMany", "actions": [{"type": "reply", "value": {"type": "name", "value": "count"}}]},
                       {"on": "say", "actions": [{"type": "reply", "value": {"type": "text", "value": "You have {count} cups"}}]}]}
                    """))
        let behavior = try Behavior(name: "cups", written: written)
        let added = try behavior.handle("add", arguments: nil, state: nil, fields: behavior.fields.mapValues(\.initial))
        #expect(try behavior.handle("howMany", arguments: nil, state: nil, fields: added.fields).reply == 1)
        #expect(try behavior.handle("say", arguments: nil, state: nil, fields: added.fields).reply == "You have 1 cups")
        // Kept as the content a model writes, and read back the same.
        #expect(try JSONDecoder().decode(Behavior.Written.self, from: JSONEncoder().encode(written)) == written)
        #expect(try Behavior.Written(yaml: written.yaml) == written)
        #expect(throws: BehaviorError("`how many` isn't a valid message name: use letters and digits, with no spaces, such as `howMany`.")) {
            try Behavior(
                name: "cups",
                written: .init(
                    speaks: nil, fields: [], initial: nil,
                    receive: [.init(on: "how many", parameters: nil, when: nil, actions: [], in: nil, then: nil)]))
        }
    }
}
