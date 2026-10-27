import AnyLanguageModel
import DiscoverableActors
import DistributedCluster
import Hail
import TurgaiDomain
import TurgaiObjects
import Yams

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Discovery's DiscoveryJSON; AnyLanguageModel has its own `JSONValue`.
typealias DiscoveryJSON = DiscoverableActors.JSONValue

/// The objects a model has met during one turn, each by its id: an object made by name by the id
/// it was made with, a built-in object by its type, the one of its kind here, and an object an
/// action returned by the id the system has for it, which holds while it lives. No id is made up.
///
/// The model can only use objects it was given: the directory's and whatever their actions
/// return.
public actor ObjectSession {
    let actorSystem: ClusterSystem
    private var objectCatalog: ObjectCatalog?
    /// The agents its own agent can ask: the other agents working for the same person, never
    /// itself, which it can't ask while it answers. They're described as every agent is, so none
    /// starts to be listed.
    let agents: [ObjectEntry]

    /// The objects met, by id.
    private var objects: [ObjectID: DiscoverableObject] = [:]
    /// The objects actions returned, by type, as written: what a tool of their type offers to
    /// choose from.
    private var returned: [ObjectTypeName: [ObjectID]] = [:]
    /// What the current result named, in order: its links are their tools.
    private var named: [Named] = []
    /// The objects made here that this session has met, by id.
    private var made: [ObjectID: DynamicObject] = [:]
    /// What the last action's object printed handling it.
    private(set) var printed: [String] = []

    /// Something a result names, whose tools it links to.
    private enum Named: Equatable {
        /// A reference to an object: following it opens the object's first page.
        case object(ObjectID)
        /// An open object's contents: its actions and current values, and removing it.
        case objectContents(ObjectID)
        /// One action of an object, such as the shop's `startShift`.
        case action(ObjectID, String)
    }

    /// Writes an object's Swift from what it should do, in a session of its own.
    let writer: ObjectWriter?
    /// What the person asked for in the turn this session serves: an object's writer sees it, as
    /// whoever writes one part of something sees what the whole is for.
    let request: String?

    public init(
        actorSystem: ClusterSystem,
        objectCatalog: ObjectCatalog? = nil,
        agents: [ObjectEntry] = [],
        writer: ObjectWriter? = nil,
        request: String? = nil
    ) {
        self.actorSystem = actorSystem
        self.objectCatalog = objectCatalog
        self.agents = agents
        self.writer = writer
        self.request = request
    }

    /// The directory's roots, with handles, titles, and descriptions.
    func list() async throws -> DiscoveryJSON {
        .array(
            try await entries().map { entry in
                [
                    "object_id": .string(listed(entry).description),
                    "type": .string(entry.type),
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
                handle: text(entry["object_id"]),
                title: text(entry["type"]),
                actions: actions,
                description: text(entry["description"])
            )
        }
        let ranked = ObjectSearchIndex(documents).search(query, limit: limit).compactMap { match in
            entries.first { text($0["object_id"]) == match.handle }
        }
        for entry in ranked {
            if case .string(let written)? = entry["object_id"] { link(.object(try await id(written: written))) }
        }
        return .array(Array(ranked))
    }

    /// Every object there is, by name only, so a long list stays short: the ones made for the
    /// agent's owner, then the others. What one holds and takes is its own tool, a call away.
    func listMade() async throws -> String {
        let yours = try await runtimeObjects().sorted()
        let others = try await entries().map { listed($0) }.filter { !yours.contains($0) }.sorted()
        for handle in yours + others { link(.object(handle)) }
        var lines: [String] = []
        if !others.isEmpty { lines.append("Objects: " + others.map(\.description).joined(separator: ", ") + ".") }
        lines.append(
            yours.isEmpty
                ? "None made for you yet: create_object makes one."
                : "Made for you: " + yours.map(\.description).joined(separator: ", ") + ".")
        return lines.joined(separator: "\n")
    }

    /// Your objects, to choose from.
    func yourObjects() async throws -> [ObjectID] {
        try await runtimeObjects().sorted()
    }

    /// The objects made by name that this turn's person may read, by handle.
    private func runtimeObjects() async throws -> [ObjectID] {
        var out: [DynamicObject] = []
        let objects = try await DynamicObjects.resolve(on: actorSystem)
        for entry in try await objects.held() {
            guard let identity = try await objects.identity(of: entry.object.id) else { continue }
            out.append(try await objects.held(identity))
        }
        return try await names(of: out)
    }

    /// The ids of `objects`, once each, sorted.
    private func names(of objects: [DynamicObject]) async throws -> [ObjectID] {
        var names: Set<ObjectID> = []
        for object in objects {
            let discoverable = try DiscoverableObject.resolve(id: object.id, using: actorSystem)
            guard let description = try? await discoverable.describe() else { continue }
            let id = id(of: discoverable, type: description.type)
            made[id] = object
            names.insert(id)
        }
        return names.sorted()
    }

    /// An object's properties and actions, with actor references shown as handles.
    func describe(_ handle: ObjectID) async throws -> DiscoveryJSON {
        let description = try await described(handle)
        return Self.presentingReferences(try DiscoveryJSON(encoding: description))
    }

    /// Runs an action. The Mac's objects are guarded by macOS's own permissions,
    /// which ask the user the first time an app is used; Turgai doesn't ask again.
    func invoke(_ handle: ObjectID, action name: String, arguments text: String?) async throws -> DiscoveryJSON {
        do {
            let result = try await perform(handle, action: name, arguments: text)
            actorSystem.log.info(
                "Object call",
                metadata: [
                    "object_id": .string(handle.description), "action": .string(name), "arguments": .string(text ?? ""),
                ]
            )
            return result
        } catch {
            actorSystem.log.info(
                "Object call failed",
                metadata: [
                    "object_id": .string(handle.description), "action": .string(name), "arguments": .string(text ?? ""),
                    "error": .string(String(describing: error)),
                ]
            )
            throw error
        }
    }

    /// What an object says it is and does.
    func described(_ handle: ObjectID) async throws -> ObjectDescription {
        if agents.contains(where: { $0.id == handle }) { return Agent.objectDescription }
        return try await call(handle) { try await $0.describe() }
    }

    // MARK: Contracts

    /// Each type's contract, read from the description it was read from: read again when that
    /// changes, as code changing does.
    private var contracts: [ObjectTypeName: (description: ObjectDescription, contract: ObjectContract)] = [:]

    /// The contract of what `description` describes.
    private func contract(of description: ObjectDescription) -> ObjectContract? {
        let type = ObjectTypeName(rawValue: description.type)
        if let read = contracts[type], read.description == description { return read.contract }
        guard let contract = try? ObjectContract(description) else { return nil }
        contracts[type] = (description, contract)
        return contract
    }

    /// The objects here conforming to `name`, by id, in order: what an argument of `any` of it
    /// chooses from. Its requirements are those the type declaring it declares; who conforms is
    /// what each takes, made here or built in.
    func conforming(to name: ObjectProtocolName) async -> [ObjectID] {
        var handles = (try? await runtimeObjects()) ?? []
        for entry in (try? await entries()) ?? [] {
            let handle = listed(entry)
            if !handles.contains(handle) { handles.append(handle) }
        }
        var contracts: [(handle: ObjectID, contract: ObjectContract)] = []
        for handle in handles {
            if let description = try? await described(handle), let contract = contract(of: description) {
                contracts.append((handle, contract))
            }
        }
        guard let requirements = contracts.lazy.compactMap({ $0.contract.protocols[name] }).first else { return [] }
        return contracts.filter { $0.contract.conforms(to: requirements) }.map(\.handle).sorted()
    }

    /// For each protocol an action's arguments take an object conforming to, as code writes it,
    /// `any Shop.RefundManager`, the objects here that do.
    func choices(for input: DiscoveryJSON?) async -> [String: [ObjectID]] {
        guard case .object(let properties)? = input?["properties"] else { return [:] }
        var choices: [String: [ObjectID]] = [:]
        for property in properties.values {
            guard let written = property.swiftType, written.hasPrefix("any "), choices[written] == nil else { continue }
            choices[written] = await conforming(to: ObjectProtocolName(rawValue: String(written.dropFirst(4))))
        }
        return choices
    }

    private func perform(_ handle: ObjectID, action name: String, arguments text: String?) async throws -> DiscoveryJSON
    {
        let description = try await described(handle)
        guard let action = description.actions[name] else {
            throw ObjectToolError.unknownAction(
                name, on: handle.description, available: description.actions.keys.sorted())
        }
        let given = try Self.arguments(text, schema: action.input)
        let missing = Self.missingArguments(given, schema: action.input)
        guard missing.isEmpty else {
            throw ObjectToolError.missingArguments(
                "\(description.type).\(name)", missing: missing,
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
                "\(description.type).\(name)", argument: argument,
                reason: Self.explanation(of: reason, for: argument, given: given, schema: action.input),
                usage: action.description)
        }
        return try await translate(result, schema: action.output, reference: mintHandle)
    }

    /// Reads a property, with actor references shown as handles.
    func read(_ handle: ObjectID, property: String) async throws -> DiscoveryJSON {
        let description = try await described(handle)
        let value = try await call(handle) { try await $0.read(property: property) }
        return try await translate(value, schema: description.properties[property], reference: mintHandle)
    }

    // MARK: Ids

    /// The id `object`, of `type`, is shown by: one checked in here as it was listed; a dynamic
    /// object's own, its virtual actor's; and otherwise the id the system has for it, which an
    /// action returned, valid while it lives.
    private func id(of object: DiscoverableObject, type: String) -> ObjectID {
        let id: ObjectID
        if let listed = checkedIn[object.id] {
            id = listed
        } else if DynamicObject.identity(of: object.id) != nil, let virtual = object.id.virtualActorID {
            id = .virtual(virtual)
        } else {
            id = object.id.virtualActorID.map(ObjectID.virtual) ?? .actor(object.id, type: nil)
            let typeName = ObjectTypeName(rawValue: type)
            if !returned[typeName, default: []].contains(id) { returned[typeName, default: []].append(id) }
        }
        return showing(id, object)
    }

    /// `object` shown as `id`: how it's written, which reads back as it.
    private func showing(_ id: ObjectID, _ object: DiscoverableObject) -> ObjectID {
        objects[id] = object
        return id
    }

    /// The id of an object listed here, as its entry has it.
    private func listed(_ entry: ObjectEntry) -> ObjectID {
        showing(entry.id, entry.object)
    }

    /// The objects listed, as the catalog last listed them, by id.
    private var checkedIn: [ClusterSystem.ActorID: ObjectID] = [:]

    /// The type of the object an action returned with `id`, if one did.
    private func returnedType(of id: ObjectID) -> ObjectTypeName? {
        returned.first { $0.value.contains(id) }?.key
    }

    /// The objects of `type` actions returned: what its tools choose from.
    private func returned(_ type: ObjectTypeName) -> [ObjectID] {
        returned[type] ?? []
    }

    /// The roots this session can see, from the cluster receptionist, in the same
    /// order every time, so each gets the same handle in every session, including the
    /// summary shown to the model.
    private func entries() async throws -> [ObjectEntry] {
        if objectCatalog == nil { objectCatalog = await ObjectCatalog(actorSystem: actorSystem) }
        guard let objectCatalog else { return [] }
        // By id, as the catalog lists its own, so each is in the same place every time.
        let entries = (try await objectCatalog.entries() + agents).sorted { $0.id < $1.id }
        checkedIn = Dictionary(entries.map { ($0.object.id, $0.id) }) { first, _ in first }
        return entries
    }

    /// The object with `id`. One of the directory's works without listing first, since the model
    /// may know it from the turn's summary; a name's id is lowercase, and models often capitalize
    /// names, such as `Ann` for `ann`.
    /// The id of the object the model wrote `written` for: one it was shown, as it was written,
    /// or the same with other capitals. Text becomes an id here, once, as it comes in.
    func id(written: String) async throws -> ObjectID {
        func met() -> ObjectID? {
            objects.keys.first { $0.description == written }
                ?? objects.keys.first { $0.description.lowercased() == written.lowercased() }
        }
        if let id = met() { return id }
        for entry in try await entries() { _ = self.listed(entry) }
        guard let id = met() else { throw ObjectToolError.unknownHandle(written) }
        return id
    }

    /// The object code named `name`: one met or listed here, or one code made under it, which the
    /// directory doesn't list.
    private func id(named name: String) async throws -> ObjectID {
        let written = ObjectNames.handle(for: name)
        if let id = try? await id(written: written) { return id }
        guard
            let made = try await DynamicObjects.resolve(on: actorSystem).existing(ObjectIdentity(rawValue: written)),
            let virtual = made.id.virtualActorID
        else { throw ObjectToolError.unknownHandle(written) }
        let id = ObjectID.virtual(virtual)
        self.made[id] = made
        return showing(id, try DiscoverableObject.resolve(id: made.id, using: actorSystem))
    }

    /// The object met with `id`.
    private func object(_ id: ObjectID) async throws -> DiscoverableObject {
        if let object = objects[id] { return object }
        for entry in try await entries() { _ = self.listed(entry) }
        guard let object = objects[id] else { throw ObjectToolError.unknownHandle(id.description) }
        return object
    }

    // MARK: Making objects

    /// Makes an object named `name` that does `task`: its Swift is written in a session of its
    /// own, whose answer is the code, until it's saved. Code that's never saved makes nothing.
    func make(_ name: String, described task: String) async throws -> CallReturn {
        if let existing = try await madeObject(named: name) {
            let type = try await existing.object.source.type
            throw ObjectToolError.failed(
                DynamicObjectsError.exists(existing.handle.description, type: type).description)
        }
        guard let writer else { throw ObjectToolError.failed("Objects can't be written here.") }
        let type = Self.typeName(of: name)
        var handle: ObjectID?
        let others = await others(except: type)
        let outcome = try await writer.write(
            type: type, task: task, current: nil, others: others.declarations, values: others.uses.valuesInWords,
            request: request
        ) { code in
            do {
                let source = try Script(code: code, type: type, uses: others.uses)
                let problems = await ScriptInstance.problems(in: source)
                guard problems.isEmpty else { return problems.map { $0.written(in: code) }.joined(separator: "\n") }
                if let made = handle {
                    try await self.replace(made, with: source)
                } else {
                    handle = try await self.create(name, described: task, spec: .new(source))
                }
                return nil
            } catch let problem as CodeProblem {
                return problem.written(in: code)
            } catch {
                return Self.problem(error)
            }
        }
        // What went wrong with the code stays with its writer: what's said here is what can be
        // done about it, which is asking again.
        guard case .saved = outcome, let handle else {
            throw ObjectToolError.failed("\(name) wasn't made: its code couldn't be written from this description.")
        }
        let shape = try? ObjectShape(try await dynamicObject(handle).source)
        return landing(
            "Saved \(handle): \(Self.contents(of: shape, now: try await currentValues(handle))).",
            on: .object(handle: handle))
    }

    /// Changes an object made here as `change` says: its Swift is rewritten in a session of its
    /// own, from its code now, until it's saved. A change that's never saved leaves it as it was.
    /// Shares `handle` with `audience` as far as `level`, or takes their access away: on behalf of
    /// whoever the turn is for, in the group they came in through. Only one who may change it does.
    func share(_ handle: ObjectID, with audience: SharingAudience, _ level: SharingLevel) async throws -> CallReturn {
        let object = try await dynamicObject(handle)
        guard let chain = CallChain.current else { throw CallOnBehalfOfNoOne(actor: handle) }
        do {
            try await object.share(with: audience.audience(in: chain.scope.group), level.access)
        } catch let refused as NotAllowed {
            throw ObjectToolError.failed(refused.description)
        }
        return switch level {
        case .read: await page("\(handle) is shared with \(audience.rawValue): they may use it.")
        case .write: await page("\(handle) is shared with \(audience.rawValue): they may use and change it.")
        case .none: await page("\(handle) is no longer shared with \(audience.rawValue).")
        }
    }

    func edit(_ handle: ObjectID, change: String) async throws -> CallReturn {
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
        if case .failed = outcome {
            throw ObjectToolError.failed("\(handle) wasn't changed: the code for this change couldn't be written.")
        }
        let changed = try await object.source
        let after = try? ObjectShape(changed)
        let said = Self.changes(from: before, to: after, now: try await currentValues(handle))
        return landing(
            "Saved \(handle): \(said).\(Self.codeChanges(from: current.code, to: changed.code))",
            on: .object(handle: handle))
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
        for entry in (try? await entries()) ?? [] { handles.insert(listed(entry)) }
        var objects: [Uses.Object] = []
        var existing: [ObjectIdentity: String] = [:]
        var summaries: [String: String] = [:]
        var descriptions: [String: ObjectDescription] = [:]
        for handle in handles.sorted() {
            guard let description = try? await described(handle), description.type != type else { continue }
            let typeName = description.type
            // What it publishes is read, never written: what isn't `private`, as Swift reads another
            // actor's property.
            // Code reaches by id, `Type(id:)`, what has one: an object made by name, or a built-in one.
            switch handle {
            case .virtual, .actor(_, type: _?): existing[ObjectIdentity(rawValue: handle.name)] = typeName
            case .actor(_, type: nil): break
            }
            // One actor per type: every object of it is a constant of that type.
            guard !objects.contains(where: { $0.type == typeName }) else { continue }
            objects.append(Uses.Object(description: description, publishes: true))
            summaries[typeName] = Self.given(description.description)
            descriptions[typeName] = description
        }
        // Types no object is of yet: what an object made with `Type()` will be, reached by no name.
        for (unmade, description) in ((try? await making { try await $0.unmadeTypes() }) ?? [:]).sorted(by: {
            $0.key < $1.key
        })
        where unmade != type && !objects.contains(where: { $0.type == unmade }) {
            objects.append(Uses.Object(description: description, publishes: true))
            summaries[unmade] = Self.given(description.description)
        }
        // The object being written declares its own types: they aren't declared for it again.
        let interface = Uses.interface(of: objects, except: type)
        var others = Others(uses: Uses(interface: interface, objects: existing))
        // In words, from the spec itself.
        for actor in interface.actors(events: [RuntimeMacros.event]) {
            // Each as the code that reaches it; a type no object is of yet, as the code that makes one.
            let reached = others.uses.ids(of: actor.name).map { "\(actor.name)(id: \"\($0)\")" }
            var declaration = ["- \(reached.isEmpty ? "\(actor.name)(id:)" : reached.joined(separator: ", "))"]
            if let summary = summaries[actor.name] { declaration.append("  \(summary).") }
            // Each with what its parameters are, as its object says, in words.
            let takes = actor.methods.sorted { $0.key < $1.key }.map { name, method in
                ([Self.written(name, method)] + Self.parameterWords(descriptions[actor.name]?.actions[name]?.input))
                    .joined(separator: "\n")
            }
            if !takes.isEmpty { declaration.append("  Methods:\n" + takes.map { "    \($0)" }.joined(separator: "\n")) }
            let publishes = actor.properties.sorted { $0.key < $1.key }.map {
                "\($0.key): \($0.value) { get async throws }"
            }
            if !publishes.isEmpty {
                declaration.append("  Properties:\n" + publishes.map { "    \($0)" }.joined(separator: "\n"))
            }
            // What an object conforming to each protocol it declares takes.
            let protocols = actor.protocols.sorted { $0.key < $1.key }.map { name, requirements in
                "\(name): "
                    + requirements.sorted { $0.key < $1.key }.map { Self.written($0.key, $0.value) }.joined(
                        separator: "; ")
            }
            if !protocols.isEmpty {
                declaration.append("  Protocols:\n" + protocols.map { "    \($0)" }.joined(separator: "\n"))
            }
            let announces = actor.events.sorted { $0.key < $1.key }.map {
                Self.written(DynamicObject.handler(for: $0.key), $0.value)
            }
            if !announces.isEmpty {
                declaration.append(
                    "  Events, each received by a function of this name:\n"
                        + announces.map { "    \($0)" }.joined(separator: "\n"))
            }
            others.declarations.append(declaration.joined(separator: "\n"))
        }
        return others
    }

    /// What each parameter of an action is, one to a line under it, as its object says.
    static func parameterWords(_ input: DiscoveryJSON?) -> [String] {
        guard case .object(let properties)? = input?["properties"] else { return [] }
        return (Uses.parameters(of: input) ?? []).compactMap { parameter in
            guard case .string(let text)? = properties[parameter.name]?["description"], !text.isEmpty else {
                return nil
            }
            return "      \(parameter.name): \(text)"
        }
    }

    /// A method as Swift declares it: `show(page: Page)`, `approve(_ amount: Int) -> Bool`.
    static func written(_ name: String, _ method: DeclaredActor.Method) -> String {
        let parameters = method.parameters.map { parameter in
            let called =
                parameter.label == parameter.name ? parameter.name : "\(parameter.label ?? "_") \(parameter.name)"
            return "\(called): \(parameter.type)"
        }
        return "\(name)(\(parameters.joined(separator: ", ")))" + (method.effects.map { " \($0)" } ?? "")
            + (method.returns.map { " -> \($0)" } ?? "")
    }

    /// An object made here, now running `source`, and every object sharing its code.
    private func replace(_ handle: ObjectID, with source: Script) async throws {
        let identity = try await dynamicObject(handle).identity
        try await making { try await $0.update(identity, source: source) }
        await changed()
    }

    /// What an edit changed, in a line: the messages it now takes or no longer takes, and the data
    /// it now holds, with its value, or no longer holds.
    static func changes(from before: ObjectShape?, to after: ObjectShape?, now values: [String: DiscoveryJSON])
        -> String
    {
        let old = Set(before?.messages.map(\.written) ?? [])
        let new = after?.messages.map(\.written) ?? []
        let oldData = Set(before?.fields.map(\.name) ?? [])
        let newData = after?.fields.map(\.name) ?? []
        var parts: [String] = []
        let takes = new.filter { !old.contains($0) }
        if !takes.isEmpty { parts.append("it now takes " + takes.joined(separator: ", ")) }
        let gone = (before?.messages.map(\.written) ?? []).filter { !new.contains($0) }
        if !gone.isEmpty { parts.append("it no longer takes " + gone.joined(separator: ", ")) }
        let holds = newData.filter { !oldData.contains($0) }.map { "\($0): \((values[$0] ?? .null).inline)" }
        if !holds.isEmpty { parts.append("it now holds " + holds.joined(separator: ", ")) }
        let dropped = (before?.fields.map(\.name) ?? []).filter { !newData.contains($0) }
        if !dropped.isEmpty { parts.append("it no longer holds " + dropped.joined(separator: ", ")) }
        return parts.isEmpty ? "what it holds and takes is the same" : parts.joined(separator: "; ")
    }

    /// How an edit changed the code, line by line, so that a change inside a method, which what
    /// the object holds and takes doesn't show, is seen too: the lines gone, then those added.
    static func codeChanges(from before: String, to after: String, limit: Int = 12) -> String {
        let difference = after.split(separator: "\n", omittingEmptySubsequences: false)
            .difference(from: before.split(separator: "\n", omittingEmptySubsequences: false))
        let lines = difference.compactMap { change -> String? in
            switch change {
            case .remove(_, let line, _):
                line.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil : "- " + line.trimmingCharacters(in: .whitespaces)
            case .insert(_, let line, _):
                line.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil : "+ " + line.trimmingCharacters(in: .whitespaces)
            }
        }
        guard !lines.isEmpty else { return "\nIts code is the same as before." }
        let shown = lines.prefix(limit).joined(separator: "\n")
        return "\nIts code changed:\n" + shown
            + (lines.count > limit ? "\n(\(lines.count - limit) more lines changed)" : "")
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
        ObjectNames.typeName(of: name)
    }

    /// Makes an object, linking its tools; returns its handle.
    private func create(_ name: String, described description: String? = nil, spec: Spec) async throws -> ObjectID {
        let object = try await making { directory in
            try await directory.held(try await directory.create(name: name, description: description, spec: spec))
        }
        actorSystem.log.info("Created object", metadata: ["name": .string(name)])
        let handle = id(
            of: try DiscoverableObject.resolve(id: object.id, using: actorSystem), type: try await object.source.type)
        made[handle] = object
        await changed()
        return handle
    }

    /// Tells whoever follows the catalog that this session made or changed an object, which its
    /// scope's objects list as it is now.
    private func changed() async {
        if objectCatalog == nil { objectCatalog = await ObjectCatalog(actorSystem: actorSystem) }
        try? await objectCatalog?.changed()
    }

    /// An object's values now, all of them.
    func values(_ handle: ObjectID) async throws -> String {
        try Self.text(.object(try await currentValues(handle)))
    }

    /// An object's values now, by name, to say what an action changed: an object it holds is
    /// shown with what that object holds, so a change inside it is a change.
    func values(of handle: ObjectID) async throws -> [String: DiscoveryJSON] {
        let description = try await described(handle)
        var values: [String: DiscoveryJSON] = [:]
        for name in description.properties.keys {
            let value = try await call(handle) { try await $0.read(property: name) }
            values[name] = try await translate(value, schema: description.properties[name]) { reference in
                let minted = try await self.mintHandle(reference)
                guard case .string(let written) = minted, let id = try? await self.id(written: written),
                    let object = try? await self.object(id)
                else { return minted }
                return .string("`\(id)`, " + (try await Self.inside(object)))
            }
        }
        return values
    }

    /// An object's values now, by name.
    private func currentValues(_ handle: ObjectID) async throws -> [String: DiscoveryJSON] {
        let description = try await described(handle)
        var values: [String: DiscoveryJSON] = [:]
        for name in description.properties.keys {
            values[name] = try await read(handle, property: name)
        }
        return values
    }

    /// Uses one of your objects: what it holds now, with its actions as the tools it lands on.
    func use(_ handle: ObjectID) async throws -> CallReturn {
        let type = try await described(handle).type
        var lines = ["\(type) `\(handle)` now:", try await values(handle)]
        if case .failing(let failure)? = try await madeObject(handle)?.health {
            lines.append("Last failed: \(failure.written)")
        }
        return landing(lines.joined(separator: "\n"), on: .object(handle: handle))
    }

    /// An object's first page: enough identity and state to choose an action. Its action schemas
    /// are linked from the page instead of repeated in its text.
    func open(_ handle: ObjectID) async throws -> String {
        let description = try await described(handle)
        var lines = ["\(description.type) (id `\(handle)`)"]
        if let summary = Self.given(description.description) { lines.append(summary) }

        let current = try await values(handle)
        if current != "{}" { lines.append("Current values:\n" + current) }
        if case .failing(let failure)? = try await madeObject(handle)?.health {
            lines.append("Last failed: \(failure.written)")
        }

        if !description.actions.isEmpty {
            var actions: [String] = []
            let returnedType = returnedType(of: handle)
            for (name, action) in description.actions.sorted(by: { $0.key < $1.key }) {
                // One an action returned is used through its type's tools.
                let tool = ActionNaming.byHandle.name(returnedType?.rawValue ?? handle.description, name)
                actions.append("- \(tool)" + (Self.given(action.description).map { ": \($0)" } ?? ""))
            }
            lines.append("Actions:\n" + actions.joined(separator: "\n"))
        }
        link(.objectContents(handle))
        return lines.joined(separator: "\n\n")
    }

    /// The object made here that `name` is the handle of, written as its handle or as its name.
    /// A handle of an object made elsewhere can't be defined.
    private func madeObject(named name: String) async throws -> (handle: ObjectID, object: DynamicObject)? {
        for written in [ObjectNames.handle(for: name), name] {
            guard let handle = try? await id(written: written), let made = try await madeObject(handle) else {
                continue
            }
            return (handle, made)
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
            let handle = listed(entry)
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
    /// are offered. One an action returned is read through its type's tool.
    private func pageLink(_ handle: ObjectID) async -> any HailCore.Tool {
        if let type = returnedType(of: handle),
            let tool = try? TypedReadTool(session: self, type: type.rawValue, among: returned(type))
        {
            return tool
        }
        return ObjectReadTool(
            session: self, handle: handle, type: (try? await described(handle).type) ?? handle.description)
    }

    /// Removes an object made with create, for good.
    func remove(_ handle: ObjectID) async throws -> DiscoveryJSON {
        let identity = try await dynamicObject(handle).identity
        try await making { try await $0.remove(identity) }
        made[handle] = nil
        objects[handle] = nil
        return "removed"
    }

    /// Runs `body` on the directory where objects are made, with its errors as the model reads them.
    private func making<Result: Sendable>(_ body: (DynamicObjects) async throws -> Result) async throws -> Result {
        let directory = try await DynamicObjects.resolve(on: actorSystem)
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
    /// object is ever called as one.
    private func dynamicObject(_ handle: ObjectID) async throws -> DynamicObject {
        // One code named by its id is reached by it too.
        if (try? await madeObject(handle)) == nil, case .virtual = handle {
            if let named = try await DynamicObjects.resolve(on: actorSystem).existing(
                ObjectIdentity(rawValue: handle.name))
            {
                return named
            }
        }
        guard let made = try await madeObject(handle) else {
            throw ObjectToolError.failed(
                "`\(handle)` wasn't made with create_object, so it can't be changed or removed this way.")
        }
        return made
    }

    /// The object behind `handle` as one made here, or `nil` for any other object.
    func madeObject(_ handle: ObjectID) async throws -> DynamicObject? {
        if let known = made[handle] { return known }
        let object = try await object(handle)
        // One the directory holds, made by name.
        let directory = try await DynamicObjects.resolve(on: actorSystem)
        guard let identity = try await directory.identity(of: object.id) else { return nil }
        let made = try await directory.held(identity)
        self.made[handle] = made
        return made
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
    func usingPage(of handle: ObjectID) async throws -> ToolPage {
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
                links += await actionTools(of: handle).filter {
                    $0.name == ActionNaming.byHandle.name(handle.description, action)
                }
            }
        }
        return .text(text, links: links)
    }

    /// What an object does: a tool for each action, and one for its values. One an action returned
    /// is used through its type's tools, which take which one as their typed `object`.
    func actionTools(of handle: ObjectID, naming: ActionNaming = .byHandle) async -> [any HailCore.Tool] {
        var tools: [any HailCore.Tool] = []
        // One that can't describe itself now, such as a removed object, offers nothing.
        guard let description = try? await described(handle) else { return [] }
        let receivers = returnedType(of: handle).map(returned)
        for (name, action) in description.actions.sorted(by: { $0.key < $1.key }) {
            do {
                let choices = await choices(for: action.input)
                tools.append(
                    try ObjectActionTool(
                        session: self,
                        receiver: receivers.map { .typed(description.type, among: $0) } ?? .named(handle),
                        type: description.type, action: name, summary: action.description, input: action.input,
                        choices: choices,
                        naming: naming))
            } catch {
                actorSystem.log.warning(
                    "Object action has no usable schema",
                    metadata: [
                        "object_id": .string(handle.description), "action": .string(name), "error": .string("\(error)"),
                    ])
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
        func line(_ entry: DiscoveryJSON) -> String {
            let actions = texts(entry["actions"])
            let events = texts(entry["events"])
            return "- id: `\(text(entry["object_id"]) ?? "")`; type: `\(text(entry["type"]) ?? "")`"
                + (Self.given(text(entry["description"])).map { " — \($0)" } ?? "")
                + (actions.isEmpty ? "" : ". Takes \(actions.joined(separator: ", ")).")
                + (events.isEmpty ? "" : "; events: \(events.joined(separator: ", "))")
        }
        if case .array(let listed) = try await list() {
            // Agents are objects too, listed apart: the same tools reach them.
            let agentIDs = Set(agents.map(\.id.description))
            let agentEntries = listed.filter { text($0["object_id"]).map(agentIDs.contains) ?? false }
            let entries = listed.filter { !(text($0["object_id"]).map(agentIDs.contains) ?? false) }
            if !entries.isEmpty {
                let more = entries.count > limit ? ["…and \(entries.count - limit) more; search_objects finds them."] : []
                lines.append((["Available objects:"] + entries.prefix(limit).map(line) + more).joined(separator: "\n"))
            }
            if !agentEntries.isEmpty {
                lines.append((["Agents:"] + agentEntries.map(line)).joined(separator: "\n"))
            }
        }
        let madeHandles = try await runtimeObjects()
        lines.append(
            madeHandles.isEmpty
                ? "No objects have been created for you yet. create_object makes a new one."
                : "Your objects: " + madeHandles.map(\.description).joined(separator: ", ") + ".")

        // Give each object its own no-argument link. A generic `use_object` call asks the model
        // to repeat a handle in an argument, creating a second way to open the same page and an
        // easy place to send the title under the wrong key.
        let directoryHandles = try await entries().map { listed($0) }
        let handles = Set(directoryHandles + madeHandles).sorted()
        var objectLinks: [any HailCore.Tool] = []
        for handle in handles { objectLinks.append(await pageLink(handle)) }
        named = []
        let tools = try await ObjectTools(session: self).tools().filter { $0.name != "use_object" }
        return ToolPage(.text(lines.joined(separator: "\n\n")), links: tools + objectLinks)
    }

    /// Runs a call on a handle's object, explaining a failure the model can recover from.
    private func call<Value>(
        _ handle: ObjectID,
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
            throw ObjectToolError.unreachable(handle.description, reason: String(describing: error))
        } catch let error as RemoteCallError {
            throw ObjectToolError.unreachable(handle.description, reason: String(describing: error))
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
        case .actor(let actor, _)?:
            reference = actor
        case .named(let name, _)?:
            let named = try await id(named: name)
            link(.object(named))
            return .string(named.description)
        case .itself?, .unmade?, nil:
            throw ObjectToolError.failed("`\(value.inline)` isn't an object it can name.")
        }
        let object = try reference.resolve(using: actorSystem)
        // One made by code is its holder's: shown as what it is and holds, never as one to call.
        if DynamicObject.identity(of: object.id) != nil, try await !isHeld(object) {
            return .string(try await Self.inside(object))
        }
        let minted = id(of: object, type: try await object.describe().type)
        link(.object(minted))
        return .string(minted.description)
    }

    /// Whether the directory holds `object`, made by name.
    private func isHeld(_ object: DiscoverableObject) async throws -> Bool {
        try await DynamicObjects.resolve(on: actorSystem).identity(of: object.id) != nil
    }

    /// An object another holds, as its holder shows it: its type, and what it holds.
    private static func inside(_ object: DiscoverableObject) async throws -> String {
        let description = try await object.describe()
        var held: [String] = []
        for name in description.properties.keys.sorted() {
            held.append("\(name): \(try await object.read(property: name).inline)")
        }
        return "a `\(description.type)`" + (held.isEmpty ? "" : " holding " + held.joined(separator: ", "))
    }

    /// A handle in the model's arguments becomes a reference.
    private func resolveHandle(_ value: DiscoveryJSON) async throws -> DiscoveryJSON {
        guard case .string(let written) = value else { throw ObjectToolError.expectedHandle }
        return try DiscoveryJSON.reference(to: try await object(try await id(written: written)))
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
        let explained =
            "`\(argument)` is a list, but it's a mapping by name: each one under its own name, not as list items"
        guard case .array(let items)? = given[argument],
            case .object(let mapping) = items.reduce(
                into: DiscoveryJSON.object([:]),
                { merged, item in
                    guard case .object(var members) = merged, case .object(let entry) = item, entry.count == 1 else {
                        merged = .null
                        return
                    }
                    members.merge(entry) { first, _ in first }
                    merged = .object(members)
                }),
            let fixed = try? text([argument: .object(mapping)])
        else { return "\(explained)." }
        return "\(explained). Yours, as a mapping:\n\n"
            + fixed.split(separator: "\n").map { "    \($0)" }.joined(separator: "\n")
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
            "There's no object with id `\(handle)`. Find it with search_objects, by what it's for or what it does, or with list_objects for your own."
        case .unknownAction(let action, let handle, let available) where available.isEmpty:
            "`\(handle)` has no action `\(action)`: it has no actions yet. Edit it with edit_object to add its events."
        case .unknownAction(let action, let handle, let available):
            "`\(handle)` has no action `\(action)`. Its actions are: \(available.joined(separator: ", "))."
        case .unreachable(let handle, let reason):
            "The object with id `\(handle)` can't be reached right now (\(reason)). Find it again with search_objects or list_objects."
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
    case object(handle: ObjectID)

    private static let objectsName = "objects"

    var address: ToolPageAddress {
        switch self {
        case .objects: ToolPageAddress(rawValue: Self.objectsName)
        case .object(let handle): ToolPageAddress(rawValue: handle.description)
        }
    }

    /// Whether `address` is the objects page's: any other is an object's, by its id as written.
    static func isObjects(_ address: ToolPageAddress) -> Bool {
        address.rawValue == objectsName
    }
}

extension ObjectSession: ToolPages {
    /// An object's page as it is now. One that's no longer there is gone.
    public func open(_ address: ToolPageAddress) async throws(ToolPageUnavailable) -> ToolPage {
        do {
            if ObjectAddress.isObjects(address) { return try await objectsPage() }
            return try await usingPage(of: try await id(written: address.rawValue))
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
    let handle: ObjectID
    public static func run(in token: borrowing EffectToken<Self>) async throws -> CallReturn {
        let (session, handle) = token.withConfiguration { ($0.session, $0.handle) }
        return await session.page(try ObjectSession.text(try await session.remove(handle)))
    }
}

public struct UseObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.use"
    let session: ObjectSession
    let handle: ObjectID
    public static func run(in token: borrowing EffectToken<Self>) async throws -> CallReturn {
        let (session, handle) = token.withConfiguration { ($0.session, $0.handle) }
        return try await session.use(handle)
    }
}

/// Changes an object made here: what it does, as described, or who may use it.
public struct EditObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.edit"
    let session: ObjectSession
    let handle: ObjectID
    let edit: ObjectEdit
    public static func run(in token: borrowing EffectToken<Self>) async throws -> CallReturn {
        let (session, handle, edit) = token.withConfiguration { ($0.session, $0.handle, $0.edit) }
        switch edit {
        case .code(let change): return try await session.edit(handle, change: change)
        case .sharing(let audience, let level): return try await session.share(handle, with: audience, level)
        }
    }
}

/// One change to one of your objects: what it holds or does, or who may use it.
enum ObjectEdit: Sendable, Equatable {
    /// What to change in what it holds or does, in words: its Swift code is rewritten for it.
    case code(String)
    /// Whom it's shared with, and how far.
    case sharing(with: SharingAudience, SharingLevel)
}

/// Whom an object is shared with, as the model chooses it: the group the turn came in through,
/// that group's admins, or everyone.
enum SharingAudience: String, CaseIterable, Sendable, Equatable {
    case members = "this chat's members"
    case admins = "this chat's admins"
    case everyone

    /// Who it is for a call that came in through `group`.
    func audience(in group: GroupID) -> Audience {
        switch self {
        case .members: .group(group)
        case .admins: .admins(of: group)
        case .everyone: .everyone
        }
    }
}

/// How far an audience may go with an object: using it, changing it too, or not at all.
enum SharingLevel: String, CaseIterable, Sendable, Equatable {
    case read
    case write
    case none

    /// Its access, or none.
    var access: AccessLevel? {
        switch self {
        case .read: .read
        case .write: .write
        case .none: nil
        }
    }
}

public struct InvokeObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.invoke"
    let session: ObjectSession
    let handle: ObjectID
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
            let old = before[name] ?? .null
            let new = after[name] ?? .null
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
    public func effect(for input: Input) throws -> FindObjectsEffect {
        FindObjectsEffect(session: session, query: input.query)
    }
    public func run(
        _ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<FindObjectsEffect>
    ) async throws -> CallReturn {
        try await FindObjectsEffect.run(in: token)
    }
}

public struct ListObjectsTool: HailCore.Tool {
    public typealias Input = EmptyToolInput
    let session: ObjectSession
    public let name = "list_objects"
    public let description = "List every object by its id: the ones made for you, and the others."
    public func effect(for input: Input) throws -> ListObjectsEffect { ListObjectsEffect(session: session) }
    public func run(
        _ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ListObjectsEffect>
    ) async throws -> CallReturn {
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
    public func run(
        _ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<MakeObjectEffect>
    ) async throws -> CallReturn {
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
        let action = ActionKeys.toolName(of: action)
        return switch self {
        case .byHandle: "\(handle)_\(action)"
        case .asObject: "object_\(handle)_\(action)"
        }
    }
}

/// Which object a tool is for: one named, whose id is the tool's name, or one of a type an action
/// returned, which the model chooses as the tool's typed `object`, among those there are.
public enum Receiver: Sendable, Equatable {
    case named(ObjectID)
    case typed(String, among: [ObjectID])

    /// The argument that chooses the object, for a tool of a type.
    static let property = "object"

    /// The schema `input` with the object to choose, for a tool of a type: a `type`, one of `ids`.
    func schema(_ input: DiscoveryJSON?) -> DiscoveryJSON? {
        guard case .typed(let type, let ids) = self else { return input }
        var schema: [String: DiscoveryJSON] = ["type": "object", "properties": [:]]
        if case .object(let given)? = input { schema = given }
        var properties: [String: DiscoveryJSON] = [:]
        if case .object(let given)? = schema["properties"] { properties = given }
        let choice: DiscoveryJSON = .object([
            "type": .string("string"), "description": .string("Which `\(type)`, by its id."),
            "enum": .array(ids.map { .string($0.description) }),
        ])
        properties[Self.property] = choice
        schema["properties"] = .object(properties)
        var required: [DiscoveryJSON] = []
        if case .array(let given)? = schema["required"] { required = given }
        schema["required"] = .array([.string(Self.property)] + required)
        if case .array(let order)? = schema["x-order"] { schema["x-order"] = .array([.string(Self.property)] + order) }
        return .object(schema)
    }

    /// The object `arguments` are for, and the arguments that are the action's own.
    func choosing(in arguments: DiscoveryJSON, for tool: String) throws -> (id: ObjectID, arguments: DiscoveryJSON) {
        switch self {
        case .named(let id):
            return (id, arguments)
        case .typed(_, let ids):
            guard case .object(var members) = arguments, case .string(let written)? = members[Self.property] else {
                throw ObjectToolError.missingArguments(tool, missing: [Self.property], unexpected: [])
            }
            guard let id = ids.first(where: { $0.description == written }) else {
                throw ObjectToolError.failed(
                    UnofferedChoice(given: written, offered: ids.map(\.description), argument: Self.property)
                        .description)
            }
            members[Self.property] = nil
            return (id, .object(members))
        }
    }
}

/// One action as a tool of its own, such as `shop_startShift`, or `Reminder_complete` for a
/// reminder an action returned: the model calls it with typed arguments, the way it calls any
/// tool. Objects are passed and returned by id.
public struct ObjectActionTool: HailCore.Tool {
    public typealias Input = GeneratedContent
    public typealias Effect = InvokeObjectEffect

    let session: ObjectSession
    let receiver: Receiver
    let type: String
    let action: String
    let summary: String?
    /// What the action is called, as a tool.
    let naming: ActionNaming
    /// The action's input schema, as the object describes it; `nil` when it takes no arguments.
    let input: DiscoveryJSON?
    private let parameters: GenerationSchema

    init(
        session: ObjectSession, receiver: Receiver, type: String, action: String, summary: String?,
        input: DiscoveryJSON?, choices: [String: [ObjectID]] = [:], naming: ActionNaming = .byHandle
    ) throws {
        self.session = session
        self.receiver = receiver
        self.type = type
        self.action = action
        self.summary = summary
        self.naming = naming
        self.input = input
        let schema = Self.handles(
            in: receiver.schema(input) ?? ["type": "object", "properties": [:]], choices: choices)
        self.parameters = try JSONDecoder().decode(GenerationSchema.self, from: JSONEncoder().encode(schema))
    }

    public var name: String {
        switch receiver {
        case .named(let id): naming.name(id.description, action)
        case .typed(let type, _): naming.name(type, action)
        }
    }
    public var description: String {
        let on: String =
            switch receiver {
            case .named(let id): "\(type) `\(id)`"
            case .typed(let type, _): "a `\(type)`"
            }
        return "\(action) on \(on)" + (summary.map { ": \($0)" } ?? "")
    }
    public var schema: ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: parameters)
    }

    public func effect(for arguments: GeneratedContent) throws -> InvokeObjectEffect {
        let given = try JSONDecoder().decode(DiscoveryJSON.self, from: Data(arguments.jsonString.utf8))
        let (id, own) = try receiver.choosing(in: given, for: name)
        let text = String(decoding: try JSONEncoder().encode(own), as: UTF8.self)
        return InvokeObjectEffect(session: session, handle: id, action: action, arguments: input == nil ? nil : text)
    }

    public func run(
        _ input: GeneratedContent, in scope: borrowing ToolScope<Never>,
        token: borrowing EffectToken<InvokeObjectEffect>
    ) async throws
        -> CallReturn
    {
        let page = try await InvokeObjectEffect.run(in: token)
        return page
    }

    /// The schema as the model writes it: a reference to an object is its handle, a string, and an
    /// optional value is the value, since leaving it out of `required` already makes it optional.
    /// - Parameter choices: For each protocol an argument takes an object conforming to, as code
    ///   writes it, the ids of the objects that do: only they can be given.
    static func handles(in schema: DiscoveryJSON, choices: [String: [ObjectID]] = [:]) -> DiscoveryJSON {
        switch schema {
        case .object(let members) where members["x-actor-reference"] == .bool(true):
            // An object is given by its id, as objects are listed, and is of the type its code
            // writes.
            let written = DiscoveryJSON.object(members).swiftType ?? "Object"
            let takes =
                members["description"].flatMap { if case .string(let text) = $0 { ", " + text } else { nil } } ?? ""
            var handle: [String: DiscoveryJSON] = [
                "type": "string", "description": .string("The id of a `\(written)`\(takes)."),
            ]
            if let ids = choices[written], !ids.isEmpty { handle["enum"] = .array(ids.map { .string($0.description) }) }
            return .object(handle)
        case .object(let members):
            if case .array(let options)? = members["anyOf"] {
                let present = options.filter { $0["type"] != "null" }
                if present.count == 1 { return handles(in: present[0], choices: choices) }
            }
            return .object(members.mapValues { handles(in: $0, choices: choices) })
        case .array(let items): return .array(items.map { handles(in: $0, choices: choices) })
        default: return schema
        }
    }
}

/// One of your objects, as a root tool's arguments choose it: the schema offers only them, so
/// no other can be named.
struct YourObject {
    static let property = "object"
    let objects: [ObjectID]

    func property(_ about: String) -> DynamicGenerationSchema.Property {
        .init(
            name: Self.property, description: about,
            schema: .init(type: String.self, guides: [.anyOf(objects.map(\.description))]))
    }

    /// The object the arguments name, as it's written: missing is a missing argument, and one
    /// that isn't yours isn't on offer.
    func object(in input: GeneratedContent, for tool: String) throws -> ObjectID {
        let written: String
        do {
            written = try input.value(String.self, forProperty: Self.property)
        } catch GeneratedContentError.propertyNotFound {
            throw ObjectToolError.missingArguments(tool, missing: [Self.property], unexpected: [])
        }
        guard let object = objects.first(where: { $0.description == written }) else {
            throw ObjectToolError.failed(
                UnofferedChoice(given: written, offered: objects.map(\.description), argument: Self.property)
                    .description)
        }
        return object
    }
}

/// Uses one of your objects: shows what it holds now, and offers its actions.
/// Reads one object: what it holds now, and what it takes. Its actions are offered after it.
public struct ObjectReadTool: HailCore.Tool {
    public typealias Input = EmptyToolInput
    let session: ObjectSession
    let handle: ObjectID
    let type: String
    /// Marked as an object's, so it isn't taken for one of its actions.
    public var name: String { "object_\(handle)" }
    public var description: String { "What \(type) `\(handle)` holds now, and what it takes." }
    public func effect(for input: Input) throws -> UseObjectEffect { UseObjectEffect(session: session, handle: handle) }
    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<UseObjectEffect>)
        async throws -> CallReturn
    {
        try await UseObjectEffect.run(in: token)
    }
}

/// Reads one of the objects of a type an action returned, chosen by its id: what it holds now, and
/// what it takes. Its actions are offered after it.
public struct TypedReadTool: HailCore.Tool {
    public typealias Input = GeneratedContent
    let session: ObjectSession
    let receiver: Receiver
    let type: String
    private let parameters: GenerationSchema

    init(session: ObjectSession, type: String, among ids: [ObjectID]) throws {
        self.session = session
        self.type = type
        receiver = .typed(type, among: ids)
        let schema = receiver.schema(nil) ?? [:]
        parameters = try JSONDecoder().decode(GenerationSchema.self, from: JSONEncoder().encode(schema))
    }

    public var name: String { "object_\(type)" }
    public var description: String { "What a `\(type)` holds now, and what it takes." }
    public var schema: ToolDefinition { ToolDefinition(name: name, description: description, parameters: parameters) }
    public func effect(for input: Input) throws -> UseObjectEffect {
        let given = try JSONDecoder().decode(DiscoveryJSON.self, from: Data(input.jsonString.utf8))
        return UseObjectEffect(session: session, handle: try receiver.choosing(in: given, for: name).id)
    }
    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<UseObjectEffect>)
        async throws -> CallReturn
    {
        try await UseObjectEffect.run(in: token)
    }
}

public struct UseObjectTool: HailCore.Tool {
    public typealias Input = GeneratedContent
    let session: ObjectSession
    /// Your objects, to choose from.
    let objects: YourObject
    public let name = "use_object"
    public let description =
        "Open an object to see its current values and available actions. Opening it does not run an action."
    private let parameters: GenerationSchema

    init(session: ObjectSession, objects: [ObjectID]) throws {
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
    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<UseObjectEffect>)
        async throws -> CallReturn
    {
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
    public let description = "Change one of your objects: what it holds or does, or who may use it."
    static let editProperty = "edit"
    static let withProperty = "with"
    static let levelProperty = "level"
    private let parameters: GenerationSchema

    init(session: ObjectSession, objects: [ObjectID]) throws {
        self.session = session
        self.objects = YourObject(objects: objects)
        // One edit, of either kind: never both, and never neither.
        let edits = DynamicGenerationSchema(
            name: "Edit",
            anyOf: [
                DynamicGenerationSchema(
                    name: "WhatItDoes", description: "What it holds or does: its Swift code is rewritten for it.",
                    properties: [
                        .init(
                            name: Self.changeProperty, description: "What to change.", schema: .init(type: String.self))
                    ]),
                DynamicGenerationSchema(
                    name: "WhoMayUseIt", description: "Who may use it, and how far.",
                    properties: [
                        .init(
                            name: Self.withProperty, description: "Whom.",
                            schema: .init(
                                type: String.self, guides: [.anyOf(SharingAudience.allCases.map(\.rawValue))])),
                        .init(
                            name: Self.levelProperty,
                            description: "read uses it; write also changes it and who may use it; none takes it away.",
                            schema: .init(type: String.self, guides: [.anyOf(SharingLevel.allCases.map(\.rawValue))])),
                    ]),
            ])
        self.parameters = try GenerationSchema(
            root: DynamicGenerationSchema(
                name: "EditObject",
                properties: [
                    self.objects.property("The object to change."),
                    .init(name: Self.editProperty, description: "What to change.", schema: edits),
                ]),
            dependencies: [])
    }

    public var schema: ToolDefinition { ToolDefinition(name: name, description: description, parameters: parameters) }

    public func effect(for input: Input) throws -> EditObjectEffect {
        EditObjectEffect(
            session: session, handle: try objects.object(in: input, for: name),
            edit: try Self.edit(in: input, for: name))
    }

    /// The edit the arguments make: what to change, in words, or whom to share it with and how far.
    static func edit(in input: Input, for tool: String) throws -> ObjectEdit {
        guard let edit = try? input.value(GeneratedContent.self, forProperty: Self.editProperty) else {
            throw ObjectToolError.missingArguments(tool, missing: [Self.editProperty], unexpected: [])
        }
        let change = try edit.text(Self.changeProperty)
        let with = try edit.text(Self.withProperty)
        let level = try edit.text(Self.levelProperty)
        switch (change, with, level) {
        case (let change?, nil, nil):
            return .code(change)
        case (nil, let with?, let level?):
            guard let audience = SharingAudience(rawValue: with) else {
                throw ObjectToolError.failed(
                    UnofferedChoice(
                        given: with, offered: SharingAudience.allCases.map(\.rawValue), argument: Self.withProperty
                    ).description)
            }
            guard let reach = SharingLevel(rawValue: level) else {
                throw ObjectToolError.failed(
                    UnofferedChoice(
                        given: level, offered: SharingLevel.allCases.map(\.rawValue), argument: Self.levelProperty
                    ).description)
            }
            return .sharing(with: audience, reach)
        case (.some, _, _):
            let unexpected = [with.map { _ in Self.withProperty }, level.map { _ in Self.levelProperty }]
            throw ObjectToolError.missingArguments(tool, missing: [], unexpected: unexpected.compactMap { $0 })
        case (nil, _, _):
            let missing = [with == nil ? Self.withProperty : nil, level == nil ? Self.levelProperty : nil]
            throw ObjectToolError.missingArguments(tool, missing: missing.compactMap { $0 }, unexpected: [])
        }
    }
    public func run(
        _ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<EditObjectEffect>
    ) async throws -> CallReturn {
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

    init(session: ObjectSession, objects: [ObjectID]) throws {
        self.session = session
        self.objects = YourObject(objects: objects)
        self.parameters = try GenerationSchema(
            root: DynamicGenerationSchema(
                name: "RemoveObject", properties: [self.objects.property("The object to remove.")]),
            dependencies: [])
    }

    public var schema: ToolDefinition { ToolDefinition(name: name, description: description, parameters: parameters) }

    public func effect(for input: Input) throws -> RemoveObjectEffect {
        RemoveObjectEffect(session: session, handle: try objects.object(in: input, for: name))
    }
    public func run(
        _ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<RemoveObjectEffect>
    ) async throws -> CallReturn {
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
        guard case .structure(let properties, _) = kind, let property = properties[name], property.kind != .null else {
            return nil
        }
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
