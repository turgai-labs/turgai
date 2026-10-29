import DiscoverableActors
import Testing
import TurgaiObjects

/// A made object's actions are described with the types its code declares, as the checker
/// resolved them: the model and other objects meet them as they meet a built-in object's.
@Suite("Typed schemas of made objects")
struct TypedSchemaTests {
    static let desk = """
        actor RefundDesk {
            /// A refund to decide on.
            struct Refund: Codable {
                var order: Int
                var reason: Reason
                /// Why, in words.
                var note: String? = nil
            }

            enum Reason: String, Codable {
                case damaged, late, wrong
            }

            /// Decides on a refund.
            func review(refund: Refund) -> Bool { true }

            func remind(about order: Int, note: String?) {}

            func reasons() -> [Reason] { [.late] }
        }
        """

    static func message(_ name: String) throws -> ObjectShape.Message {
        let shape = try ObjectShape(try Script(code: desk, type: "RefundDesk"))
        return try #require(shape.messages.first { $0.name == name })
    }

    @Test func aStructParameterIsDescribedByItsFields() throws {
        let refund = try #require(try Self.message("review").input?["properties"]?["refund"])
        #expect(refund["title"] == "RefundDesk.Refund")
        #expect(refund["description"] == "A refund to decide on.")
        #expect(refund["x-order"] == ["order", "reason", "note"])
        #expect(refund["required"] == ["order", "reason"])
        #expect(refund["properties"]?["order"]?["type"] == "integer")
        #expect(refund["properties"]?["note"]?["description"] == "Why, in words.")
        let reason = try #require(refund["properties"]?["reason"])
        #expect(reason["enum"] == ["damaged", "late", "wrong"])
        #expect(reason["title"] == "RefundDesk.Reason")
    }

    @Test func anOptionalParameterMayBeLeftOut() throws {
        let input = try #require(try Self.message("remind").input)
        #expect(input["required"] == ["order"])
        #expect(input["properties"]?["note"]?["type"] == "string")
    }

    @Test func aReplyIsDescribedByItsType() throws {
        let reply = try #require(try Self.message("reasons").output)
        #expect(reply["type"] == "array")
        #expect(reply["items"]?["enum"] == ["damaged", "late", "wrong"])
    }

    /// Another object's code meets the desk's types as Swift declares them, and is checked
    /// against them.
    @Test func anotherObjectsCodeIsCheckedAgainstTheTypes() async throws {
        let spec = try Script(code: Self.desk, type: "RefundDesk").spec(description: nil)
        let interface = Uses.interface(of: [Uses.Object(description: spec, publishes: false)])
        #expect(
            interface.source.contains(
                "extension RefundDesk {\n    /// A refund to decide on.\n    struct Refund: Codable {"),
            "\(interface.source)")
        #expect(interface.source.contains("    enum Reason: String, Codable {"), "\(interface.source)")
        let uses = Uses(
            interface: interface, objects: [ObjectIdentity(rawValue: "desk"): "RefundDesk"], lasting: ["RefundDesk"])
        func clerk(_ refund: String) -> String {
            "actor Clerk {\n    let desk = RefundDesk(id: \"desk\")\n\n    func file() async throws -> Bool {\n        try await desk.review(refund: \(refund))\n    }\n}"
        }
        let right = await ScriptInstance.problems(
            in: try Script(code: clerk("RefundDesk.Refund(order: 12, reason: .late)"), type: "Clerk", uses: uses))
        #expect(right.isEmpty, "\(right)")
        let wrong = await ScriptInstance.problems(
            in: try Script(code: clerk(#"RefundDesk.Refund(order: "12", reason: .late)"#), type: "Clerk", uses: uses))
        #expect(!wrong.isEmpty)
    }

    /// Two objects can each have a type of the same name: each is named with the object it's in,
    /// as Swift names a nested type, and code says which it means.
    @Test func nestedTypesOfTwoObjectsDontCollide() async throws {
        let warehouse = """
            actor Warehouse {
                struct Refund: Codable {
                    var parcel: String
                }

                func receive(refund: Refund) {}
            }
            """
        let interface = Uses.interface(of: [
            Uses.Object(
                description: try Script(code: Self.desk, type: "RefundDesk").spec(description: nil), publishes: false),
            Uses.Object(
                description: try Script(code: warehouse, type: "Warehouse").spec(description: nil), publishes: false),
        ])
        #expect(interface.valueTypes.isSuperset(of: ["RefundDesk.Refund", "Warehouse.Refund"]))
        // A method that returns nothing is declared returning nothing.
        #expect(
            interface.source.contains("func receive(refund: Warehouse.Refund) async throws\n"), "\(interface.source)")
        let receive = try #require(
            try Script(code: warehouse, type: "Warehouse").spec(description: nil).actions["receive"])
        #expect(receive.output == nil, "\(String(describing: receive.output))")
        let uses = Uses(
            interface: interface,
            objects: [
                ObjectIdentity(rawValue: "desk"): "RefundDesk", ObjectIdentity(rawValue: "warehouse"): "Warehouse",
            ], lasting: ["RefundDesk", "Warehouse"])
        let clerk = """
            actor Clerk {
                let desk = RefundDesk(id: "desk")
                let warehouse = Warehouse(id: "warehouse")

                func file() async throws {
                    _ = try await desk.review(refund: RefundDesk.Refund(order: 12, reason: .late))
                    try await warehouse.receive(refund: Warehouse.Refund(parcel: "A1"))
                }
            }
            """
        let problems = await ScriptInstance.problems(in: try Script(code: clerk, type: "Clerk", uses: uses))
        #expect(problems.isEmpty, "\(problems)\n\(interface.source)")
        let mixed = clerk.replacingOccurrences(of: "Warehouse.Refund(parcel", with: "RefundDesk.Refund(parcel")
        #expect(!(await ScriptInstance.problems(in: try Script(code: mixed, type: "Clerk", uses: uses))).isEmpty)
    }

    /// Foundation's value types are the module's: code names them without importing Foundation,
    /// and they're described as every object describes them.
    @Test func foundationValuesAreDescribedAsEveryObjectDoes() throws {
        let code = """
            actor Ledger {
                func record(amount: Decimal, at date: Date, id: UUID) -> Date { date.addingTimeInterval(60) }
            }
            """
        let shape = try ObjectShape(try Script(code: code, type: "Ledger"))
        let record = try #require(shape.messages.first { $0.name == "record" })
        let properties = try #require(record.input?["properties"])
        #expect(properties["date"]?["format"] == "date-time")
        #expect(properties["date"]?["title"] == "Date")
        #expect(properties["amount"]?["title"] == "Decimal")
        #expect(properties["id"]?["format"] == "uuid")
        #expect(record.output?["title"] == "Date")
    }

    /// What isn't of its type is refused with where it is in the value, as `DecodingError` says.
    @Test func aMismatchSaysWhereItIs() async throws {
        let instance = try await ScriptInstance.start(
            try Script(code: Self.desk, type: "RefundDesk"), as: ObjectIdentity(rawValue: "desk"),
            reaches: { _, _ in .null },
            makes: { type, _ in throw CodeProblem("\(type) isn't made here") },
            tools: { function, _ in throw CodeProblem("\(function) isn't here") }, schedules: { _ in },
            cancels: { _ in })
        let error = await #expect(throws: CodeProblem.self) {
            try await instance.handle("review", arguments: ["refund": ["order": 7, "reason": "early"]])
        }
        #expect(error?.message == "`refund.reason`: \"early\" isn't a case of 'RefundDesk.Reason'")
    }

    /// A type of the object being written that another object's methods use is its own: the
    /// module it imports doesn't declare it again.
    @Test func anObjectsOwnTypesArentDeclaredAgain() async throws {
        // The clerk is made first, with a type of its own.
        let first = """
            actor Clerk {
                struct Note: Codable {
                    var text: String
                }

                func last() -> Note {
                    Note(text: "Refund")
                }
            }
            """
        let clerkSpec = try Script(code: first, type: "Clerk").spec(description: nil)
        // Then the desk, written against the clerk: its method takes the clerk's `Note`.
        let deskUses = Uses(
            interface: Uses.interface(of: [Uses.Object(description: clerkSpec, publishes: false)]), objects: [:],
            lasting: ["Clerk"])
        let desk = try Script(code: "actor Desk {\n    func file(note: Clerk.Note) {}\n}", type: "Desk", uses: deskUses)
        #expect(await ScriptInstance.problems(in: desk).isEmpty)
        let deskSpec = try desk.spec(description: nil)
        #expect(deskSpec.actions["file"]?.input?["properties"]?["note"]?["title"] == "Clerk.Note")
        // Then the clerk is changed to file a note with the desk: its module declares the desk,
        // and not the clerk's own `Note` again.
        let changed = first.replacingOccurrences(
            of: "    func last() -> Note {",
            with:
                "    let desk = Desk(id: \"desk\")\n\n    func send() async throws {\n        try await desk.file(note: Note(text: \"Refund\"))\n    }\n\n    func last() -> Note {"
        )
        let clerkUses = Uses(
            interface: Uses.interface(of: [Uses.Object(description: deskSpec, publishes: false)], except: "Clerk"),
            objects: [ObjectIdentity(rawValue: "desk"): "Desk"], lasting: ["Desk"])
        #expect(!clerkUses.interface.source.contains("struct Note"), "\(clerkUses.interface.source)")
        let problems = await ScriptInstance.problems(in: try Script(code: changed, type: "Clerk", uses: clerkUses))
        #expect(problems.isEmpty, "\(problems)\n\(clerkUses.interface.source)")
    }
}

/// A protocol an object's type declares within it: described with the object, declared in the
/// module other objects' code imports, and conformed to as Swift checks it.
@Suite("Protocols objects declare")
struct ObjectProtocolTests {
    static let shop = """
        actor Shop {
            /// Who decides on refunds.
            protocol RefundManager {
                func refundRequested(order: Int, total: Double) async throws
            }

            var managers: [any RefundManager] = []

            func startShift(manager: any RefundManager) {
                managers.append(manager)
            }
        }
        """

    @Test func aProtocolIsDescribedDeclaredAndConformedTo() async throws {
        let description = try Script(code: Self.shop, type: "Shop").spec(description: nil)
        let manager = try #require(description.protocols["Shop.RefundManager"])
        #expect(manager.description == "Who decides on refunds.")
        #expect(manager.requirements["refundRequested"]?.input?["properties"]?["total"]?["type"] == "number")
        #expect(
            description.actions["startShift"]?.input?["properties"]?["manager"]?["x-swift-type"]
                == "any Shop.RefundManager")

        let interface = Uses.interface(of: [Uses.Object(description: description, publishes: true)])
        #expect(
            interface.source.contains(
                "    protocol RefundManager {\n        func refundRequested(order: Int, total: Double) async throws\n    }"
            ), "\(interface.source)")
        #expect(
            interface.source.contains("func startShift(manager: any Shop.RefundManager) async throws"),
            "\(interface.source)")

        let uses = Uses(interface: interface, objects: [ObjectIdentity(rawValue: "shop"): "Shop"], lasting: ["Shop"])
        func refusals(_ code: String) async throws -> [String] {
            await ScriptInstance.problems(in: try Script(code: code, type: "Ann", uses: uses)).map(\.message)
        }
        #expect(
            try await refusals(
                "actor Ann: Shop.RefundManager {\n    func refundRequested(order: Int, total: Double) async throws {}\n}"
            ).isEmpty)
        #expect(
            !(try await refusals("actor Ann: Shop.RefundManager {\n    func refundDenied(order: Int) {}\n}")).isEmpty)
    }

    /// Who conforms is decided by what each takes, one way for every object: one that never said
    /// it conforms, such as a built-in, conforms when it takes the requirements as written.
    @Test func whoConformsIsWhatEachTakes() throws {
        let shop = try ObjectContract(try Script(code: Self.shop, type: "Shop").spec(description: nil))
        let manager = try #require(shop.protocols[ObjectProtocolName(rawValue: "Shop.RefundManager")])
        let ann = try ObjectContract(
            try Script(
                code:
                    "actor Ann: Shop.RefundManager {\n    func refundRequested(order: Int, total: Double) async throws {}\n}",
                type: "Ann"
            )
            .spec(description: nil))
        #expect(ann.conforms(to: manager))
        let counter = try ObjectContract(
            try Script(code: "actor Counter {\n    func add() {}\n}", type: "Counter").spec(description: nil))
        #expect(!counter.conforms(to: manager))
        let builtIn = ObjectDescription(
            type: "Desk", description: nil,
            actions: [
                "refundRequested": ObjectAction(
                    description: nil,
                    input: [
                        "type": "object", "properties": ["order": ["type": "integer"], "total": ["type": "number"]],
                        "required": ["order", "total"], "x-order": ["order", "total"],
                    ], output: nil)
            ])
        #expect(try ObjectContract(builtIn).conforms(to: manager))
    }

    /// The YAML view says what an object declares, conforms to, follows and keeps private.
    @Test func theViewSaysProtocolsConformanceFollowingAndPrivacy() throws {
        let shop = try ObjectSource(try Script(code: Self.shop, type: "Shop")).yaml
        let ann = try ObjectSource(
            try Script(
                code:
                    "actor Ann: Shop.RefundManager {\n    private var notes = \"\"\n    @Subscribed var website = Website(id: \"website\")\n    @Event func decided(order: Int)\n\n    func refundRequested(order: Int, total: Double) async throws {}\n}",
                type: "Ann")
        ).yaml
        #expect(
            shop.contains(
                "protocols:\n  RefundManager:\n  - 'refundRequested(order: Int, total: Double) async throws'"),
            "\(shop)")
        #expect(ann.contains("conforms:\n- Shop.RefundManager"), "\(ann)")
        #expect(ann.contains("data: |\n  private notes = \"\""), "\(ann)")
        #expect(ann.contains("follows: |\n  website = Website(id: \"website\")"), "\(ann)")
        #expect(ann.contains("announces:\n- 'decided(order: Int)'"), "\(ann)")
        #expect(!ann.contains("helpers"), "\(ann)")
    }
}
