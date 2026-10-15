import AnyLanguageModel
import DiscoverableActors
import DistributedCluster
import Hail
import TurgaiDomain
import SwiftScriptInterpreter
import TurgaiObjects
import Yams

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Discovery's DiscoveryJSON; AnyLanguageModel has its own `JSONValue`.
typealias DiscoveryJSON = DiscoverableActors.JSONValue

/// The objects a model has met during one turn, behind readable handles such as
/// `mac` or `reminder-list-2`.
///
/// The model never sees actor IDs, so it can only use objects it was given:
/// the directory's roots and whatever their actions return. A handle points at
/// one incarnation of an object; when that object stops, the model lists again
/// and walks back to it.
public actor ObjectSession {
    let actorSystem: ClusterSystem
    private var objectCatalog: ObjectCatalog?
    let scopes: [ObjectScope]

    private var objects: [String: DiscoverableObject] = [:]
    private var handles: [ClusterSystem.ActorID: String] = [:]
    /// How many handles each kind of object has, to number the second one on.
    private var kinds: [String: Int] = [:]
    /// What the current result named, in order: its links are their tools.
    private var named: [Named] = []
    /// The objects made here that this session has met, by handle.
    private var made: [String: DynamicObject] = [:]
    /// What the last action's object printed handling it.
    private(set) var printed: [String] = []

    /// Something a result names, whose tools it links to.
    private enum Named: Equatable {
        /// A reference to an object: following it opens the object's first page.
        case object(String)
        /// An open object's contents: its actions and current values, and removing it.
        case objectContents(String)
        /// One action of an object, such as the shop's `startShift`.
        case action(String, String)
    }

    /// Writes an object's Swift from what it should do, in a session of its own.
    let writer: ObjectWriter?
    /// What the person asked for in the turn this session serves: an object's writer sees it, as
    /// whoever writes one part of something sees what the whole is for.
    let request: String?

    public init(
        actorSystem: ClusterSystem,
        objectCatalog: ObjectCatalog? = nil,
        scopes: [ObjectScope],
        writer: ObjectWriter? = nil,
        request: String? = nil
    ) {
        self.actorSystem = actorSystem
        self.objectCatalog = objectCatalog
        self.scopes = scopes
        self.writer = writer
        self.request = request
    }

    /// The directory's roots, with handles, titles, and descriptions.
    func list() async throws -> DiscoveryJSON {
        .array(
            try await entries().map { entry in
                [
                    "handle": .string(handle(for: entry.object, titled: entry.title)),
                    "title": .string(entry.title),
                    "description": entry.description.map(DiscoveryJSON.string) ?? .null,
                    "actions": .array(entry.actions.map(DiscoveryJSON.string)),
                    "events": .array(entry.events.map(DiscoveryJSON.string)),
                ]
            })
    }

    /// The roots that best match `query`, so a model doesn't read the whole directory.
    ///
    /// Each query word that starts a word of a root's title counts twice, and of its
    /// description once, so "reminder" matches "Reminders". Short and filler words are
    /// ignored, and roots that match nothing are left out.
    func find(_ query: String, limit: Int = 5) async throws -> DiscoveryJSON {
        guard case .array(let entries) = try await list() else { return [] }
        func text(_ value: DiscoveryJSON?) -> String {
            if case .string(let text)? = value { text } else { "" }
        }
        let documents = entries.map { entry in
            let actions: String
            if case .array(let names)? = entry["actions"] {
                actions = names.map { text($0) }.joined(separator: " ")
            } else {
                actions = ""
            }
            return ObjectSearchIndex.Document(
                handle: text(entry["handle"]),
                title: text(entry["title"]),
                actions: actions,
                description: text(entry["description"])
            )
        }
        let ranked = ObjectSearchIndex(documents).search(query, limit: limit).compactMap { match in
            entries.first { text($0["handle"]) == match.handle }
        }
        for entry in ranked { if case .string(let handle)? = entry["handle"] { link(.object(handle)) } }
        return .array(Array(ranked))
    }

    /// Every object there is, by name only, so a long list stays short: the ones made for the
    /// agent's owner, then the others. What one holds and takes is its own tool, a call away.
    func listMade() async throws -> String {
        let yours = try await runtimeObjects().sorted()
        let others = try await entries().map { handle(for: $0.object, titled: $0.title) }.filter { !yours.contains($0) }.sorted()
        for handle in yours + others { link(.object(handle)) }
        var lines: [String] = []
        if !others.isEmpty { lines.append("Objects: " + others.joined(separator: ", ") + ".") }
        lines.append(
            yours.isEmpty
                ? "None made for you yet: create_object makes one."
                : "Made for you: " + yours.joined(separator: ", ") + ".")
        return lines.joined(separator: "\n")
    }

    /// Your objects, to choose from.
    func yourObjects() async throws -> [String] {
        try await runtimeObjects().sorted()
    }

    /// The objects made in this session's scopes and out in the runtime, by handle.
    private func runtimeObjects() async throws -> [String] {
        // Made here a moment ago, before the runtime lists it, or listed by the runtime.
        var out = Array(made.values)
        for scope in scopes {
            out += await actorSystem.receptionist.lookup(scope.madeObjectsKey)
        }
        return try await names(of: out)
    }

    /// The handles of `objects`, once each, sorted, as they'll be called by this session.
    private func names(of objects: [DynamicObject]) async throws -> [String] {
        var seen: Set<ClusterSystem.ActorID> = []
        var names: [String] = []
        for object in objects where seen.insert(object.id).inserted {
            let discoverable = try DiscoverableObject.resolve(id: object.id, using: actorSystem)
            guard let description = try? await discoverable.describe() else { continue }
            let handle = handle(for: discoverable, titled: description.title)
            made[handle] = object
            names.append(handle)
        }
        return names.sorted()
    }

    /// An object's properties and actions, with actor references shown as handles.
    func describe(_ handle: String) async throws -> DiscoveryJSON {
        let description = try await described(handle)
        return Self.presentingReferences(try DiscoveryJSON(encoding: description))
    }

    /// Runs an action. The Mac's objects are guarded by macOS's own permissions,
    /// which ask the user the first time an app is used; Turgai doesn't ask again.
    func invoke(_ handle: String, action name: String, arguments text: String?) async throws -> DiscoveryJSON {
        do {
            let result = try await perform(handle, action: name, arguments: text)
            actorSystem.log.info(
                "Object call",
                metadata: ["handle": .string(handle), "action": .string(name), "arguments": .string(text ?? "")]
            )
            return result
        } catch {
            actorSystem.log.info(
                "Object call failed",
                metadata: [
                    "handle": .string(handle), "action": .string(name), "arguments": .string(text ?? ""),
                    "error": .string(String(describing: error)),
                ]
            )
            throw error
        }
    }

    /// What an object says it is and does.
    func described(_ handle: String) async throws -> ObjectDescription {
        try await call(handle) { try await $0.describe() }
    }

    private func perform(_ handle: String, action name: String, arguments text: String?) async throws -> DiscoveryJSON {
        let description = try await described(handle)
        guard let action = description.actions[name] else {
            throw ObjectToolError.unknownAction(name, on: handle, available: description.actions.keys.sorted())
        }
        let given = try Self.arguments(text, schema: action.input)
        let missing = Self.missingArguments(given, schema: action.input)
        guard missing.isEmpty else {
            throw ObjectToolError.missingArguments(
                "\(description.title).\(name)", missing: missing,
                unexpected: Self.unexpectedArguments(given, schema: action.input))
        }
        let arguments = try await translate(given, schema: action.input, reference: resolveHandle)
        let result: DiscoveryJSON
        do {
            if let made = try await madeObject(handle) {
                let answer = try await call(handle) { _ in try await made.respond(name, arguments: arguments) }
                printed = answer.printed
                result = answer.reply
            } else {
                printed = []
                result = try await call(handle) { try await $0.invoke(name, arguments: arguments) }
            }
        } catch DiscoveryError.invalidArgument(let argument, let reason) {
            throw ObjectToolError.invalidArgument(
                "\(description.title).\(name)", argument: argument,
                reason: Self.explanation(of: reason, for: argument, given: given, schema: action.input),
                usage: action.description)
        }
        return try await translate(result, schema: action.output, reference: mintHandle)
    }

    /// Reads a property, with actor references shown as handles.
    func read(_ handle: String, property: String) async throws -> DiscoveryJSON {
        let description = try await described(handle)
        let value = try await call(handle) { try await $0.read(property: property) }
        return try await translate(value, schema: description.properties[property], reference: mintHandle)
    }

    // MARK: Handles

    /// A handle named after the object's title, such as `reminder-list` for ReminderList or
    /// `refund-manager` for "Refund manager", numbered from the second one on.
    private func handle(for object: DiscoverableObject, titled title: String) -> String {
        if let handle = handles[object.id] { return handle }
        let kind = Self.kind(of: title)
        let count = kinds[kind, default: 0] + 1
        kinds[kind] = count
        let handle = count == 1 ? kind : "\(kind)-\(count)"
        objects[handle] = object
        handles[object.id] = handle
        return handle
    }

    /// The object's kind in kebab case, such as `reminder-list`, from its actor name
    /// (`ReminderList-b`): the cluster names an actor after its type, then a dash and a
    /// unique suffix. Type names can't contain a dash, so the suffix starts at the first one.
    static func kind(of title: String) -> String {
        ObjectNames.handle(for: title)
    }

    /// The roots this session can see, from the cluster receptionist, in the same
    /// order every time, so each gets the same handle in every session, including the
    /// summary shown to the model.
    private func entries() async throws -> [ObjectEntry] {
        if objectCatalog == nil { objectCatalog = await ObjectCatalog(actorSystem: actorSystem) }
        guard let objectCatalog else { return [] }
        return try await objectCatalog.entries(in: scopes)
    }

    /// The object behind `handle`. A root's handle works without listing first, since
    /// the model may know it from the turn's summary.
    /// The object behind `handle`, ignoring case: handles are lowercase, and models often
    /// capitalize names, such as `Ann` for `ann`.
    private func object(_ handle: String) async throws -> DiscoverableObject {
        let handle = handle.lowercased()
        if let object = objects[handle] { return object }
        for entry in try await entries() { _ = self.handle(for: entry.object, titled: entry.title) }
        guard let object = objects[handle] else { throw ObjectToolError.unknownHandle(handle) }
        return object
    }

    // MARK: Making objects

    /// Makes an object named `name` that does `task`: its Swift is written in a session of its
    /// own, whose answer is the code, until it's saved. Code that's never saved makes nothing.
    func make(_ name: String, described task: String) async throws -> CallReturn {
        if let existing = try await madeObject(named: name) {
            throw ObjectToolError.failed("`\(existing.handle)` already exists: change it with edit_object.")
        }
        guard let writer else { throw ObjectToolError.failed("Objects can't be written here.") }
        let type = Self.typeName(of: name)
        var handle: String?
        let others = await others(except: type)
        let outcome = try await writer.write(
            type: type, task: task, current: nil, others: others.declarations, values: others.uses.valuesInWords, request: request
        ) { code in
            do {
                let source = try Script(code: code, type: type, uses: others.uses)
                let problems = await ScriptInstance.problems(in: source)
                guard problems.isEmpty else { return problems.map { $0.written(in: code) }.joined(separator: "\n") }
                if let made = handle { try await self.replace(made, with: source) } else { handle = try await self.create(name, described: task, spec: .new(source)) }
                return nil
            } catch let problem as CodeProblem {
                return problem.written(in: code)
            } catch {
                return Self.problem(error)
            }
        }
        // What went wrong with the code stays with its writer: what's said here is what can be
        // done about it, which is asking again.
        switch outcome {
        case .saved: break
        case .failed: throw ObjectToolError.failed("\(name) wasn't made: its code couldn't be written from this description.")
        // What it's asked to do has no answer its writer could find: that's for whoever asked.
        case .ranOut: throw ObjectToolError.failed("\(name) wasn't made: its writer found no way to do what it's asked.")
        }
        guard let handle else { throw ObjectToolError.failed("\(name) wasn't made: its code couldn't be written from this description.") }
        let shape = try? ObjectShape(try await dynamicObject(handle).source)
        return landing("Saved \(handle): \(Self.contents(of: shape, now: try await currentValues(handle))).", on: .object(handle: handle))
    }

    /// Changes an object made here as `change` says: its Swift is rewritten in a session of its
    /// own, from its code now, until it's saved. A change that's never saved leaves it as it was.
    func edit(_ handle: String, change: String) async throws -> CallReturn {
        let object = try await dynamicObject(handle)
        guard let writer else { throw ObjectToolError.failed("Objects can't be written here.") }
        let current = try await object.source
        let before = try? ObjectShape(current)
        let others = await others(except: current.type)
        let failure = if case .failing(let failure) = try await object.health { failure.written } else { String?.none }
        let outcome = try await writer.write(
            type: current.type, task: change, current: current.code, failure: failure, others: others.declarations,
            values: others.uses.valuesInWords, request: request
        ) { code in
            do {
                let source = try Script(code: code, type: current.type, uses: others.uses)
                let problems = await ScriptInstance.problems(in: source)
                guard problems.isEmpty else { return problems.map { $0.written(in: code) }.joined(separator: "\n") }
                try await self.replace(handle, with: source)
                return nil
            } catch let problem as CodeProblem {
                return problem.written(in: code)
            } catch {
                return Self.problem(error)
            }
        }
        switch outcome {
        case .saved: break
        case .failed: throw ObjectToolError.failed("\(handle) wasn't changed: the code for this change couldn't be written.")
        case .ranOut: throw ObjectToolError.failed("\(handle) wasn't changed: its writer found no way to make this change.")
        }
        let after = try? ObjectShape(try await object.source)
        return landing("Saved \(handle): \(Self.changes(from: before, to: after, now: try await currentValues(handle))).", on: .object(handle: handle))
    }

    /// The objects that exist here but `type`, as code written here meets them: one spec, read
    /// from each object's description, which the code imports, and which the writer is told in
    /// words, so what it's told is what its code is checked and run against.
    struct Others {
        /// Each object in a few lines: the name code reaches it by and its type, what it is, its
        /// methods, what it publishes and its events. Words, never code to copy.
        var declarations: [String] = []
        /// The spec, as the module the code imports, and the names objects are reached by.
        var uses = Uses.nothing
    }

    func others(except type: String) async -> Others {
        var handles = Set((try? await runtimeObjects()) ?? [])
        for entry in (try? await entries()) ?? [] { handles.insert(handle(for: entry.object, titled: entry.title)) }
        var objects: [Uses.Object] = []
        var names: [String: String] = [:]
        var summaries: [String: String] = [:]
        var descriptions: [String: ObjectDescription] = [:]
        for handle in handles.sorted() where Self.typeName(of: handle) != type {
            guard let description = try? await object(handle).describe() else { continue }
            let typeName = Self.typeName(of: handle)
            // What it publishes is read, never written. An object made here is only asked, through
            // its functions; what it holds is its own.
            objects.append(Uses.Object(type: typeName, description: description, publishes: (try? await madeObject(handle)) == nil))
            names[Self.valueName(of: handle)] = typeName
            summaries[typeName] = Self.given(description.description)
            descriptions[typeName] = description
        }
        // Kinds no object runs yet: what an object made with `Type()` will be, reached by no name.
        for (kindType, description) in ((try? await making { try await $0.unmadeKinds() }) ?? [:]).sorted(by: { $0.key < $1.key })
        where kindType != type && !objects.contains(where: { $0.type == kindType }) {
            objects.append(Uses.Object(type: kindType, description: description, publishes: false))
            summaries[kindType] = Self.given(description.description)
        }
        let interface = Uses.interface(of: objects)
        var others = Others(uses: Uses(interface: interface, names: names))
        // In words, from the spec itself.
        for actor in interface.actors(events: [RuntimeMacros.event]) {
            let name = names.first { $0.value == actor.name }?.key ?? actor.name
            var declaration = ["- \(name): \(actor.name)"]
            if let summary = summaries[actor.name] { declaration.append("  \(summary).") }
            // Each with what its parameters are, as its object says, in words.
            let takes = actor.methods.sorted { $0.key < $1.key }.map { name, method in
                ([Self.written(name, method)] + Self.parameterWords(descriptions[actor.name]?.actions[name]?.input)).joined(separator: "\n")
            }
            if !takes.isEmpty { declaration.append("  Methods:\n" + takes.map { "    \($0)" }.joined(separator: "\n")) }
            let publishes = actor.properties.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value) { get async throws }" }
            if !publishes.isEmpty {
                declaration.append("  Properties:\n" + publishes.map { "    \($0)" }.joined(separator: "\n"))
            }
            let announces = actor.events.sorted { $0.key < $1.key }.map { Self.written(DynamicObject.handler(for: $0.key), $0.value) }
            if !announces.isEmpty {
                declaration.append("  Events, each received by a function of this name:\n" + announces.map { "    \($0)" }.joined(separator: "\n"))
            }
            others.declarations.append(declaration.joined(separator: "\n"))
        }
        return others
    }

    /// What each parameter of an action is, one to a line under it, as its object says.
    static func parameterWords(_ input: DiscoveryJSON?) -> [String] {
        guard case .object(let properties)? = input?["properties"] else { return [] }
        return Uses.parameters(of: input).compactMap { parameter in
            guard case .string(let text)? = properties[parameter.name]?["description"], !text.isEmpty else { return nil }
            return "      \(parameter.name): \(text)"
        }
    }

    /// A method as Swift declares it: `show(page: Page)`, `approve(_ amount: Int) -> Bool`.
    static func written(_ name: String, _ method: CheckedMethod) -> String {
        let parameters = method.parameters.map { parameter in
            let called = parameter.label == parameter.name ? parameter.name : "\(parameter.label ?? "_") \(parameter.name)"
            return "\(called): \(parameter.type ?? "Any")"
        }
        return "\(name)(\(parameters.joined(separator: ", ")))" + (method.effects.map { " \($0)" } ?? "")
            + (method.returns.map { " -> \($0)" } ?? "")
    }

    /// How code names the object with `handle`: `trip-planner` is `tripPlanner`, as a Swift value.
    static func valueName(of handle: String) -> String {
        let words = handle.split(separator: "-")
        guard let first = words.first else { return handle }
        return first.lowercased() + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// An object made here, now running `source`, and every object sharing its code.
    private func replace(_ handle: String, with source: Script) async throws {
        let identity = try await dynamicObject(handle).identity
        try await making { try await $0.update(identity, source: source) }
        try await catalogue(handle)
    }

    /// What an edit changed, in a line: the messages it now takes or no longer takes, and the data
    /// it now holds, with its value, or no longer holds.
    static func changes(from before: ObjectShape?, to after: ObjectShape?, now values: [String: DiscoveryJSON]) -> String {
        let old = Set(before?.messages.map(\.written) ?? []), new = after?.messages.map(\.written) ?? []
        let oldData = Set(before?.fields.map(\.name) ?? []), newData = after?.fields.map(\.name) ?? []
        var parts: [String] = []
        let takes = new.filter { !old.contains($0) }
        if !takes.isEmpty { parts.append("it now takes " + takes.joined(separator: ", ")) }
        let gone = (before?.messages.map(\.written) ?? []).filter { !new.contains($0) }
        if !gone.isEmpty { parts.append("it no longer takes " + gone.joined(separator: ", ")) }
        let holds = newData.filter { !oldData.contains($0) }.map { "\($0): \((values[$0] ?? .null).inline)" }
        if !holds.isEmpty { parts.append("it now holds " + holds.joined(separator: ", ")) }
        let dropped = (before?.fields.map(\.name) ?? []).filter { !newData.contains($0) }
        if !dropped.isEmpty { parts.append("it no longer holds " + dropped.joined(separator: ", ")) }
        return parts.isEmpty ? "what it holds and takes didn't change" : parts.joined(separator: "; ")
    }

    /// What an object is, in a line, as an edit's changes are said: the data it holds, with its
    /// values, and the messages it takes.
    static func contents(of shape: ObjectShape?, now values: [String: DiscoveryJSON]) -> String {
        var parts: [String] = []
        let holds = (shape?.fields.map(\.name) ?? []).map { "\($0): \((values[$0] ?? .null).inline)" }
        if !holds.isEmpty { parts.append("it holds " + holds.joined(separator: ", ")) }
        let takes = shape?.messages.map(\.written) ?? []
        if !takes.isEmpty { parts.append("it takes " + takes.joined(separator: ", ")) }
        return parts.isEmpty ? "it holds and takes nothing" : parts.joined(separator: "; ")
    }

    /// What's wrong with code, as the writer reads it.
    static func problem(_ error: any Error) -> String {
        if let error = error as? ObjectToolError, case .failed(let message) = error {
            return message.hasPrefix("Not saved: ") ? String(message.dropFirst("Not saved: ".count)) : message
        }
        return String(describing: error)
    }

    /// The actor's type for an object's name, from its handle, so every spelling of one object
    /// meets there: `coffee counter`, `coffee-counter` and `coffeeCounter` are `CoffeeCounter`.
    static func typeName(of name: String) -> String {
        let type = ObjectNames.handle(for: name).split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return type.first?.isLetter == true ? type : "Object" + type
    }

    /// Makes an object, linking its tools; returns its handle.
    private func create(_ name: String, described description: String? = nil, spec: Spec) async throws -> String {
        let identity = try await making { try await $0.create(name: name, description: description, spec: spec) }
        // The reference it checks in under, so searching for it later finds the same handle.
        let object = try await DynamicObject.resolve(on: actorSystem, identity: identity).stableReference
        actorSystem.log.info("Created object", metadata: ["name": .string(name)])
        let handle = handle(for: try DiscoverableObject.resolve(id: object.id, using: actorSystem), titled: name)
        made[handle] = object
        try await catalogue(handle)
        return handle
    }

    /// Records an object made or changed here in the catalog right away, so searching finds it
    /// as it is now, without waiting for the receptionist's listing.
    private func catalogue(_ handle: String) async throws {
        if objectCatalog == nil { objectCatalog = await ObjectCatalog(actorSystem: actorSystem) }
        try await objectCatalog?.record(try object(handle), in: .shared)
    }

    /// Runs `body`, with a typing error as the model reads it.
    static func reading<Result>(_ body: () throws -> Result) throws -> Result {
        do {
            return try body()
        } catch let error as BehaviorError {
            throw ObjectToolError.failed(error.description)
        }
    }

    /// An object's values now, all of them.
    func values(_ handle: String) async throws -> String {
        try Self.text(.object(try await currentValues(handle)))
    }

    /// An object's values now, by name, to say what an action changed.
    func values(of handle: String) async throws -> [String: DiscoveryJSON] {
        try await currentValues(handle)
    }

    /// An object's values now, by name.
    private func currentValues(_ handle: String) async throws -> [String: DiscoveryJSON] {
        let description = try await described(handle)
        var values: [String: DiscoveryJSON] = [:]
        for name in description.properties.keys {
            values[name] = try await read(handle, property: name)
        }
        return values
    }

    /// Uses one of your objects: what it holds now, with its actions as the tools it lands on.
    func use(_ handle: String) async throws -> CallReturn {
        let title = try await described(handle).title
        var lines = ["\(title) now:", try await values(handle)]
        if case .failing(let failure)? = try await madeObject(handle)?.health { lines.append("Last failed: \(failure.written)") }
        return landing(lines.joined(separator: "\n"), on: .object(handle: handle))
    }

    /// An object's first page: enough identity and state to choose an action. Its action schemas
    /// are linked from the page instead of repeated in its text.
    func open(_ handle: String) async throws -> String {
        let description = try await described(handle)
        var lines = ["\(description.title) (`\(handle)`)"]
        if let summary = Self.given(description.description) { lines.append(summary) }

        let current = try await values(handle)
        if current != "{}" { lines.append("Current values:\n" + current) }
        if case .failing(let failure)? = try await madeObject(handle)?.health { lines.append("Last failed: \(failure.written)") }

        if !description.actions.isEmpty {
            var actions: [String] = []
            for (name, action) in description.actions.sorted(by: { $0.key < $1.key }) {
                actions.append(
                    "- \(handle)_\(name)" + (Self.given(action.description).map { ": \($0)" } ?? ""))
            }
            lines.append("Actions:\n" + actions.joined(separator: "\n"))
        }
        link(.objectContents(handle))
        return lines.joined(separator: "\n\n")
    }

    /// The object made here that `name` is the handle of, written as its handle or as its name.
    /// A handle of an object made elsewhere can't be defined.
    private func madeObject(named name: String) async throws -> (handle: String, object: DynamicObject)? {
        for handle in [ObjectNames.handle(for: name), name] {
            guard (try? await object(handle)) != nil else { continue }
            return (handle, try await dynamicObject(handle))
        }
        return nil
    }

    /// Text that was given: `nil` for missing or blank.
    /// A description as given, without the full stop it ends with, for a line that goes on after
    /// it; `nil` when there's none.
    private static func given(_ text: String?) -> String? {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let given = text.hasSuffix(".") ? String(text.dropLast()) : text
        return given.isEmpty ? nil : given
    }

    /// The objects here as tools: each one's to read it, and each of its actions, the ones made for
    /// you first, then the rest.
    /// The tool list is the list of objects, all of them: a runtime too big for a model's context
    /// is one that model doesn't fit.
    public func objectTools() async -> [any HailCore.Tool] {
        var handles = (try? await yourObjects()) ?? []
        for entry in (try? await entries()) ?? [] {
            let handle = handle(for: entry.object, titled: entry.title)
            if !handles.contains(handle) { handles.append(handle) }
        }
        var tools: [any HailCore.Tool] = []
        for handle in handles {
            tools.append(await pageLink(handle))
            tools += await actionTools(of: handle, naming: .asObject)
        }
        return tools
    }

    /// The tool that reads an object: what it holds now, and what it takes, after which its actions
    /// are offered.
    private func pageLink(_ handle: String) async -> ObjectReadTool {
        ObjectReadTool(session: self, handle: handle, title: (try? await described(handle).title) ?? handle)
    }

    /// Removes an object made with create, for good.
    func remove(_ handle: String) async throws -> DiscoveryJSON {
        let identity = try await dynamicObject(handle).identity
        try await making { try await $0.remove(identity) }
        made[handle.lowercased()] = nil
        objects[handle.lowercased()] = nil
        return "removed"
    }

    /// Runs `body` on the directory where objects are made, with its errors as the model reads them.
    private func making<Result: Sendable>(_ body: (DynamicObjects) async throws -> Result) async throws -> Result {
        let directory = try await DynamicObjects.resolve(on: actorSystem, scope: .shared)
        do {
            return try await body(directory)
        } catch let error as CodeProblem {
            // Kept as it is, at its line, for whoever writes the code to read against it.
            throw error
        } catch let error as DynamicObjectsError {
            throw ObjectToolError.failed(error.description)
        } catch let error as DynamicObjectError {
            throw ObjectToolError.failed(error.description)
        }
    }

    /// The object behind `handle`, if it was made with create.
    /// The object behind `handle`, if it was made here: one checked in as what it is, so no other
    /// kind of object is ever called as one.
    private func dynamicObject(_ handle: String) async throws -> DynamicObject {
        guard let made = try await madeObject(handle) else {
            throw ObjectToolError.failed("`\(handle)` wasn't made with create_object, so it can't be changed or removed this way.")
        }
        return made
    }

    /// The object behind `handle` as one made here, or `nil` for any other kind of object.
    func madeObject(_ handle: String) async throws -> DynamicObject? {
        let handle = handle.lowercased()
        if let known = made[handle] { return known }
        let object = try await object(handle)
        for scope in scopes {
            for candidate in await actorSystem.receptionist.lookup(scope.madeObjectsKey) where candidate.id == object.id {
                made[handle] = candidate
                return candidate
            }
        }
        return nil
    }

    // MARK: Actions as tools

    /// Notes that the current result names an object, which links its tools.
    private func link(_ named: Named) {
        if !self.named.contains(named) { self.named.append(named) }
    }

    /// A result on an object's page: what it did, landed on the object. What it named is the
    /// page's to link, so it's let go.
    func landing(_ text: String, on address: ObjectAddress) -> CallReturn {
        named = []
        return .text(text, landing: address.address)
    }

    /// An object as it is now, to use: what it holds, and its actions.
    func usingPage(of handle: String) async throws -> ToolPage {
        await linked(try await open(handle))
    }

    /// The current result, with the tools of what it named as its links. Taking it starts the
    /// next result's names.
    func page(_ text: String) async -> CallReturn {
        CallReturn(await linked(text))
    }

    /// `text`, with the tools of what it named as its links. Taking them starts the next names.
    private func linked(_ text: String) async -> ToolPage {
        let named = self.named
        self.named = []
        var links: [any HailCore.Tool] = []
        for item in named {
            switch item {
            case .object(let handle):
                links.append(await pageLink(handle))
            case .objectContents(let handle):
                links += await actionTools(of: handle)
            case .action(let handle, let action):
                links += await actionTools(of: handle).filter { $0.name == ActionNaming.byHandle.name(handle, action) }
            }
        }
        return .text(text, links: links)
    }


    /// What an object does: a tool for each action, and one for its values.
    func actionTools(of handle: String, naming: ActionNaming = .byHandle) async -> [any HailCore.Tool] {
        var tools: [any HailCore.Tool] = []
        // One that can't describe itself now, such as a removed object, offers nothing.
        guard let description = try? await described(handle) else { return [] }
        for (name, action) in description.actions.sorted(by: { $0.key < $1.key }) {
            do {
                tools.append(
                    try ObjectActionTool(
                        session: self, handle: handle, title: description.title, action: name,
                        summary: action.description, input: action.input, naming: naming))
            } catch {
                actorSystem.log.warning(
                    "Object action has no usable schema",
                    metadata: ["handle": .string(handle), "action": .string(name), "error": .string("\(error)")])
            }
        }
        return tools
    }

    /// The objects page: what they're for, the objects here, by handle, with what each does, and
    /// yours; its links are the tools to find and make objects, and a direct page link for each
    /// object. The handle belongs in the link, so opening an object takes no guessed arguments.
    func objectsPage(limit: Int = 20) async throws -> ToolPage {
        func text(_ value: DiscoveryJSON?) -> String? { if case .string(let text)? = value { text } else { nil } }
        func texts(_ value: DiscoveryJSON?) -> [String] {
            guard case .array(let values)? = value else { return [] }
            return values.compactMap { text($0) }
        }
        var lines = [ObjectTools.description]
        if case .array(let entries) = try await list(), !entries.isEmpty {
            let shown = entries.prefix(limit).map { entry in
                let actions = texts(entry["actions"]), events = texts(entry["events"])
                return "- \(text(entry["handle"]) ?? ""): Object — " + (Self.given(text(entry["description"])) ?? text(entry["title"]) ?? "")
                    + (actions.isEmpty ? "" : ". Takes \(actions.joined(separator: ", ")).")
                    + (events.isEmpty ? "" : "; events: \(events.joined(separator: ", "))")
            }
            let more = entries.count > limit ? ["…and \(entries.count - limit) more; search_objects finds them."] : []
            lines.append((["Available objects:"] + shown + more).joined(separator: "\n"))
        }
        let madeHandles = try await runtimeObjects()
        lines.append(
            madeHandles.isEmpty
                ? "No objects have been created for you yet. create_object makes a new one."
                : "Your objects: " + madeHandles.joined(separator: ", ") + ".")

        // Give each object its own no-argument link. A generic `use_object` call asks the model
        // to repeat a handle in an argument, creating a second way to open the same page and an
        // easy place to send the title under the wrong key.
        let directoryHandles = try await entries().map { handle(for: $0.object, titled: $0.title) }
        let handles = Set(directoryHandles + madeHandles).sorted()
        var objectLinks: [any HailCore.Tool] = []
        for handle in handles { objectLinks.append(await pageLink(handle)) }
        named = []
        let tools = try await ObjectTools(session: self).tools().filter { $0.name != "use_object" }
        return ToolPage(.text(lines.joined(separator: "\n\n")), links: tools + objectLinks)
    }

    /// Runs a call on a handle's object, explaining a failure the model can recover from.
    private func call<Value>(
        _ handle: String,
        _ body: (DiscoverableObject) async throws -> Value
    ) async throws -> Value {
        let object = try await object(handle)
        do {
            return try await body(object)
        } catch let error as DiscoveryError {
            throw error
        } catch let error as ObjectToolError {
            throw error
        } catch let error as DeadLetterError {
            throw ObjectToolError.unreachable(handle, reason: String(describing: error))
        } catch let error as RemoteCallError {
            throw ObjectToolError.unreachable(handle, reason: String(describing: error))
        } catch let error as GenericRemoteCallError {
            // The object failed with an error the cluster couldn't send back as it was.
            throw ObjectToolError.failed(error.message)
        } catch {
            // The object's own error, such as missing access: the model can act on it.
            throw ObjectToolError.failed(String(describing: error))
        }
    }

    /// A reference in a result becomes a handle: a living actor's is the handle of that actor; one
    /// by its name or id is the handle of that name, as an Erlang registered name is.
    private func mintHandle(_ value: DiscoveryJSON) async throws -> DiscoveryJSON {
        let reference: ActorReference
        switch ObjectReference(value) {
        case .actor(let actor)?:
            reference = actor
        case .named(let name)?, .virtual(let name, _)?:
            let named = ObjectNames.handle(for: name)
            link(.object(named))
            return .string(named)
        case .itself?, nil:
            throw ObjectToolError.failed("`\(value.inline)` isn't an object it can name.")
        }
        let object = try reference.resolve(using: actorSystem)
        let minted: String
        if let known = handles[object.id] {
            minted = known
        } else {
            minted = handle(for: object, titled: try await object.describe().title)
        }
        link(.object(minted))
        return .string(minted)
    }

    /// A handle in the model's arguments becomes a reference.
    private func resolveHandle(_ value: DiscoveryJSON) async throws -> DiscoveryJSON {
        guard case .string(let handle) = value else { throw ObjectToolError.expectedHandle }
        return try DiscoveryJSON.reference(to: try await object(handle))
    }

    // MARK: References

    /// Rewrites each actor reference in `value`, wherever `schema` marks one.
    private func translate(
        _ value: DiscoveryJSON,
        schema: DiscoveryJSON?,
        reference: (DiscoveryJSON) async throws -> DiscoveryJSON
    ) async throws -> DiscoveryJSON {
        guard let schema, case .object(let fields) = schema, value != .null else { return value }
        if Self.isReference(schema) { return try await reference(value) }
        if case .array(let options)? = fields["anyOf"] ?? fields["oneOf"] {
            guard let option = options.first(where: { Self.matches($0, value) }) else { return value }
            return try await translate(value, schema: option, reference: reference)
        }
        switch value {
        case .array(let elements):
            var translated: [DiscoveryJSON] = []
            for element in elements {
                translated.append(try await translate(element, schema: fields["items"], reference: reference))
            }
            return .array(translated)
        case .object(let members):
            var translated: [String: DiscoveryJSON] = [:]
            for (key, member) in members {
                let memberSchema = fields["properties"]?[key] ?? fields["additionalProperties"]
                translated[key] = try await translate(member, schema: memberSchema, reference: reference)
            }
            return .object(translated)
        default:
            return value
        }
    }

    /// The call's arguments. An action with a single argument also takes its bare
    /// value, such as `gorillaz` for `play(query)`, or one misnamed key, such as
    /// `{"artist": "gorillaz"}`; small models often write either.
    static func arguments(_ text: String?, schema: DiscoveryJSON?) throws -> DiscoveryJSON {
        guard case .object(let properties)? = schema?["properties"], properties.count == 1,
            let name = properties.keys.first
        else { return try parse(text) }
        let value: DiscoveryJSON
        if looksLikeJSON(text) {
            // Text meant as JSON that doesn't parse is a mistake to report, not a bare value.
            value = try parse(text)
        } else {
            switch try? parse(text) {
            case .object(let members)? where members[name] != nil: value = .object(members)
            // A bare value stays one, even when it reads as a mapping, such as "Gorillaz: Demon Days".
            case .object?, nil: value = text.map(DiscoveryJSON.string) ?? .null
            case let parsed?: value = parsed
            }
        }
        switch value {
        case .null: return value
        case .object(let members) where members[name] == nil && members.count == 1:
            return [name: members.values.first!]
        case .object: return value
        default: return [name: value]
        }
    }

    /// A rejected argument explained, Elm-style, when the mistake is a common one: a list where
    /// a mapping by name belongs, with the model's own list turned into that mapping.
    static func explanation(
        of reason: String, for argument: String, given: DiscoveryJSON, schema: DiscoveryJSON?
    ) -> String {
        guard reason.hasPrefix("expected object, got array"),
            schema?["properties"]?[argument]?["additionalProperties"] != nil
        else { return reason }
        let explained = "`\(argument)` is a list, but it's a mapping by name: each one under its own name, not as list items"
        guard case .array(let items)? = given[argument],
            case .object(let mapping) = items.reduce(into: DiscoveryJSON.object([:]), { merged, item in
                guard case .object(var members) = merged, case .object(let entry) = item, entry.count == 1 else {
                    merged = .null
                    return
                }
                members.merge(entry) { first, _ in first }
                merged = .object(members)
            }),
            let fixed = try? text([argument: .object(mapping)])
        else { return "\(explained)." }
        return "\(explained). Yours, as a mapping:\n\n" + fixed.split(separator: "\n").map { "    \($0)" }.joined(separator: "\n")
    }

    /// The arguments `value` names that the action doesn't take.
    static func unexpectedArguments(_ value: DiscoveryJSON, schema: DiscoveryJSON?) -> [String] {
        guard case .object(let members) = value else { return [] }
        let known: Set<String> =
            if case .object(let properties)? = schema?["properties"] { Set(properties.keys) } else { [] }
        return members.keys.filter { !known.contains($0) }.sorted()
    }

    /// The required arguments `value` leaves out.
    static func missingArguments(_ value: DiscoveryJSON, schema: DiscoveryJSON?) -> [String] {
        guard case .array(let required)? = schema?["required"] else { return [] }
        let given: [String: DiscoveryJSON] = if case .object(let members) = value { members } else { [:] }
        return required.compactMap { field in
            guard case .string(let name) = field else { return nil }
            return given[name] == nil || given[name] == .null ? name : nil
        }
    }

    static func isReference(_ schema: DiscoveryJSON) -> Bool {
        schema["x-actor-reference"] == true
    }

    /// Whether `value` could be an instance of `option`, to pick a branch of `anyOf`.
    private static func matches(_ option: DiscoveryJSON, _ value: DiscoveryJSON) -> Bool {
        if isReference(option) {
            switch value {
            case .object: return ObjectReference(value) != nil
            case .string: return true
            default: return false
            }
        }
        guard case .string(let type)? = option["type"] else { return true }
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object),
            ("integer", .integer), ("integer", .unsignedInteger),
            ("number", .number), ("number", .integer), ("number", .unsignedInteger):
            return true
        default:
            return false
        }
    }

    /// Replaces reference schemas with handle schemas, which is what the model passes and gets.
    static func presentingReferences(_ value: DiscoveryJSON) -> DiscoveryJSON {
        switch value {
        case .object(let fields):
            if isReference(value) {
                return ["type": "string", "description": "The object ID shown by search_objects or list_objects."]
            }
            return .object(fields.mapValues(presentingReferences))
        case .array(let elements):
            return .array(elements.map(presentingReferences))
        default:
            return value
        }
    }

    // MARK: DiscoveryJSON text

    /// The model's arguments, as YAML, which models write without counting brackets, or JSON,
    /// which is also YAML.
    static func parse(_ text: String?) throws -> DiscoveryJSON {
        do {
            return try YAMLDocument.read(text ?? "")
        } catch {
            throw ObjectToolError.unreadable(error.explanation)
        }
    }

    private static func looksLikeJSON(_ text: String?) -> Bool {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    /// A result as the model reads it: YAML, the way it writes its arguments, keys sorted.
    static func text(_ value: DiscoveryJSON) throws -> String {
        try Yams.dump(object: plain(value), sortKeys: true).trimmingCharacters(in: .newlines)
    }

    private static func plain(_ value: DiscoveryJSON) -> Any {
        switch value {
        case .null: NSNull()
        case .bool(let bool): bool
        // A whole number reads as one: YAML would write 3000.0 as 3e+3.
        case .number(let number) where number.rounded() == number && abs(number) < 1e15: Int(number)
        case .number(let number): number
        case .integer(let integer): Int(integer)
        case .unsignedInteger(let integer): Int(clamping: integer)
        case .string(let string): string
        case .array(let elements): elements.map(plain)
        case .object(let members): members.mapValues(plain)
        }
    }
}

public enum ObjectToolError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownHandle(String)
    /// An action the object behind a handle doesn't have, such as one taken away mid-turn, and
    /// the actions it does have.
    case unknownAction(String, on: String, available: [String])
    case unreachable(String, reason: String)
    case expectedHandle
    case unreadable(String)
    /// An argument the action rejected, with the action's own description of how to call it.
    case invalidArgument(String, argument: String, reason: String, usage: String?)
    case missingArguments(String, missing: [String], unexpected: [String])
    case failed(String)

    public var description: String {
        switch self {
        // Each says what went wrong and what to do instead, with only real names in it: a small
        // model copies examples, so an invented one becomes its next mistake.
        case .unknownHandle(let handle):
            "There's no object `\(handle)`. Find it with search_objects, by what it's for or what it does, or with list_objects for your own."
        case .unknownAction(let action, let handle, let available) where available.isEmpty:
            "`\(handle)` has no action `\(action)`: it has no actions yet. Edit it with edit_object to add its events."
        case .unknownAction(let action, let handle, let available):
            "`\(handle)` has no action `\(action)`. Its actions are: \(available.joined(separator: ", "))."
        case .unreachable(let handle, let reason):
            "The object `\(handle)` can't be reached right now (\(reason)). Find it again with search_objects or list_objects."
        case .expectedHandle:
            "Supply the object ID shown by search_objects or list_objects."
        case .unreadable(let explanation):
            explanation
        case .invalidArgument(let action, let argument, let reason, let usage):
            "\(action) couldn't use `\(argument)`: \(reason)." + (usage.map { "\n\nHow \(action) works: \($0)" } ?? "")
        case .missingArguments(let action, let missing, let unexpected):
            "\(action) needs \(missing.map { "`\($0)`" }.joined(separator: " and "))"
                + (unexpected.isEmpty ? "" : ", not \(unexpected.map { "`\($0)`" }.joined(separator: " or "))")
                + ". Call it again with \(missing.count == 1 ? "it" : "them")."
        case .failed(let reason):
            reason
        }
    }
}

// MARK: - Effects


/// An object being made or changed, a step at a time: its fields, the messages it takes, and what
/// it does with each. Read as a spec only when it's checked; nothing exists, or changes, until
/// it's done.
/// What an object effect gives the model: its text, and the tools it links to, such as the
/// actions of the objects it found.
/// Where an object's pages are: the objects, and each object itself, to use it.
enum ObjectAddress: Hashable {
    /// The objects: what's here, and the tools to find, make and use them.
    case objects
    case object(handle: String)

    private static let objectsName = "objects"

    var address: ToolPageAddress {
        switch self {
        case .objects: ToolPageAddress(rawValue: Self.objectsName)
        case .object(let handle): ToolPageAddress(rawValue: handle.lowercased())
        }
    }

    /// The address read back: only this type writes them, so routing is all it takes.
    init(_ address: ToolPageAddress) {
        self = address.rawValue == Self.objectsName ? .objects : .object(handle: address.rawValue)
    }
}

extension ObjectSession: ToolPages {
    /// An object's page as it is now. One that's no longer there is gone.
    public func open(_ address: ToolPageAddress) async throws(ToolPageUnavailable) -> ToolPage {
        do {
            switch ObjectAddress(address) {
            case .objects: return try await objectsPage()
            case .object(let handle): return try await usingPage(of: handle)
            }
        } catch ObjectToolError.unknownHandle {
            throw .gone
        } catch {
            throw .unreachable(String(describing: error))
        }
    }
}

public struct FindObjectsEffect: ScopedEffect, Sendable {
    public let name = "objects.find"
    let session: ObjectSession
    let query: String
    public static func run(in token: borrowing EffectToken<Self>) async throws -> CallReturn {
        let (session, query) = token.withConfiguration { ($0.session, $0.query) }
        return await session.page(try ObjectSession.text(try await session.find(query)))
    }
}

/// Lists the objects that belong to the agent's owner.
public struct ListObjectsEffect: ScopedEffect, Sendable {
    public let name = "objects.list"
    let session: ObjectSession
    public static func run(in token: borrowing EffectToken<Self>) async throws -> CallReturn {
        let session = token.withConfiguration { $0.session }
        return await session.page(try await session.listMade())
    }
}

/// Makes an object in the runtime, from its Swift.
public struct MakeObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.make"
    let session: ObjectSession
    let objectName: String
    let task: String
    public static func run(in token: borrowing EffectToken<Self>) async throws -> CallReturn {
        let (session, name, task) = token.withConfiguration { ($0.session, $0.objectName, $0.task) }
        return try await session.make(name, described: task)
    }
}

public struct RemoveObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.remove"
    let session: ObjectSession
    let handle: String
    public static func run(in token: borrowing EffectToken<Self>) async throws -> CallReturn {
        let (session, handle) = token.withConfiguration { ($0.session, $0.handle) }
        return await session.page(try ObjectSession.text(try await session.remove(handle)))
    }
}

public struct UseObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.use"
    let session: ObjectSession
    let handle: String
    public static func run(in token: borrowing EffectToken<Self>) async throws -> CallReturn {
        let (session, handle) = token.withConfiguration { ($0.session, $0.handle) }
        return try await session.use(handle)
    }
}

/// Changes an object made here as described.
public struct EditObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.edit"
    let session: ObjectSession
    let handle: String
    let change: String
    public static func run(in token: borrowing EffectToken<Self>) async throws -> CallReturn {
        let (session, handle, change) = token.withConfiguration { ($0.session, $0.handle, $0.change) }
        return try await session.edit(handle, change: change)
    }
}

public struct InvokeObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.invoke"
    let session: ObjectSession
    let handle: String
    let action: String
    let arguments: String?
    public static func run(in token: borrowing EffectToken<Self>) async throws -> CallReturn {
        let (session, handle, action, arguments) = token.withConfiguration {
            ($0.session, $0.handle, $0.action, $0.arguments)
        }
        // What the action did, as a diff: its reply, each value it changed, and what it printed.
        let before = try await session.values(of: handle)
        let result = try await session.invoke(handle, action: action, arguments: arguments)
        let after = try await session.values(of: handle)
        let changes = Set(before.keys).union(after.keys).sorted().compactMap { name -> String? in
            let old = before[name] ?? .null, new = after[name] ?? .null
            return old == new ? nil : "\(name): \(old.inline) → \(new.inline)"
        }
        var lines = [result == .null ? "Done." : "Result: \(result.inline)"]
        lines.append(changes.isEmpty ? "Nothing it holds changed." : changes.joined(separator: "; ") + ".")
        let printed = await session.printed
        if !printed.isEmpty { lines.append("It printed: " + printed.joined(separator: " ")) }
        return await session.page(lines.joined(separator: "\n"))
    }
}

// MARK: - Tool

/// The tools a turn starts with, named the way most APIs name theirs, verb then noun:
/// `search_objects` and `create_object`. Everything else is linked from their results.
public struct ObjectTools: Sendable {
    let session: ObjectSession

    public init(session: ObjectSession) {
        self.session = session
    }

    /// What the objects are for: the objects page says it, and its link starts with it.
    public static let description =
        "Objects store information and perform actions. Open an object to see its current values and the actions you can call."

    /// The link a turn starts from: going there shows the objects page, with what's here and the
    /// tools to find, make and use them.
    public static var link: ToolPageLink {
        ToolPageLink(name: "objects", description: description, address: ObjectAddress.objects.address)
    }

    /// Listing your objects, searching, creating, and, once you have some, editing and removing them:
    /// everything else is offered in the scopes of their calls.
    public func tools() async throws -> [any HailCore.Tool] {
        let objects = try await session.yourObjects()
        let always: [any HailCore.Tool] = [
            ListObjectsTool(session: session), SearchObjectsTool(session: session),
            try CreateObjectTool(session: session),
        ]
        guard !objects.isEmpty else { return always }
        return always + [
            try UseObjectTool(session: session, objects: objects),
            try EditObjectTool(session: session, objects: objects),
            try RemoveObjectTool(session: session, objects: objects),
        ]
    }
}

public struct SearchObjectsTool: HailCore.Tool {
    public typealias Input = ObjectToolsFindInput
    let session: ObjectSession
    public let name = "search_objects"
    public let description =
        "Find objects by their purpose or actions. Returns matching object IDs and links to open them. Includes this machine's apps."
    public func effect(for input: Input) throws -> FindObjectsEffect { FindObjectsEffect(session: session, query: input.query) }
    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<FindObjectsEffect>) async throws -> CallReturn {
        try await FindObjectsEffect.run(in: token)
    }
}

public struct ListObjectsTool: HailCore.Tool {
    public typealias Input = EmptyToolInput
    let session: ObjectSession
    public let name = "list_objects"
    public let description = "List every object by name: the ones made for you, and the others."
    public func effect(for input: Input) throws -> ListObjectsEffect { ListObjectsEffect(session: session) }
    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ListObjectsEffect>) async throws -> CallReturn {
        try await ListObjectsEffect.run(in: token)
    }
}

public struct CreateObjectTool: HailCore.Tool {
    /// A new object: its name, and what it holds and does.
    @Generable(description: "A new object.")
    public struct Input: Sendable {
        @Guide(description: "Its name. It must not already exist.")
        public let name: String
        @Guide(description: "What it holds and does.")
        public let description: String
    }

    let session: ObjectSession
    public let name = "create_object"
    public let description = "Create an object that holds and does what's described: its Swift code is written from it."

    init(session: ObjectSession) throws {
        self.session = session
    }

    public func effect(for input: Input) throws -> MakeObjectEffect {
        MakeObjectEffect(session: session, objectName: input.name, task: input.description)
    }
    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<MakeObjectEffect>) async throws -> CallReturn {
        try await MakeObjectEffect.run(in: token)
    }
}

/// What an object's action is called as a tool: by its object's handle, `ann_approveRaise`, as an
/// object's page offers it; or as an object's, `object_ann_approveRaise`, as it's offered with every
/// object at the start of a turn. Either calls the same action.
public enum ActionNaming: Sendable {
    case byHandle
    case asObject

    func name(_ handle: String, _ action: String) -> String {
        switch self {
        case .byHandle: "\(handle)_\(action)"
        case .asObject: "object_\(handle)_\(action)"
        }
    }
}

/// One action of one object as a tool of its own, such as `shop_startShift`: the model calls it
/// with typed arguments, the way it calls any tool. Objects are passed and returned by handle.
public struct ObjectActionTool: HailCore.Tool {
    public typealias Input = GeneratedContent
    public typealias Effect = InvokeObjectEffect

    let session: ObjectSession
    let handle: String
    let title: String
    let action: String
    let summary: String?
    /// What the action is called, as a tool.
    let naming: ActionNaming
    /// The action's input schema, as the object describes it; `nil` when it takes no arguments.
    let input: DiscoveryJSON?
    private let parameters: GenerationSchema

    init(
        session: ObjectSession, handle: String, title: String, action: String, summary: String?,
        input: DiscoveryJSON?, naming: ActionNaming = .byHandle
    ) throws {
        self.session = session
        self.handle = handle
        self.title = title
        self.action = action
        self.summary = summary
        self.naming = naming
        self.input = input
        let schema = Self.handles(in: input ?? ["type": "object", "properties": [:]])
        self.parameters = try JSONDecoder().decode(GenerationSchema.self, from: JSONEncoder().encode(schema))
    }

    public var name: String { naming.name(handle, action) }
    public var description: String {
        "\(action) on \(title) (`\(handle)`)" + (summary.map { ": \($0)" } ?? "")
    }
    public var schema: ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: parameters)
    }

    public func effect(for arguments: GeneratedContent) throws -> InvokeObjectEffect {
        InvokeObjectEffect(
            session: session, handle: handle, action: action, arguments: input == nil ? nil : arguments.jsonString)
    }

    public func run(_ input: GeneratedContent, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<InvokeObjectEffect>) async throws
        -> CallReturn
    {
        let page = try await InvokeObjectEffect.run(in: token)
        return page
    }

    /// The schema as the model writes it: a reference to an object is its handle, a string, and an
    /// optional value is the value, since leaving it out of `required` already makes it optional.
    static func handles(in schema: DiscoveryJSON) -> DiscoveryJSON {
        switch schema {
        case .object(let members) where members["x-actor-reference"] == .bool(true):
            // An object is given by its name, as the objects page lists it, and is of the type its
            // code writes.
            let takes = members["description"].flatMap { if case .string(let text) = $0 { ", " + text } else { nil } } ?? ""
            return ["type": "string", "description": .string("\(DiscoveryJSON.object(members).swiftType)\(takes).")]
        case .object(let members):
            if case .array(let choices)? = members["anyOf"] {
                let present = choices.filter { $0["type"] != "null" }
                if present.count == 1 { return handles(in: present[0]) }
            }
            return .object(members.mapValues(handles))
        case .array(let items): return .array(items.map(handles))
        default: return schema
        }
    }
}

/// One of your objects, as a root tool's arguments choose it: the schema offers only them, so
/// no other can be named.
struct YourObject {
    static let property = "object"
    let objects: [String]

    func property(_ about: String) -> DynamicGenerationSchema.Property {
        .init(name: Self.property, description: about, schema: .init(type: String.self, guides: [.anyOf(objects)]))
    }

    /// The object the arguments name: missing is a missing argument, and one that isn't yours
    /// isn't on offer.
    func object(in input: GeneratedContent, for tool: String) throws -> String {
        let object: String
        do {
            object = try input.value(String.self, forProperty: Self.property)
        } catch GeneratedContentError.propertyNotFound {
            throw ObjectToolError.missingArguments(tool, missing: [Self.property], unexpected: [])
        }
        guard objects.contains(object) else {
            throw ObjectToolError.failed(UnofferedChoice(given: object, offered: objects, argument: Self.property).description)
        }
        return object
    }
}

/// Uses one of your objects: shows what it holds now, and offers its actions.
/// Reads one object: what it holds now, and what it takes. Its actions are offered after it.
public struct ObjectReadTool: HailCore.Tool {
    public typealias Input = EmptyToolInput
    let session: ObjectSession
    let handle: String
    let title: String
    /// Marked as an object's, so it isn't taken for one of its actions.
    public var name: String { "object_\(handle)" }
    public var description: String { "What \(title) holds now, and what it takes." }
    public func effect(for input: Input) throws -> UseObjectEffect { UseObjectEffect(session: session, handle: handle) }
    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<UseObjectEffect>) async throws -> CallReturn {
        try await UseObjectEffect.run(in: token)
    }
}

public struct UseObjectTool: HailCore.Tool {
    public typealias Input = GeneratedContent
    let session: ObjectSession
    /// Your objects, to choose from.
    let objects: YourObject
    public let name = "use_object"
    public let description = "Open an object to see its current values and available actions. Opening it does not run an action."
    private let parameters: GenerationSchema

    init(session: ObjectSession, objects: [String]) throws {
        self.session = session
        self.objects = YourObject(objects: objects)
        self.parameters = try GenerationSchema(
            root: DynamicGenerationSchema(name: "UseObject", properties: [self.objects.property("The object to use.")]),
            dependencies: [])
    }

    public var schema: ToolDefinition { ToolDefinition(name: name, description: description, parameters: parameters) }

    public func effect(for input: Input) throws -> UseObjectEffect {
        UseObjectEffect(session: session, handle: try objects.object(in: input, for: name))
    }
    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<UseObjectEffect>) async throws -> CallReturn {
        try await UseObjectEffect.run(in: token)
    }
}

/// Changes one of your objects to its new Swift code.
public struct EditObjectTool: HailCore.Tool {
    public typealias Input = GeneratedContent
    static let changeProperty = "change"
    let session: ObjectSession
    /// Your objects, to choose from: the only ones it can change.
    let objects: YourObject
    public let name = "edit_object"
    public let description = "Change what an object holds or does: its Swift code is rewritten for it."
    private let parameters: GenerationSchema

    init(session: ObjectSession, objects: [String]) throws {
        self.session = session
        self.objects = YourObject(objects: objects)
        self.parameters = try GenerationSchema(
            root: DynamicGenerationSchema(name: "EditObject", properties: [
                self.objects.property("The object to change."),
                .init(name: Self.changeProperty, description: "What to change.", schema: .init(type: String.self)),
            ]),
            dependencies: [])
    }

    public var schema: ToolDefinition { ToolDefinition(name: name, description: description, parameters: parameters) }

    public func effect(for input: Input) throws -> EditObjectEffect {
        guard let change = try input.text(Self.changeProperty) else {
            throw ObjectToolError.missingArguments(name, missing: [Self.changeProperty], unexpected: [])
        }
        return EditObjectEffect(session: session, handle: try objects.object(in: input, for: name), change: change)
    }
    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<EditObjectEffect>) async throws -> CallReturn {
        try await EditObjectEffect.run(in: token)
    }
}

/// Copies one of your objects as a new one: the same behavior, starting as it started, and its
/// own from then on.
/// Removes one of your objects, for good. A root tool, beside editing: `<handle>_…` names are only
/// an object's own actions and steps.
public struct RemoveObjectTool: HailCore.Tool {
    public typealias Input = GeneratedContent
    let session: ObjectSession
    /// Your objects, to choose from: the only ones it can remove.
    let objects: YourObject
    public let name = "remove_object"
    public let description = "Permanently remove an object."
    private let parameters: GenerationSchema

    init(session: ObjectSession, objects: [String]) throws {
        self.session = session
        self.objects = YourObject(objects: objects)
        self.parameters = try GenerationSchema(
            root: DynamicGenerationSchema(name: "RemoveObject", properties: [self.objects.property("The object to remove.")]),
            dependencies: [])
    }

    public var schema: ToolDefinition { ToolDefinition(name: name, description: description, parameters: parameters) }

    public func effect(for input: Input) throws -> RemoveObjectEffect {
        RemoveObjectEffect(session: session, handle: try objects.object(in: input, for: name))
    }
    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<RemoveObjectEffect>) async throws -> CallReturn {
        try await RemoveObjectEffect.run(in: token)
    }
}

/// One step that makes an object, Erlang underneath: `<handle>_on`, one `receive` clause
/// (message, argument patterns, guard, body); `<handle>_data`, a field of its state;
/// `<handle>_remove_event`, taking a clause out; and `<handle>_set_value`, its own state when it
/// follows the rules of another, as an Erlang module is spawned again with state of its own.
extension GeneratedContent {
    /// A property's content, if it has one.
    func property(_ name: String) -> GeneratedContent? {
        guard case .structure(let properties, _) = kind, let property = properties[name], property.kind != .null else { return nil }
        return property
    }
}

/// A choice the step doesn't offer, such as a kind of data that isn't one.
struct UnofferedChoice: Error, CustomStringConvertible {
    let given: String
    let offered: [String]
    /// Which argument it was given for, such as `do`.
    var argument: String? = nil
    var description: String {
        (argument.map { "`\($0)` is `\(given)`, which isn't offered." } ?? "`\(given)` isn't offered.")
            + " Choose one of: \(offered.joined(separator: ", "))."
    }
}

extension GeneratedContent {
    /// The text of an optional property, or nil when it's missing or blank.
    func text(_ property: String) throws -> String? {
        let text = try value(String?.self, forProperty: property)?.trimmingCharacters(in: .whitespaces)
        return text?.isEmpty == false ? text : nil
    }
}

@Generable
public struct ObjectToolsFindInput: Sendable {
    @Guide(description: "Words for what you need, in your own words.")
    public let query: String
}
