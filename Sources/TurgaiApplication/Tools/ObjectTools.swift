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

    /// Something a result names, whose tools it links to.
    private enum Named: Equatable {
        /// A reference to an object: following it opens the object's first page.
        case object(String)
        /// An open object's contents: its actions and current values, and removing it.
        case objectContents(String)
        /// An object being defined: the steps that change what it holds and does.
        case objectDefining(String)
        /// One action of an object, such as the shop's `startShift`.
        case action(String, String)
    }

    public init(
        actorSystem: ClusterSystem,
        objectCatalog: ObjectCatalog? = nil,
        scopes: [ObjectScope]
    ) {
        self.actorSystem = actorSystem
        self.objectCatalog = objectCatalog
        self.scopes = scopes
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

    /// The objects made in this session's scopes: what belongs to the agent's owner, kept by the
    /// runtime, by name only, so a long list stays short. The page links to each: what one does
    /// is on its own page, a call away.
    func listMade() async throws -> String {
        let yours = try await runtimeObjects()
        guard !yours.isEmpty else { return "No objects have been created for you yet. Use create_object if the task needs a new object." }
        for handle in yours { link(.object(handle)) }
        return "Your objects: " + yours.joined(separator: ", ") + "."
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
    private func described(_ handle: String) async throws -> ObjectDescription {
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
            result = try await call(handle) { try await $0.invoke(name, arguments: arguments) }
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

    /// Makes a new object: one that holds and does nothing yet, defined a step at a time, each step
    /// changing it at once; or, `like` one of yours, following its rules, shared from then on, the
    /// way an Erlang module is written once and spawned again with state of its own.
    func make(_ name: String, like original: String? = nil) async throws -> CallReturn {
        if let existing = try await madeObject(named: name) {
            link(.object(existing.handle))
            return await page("`\(existing.handle)` already exists.")
        }
        guard let original else {
            let handle = try await create(name, spec: .written(.empty))
            return landing("Created empty \(handle). Now add the data it needs and define the actions needed for the current task.", on: .making(handle: handle))
        }
        let handle = try await create(name, spec: .sameAs(try await dynamicObject(original)))
        return landing("Made \(handle): it does what \(original) does, and holds its own values.", on: .making(handle: handle))
    }

    /// Opens an object made here to change it: its define steps, each changing it at once.
    func edit(_ handle: String) async throws -> CallReturn {
        _ = try await dynamicObject(handle)
        return landing("Opened editing tools for \(handle). Each change is saved immediately.", on: .making(handle: handle))
    }

    /// Applies a define step to an object made here, saying what it is now, and what's still
    /// missing. A step that doesn't fit leaves it as it was.
    func define(_ handle: String, change: Change) async throws -> CallReturn {
        let object = try await dynamicObject(handle)
        let written = try await object.written
        let edit: Behavior.Written.Edit
        switch change {
        case .edit(let change):
            edit = change
        case .values(let values):
            let before = try await currentValues(handle)
            try await call(handle) { _ in try await object.set(values: values) }
            let current = try await currentValues(handle)
            guard before != current else {
                throw ObjectToolError.failed("No value changed on `\(handle)`; its current state is unchanged.")
            }
            let behavior = try Self.reading { try Behavior(name: handle, written: written) }
            let state = Self.overview(of: behavior, handle: handle, now: current)
            return landing("Updated current values.\n\nCurrent state:\n\(state)", on: .making(handle: handle))
        }
        let spec = written.applying(edit)
        let before = try Self.reading { try Behavior(name: handle, written: written) }
        let after = try Self.reading { try Behavior(name: handle, written: spec) }
        guard before.fields != after.fields || before.clauses != after.clauses else {
            throw ObjectToolError.failed("No changes were made to `\(handle)` because this definition is already saved.")
        }
        let identity = try await object.identity
        try await making { try await $0.update(identity, spec: spec) }
        try await catalogue(handle)
        let current = try await currentValues(handle)
        let changes = Self.changes(from: before, to: after)
        let state = Self.overview(of: after, handle: handle, now: current)
        return landing("\(changes)\n\nCurrent state:\n\(state)", on: .making(handle: handle))
    }

    /// What a step changed: the data it now holds, and each event whose rules changed, with all
    /// its rules, top to bottom, the way they're tried.
    static func changes(from before: Behavior, to after: Behavior) -> String {
        let held = after.fields.keys.sorted().compactMap { name -> String? in
            guard let field = after.fields[name] else { return nil }
            guard let previous = before.fields[name] else {
                return "holds \(name), starting at \(field.initial.inline)"
            }
            guard previous != field else { return nil }
            return "\(name) now starts as \(field.initial.inline)"
        }
        let events = after.messages.filter { before.rules(of: $0.name) != after.rules(of: $0.name) }.map { message in
            message.written + ":\n" + after.rules(of: message.name).map { "  " + $0 }.joined(separator: "\n")
        }
        let gone = before.messages.map(\.name).filter { name in !after.messages.contains { $0.name == name } }.map { "\($0) is gone" }
        let changed = held + events + gone
        let eventNote = events.isEmpty ? [] : ["Saved these instructions. No action was run."]
        return (changed + eventNote).joined(separator: "\n")
    }

    /// The one thing to do next with an object, from what it holds and does now, naming its tool.
    static func next(for spec: Behavior.Written, handle: String) -> String {
        if spec.fields.isEmpty {
            return "Next: add the data needed for this task with \(handle)_add_data, then define its actions with \(handle)_add_event."
        }
        if spec.receive.isEmpty {
            return "Next: define the actions needed for this task with \(handle)_add_event."
        }
        return "If the task needs more data or actions, define them with the editing tools. When the required actions are defined, call \(handle) to open them."
    }

    /// Makes an object, linking its tools; returns its handle.
    private func create(_ name: String, spec: Spec) async throws -> String {
        let identity = try await making { try await $0.create(name: name, spec: spec) }
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

    /// An object being made, in a few lines: what it holds now, and its events with what each
    /// does, top to bottom. One without data or events says it isn't set up yet, which can't be
    /// read as its data being empty, such as a shopping list with no items.
    static func overview(of behavior: Behavior, handle: String, now values: [String: DiscoveryJSON]) -> String {
        let fields = behavior.fields.keys.sorted().map { name in
            "\(name): \((values[name] ?? behavior.fields[name]?.initial ?? .null).inline)"
        }
        let events = behavior.messages.map { message in
            "  \(message.written):\n" + behavior.rules(of: message.name).map { "    " + $0 }.joined(separator: "\n")
        }
        return "Object: \(handle)\nCurrent values:\n"
            + (fields.isEmpty ? "- None defined." : fields.map { "- " + $0 }.joined(separator: "\n"))
            + "\nDefined actions and received events:\n"
            + (events.isEmpty ? "- None defined." : events.joined(separator: "\n"))
    }

    /// Runs `body`, with a spec's errors as the model reads them.
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

    /// An object's values now, by name.
    private func currentValues(_ handle: String) async throws -> [String: DiscoveryJSON] {
        let description = try await described(handle)
        var values: [String: DiscoveryJSON] = [:]
        for name in description.properties.keys {
            values[name] = try await read(handle, property: name)
        }
        return values
    }

    /// Uses one of your objects: what it holds now, and its actions.
    func use(_ handle: String) async throws -> CallReturn {
        _ = try await object(handle)
        return landing("Opened \(handle).", on: .object(handle: handle))
    }

    /// An object's first page: enough identity and state to choose an action. Its action schemas
    /// are linked from the page instead of repeated in its text.
    func open(_ handle: String) async throws -> String {
        let description = try await described(handle)
        var lines = ["\(description.title) (`\(handle)`)"]
        if let summary = Self.given(description.description) { lines.append(summary) }

        let current = try await values(handle)
        if current != "{}" { lines.append("Current values:\n" + current) }

        if !description.actions.isEmpty {
            var actions: [String] = []
            for (name, action) in description.actions.sorted(by: { $0.key < $1.key }) {
                actions.append(
                    "- \(handle)_\(name)" + (Self.given(action.description).map { ": \($0)" } ?? "")
                        + (try await wanting(action.input)))
            }
            lines.append("Actions:\n" + actions.joined(separator: "\n"))
            lines.append(
                "Use the matching actions now to fulfill the current task, then answer from the resulting values. "
                    + "Don't ask again when the task already supplies everything an action needs.")
        }
        link(.objectContents(handle))
        return lines.joined(separator: "\n\n")
    }

    /// What an action wants of the objects given to it, in words, and whether any of yours fits.
    private func wanting(_ input: DiscoveryJSON?) async throws -> String {
        var lines = ""
        for (parameter, want) in try Self.reading({ try Want.wants(in: input) }).sorted(by: { $0.key < $1.key }) {
            let fits = try await fitting(want).isEmpty ? " None of your created objects meets this requirement yet." : ""
            lines += "\n  Argument \(parameter) needs an object that \(want.written).\(fits)"
        }
        return lines
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
    private static func given(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
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
        } catch let error as BehaviorError {
            throw ObjectToolError.failed(error.description)
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
    private func madeObject(_ handle: String) async throws -> DynamicObject? {
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
    func usingPage(of handle: String) async throws -> Page {
        await linked(try await open(handle))
    }

    /// An object made here as it's being made: what it holds and does so far, and what's next.
    /// Its definition steps and every action that already works are links on the same live page.
    func makingPage(of handle: String) async throws -> Page {
        let object = try await dynamicObject(handle)
        let spec = try await object.written
        let behavior = try Self.reading { try Behavior(name: handle, written: spec) }
        let sharing = try await sharing(object)
        link(.object(handle))
        link(.objectDefining(handle))
        // While it holds and does nothing, the page says how an object is made.
        let asked = try await asked(excluding: handle)
        let fits = Self.fits(behavior.description(title: handle, values: [:]), asked: asked)
        for fit in fits { link(.action(fit.by, fit.action)) }
        let shared =
            sharing.isEmpty
            ? ""
            : "Shared definition with: \(sharing.joined(separator: ", ")). Changes to data definitions and event rules affect all these objects. Use \(handle)_set_value to change only this object's current values.\n\n"
        return await linked(
            Self.overview(of: behavior, handle: handle, now: try await currentValues(handle)) + "\n\n" + shared
                + Self.fitting(fits, handle: handle) + Self.asking(asked, by: spec, handle: handle) + Self.next(for: spec, handle: handle))
    }

    /// The other objects following the rules `object` follows, by name.
    private func sharing(_ object: DynamicObject) async throws -> [String] {
        let identity = try await object.identity
        return try await making { try await $0.sharing(identity) }
    }

    /// The actions an object, as it describes itself, can now be given to: each asked-for action
    /// whose want it meets, once.
    static func fits(_ description: ObjectDescription, asked: [DefineStep.Asked]) -> [DefineStep.Asked] {
        var fits: [DefineStep.Asked] = []
        for asked in asked where asked.want.gap(in: description) == nil {
            guard !fits.contains(where: { $0.by == asked.by && $0.action == asked.action && $0.parameter == asked.parameter }) else { continue }
            fits.append(asked)
        }
        return fits
    }

    /// Where an object can be given now, naming the tools.
    static func fitting(_ fits: [DefineStep.Asked], handle: String) -> String {
        guard !fits.isEmpty else { return "" }
        return fits.map { "You can pass \(handle) as argument \($0.parameter) to \($0.by)_\($0.action)." }.joined(separator: " ") + "\n\n"
    }

    /// What other objects ask for that the object being made doesn't take yet, naming its tool.
    static func asking(_ asked: [DefineStep.Asked], by spec: Behavior.Written, handle: String) -> String {
        let untaken = asked.filter { asked in !spec.receive.contains { $0.on == asked.message.name } }
        guard !untaken.isEmpty else { return "" }
        return "Events other objects send:\n" + untaken.map { "- " + $0.written }.joined(separator: "\n")
            + "\nAdd an event with \(handle)_add_event only if \(handle) needs to handle it for the current task.\n\n"
    }

    /// The messages objects here ask for, from the objects given to their actions, each once,
    /// leaving out what `handle` asks for itself.
    func asked(excluding handle: String) async throws -> [DefineStep.Asked] {
        var asked: [DefineStep.Asked] = []
        for entry in try await entries() {
            let by = self.handle(for: entry.object, titled: entry.title)
            guard by != handle.lowercased() else { continue }
            for (action, parameters) in entry.wants.sorted(by: { $0.key < $1.key }) {
                for (parameter, want) in parameters.sorted(by: { $0.key < $1.key }) {
                    for message in want.takes.messages where !asked.contains(where: { $0.by == by && $0.message == message }) {
                        asked.append(DefineStep.Asked(by: by, action: action, parameter: parameter, want: want, message: message))
                    }
                }
            }
        }
        return asked
    }

    /// Your objects that take what `want` asks for, to choose from.
    private func fitting(_ want: Want) async throws -> [String] {
        var fitting: [String] = []
        for handle in try await yourObjects() where want.gap(in: try await described(handle)) == nil {
            fitting.append(handle)
        }
        return fitting
    }

    /// The current result, with the tools of what it named as its links. Taking it starts the
    /// next result's names.
    func page(_ text: String) async -> CallReturn {
        CallReturn(await linked(text))
    }

    /// `text`, with the tools of what it named as its links. Taking them starts the next names.
    private func linked(_ text: String) async -> Page {
        let named = self.named
        self.named = []
        var links: [any HailCore.Tool] = []
        for item in named {
            switch item {
            case .object(let handle):
                links.append(
                    PageLink(
                        name: handle, description: "Show \(handle)'s current values and available actions.",
                        address: ObjectAddress.object(handle: handle).address))
            case .objectDefining(let handle):
                links += await defineTools(of: handle)
            case .objectContents(let handle):
                links += await actionTools(of: handle)
            case .action(let handle, let action):
                links += await actionTools(of: handle).filter { $0.name == "\(handle)_\(action)" }
            }
        }
        return .text(text, links: links)
    }

    /// The steps that define an object made here, for it as it is now.
    func defineTools(of handle: String) async -> [any HailCore.Tool] {
        do {
            let object = try await dynamicObject(handle)
            return DefineStep.tools(
                handle: handle, spec: try await object.written, asked: try await asked(excluding: handle),
                shared: try await sharing(object).isEmpty ? .alone : .shared, session: self)
        } catch {
            // One that can't be read now, such as a removed object, offers no steps.
            actorSystem.log.warning(
                "Object has no define steps", metadata: ["handle": .string(handle), "error": .string("\(error)")])
            return []
        }
    }

    /// What an object does: a tool for each action, and one for its values.
    func actionTools(of handle: String) async -> [any HailCore.Tool] {
        var tools: [any HailCore.Tool] = []
        // One that can't describe itself now, such as a removed object, offers nothing.
        guard let description = try? await described(handle) else { return [] }
        for (name, action) in description.actions.sorted(by: { $0.key < $1.key }) {
            do {
                guard let offered = try await offered(for: action.input) else { continue }
                tools.append(
                    try ObjectActionTool(
                        session: self, handle: handle, title: description.title, action: name,
                        summary: action.description, input: action.input, offered: offered))
            } catch {
                actorSystem.log.warning(
                    "Object action has no usable schema",
                    metadata: ["handle": .string(handle), "action": .string(name), "error": .string("\(error)")])
            }
        }
        return tools
    }

    /// The objects to choose from for each parameter of an action that wants one, by parameter;
    /// `nil` when one of them has none to choose from yet, so the action can't be called.
    private func offered(for input: DiscoveryJSON?) async throws -> [String: ObjectActionTool.Offer]? {
        var offered: [String: ObjectActionTool.Offer] = [:]
        for (parameter, want) in try Self.reading({ try Want.wants(in: input) }) {
            let fitting = try await fitting(want)
            guard !fitting.isEmpty else { return nil }
            offered[parameter] = ObjectActionTool.Offer(want: want, objects: fitting)
        }
        return offered
    }

    /// The objects page: what they're for, the objects here, by handle, with what each does, and
    /// yours; its links are the tools to find and make objects, and a direct page link for each
    /// object. The handle belongs in the link, so opening an object takes no guessed arguments.
    func objectsPage(limit: Int = 20) async throws -> Page {
        func text(_ value: DiscoveryJSON?) -> String? { if case .string(let text)? = value { text } else { nil } }
        func texts(_ value: DiscoveryJSON?) -> [String] {
            guard case .array(let values)? = value else { return [] }
            return values.compactMap { text($0) }
        }
        var lines = [ObjectTools.description]
        if case .array(let entries) = try await list(), !entries.isEmpty {
            let shown = entries.prefix(limit).map { entry in
                let actions = texts(entry["actions"]), events = texts(entry["events"])
                return "- id: `\(text(entry["handle"]) ?? "")`; name: `\(text(entry["title"]) ?? "")`"
                    + "; purpose: " + (text(entry["description"]) ?? "not stated")
                    + (actions.isEmpty ? "" : "; actions: \(actions.joined(separator: ", "))")
                    + (events.isEmpty ? "" : "; events: \(events.joined(separator: ", "))")
            }
            let more = entries.count > limit ? ["…and \(entries.count - limit) more; search_objects finds them."] : []
            lines.append((["Available objects:"] + shown + more).joined(separator: "\n"))
        }
        let madeHandles = try await runtimeObjects()
        lines.append(
            madeHandles.isEmpty
                ? "No objects have been created for you yet. Use create_object if the task needs a new object."
                : "Your objects: " + madeHandles.joined(separator: ", ") + ".")

        // Give each object its own no-argument link. A generic `use_object` call asks the model
        // to repeat a handle in an argument, creating a second way to open the same page and an
        // easy place to send the title under the wrong key.
        let directoryHandles = try await entries().map { handle(for: $0.object, titled: $0.title) }
        let handles = Set(directoryHandles + madeHandles).sorted()
        let objectLinks: [any HailCore.Tool] = handles.map { handle in
            PageLink(
                name: handle,
                description: "Show \(handle)'s current values and available actions.",
                address: ObjectAddress.object(handle: handle).address)
        }
        named = []
        let tools = try await ObjectTools(session: self).tools().filter { $0.name != "use_object" }
        return Page(.text(lines.joined(separator: "\n\n")), links: tools + objectLinks)
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

    /// A reference in a result becomes a handle.
    private func mintHandle(_ value: DiscoveryJSON) async throws -> DiscoveryJSON {
        let object = try value.decode(ActorReference.self).resolve(using: actorSystem)
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
        else { return "\(explained), such as:\n\n    \(argument):\n      name: {…}" }
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
            case .object(let fields): return fields["id"] != nil
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
/// Where an object's pages are: the object itself, to use it; and, for one made here, the object
/// as it's being made.
enum ObjectAddress: Hashable {
    /// The objects: what's here, and the tools to find, make and use them.
    case objects
    case object(handle: String)
    case making(handle: String)

    private static let objectsName = "objects"
    private static let makingSuffix = "/making"

    var address: PageAddress {
        switch self {
        case .objects: PageAddress(rawValue: Self.objectsName)
        case .object(let handle): PageAddress(rawValue: handle.lowercased())
        case .making(let handle): PageAddress(rawValue: handle.lowercased() + Self.makingSuffix)
        }
    }

    /// The address read back: only this type writes them, so routing is all it takes.
    init(_ address: PageAddress) {
        let raw = address.rawValue
        if raw == Self.objectsName {
            self = .objects
        } else if raw.hasSuffix(Self.makingSuffix) {
            self = .making(handle: String(raw.dropLast(Self.makingSuffix.count)))
        } else {
            self = .object(handle: raw)
        }
    }
}

extension ObjectSession: Pages {
    /// An object's page as it is now. One that's no longer there is gone.
    public func open(_ address: PageAddress) async throws(PageUnavailable) -> Page {
        do {
            switch ObjectAddress(address) {
            case .objects: return try await objectsPage()
            case .object(let handle): return try await usingPage(of: handle)
            case .making(let handle): return try await makingPage(of: handle)
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

/// Makes an object in the runtime.
public struct MakeObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.make"
    let session: ObjectSession
    let objectName: String
    /// One of yours whose rules it follows, or `nil` for a new, empty one.
    let like: String?
    public static func run(in token: borrowing EffectToken<Self>) async throws -> CallReturn {
        let (session, name, like) = token.withConfiguration { ($0.session, $0.objectName, $0.like) }
        return try await session.make(name, like: like)
    }
}

/// Changes what an object made here holds or does, at once.
public struct DefineObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.define"
    let session: ObjectSession
    let handle: String
    let change: Change
    public static func run(in token: borrowing EffectToken<Self>) async throws -> CallReturn {
        let (session, handle, change) = token.withConfiguration { ($0.session, $0.handle, $0.change) }
        return try await session.define(handle, change: change)
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

public struct EditObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.edit"
    let session: ObjectSession
    let handle: String
    public static func run(in token: borrowing EffectToken<Self>) async throws -> CallReturn {
        let (session, handle) = token.withConfiguration { ($0.session, $0.handle) }
        return try await session.edit(handle)
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
        let result = try await session.invoke(handle, action: action, arguments: arguments)
        let state = try await session.open(handle)
        let reply = result == .null ? "Completed `\(action)` on `\(handle)`." : "Result: \(try ObjectSession.text(result))"
        return await session.page("\(reply)\n\nObject state after the action:\n\(state)")
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
        "Objects store information and perform actions. Open an object to see its current values and the actions you can call. Create an object when the task needs something new."

    /// The link a turn starts from: going there shows the objects page, with what's here and the
    /// tools to find, make and use them.
    public static var link: PageLink {
        PageLink(name: "objects", description: description, address: ObjectAddress.objects.address)
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
            try CreateObjectLikeTool(session: session, objects: objects),
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
        "Find objects by their purpose or actions. Returns matching object IDs and links to open them. Includes available Mac apps, such as Reminders."
    public func effect(for input: Input) throws -> FindObjectsEffect { FindObjectsEffect(session: session, query: input.query) }
    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<FindObjectsEffect>) async throws -> CallReturn {
        try await FindObjectsEffect.run(in: token)
    }
}

public struct ListObjectsTool: HailCore.Tool {
    public typealias Input = EmptyToolInput
    let session: ObjectSession
    public let name = "list_objects"
    public let description = "List objects created for you, with links to open their current values and actions."
    public func effect(for input: Input) throws -> ListObjectsEffect { ListObjectsEffect(session: session) }
    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ListObjectsEffect>) async throws -> CallReturn {
        try await ListObjectsEffect.run(in: token)
    }
}

public struct CreateObjectTool: HailCore.Tool {
    public typealias Input = GeneratedContent
    static let nameProperty = "name"

    let session: ObjectSession
    public let name = "create_object"
    public let description =
        "Create an empty object and open its editing tools. Then add its data and define its actions. To find an existing object, use search_objects."
    private let parameters: GenerationSchema

    init(session: ObjectSession) throws {
        self.session = session
        self.parameters = try GenerationSchema(
            root: DynamicGenerationSchema(name: "CreateObject", properties: [
                .init(
                    name: Self.nameProperty, description: "The name of the new object. It must not already exist.",
                    schema: .init(type: String.self))
            ]),
            dependencies: [])
    }

    public var schema: ToolDefinition { ToolDefinition(name: name, description: description, parameters: parameters) }

    public func effect(for input: Input) throws -> MakeObjectEffect {
        guard let objectName = try input.text(Self.nameProperty) else {
            throw ObjectToolError.missingArguments(name, missing: [Self.nameProperty], unexpected: [])
        }
        return MakeObjectEffect(session: session, objectName: objectName, like: nil)
    }
    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<MakeObjectEffect>) async throws -> CallReturn {
        try await MakeObjectEffect.run(in: token)
    }
}

/// Creates an object that follows the rules one of yours follows, holding its own values: the way
/// an Erlang module is written once and spawned again with state of its own.
public struct CreateObjectLikeTool: HailCore.Tool {
    public typealias Input = GeneratedContent
    let session: ObjectSession
    /// Your objects, to choose from: the only ones it can be like.
    let objects: YourObject
    public let name = "create_object_like"
    public let description =
        "Create an object with a shared definition and separate current values. Changes to the shared data definitions and event rules affect both objects."
    private let parameters: GenerationSchema

    init(session: ObjectSession, objects: [String]) throws {
        self.session = session
        self.objects = YourObject(objects: objects)
        self.parameters = try GenerationSchema(
            root: DynamicGenerationSchema(name: "CreateObjectLike", properties: [
                self.objects.property("The ID of the object whose definition to share."),
                .init(
                    name: CreateObjectTool.nameProperty, description: "The name of the new object.",
                    schema: .init(type: String.self)),
            ]),
            dependencies: [])
    }

    public var schema: ToolDefinition { ToolDefinition(name: name, description: description, parameters: parameters) }

    public func effect(for input: Input) throws -> MakeObjectEffect {
        guard let objectName = try input.text(CreateObjectTool.nameProperty) else {
            throw ObjectToolError.missingArguments(name, missing: [CreateObjectTool.nameProperty], unexpected: [])
        }
        return MakeObjectEffect(session: session, objectName: objectName, like: try objects.object(in: input, for: name))
    }
    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<MakeObjectEffect>) async throws -> CallReturn {
        try await MakeObjectEffect.run(in: token)
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
    /// The action's input schema, as the object describes it; `nil` when it takes no arguments.
    let input: DiscoveryJSON?
    private let parameters: GenerationSchema

    /// The objects to choose from for a parameter that wants one: those that take what it wants.
    struct Offer: Sendable {
        let want: Want
        let objects: [String]

        var schema: DiscoveryJSON {
            [
                "type": "string", "enum": .array(objects.map(DiscoveryJSON.string)),
                "description": .string("An object that \(want.written)."),
            ]
        }
    }

    init(
        session: ObjectSession, handle: String, title: String, action: String, summary: String?,
        input: DiscoveryJSON?, offered: [String: Offer] = [:]
    ) throws {
        self.session = session
        self.handle = handle
        self.title = title
        self.action = action
        self.summary = summary
        self.input = input
        var schema = Self.handles(in: input ?? ["type": "object", "properties": [:]])
        if case .object(var root) = schema, case .object(var properties)? = root["properties"] {
            for (parameter, offer) in offered { properties[parameter] = offer.schema }
            root["properties"] = .object(properties)
            schema = .object(root)
        }
        self.parameters = try JSONDecoder().decode(GenerationSchema.self, from: JSONEncoder().encode(schema))
    }

    public var name: String { "\(handle)_\(action)" }
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
            return ["type": "string", "description": "The object ID shown by search_objects or list_objects."]
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

/// Changes one of your objects: what it holds, or what it does, a step at a time.
public struct EditObjectTool: HailCore.Tool {
    public typealias Input = GeneratedContent
    let session: ObjectSession
    /// Your objects, to choose from: the only ones it can change.
    let objects: YourObject
    public let name = "edit_object"
    public let description = "Open tools for changing an object's data and event rules. Opening these tools does not change the object."
    private let parameters: GenerationSchema

    init(session: ObjectSession, objects: [String]) throws {
        self.session = session
        self.objects = YourObject(objects: objects)
        self.parameters = try GenerationSchema(
            root: DynamicGenerationSchema(name: "EditObject", properties: [self.objects.property("The object to change.")]),
            dependencies: [])
    }

    public var schema: ToolDefinition { ToolDefinition(name: name, description: description, parameters: parameters) }

    public func effect(for input: Input) throws -> EditObjectEffect {
        EditObjectEffect(session: session, handle: try objects.object(in: input, for: name))
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

/// One step that makes an object, in plain words over Erlang underneath: `<handle>_add_data`, a
/// field of its state; `<handle>_add_rule`, one `receive` clause, an event, a condition and what it
/// does; `<handle>_remove_rule`, taking a clause out; and `<handle>_set_value`, its own state when
/// it follows the rules of another, as an Erlang module is spawned again with state of its own.
struct DefineStep: Sendable {
    enum Kind: String, Sendable {
        case data = "add_data"
        case event = "add_event"
        case remove = "remove_event"
        case value = "set_value"
    }

    /// Whether other objects follow the same rules.
    enum Sharing: Sendable {
        case alone, shared
    }

    /// A message another object asks for, from the objects given to one of its actions: the
    /// shop's `startShift` asks a manager for `refundRequested(order, total)`, and lets it answer
    /// `refundApproved(order)` or `refundDenied(order)`.
    struct Asked: Sendable, Equatable {
        /// The handle of the object asking.
        let by: String
        /// The action, and its parameter, that wants an object taking it.
        let action: String
        let parameter: String
        let want: Want
        let message: Signature

        /// Names the sender, recipient, event and accepted replies.
        var written: String {
            let answers = want.answers.messages.map(\.written).joined(separator: " or ")
            return "\(by) sends \(message.written) to its \(parameter)."
                + (answers.isEmpty ? "" : " The \(parameter) can reply with \(answers).")
        }
    }

    /// What a piece of data holds, as the model chooses it.
    enum DataKind: String, CaseIterable, Sendable {
        case number, text, boolean, list

        /// The kind of data that starts as `value`.
        init(of value: Behavior.Written.Value) {
            switch value {
            case .number: self = .number
            case .boolean: self = .boolean
            case .list: self = .list
            default: self = .text
            }
        }

        /// What it starts as, from how it's written: nothing is its empty value.
        func start(_ written: String?) throws -> Behavior.Written.Value {
            guard let written else { return empty }
            switch self {
            case .number:
                guard let number = Double(written) else { throw ObjectToolError.failed("A number starts as a number, but it's `\(written)`.") }
                return .number(number)
            case .boolean:
                switch written.lowercased() {
                case "true", "1": return .boolean(true)
                case "false", "0": return .boolean(false)
                default:
                    throw ObjectToolError.failed("A boolean starts as true or false, or 1 or 0, but it's `\(written)`.")
                }
            case .list:
                return .list(DefineStep.items(written))
            case .text:
                return .text(written)
            }
        }

        /// What an event can do with data of this kind: the changes first, then reading it.
        var verbs: [Verb] {
            switch self {
            case .number: [.add, .subtract, .set, .clear, .get]
            case .list: [.append, .remove, .set, .clear, .get]
            case .text, .boolean: [.set, .clear, .get]
            }
        }

        /// The type of what it holds, for checking what a step puts in it.
        var valueType: ValueType {
            switch self {
            case .number: .number
            case .text: .string
            case .boolean: .boolean
            case .list: .list
            }
        }

        /// The type of a value of this kind, as an event is given one.
        var type: Behavior.Written.Kind {
            switch self {
            case .number: .number
            case .text: .string
            case .boolean: .boolean
            case .list: .list
            }
        }

        /// What data of this kind is when it holds nothing, such as `[]` for a list.
        var empty: Behavior.Written.Value {
            switch self {
            case .number: .number(0)
            case .list: .list([])
            case .boolean: .boolean(false)
            case .text: .text("")
            }
        }
    }

    /// What `define_data` is called with: the data's name, what it holds, and what it starts as.
    struct DataStep {
        enum Property: String { case name, kind, start }

        let name: String
        let kind: DataKind
        let start: String?

        static var schema: DynamicGenerationSchema {
            DynamicGenerationSchema(name: "DataStep", properties: [
                .init(name: Property.name.rawValue, description: "The name of the stored value.", schema: .init(type: String.self)),
                .init(
                    name: Property.kind.rawValue,
                    description: "The stored value's type. number: a count or amount. text: a single text value. boolean: true or false. list: several items you can add and remove individually.",
                    schema: .init(type: String.self, guides: [.anyOf(DataKind.allCases.map(\.rawValue))])),
                .init(
                    name: Property.start.rawValue,
                    description: "The initial value, written as text. For a list, separate items with commas. If omitted, defaults to 0, empty text, false, or an empty list, according to kind.",
                    schema: .init(type: String.self), isOptional: true),
            ])
        }

        init(_ content: GeneratedContent) throws {
            name = try content.value(forProperty: Property.name.rawValue)
            kind = try content.value(forProperty: Property.kind.rawValue)
            start = try content.text(Property.start.rawValue)
        }
    }

    /// What an event does with one piece of its data. The changes come first.
    enum Verb: String, CaseIterable, Sendable {
        case add, subtract, append, remove, set, clear, get

        /// What the event is given each time it's called, for a verb that changes its data by
        /// something: the amount for a number, the item for a list, the new value for `set`.
        func given(for kind: DataKind) -> Behavior.Written.Parameter? {
            switch self {
            case .add, .subtract: .named("amount", .number)
            case .append, .remove: .named("item", .string)
            case .set: .named("value", kind.type)
            case .clear, .get: nil
            }
        }

        /// Whether a value of `type` is what this verb takes for data holding `kind`: a number to add
        /// or subtract, one item to append or remove, a value of the data's own type to set. Clearing
        /// and getting take nothing.
        func takes(_ type: ValueType, holding kind: DataKind) -> Bool {
            switch self {
            case .add, .subtract: type.isSubtype(of: .number)
            case .append, .remove: [.string, .integer, .number].contains(type)
            case .set: type.isSubtype(of: kind.valueType)
            case .clear, .get: false
            }
        }

        /// The step as it's chosen, with its data: `add to cups`, `remove from items`, `clear items`.
        func label(for data: String) -> String {
            switch self {
            case .add, .append: "\(rawValue) to \(data)"
            case .subtract, .remove: "\(rawValue) from \(data)"
            case .set, .clear, .get: "\(rawValue) \(data)"
            }
        }

        /// What it does to `data`, which holds `kind`, with `value`, what it's given.
        func action(on data: String, holding kind: DataKind, with value: Behavior.Written.Value?) -> Behavior.Written.Action {
            switch self {
            case .add: .add(value ?? .number(0), to: data)
            case .subtract: .subtract(value ?? .number(0), from: data)
            case .append: .append(value ?? .text(""), to: data)
            case .remove: .remove(value ?? .text(""), from: data)
            case .set: .set(field: data, to: value ?? kind.empty)
            case .clear: .set(field: data, to: kind.empty)
            case .get: .reply(.name(data))
            }
        }
    }

    /// How a guard compares, as the model chooses it.
    enum Comparison: String, CaseIterable, Sendable {
        case lessThan = "<", atMost = "<=", greaterThan = ">", atLeast = ">=", equal = "==", notEqual = "!="

        var written: Behavior.Written.Comparison {
            switch self {
            case .lessThan: .lessThan
            case .atMost: .atMost
            case .greaterThan: .greaterThan
            case .atLeast: .atLeast
            case .equal: .equal
            case .notEqual: .notEqual
            }
        }
    }

    /// What a step or condition uses: a literal, an argument of the event, or a piece of the
    /// object's data. References are tagged so text is never mistaken for a name.
    enum Operand: Equatable {
        case number(Double)
        case text(String)
        case boolean(Bool)
        case given(Parameter)
        case held(String, DataKind)

        var type: ValueType {
            switch self {
            case .number: .number
            case .text: .string
            case .boolean: .boolean
            case .given(let parameter): parameter.type
            case .held(_, let kind): kind.valueType
            }
        }

        var written: Behavior.Written.Value {
            switch self {
            case .number(let number): .number(number)
            case .text(let text): .text(text)
            case .boolean(let flag): .boolean(flag)
            case .given(let parameter): .name(parameter.name)
            case .held(let field, _): .name(field)
            }
        }

        var name: String {
            switch self {
            case .number(let number): number.rounded() == number ? String(Int(number)) : String(number)
            case .text(let text): text
            case .boolean(let flag): String(flag)
            case .given(let parameter): parameter.name
            case .held(let field, _): field
            }
        }

        /// The operand `content` chooses: a literal, `{argument: name}`, or `{data: name}`.
        static func read(_ content: GeneratedContent, given: [Parameter], fields: [String: DataKind]) throws -> Operand {
            switch content.kind {
            case .number(let number):
                return .number(number)
            case .string(let text):
                return .text(text)
            case .bool(let flag):
                return .boolean(flag)
            case .structure(let properties, _):
                if let reference = properties["argument"] {
                    let written: String = try reference.value()
                    let name = Behavior.Written.messageName(from: written)
                    guard let parameter = given.first(where: { $0.name == name }) else {
                        throw ObjectToolError.failed(
                            "There is no argument `\(written)`. Choose one of: \(given.map(\.name).joined(separator: ", ")).")
                    }
                    return .given(parameter)
                }
                if let reference = properties["data"] {
                    let written: String = try reference.value()
                    let name = Behavior.Written.messageName(from: written)
                    guard let kind = fields[name] else {
                        throw ObjectToolError.failed(
                            "There is no stored value `\(written)`. Choose one of: \(fields.keys.sorted().joined(separator: ", ")).")
                    }
                    return .held(name, kind)
                }
                throw ObjectToolError.failed("A value reference needs `argument` or `data`.")
            default:
                throw ObjectToolError.failed("A value is a literal, {argument: name}, or {data: name}.")
            }
        }

        /// In an event step, numeric 1 and 0 are the model-friendly spellings of true and false
        /// when setting boolean data. Numbers keep their numeric meaning for every other field.
        func forSetting(_ kind: DataKind) -> Operand {
            guard kind == .boolean, case .number(let number) = self else { return self }
            if number == 1 { return .boolean(true) }
            if number == 0 { return .boolean(false) }
            return self
        }
    }

    /// What one step of an event does, as a choice that's whole: the verb with its data, such as
    /// `append to items`, or an answer to another object, such as `tell shop refundApproved`. Each
    /// is one expression of an Erlang clause's body.
    struct Doing: Sendable {
        enum Kind: Sendable {
            case data(Verb, String)
            case answer(Answer)
            /// Takes the event and changes nothing, as an Erlang clause that just loops.
            case nothing
        }

        let label: String
        let kind: Kind

        /// Every step the object can take: its data's verbs, nothing, then the answers others
        /// accept.
        static func all(fields: [(String, DataKind)], answers: [Answer]) -> [Doing] {
            fields.flatMap { field, held in
                held.verbs.map { verb in Doing(label: verb.label(for: field), kind: .data(verb, field)) }
            } + [Doing(label: "nothing", kind: .nothing)] + answers.map { Doing(label: $0.label, kind: .answer($0)) }
        }
    }

    /// What `add_event` is called with: one clause, the way an Erlang `receive` clause is written:
    /// the `event`, `if` one value `is` compared `than` another, and what it `does`, steps in
    /// order. A value is a literal or an explicit reference to an argument or stored value, read
    /// as an ``Operand`` at the edge.
    struct EventStep {
        enum Property: String { case event, takes, `if`, `is`, than, does }
        enum StepProperty: String { case `do`, value }

        struct Input {
            enum Property: String { case name, type }
            let name: String
            let type: DataKind

            static var schema: DynamicGenerationSchema {
                DynamicGenerationSchema(name: "EventInput", properties: [
                    .init(name: Property.name.rawValue, description: "The argument name.", schema: .init(type: String.self)),
                    .init(
                        name: Property.type.rawValue, description: "The argument type.",
                        schema: .init(type: String.self, guides: [.anyOf(DataKind.allCases.map(\.rawValue))]))
                ])
            }

            init(_ content: GeneratedContent) throws {
                let written: String = try content.value(forProperty: Property.name.rawValue)
                name = Behavior.Written.messageName(from: written)
                type = try content.value(forProperty: Property.type.rawValue)
            }

            var parameter: Parameter { .init(name: name, type: type.valueType) }
            var written: Behavior.Written.Parameter { .named(name, type.type) }
        }

        struct Step {
            let does: String
            let value: GeneratedContent?
        }

        let event: String
        let takes: [Input]
        let `if`: GeneratedContent?
        let `is`: Comparison?
        let than: GeneratedContent?
        let does: [Step]

        /// A literal or an explicit reference. Known names are offered where they are available;
        /// arguments declared in this same call are checked when the call is read.
        static func operand(_ name: String, arguments: [String], data: [String]) -> DynamicGenerationSchema {
            func reference(_ property: String, choices: [String]) -> DynamicGenerationSchema {
                DynamicGenerationSchema(name: name + property.capitalized, properties: [
                    .init(
                        name: property,
                        schema: choices.isEmpty
                            ? .init(type: String.self)
                            : .init(type: String.self, guides: [.anyOf(choices)]))
                ])
            }
            return DynamicGenerationSchema(name: name, anyOf: [
                .init(type: Double.self),
                .init(type: String.self),
                .init(type: Bool.self),
                reference("argument", choices: arguments),
                reference("data", choices: data),
            ])
        }

        static func schema(does: [String], arguments: [String], data: [String]) -> DynamicGenerationSchema {
            let step = DynamicGenerationSchema(name: "Step", properties: [
                .init(name: StepProperty.do.rawValue, description: "What this step does.", schema: .init(type: String.self, guides: [.anyOf(does)])),
                .init(
                    name: StepProperty.value.rawValue,
                    description: "A literal, {argument: name}, or {data: name}. Steps get and clear need no value.",
                    schema: operand("Value", arguments: arguments, data: data), isOptional: true),
            ])
            var properties: [DynamicGenerationSchema.Property] = [
                .init(
                    name: Property.event.rawValue, description: "The action name to define, or the exact name of an event sent by another object.",
                    schema: .init(type: String.self)),
                .init(
                    name: Property.takes.rawValue,
                    description: "Arguments this event receives. Omit when it receives none or another object's event already declares them.",
                    schema: .init(arrayOf: Input.schema), isOptional: true),
            ]
            if !arguments.isEmpty || !data.isEmpty {
                properties += [
                    .init(
                        name: Property.if.rawValue, description: "The value to test. Supply is and than too.",
                        schema: operand("ConditionValue", arguments: arguments, data: data), isOptional: true),
                    .init(
                        name: Property.is.rawValue, description: "The comparison operator for if and than.",
                        schema: .init(type: String.self, guides: [.anyOf(Comparison.allCases.map(\.rawValue))]), isOptional: true),
                    .init(
                        name: Property.than.rawValue, description: "The value to compare with.",
                        schema: operand("ComparedValue", arguments: arguments, data: data), isOptional: true),
                ]
            }
            properties.append(
                .init(
                    name: Property.does.rawValue, description: "Steps to run in order when this event is called or received. Choose nothing to handle the event without changing data or sending a reply.",
                    schema: .init(arrayOf: step)))
            return DynamicGenerationSchema(name: "EventStep", properties: properties)
        }

        init(_ content: GeneratedContent) throws {
            event = try content.value(forProperty: Property.event.rawValue)
            let inputs: [GeneratedContent] = try content.value([GeneratedContent]?.self, forProperty: Property.takes.rawValue) ?? []
            takes = try inputs.map(Input.init)
            `if` = content.property(Property.if.rawValue)
            `is` = try content.text(Property.is.rawValue).map { written in
                guard let comparison = Comparison(rawValue: written) else {
                    throw UnofferedChoice(given: written, offered: Comparison.allCases.map(\.rawValue), argument: Property.is.rawValue)
                }
                return comparison
            }
            than = content.property(Property.than.rawValue)
            let steps: [GeneratedContent] = try content.value(forProperty: Property.does.rawValue)
            does = try steps.map { step in
                Step(does: try step.value(forProperty: StepProperty.do.rawValue), value: step.property(StepProperty.value.rawValue))
            }
        }
    }

    /// What `remove_rule` is called with: one of its rules.
    struct RemoveStep {
        static let property = "event"

        let rule: String

        static func schema(rules: [String]) -> DynamicGenerationSchema {
            DynamicGenerationSchema(name: "RemoveStep", properties: [
                .init(name: property, description: "The event rule to remove. Select the entry including its condition, if present.", schema: .init(type: String.self, guides: [.anyOf(rules)]))
            ])
        }

        init(_ content: GeneratedContent) throws {
            rule = try content.value(forProperty: Self.property)
        }
    }

    /// What `set_value` is called with: one piece of its data, and its value now.
    struct ValueStep {
        enum Property: String { case data, value }

        let data: String
        let value: String

        static func schema(data fields: [String]) -> DynamicGenerationSchema {
            DynamicGenerationSchema(name: "ValueStep", properties: [
                .init(
                    name: Property.data.rawValue, description: "The name of the stored value to change.",
                    schema: .init(type: String.self, guides: [.anyOf(fields)])),
                .init(name: Property.value.rawValue, description: "The new value, written as text.", schema: .init(type: String.self)),
            ])
        }

        init(_ content: GeneratedContent) throws {
            data = try content.value(forProperty: Property.data.rawValue)
            value = try content.value(forProperty: Property.value.rawValue)
        }
    }

    let handle: String
    let kind: Kind
    /// The object's data, by name, with what each holds.
    let fields: [String: DataKind]
    /// What other objects send, for a rule written on one of them by name alone.
    let asked: [Asked]
    /// Its rules, by name, to take one out.
    let rules: [String]
    let description: String
    private let parameters: GenerationSchema

    var name: String { "\(handle)_\(kind.rawValue)" }
    var schema: ToolDefinition { ToolDefinition(name: name, description: description, parameters: parameters) }

    /// The steps of an object as it is: its data, always; a rule once it holds something, or once
    /// another object asks for something; taking one out once it has some; its own values, once it
    /// follows the rules of another and holds something.
    static func tools(
        handle: String, spec: Behavior.Written, asked: [Asked] = [], shared: Sharing = .alone, session: ObjectSession
    ) -> [ObjectDefineTool] {
        let fields = spec.fields.map { ($0.name, DataKind(of: $0.start)) }
        func step(_ kind: Kind) -> ObjectDefineTool? {
            (try? DefineStep(handle: handle, kind: kind, fields: fields, asked: asked, rules: spec.rules))
                .map { ObjectDefineTool(session: session, step: $0) }
        }
        var kinds: [Kind] = fields.isEmpty ? (asked.isEmpty ? [.data] : [.data, .event]) : [.event, .data]
        if !spec.receive.isEmpty { kinds.append(.remove) }
        if case .shared = shared, !fields.isEmpty { kinds.append(.value) }
        return kinds.compactMap(step)
    }

    init(handle: String, kind: Kind, fields: [(String, DataKind)], asked: [Asked] = [], rules: [String] = []) throws {
        self.handle = handle
        self.kind = kind
        self.fields = Dictionary(fields) { first, _ in first }
        self.asked = asked
        self.rules = rules
        let schema: DynamicGenerationSchema
        switch kind {
        case .data:
            description = "Add a stored value to \(handle)."
            schema = DataStep.schema
        case .event:
            description = "Define an event and its steps. This saves the event; it does not run it."
            let values = Self.values(of: asked)
            schema = EventStep.schema(
                does: Doing.all(fields: fields, answers: Self.answers(of: asked)).map(\.label),
                arguments: values, data: fields.map(\.0))
        case .remove:
            description = "Remove an event from \(handle)."
            schema = RemoveStep.schema(rules: rules)
        case .value:
            description = "Change a current value on \(handle)."
            schema = ValueStep.schema(data: fields.map(\.0))
        }
        self.parameters = try GenerationSchema(root: schema, dependencies: [])
    }

    /// The values of the messages other objects send, each once.
    static func values(of asked: [Asked]) -> [String] {
        var values: [String] = []
        for name in asked.flatMap(\.message.parameters).map(\.name) where !values.contains(name) { values.append(name) }
        return values
    }

    /// A message to send back to an object that asks for something: `tell shop refundApproved`.
    struct Answer {
        let by: String
        let message: Signature
        /// What `by` sends that this answers, such as `refundRequested`.
        let answering: String
        var label: String { "tell \(by) \(message.name)" }
    }

    static func answers(of asked: [Asked]) -> [Answer] {
        var answers: [Answer] = []
        for asked in asked {
            for message in asked.want.answers.messages where !answers.contains(where: { $0.by == asked.by && $0.message == message }) {
                answers.append(Answer(by: asked.by, message: message, answering: asked.message.name))
            }
        }
        return answers
    }

    static func items(_ written: String) -> [String] {
        written.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The step the arguments describe, with what's missing or off said in this tool's terms.
    private func read<Step>(_ step: (GeneratedContent) throws -> Step, _ input: GeneratedContent) throws -> Step {
        do {
            return try step(input)
        } catch GeneratedContentError.propertyNotFound(let property) {
            throw ObjectToolError.missingArguments(name, missing: [property], unexpected: [])
        } catch let error as UnofferedChoice {
            throw ObjectToolError.failed(error.description)
        }
    }

    /// The change the arguments describe: data to hold, or a clause to receive with.
    func change(from input: GeneratedContent) throws -> Change {
        switch kind {
        case .data:
            let step = try read(DataStep.init, input)
            // A name as the spec writes one: `how many` becomes `howMany`.
            let field = Behavior.Written.messageName(from: step.name)
            let start = try step.kind.start(step.start)
            return .edit(.hold(field, start: start))
        case .event:
            let step = try read(EventStep.init, input)
            // A name as the spec writes one: `add cup` becomes `addCup`.
            let event = Behavior.Written.messageName(from: step.event)
            let sent = asked.first { $0.message.name == event }?.message
            let doings = Doing.all(fields: fields.map { ($0.key, $0.value) }, answers: Self.answers(of: asked))
            let chosen = try step.does.map { written in
                guard let doing = doings.first(where: { $0.label == written.does }) else {
                    throw UnofferedChoice(given: written.does, offered: doings.map(\.label), argument: EventStep.StepProperty.do.rawValue)
                }
                return (doing, written.value)
            }
            // `nothing` is the identity of a sequence of steps: with others, it's as if left out.
            let steps = chosen.filter { if case .nothing = $0.0.kind { false } else { true } }
            var actions: [Behavior.Written.Action] = []
            if sent != nil, !step.takes.isEmpty {
                throw ObjectToolError.failed("`\(event)` is sent by another object, which already declares its arguments. Omit `takes`.")
            }
            let given = sent?.parameters ?? step.takes.map(\.parameter)
            for (doing, value) in steps {
                switch doing.kind {
                case .nothing:
                    break
                case .answer(let answer):
                    actions.append(.telling(answer.by, try Self.forwarded(answer, from: sent, as: doing.label)))
                case .data(let verb, let data):
                    let held = fields[data] ?? .text
                    // A value given to a step that takes none, such as `get` or `clear`, changes
                    // nothing, so it's let be.
                    if let value, verb.given(for: held) != nil {
                        let operand = try Operand.read(value, given: given, fields: fields).forSetting(held)
                        guard verb.takes(operand.type, holding: held) else {
                            throw ObjectToolError.failed(Self.wrongValue(doing.label, operand, verb: verb, holding: held, sent: sent))
                        }
                        actions.append(verb.action(on: data, holding: held, with: operand.written))
                    } else if verb.given(for: held) != nil {
                        throw ObjectToolError.failed(
                            "`\(doing.label)` needs `value`: a literal, {argument: name}, or {data: name}.")
                    } else {
                        actions.append(verb.action(on: data, holding: held, with: nil))
                    }
                }
            }
            let guards = try Self.guarded(step, given: given, fields: fields)
            return .edit(
                .receive(
                    .on(event, taking: nil, when: guards, doing: actions),
                    taking: sent == nil ? step.takes.map(\.written) : [], message: sent))
        case .remove:
            let step = try read(RemoveStep.init, input)
            guard rules.contains(step.rule) else { throw UnofferedChoice(given: step.rule, offered: rules, argument: RemoveStep.property) }
            return .edit(.remove(rule: step.rule))
        case .value:
            let step = try read(ValueStep.init, input)
            guard let held = fields[step.data] else {
                throw UnofferedChoice(given: step.data, offered: fields.keys.sorted(), argument: ValueStep.Property.data.rawValue)
            }
            let value = try ObjectSession.reading { try Behavior.Field.value(try held.start(step.value), of: step.data) }
            return .values([step.data: value])
        }
    }
}

extension DefineStep {
    /// The condition an event is written with: `if` a value `is` compared `than` another, both
    /// read as operands, and comparable; none without `if`.
    static func guarded(_ step: EventStep, given: [Parameter], fields: [String: DataKind]) throws -> [Behavior.Written.Guard]? {
        guard let written = step.if else { return nil }
        guard let comparison = step.is, let than = step.than else {
            throw ObjectToolError.failed("A condition needs `if`, `is`, and `than`.")
        }
        let left = try Operand.read(written, given: given, fields: fields)
        let right = try Operand.read(than, given: given, fields: fields)
        let ordered = comparison != .equal && comparison != .notEqual
        let comparable =
            ordered
            ? left.type.isSubtype(of: .number) && right.type.isSubtype(of: .number)
            : left.type.isSubtype(of: right.type) || right.type.isSubtype(of: left.type)
        guard comparable else {
            throw ObjectToolError.failed(
                "`\(left.name) \(comparison.rawValue) \(right.name)` compares \(left.type.withArticle) with \(right.type.withArticle)\(ordered ? ", but <, <=, > and >= compare numbers" : ", which can't be equal"). Compare it with a number, or one of its data of the same kind.")
        }
        return [.comparing(left.written, comparison.written, right.written)]
    }

    /// A step given a value it doesn't take: what was given and what the step takes.
    static func wrongValue(_ label: String, _ operand: Operand, verb: Verb, holding held: DataKind, sent: Signature?) -> String {
        let takes: String =
            switch verb {
            case .add, .subtract: "a number"
            case .append, .remove: "one item"
            case .set: held.valueType.withArticle
            case .clear, .get: "nothing"
            }
        let fitting = (sent?.parameters ?? []).filter { verb.takes($0.type, holding: held) }.map(\.name)
        guard let first = fitting.first else {
            return "`\(label)` takes \(takes), but `\(operand.name)` is \(operand.type.withArticle). Give it \(takes) instead."
        }
        return "`\(label)` takes \(takes), but `\(operand.name)` is \(operand.type.withArticle). Arguments that fit: \(fitting.joined(separator: ", ")). Use {argument: \"\(first)\"}."
    }

    /// What `answer` passes on, from the event `sent`: each of its values, by name, of a type it
    /// takes. Refused when the event isn't given one of them.
    static func forwarded(_ answer: Answer, from sent: Signature?, as label: String) throws -> Signature {
        for wanted in answer.message.parameters {
            guard let own = sent?.parameters.first(where: { $0.name == wanted.name }), own.type.isSubtype(of: wanted.type) else {
                throw ObjectToolError.failed(
                    "`\(label)` sends back \(answer.message.written), which needs the event's \(wanted.name), but this event isn't given one. It's for the event \(answer.by) sends, such as {event: \"\(answer.answering)\", does: [{do: \"\(label)\"}]}.")
            }
        }
        return answer.message
    }
}

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

extension DefineStep.DataKind: ConvertibleFromGeneratedContent {
    init(_ content: GeneratedContent) throws {
        let given: String = try content.value()
        guard let kind = Self(rawValue: given) else {
            throw UnofferedChoice(given: given, offered: Self.allCases.map(\.rawValue), argument: DefineStep.DataStep.Property.kind.rawValue)
        }
        self = kind
    }
}

extension GeneratedContent {
    /// The text of an optional property, or nil when it's missing or blank.
    func text(_ property: String) throws -> String? {
        let text = try value(String?.self, forProperty: property)?.trimmingCharacters(in: .whitespaces)
        return text?.isEmpty == false ? text : nil
    }
}

/// A define step, as a change to an object: typed, applied to the object as it is when it runs.
public enum Change: Sendable {
    /// A change to what it holds and its events, which every object doing the same shares.
    case edit(Behavior.Written.Edit)
    /// Values of its own data, for it alone.
    case values([String: DiscoverableActors.JSONValue])
}

/// A define step as a tool of its own, linked from the object's pages.
public struct ObjectDefineTool: HailCore.Tool {
    public typealias Input = GeneratedContent
    let session: ObjectSession
    let step: DefineStep
    public var name: String { step.name }
    public var description: String { step.description }
    public var schema: ToolDefinition { step.schema }
    public func effect(for input: Input) throws -> DefineObjectEffect {
        DefineObjectEffect(session: session, handle: step.handle, change: try step.change(from: input))
    }
    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<DefineObjectEffect>) async throws -> CallReturn {
        try await DefineObjectEffect.run(in: token)
    }
}

@Generable
public struct ObjectToolsFindInput: Sendable {
    @Guide(description: "Words for what you need, in your own words.")
    public let query: String
}
