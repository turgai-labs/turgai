import DiscoverableActors
import Distributed
import DistributedCluster

/// An object that runs an ``ObjectSpec`` instead of compiled Swift: it describes itself
/// from the spec, keeps its properties, and runs its actions' steps. To other objects and
/// to models, it's an object like any other.
///
/// It doesn't look for or listen to anything itself. Properties can hold references to the
/// objects it works with, given when it's created, and whoever subscribes it to an event
/// names the action that receives it.
public distributed actor DynamicObject: DiscoverableActor {
    public typealias ActorSystem = ClusterSystem

    private let spec: ObjectSpec
    private var values: [String: JSONValue]

    /// - Parameter values: Property values to start with instead of the spec's initial ones,
    ///   such as references to the objects it works with.
    public init(
        actorSystem: ActorSystem,
        spec: ObjectSpec,
        values: [String: JSONValue] = [:],
        scope: ObjectScope
    ) async throws {
        try spec.validate()
        self.actorSystem = actorSystem
        self.spec = spec
        self.values = spec.properties.mapValues(\.initial).merging(values) { _, given in given }
        let object = try DiscoverableObject.resolve(id: self.id, using: actorSystem)
        await actorSystem.receptionist.checkIn(object, with: scope.receptionistKey)
    }

    // MARK: DiscoverableActor
    //
    // Every requirement is implemented `async`: a sync implementation can be bypassed by the
    // library's async `invoke` overloads (https://github.com/swiftlang/swift/issues/92795).

    public distributed func describe() async -> ObjectDescription {
        var properties: [String: JSONValue] = [:]
        for (name, property) in spec.properties {
            guard case .object(var schema) = property.schema else { continue }
            if let description = property.description { schema["description"] = .string(description) }
            schema["readOnly"] = true
            properties[name] = .object(schema)
        }
        return ObjectDescription(
            title: spec.title,
            description: spec.description,
            properties: properties,
            actions: spec.actions.mapValues { ObjectAction(description: $0.description, input: $0.input) }
        )
    }

    @discardableResult
    public distributed func invoke(_ action: String, arguments: JSONValue) async throws -> JSONValue {
        guard let found = spec.actions[action] else { throw DiscoveryError.unknownAction(action) }
        try Self.check(arguments, against: found.input)
        return try await run(found.steps, arguments: arguments)
    }

    public distributed func read(property name: String) async throws -> JSONValue {
        guard let value = values[name] else { throw DiscoveryError.unknownProperty(name) }
        return value
    }

    public distributed func subscribeEvent(_ event: String, listener: ActorReference, action: String) async throws {
        throw DiscoveryError.unknownEvent(event)
    }

    public distributed func unsubscribeEvent(_ event: String, listener: ActorReference) async throws {
        throw DiscoveryError.unknownEvent(event)
    }

    // MARK: Running steps

    private func run(_ steps: [ObjectSpec.Step], arguments: JSONValue) async throws -> JSONValue {
        var context: [String: JSONValue] = ["arguments": arguments]
        for step in steps {
            context["properties"] = .object(values)
            switch step {
            case .set(let property, let value):
                values[property] = try Self.evaluate(value, in: context)
            case .append(let property, let value):
                guard case .array(var items)? = values[property] else { throw DynamicObjectError.notAnArray(property) }
                items.append(try Self.evaluate(value, in: context))
                values[property] = .array(items)
            case .call(let property, let action, let arguments):
                let object = try reference(in: property)
                let evaluated = try arguments.mapValues { try Self.evaluate($0, in: context) }
                context["result"] = try await object.invoke(action, arguments: .object(evaluated))
            case .return(let value):
                return try Self.evaluate(value, in: context)
            }
        }
        return nil
    }

    /// The object a property refers to.
    private func reference(in property: String) throws -> DiscoverableObject {
        guard let value = values[property], value != .null else { throw DynamicObjectError.noReference(property) }
        do {
            return try value.decode(ActorReference.self).resolve(using: actorSystem)
        } catch {
            throw DynamicObjectError.noReference(property)
        }
    }

    private static func evaluate(_ value: ObjectSpec.Value, in context: [String: JSONValue]) throws -> JSONValue {
        switch value {
        case .literal(let json):
            return json
        case .from(let path):
            var current: JSONValue = .object(context)
            for key in path {
                guard let next = current[key] else { throw DynamicObjectError.missingValue(path.joined(separator: ".")) }
                current = next
            }
            return current
        }
    }

    /// Required arguments are present and nothing else is passed.
    private static func check(_ arguments: JSONValue, against schema: JSONValue?) throws {
        let given: [String: JSONValue] = if case .object(let members) = arguments { members } else { [:] }
        let known: Set<String> = if case .object(let properties)? = schema?["properties"] { Set(properties.keys) } else { [] }
        if let extra = given.keys.sorted().first(where: { !known.contains($0) }) {
            throw DiscoveryError.unexpectedArgument(extra)
        }
        if case .array(let required)? = schema?["required"] {
            for case .string(let name) in required where given[name] == nil || given[name] == .null {
                throw DiscoveryError.missingArgument(name)
            }
        }
    }
}

public enum DynamicObjectError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case noReference(String)
    case notAnArray(String)
    case missingValue(String)

    public var description: String {
        switch self {
        case .noReference(let property): "\(property) doesn't hold a reference to an object."
        case .notAnArray(let property): "\(property) isn't a list, so nothing can be appended to it."
        case .missingValue(let path): "There's no value at \(path)."
        }
    }
}
