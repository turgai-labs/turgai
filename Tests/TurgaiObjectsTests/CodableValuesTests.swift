import Testing

@testable import TurgaiObjects

/// What an object takes, gives back, announces or holds is `Codable`, as the runtime sends and
/// keeps it: anything else is refused at its code, in Swift's words.
@Suite("Codable values")
struct CodableValuesTests {
    private static func refusals(_ code: String, type: String) async throws -> [String] {
        await ScriptInstance.problems(in: try Script(code: code, type: type)).map(\.message)
    }

    /// The eval's counter, whose report another object passed on as a value it wasn't.
    @Test func aTupleIsntSentOrKept() async throws {
        let code = """
            actor Counter {
                var name = ""
                var value = 0
                var last: (String, Int)? = nil

                func report() -> (name: String, value: Int) {
                    (name, value)
                }

                func add(pair: (Int, Int)) {
                    value += pair.0
                }
            }
            """
        #expect(
            try await Self.refusals(code, type: "Counter") == [
                "stored property 'last' of type '(String, Int)?' does not conform to 'Codable': '(String, Int)' doesn't",
                "result type '(name: String, value: Int)' of 'report()' does not conform to 'Codable'",
                "parameter 'pair' of type '(Int, Int)' in 'add(pair:)' does not conform to 'Codable'",
            ])
    }

    @Test func aStructSaysItsCodable() async throws {
        let unsaid = """
            actor Desk {
                struct Report {
                    var count: Int
                }

                func report() -> [Report] {
                    []
                }
            }
            """
        #expect(
            try await Self.refusals(unsaid, type: "Desk") == [
                "result type '[Desk.Report]' of 'report()' does not conform to 'Codable': 'Desk.Report' doesn't"
            ])
        let said = unsaid.replacingOccurrences(of: "struct Report {", with: "struct Report: Codable {")
        #expect(try await Self.refusals(said, type: "Desk").isEmpty)
    }

    /// A type that says it's `Codable` holds only what is, as Swift makes it.
    @Test func aCodableTypeHoldsOnlyCodableValues() async throws {
        let code = """
            actor Desk {
                struct Report: Codable {
                    var pair: (Int, Int)
                }

                enum Answer: Codable {
                    case count(Int)
                    case letter(Character)
                }

                func report() -> Report? {
                    nil
                }

                func answer() -> Answer? {
                    nil
                }
            }
            """
        let refusals = try await Self.refusals(code, type: "Desk")
        #expect(
            refusals == [
                "type 'Desk.Report' does not conform to protocol 'Codable'",
                "type 'Desk.Answer' does not conform to protocol 'Codable'",
            ], "\(refusals)")
    }

    /// What isn't the actor's own to send, private, isn't held to it; what it holds always is.
    @Test func privateMethodsArentSent() async throws {
        let code = """
            actor Desk {
                private var cache: [String: Int] = [:]

                private func pair() -> (Int, Int) {
                    (1, 2)
                }

                func total() -> Int {
                    let (first, second) = pair()
                    return first + second
                }
            }
            """
        #expect(try await Self.refusals(code, type: "Desk").isEmpty)
    }

    /// A dictionary keyed by any `Codable` type is carried as `Codable` writes it.
    @Test func aDictionaryIsKeyedByAnyCodableType() async throws {
        let code = """
            actor Scores {
                var byRound: [Int: Int] = [:]
                var byWin: [Bool: Int] = [:]
            }
            """
        #expect(try await Self.refusals(code, type: "Scores").isEmpty)
    }

    /// An object it holds lasts, as a virtual actor, so what it holds still reaches it after a
    /// restart; one that doesn't goes within a call.
    @Test func anObjectItHoldsLasts() async throws {
        let uses = Uses(
            interface: ModuleInterface(
                name: Uses.module,
                source:
                    "actor Website {\n    func show(text: String) async throws\n}\n\nactor Ledger {\n    init(id: String)\n    func total() async throws -> Int\n}"
            ),
            objects: [ObjectIdentity(rawValue: "ledger"): "Ledger"], lasting: ["Ledger"])
        let code = """
            actor Desk {
                let ledger = Ledger(id: "ledger")
                var shown: [Website] = []

                func show(on site: Website) async throws -> Website {
                    try await site.show(text: "\\(try await ledger.total())")
                    return site
                }
            }
            """
        let refusals = await ScriptInstance.problems(in: try Script(code: code, type: "Desk", uses: uses)).map(
            \.message)
        #expect(
            refusals == ["stored property 'shown' of type '[Website]' holds 'Website', an object whose id doesn't last"],
            "\(refusals)")
    }

    /// Objects go as references, and the values Swift and Foundation make `Codable` go as they are.
    @Test func objectsAndCodableValuesAreSent() async throws {
        let code = """
            import Foundation

            actor Clerk {}

            actor Desk {
                let clerk = Clerk()
                var seen: Set<String> = []
                var at: [String: Date] = [:]
                var ids: [UUID] = []

                func hand(to clerk: Clerk, amount: Decimal?) -> URL? {
                    nil
                }
            }
            """
        #expect(try await Self.refusals(code, type: "Desk").isEmpty)
    }
}
