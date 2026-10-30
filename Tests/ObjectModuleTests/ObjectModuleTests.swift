import DoppelCompilerCheck
import Foundation
import Testing

@testable import TurgaiObjects

/// What Turgai gives an object's code, as Swift: for every object written so far, the module it
/// imports and its runtime compile, so Swift checks the code itself against them.
///
/// With `SWIFT_CORPUS_EXPORT` set to a directory, each object's module is written there as plain
/// Swift files, for Doppel to hold its own checking to Swift's.
@Suite("The Swift module Turgai gives code")
struct ObjectModuleTests {
    @Test func whatTheCodeIsGivenCompiles() throws {
        let compiler = try SwiftCompiler()
        var checked: Set<[ObjectModule.File]> = []
        for (name, script) in try Self.corpus() {
            let module = ObjectModule(script)
            if checked.insert(module.given).inserted {
                let refused = try compiler.typecheck(module.given.map { .init(name: $0.name, code: $0.code) })
                    .filter { $0.severity == .error }
                #expect(refused.isEmpty, "\(name): what its code is given doesn't compile: \(refused)")
            }
            if let export = ProcessInfo.processInfo.environment["SWIFT_CORPUS_EXPORT"] {
                let directory = URL(fileURLWithPath: export).appendingPathComponent(name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for file in module.files {
                    try file.code.write(
                        to: directory.appendingPathComponent(file.name), atomically: true, encoding: .utf8)
                }
            }
        }
    }

    @Test("an @Event type is announced by its actor, and both attributes stay as written, on the lines they're written")
    func macrosExpandOnTheirLines() {
        let code =
            "actor Counter {\n    @Subscribed var shop = Shop(id: \"shop\")\n    @Event struct Added {\n        var count: Int\n    }\n}"
        #expect(
            ObjectModule.expanded(code, type: "Counter")
                == "actor Counter { init(id: String) {}; func announce(_ event: Added) { __announce(\"Added\", event) };\n    @Subscribed var shop = Shop(id: \"shop\")\n    @Event struct Added: Codable {\n        var count: Int\n    }\n}"
        )
    }

    /// The written objects, each with what it was written against.
    static func corpus() throws -> [(String, Script)] {
        let directory = try #require(Bundle.module.url(forResource: "Corpus", withExtension: nil))
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map {
                (
                    $0.deletingPathExtension().lastPathComponent,
                    try JSONDecoder().decode(Script.self, from: Data(contentsOf: $0))
                )
            }
    }
}
