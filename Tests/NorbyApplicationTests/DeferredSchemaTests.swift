import AnyLanguageModel
import Testing

@testable import NorbyApplication

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct DeferredSchemaTests {
    @Test
    func deferredEnumConstraintsMatchTheirDecoders() throws {
        for schema in [
            TimerToolsCreateInput.generationSchema,
            TimerToolsReplaceInput.generationSchema,
            ScheduleToolsCreateInput.generationSchema,
            ScheduleToolsReplaceInput.generationSchema,
        ] {
            let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any])
            let definitions = json["$defs"] as? [String: Any] ?? [:]
            func resolve(_ value: Any?) throws -> [String: Any] {
                let object = try #require(value as? [String: Any])
                if let reference = object["$ref"] as? String {
                    let key = try #require(reference.split(separator: "/").last)
                    return try resolve(definitions[String(key)])
                }
                return object
            }
            let root = try resolve(json)
            let properties = try #require(root["properties"] as? [String: Any])
            let action = try resolve(properties["action"])
            #expect(action["enum"] != nil || action["anyOf"] != nil)
            if let trigger = properties["trigger"] {
                let fields = try #require(try resolve(trigger)["properties"] as? [String: Any])
                #expect(fields["kind"] != nil)
                #expect(fields["unit"] != nil)
            }
            if let recurrence = properties["recurrence"] {
                let fields = try #require(try resolve(recurrence)["properties"] as? [String: Any])
                #expect(fields["frequency"] != nil)
                let weekdays = try resolve(fields["weekdays"])
                #expect(weekdays["items"] != nil)
            }
        }
    }

    @Test
    func deferredToolsHaveSeparateNonUnionSchemas() throws {
        let definitions: [(String, GenerationSchema)] = [
            ("timer_create", TimerToolsCreateInput.generationSchema),
            ("timer_replace", TimerToolsReplaceInput.generationSchema),
            ("timer_cancel", TimerToolsCancelInput.generationSchema),
            ("timer_list", TimerToolsListInput.generationSchema),
            ("schedule_create", ScheduleToolsCreateInput.generationSchema),
            ("schedule_replace", ScheduleToolsReplaceInput.generationSchema),
            ("schedule_cancel", ScheduleToolsCancelInput.generationSchema),
            ("schedule_list", ScheduleToolsListInput.generationSchema),
            ("schedule_trigger", ScheduleToolsTriggerInput.generationSchema),
        ]
        for (name, schema) in definitions {
            let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any])
            #expect(json["anyOf"] == nil, "\(name) must not expose an operation union")
            let root: [String: Any]
            if let reference = json["$ref"] as? String {
                let definitions = try #require(json["$defs"] as? [String: Any])
                let key = String(try #require(reference.split(separator: "/").last))
                root = try #require(definitions[key] as? [String: Any])
            } else {
                root = json
            }
            let properties = try #require(root["properties"] as? [String: Any])
            #expect(properties["operation"] == nil, "\(name) must not expose a polymorphic operation field")
        }
    }
}
