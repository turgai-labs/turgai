import DiscoverableActors
import Foundation
import Hail
import Testing
import TurgaiObjects

@testable import TurgaiApplication
@testable import TurgaiSpaces

/// An action's tool, as the model meets it: every argument its code takes can be written, and
/// reaches the object as its code takes it.
struct ObjectActionSchemaTests {
    /// A dictionary has no shape a tool's schema can name, so the model writes its pairs, and the
    /// object is given the dictionary.
    @Test func aDictionaryIsWrittenAsItsPairs() async throws {
        let code = """
            actor Forecaster {
                struct Forecast: Codable {
                    var units: [String: String]?
                    var hours: [Int: Double]
                }

                func summary(_ forecast: Forecast, place: String) -> String {
                    let unit = forecast.units?["temperature"] ?? "?"
                    let hours = forecast.hours.keys.sorted().map { "\\($0): \\(forecast.hours[$0]!)\\(unit)" }
                    return place + " " + hours.joined(separator: ", ")
                }
            }
            """
        let script = try Script(code: code, type: "Forecaster")
        let input = try #require(try script.spec(description: nil).actions["summary"]?.input)
        // The tool's schema can be read as one.
        _ = try ObjectActionTool.parameters(input)
        let written = ObjectActionTool.handles(in: input)
        #expect(written["properties"]?["forecast"]?["properties"]?["units"]?["type"] == "array")
        // What the model writes: each dictionary as its pairs.
        let arguments: DiscoveryJSON = [
            "place": "Vienna",
            "forecast": [
                "units": [["key": "temperature", "value": "°C"]],
                "hours": [["key": 9, "value": 4.5], ["key": 8, "value": 3.0]],
            ],
        ]
        let given = try ObjectActionTool.dictionaries(in: arguments, as: input, for: "forecaster_summary")
        let instance = try await ScriptInstance.start(
            script, as: ObjectIdentity(rawValue: "forecaster"),
            reaches: { _, _ in .null },
            makes: { type, _ in throw CodeProblem("\(type) isn't made here") },
            tools: { function, _ in throw CodeProblem("\(function) isn't here") }, schedules: { _ in },
            cancels: { _ in })
        #expect(
            try await instance.handle("summary", arguments: given).reply == "Vienna 8: 3.0°C, 9: 4.5°C")
        // A pair without its value isn't a pair.
        #expect(throws: ObjectToolError.self) {
            try ObjectActionTool.dictionaries(
                in: ["place": "Vienna", "forecast": ["hours": [["key": 9]]]], as: input, for: "forecaster_summary")
        }
    }
}
