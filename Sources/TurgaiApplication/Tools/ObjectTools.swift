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
    /// Whether the guide's been read this turn, which adds objects_define.
    private(set) var readGuide = false

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
        let words = Self.words(query).filter { $0.count >= 3 && !Self.fillerWords.contains($0) }
        guard !words.isEmpty, case .array(let entries) = try await list() else { return [] }
        func text(_ value: DiscoveryJSON?) -> String {
            if case .string(let text)? = value { text } else { "" }
        }
        func matches(_ word: String, in text: String) -> Bool {
            Self.words(text).contains { $0.hasPrefix(word) }
        }
        let ranked =
            entries
            .map { entry -> (entry: DiscoveryJSON, score: Int) in
                let title = text(entry["title"])
                let description = text(entry["description"])
                let score = words.reduce(0) { total, word in
                    total + (matches(word, in: title) ? 2 : 0) + (matches(word, in: description) ? 1 : 0)
                }
                return (entry, score)
            }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.entry)
        return .array(Array(ranked))
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Words that say nothing about which object is meant.
    private static let fillerWords: Set<String> = [
        "the", "and", "for", "with", "what", "how", "set", "get", "show", "make", "please", "can", "you",
        "your", "this", "that", "into", "from", "about",
    ]

    /// An object's properties and actions, with actor references shown as handles.
    func describe(_ handle: String) async throws -> DiscoveryJSON {
        let description = try await call(handle) { try await $0.describe() }
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

    private func perform(_ handle: String, action name: String, arguments text: String?) async throws -> DiscoveryJSON {
        let object = try await self.object(handle)
        let description = try await call(handle) { try await $0.describe() }
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
            result = try await call(handle) { _ in try await object.invoke(name, arguments: arguments) }
        } catch DiscoveryError.invalidArgument(let argument, let reason) {
            throw ObjectToolError.invalidArgument(
                "\(description.title).\(name)", argument: argument,
                reason: Self.explanation(of: reason, for: argument, given: given, schema: action.input),
                usage: action.description)
        }
        return try await translate(result, schema: action.output, reference: mintHandle)
    }

    /// An object as a model reads it: what it is, the tools that send it messages, with what each
    /// is for, and its values now. An object made with create also shows its spec, which is an
    /// example of how specs are written, too.
    func summary(_ handle: String) async throws -> String {
        let handle = handle.lowercased()
        let description = try await call(handle) { try await $0.describe() }
        var lines = ["\(description.title) (\(handle))"]
        // A made object's description ends with its spec, shown on its own below.
        let parts = (description.description ?? "").components(separatedBy: " Its spec:\n")
        if let about = parts.first, !about.isEmpty { lines.append(about) }

        if !description.actions.isEmpty {
            lines.append("")
            lines.append("Takes, as tools:")
            for (name, action) in description.actions.sorted(by: { $0.key < $1.key }) {
                let properties: [String: DiscoveryJSON] = if case .object(let members)? = action.input?["properties"] { members } else { [:] }
                let parameters = properties.keys.sorted().map { "\($0): \(Self.typeName(properties[$0] ?? .null))" }
                let about = action.description.map { " — \(Self.firstSentence($0))" } ?? ""
                lines.append("  \(handle)_\(name)(\(parameters.joined(separator: ", ")))\(about)")
            }
        }

        var values: [String] = []
        for name in description.properties.keys.sorted() {
            guard let value = try? await read(handle, property: name) else { continue }
            values.append("  \(name): \(value.inline)")
        }
        if !values.isEmpty {
            lines.append("")
            lines.append("Now:")
            lines += values
        }

        if parts.count > 1 {
            lines.append("")
            lines.append("Its spec:")
            lines += parts[1].split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    /// A parameter's type in a signature: `integer`, `list`, or `object` for another object's handle.
    private static func typeName(_ schema: DiscoveryJSON) -> String {
        if isReference(schema) { return "object" }
        switch schema["type"] {
        case "array"?: return "list"
        case .string(let type)?: return type
        default: return "any"
        }
    }

    private static func firstSentence(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard let end = flat.range(of: ". ") else { return flat }
        return String(flat[..<end.lowerBound]) + "."
    }

    /// Reads a property, with actor references shown as handles.
    func read(_ handle: String, property: String) async throws -> DiscoveryJSON {
        let description = try await call(handle) { try await $0.describe() }
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

    /// How a spec is written, with an example: what objects_guide shows. The example is the
    /// arguments of objects_define, made from the same types, so it's always one that's accepted.
    static var guide: String {
        typealias W = Behavior.Written
        let example = ObjectToolsDefineInput(
            name: "Loan desk",
            spec: W(
                speaks: nil,
                fields: [W.Field(name: "lent", start: .list([])), W.Field(name: "loans", start: .number(0))],
                initial: nil,
                receive: [
                    W.Clause(
                        on: "borrow", parameters: [W.Parameter(name: "book", type: .string, speaks: nil)],
                        when: [W.Guard(left: .name("lent"), comparison: .contains, right: .name("book"))],
                        actions: [.reply(.text("{book} is lent out"))], in: nil, then: nil),
                    W.Clause(
                        on: "borrow", parameters: [W.Parameter(name: "book", type: .string, speaks: nil)], when: nil,
                        actions: [.append(.name("book"), to: "lent"), .add(.number(1), to: "loans"), .reply(.text("Enjoy {book}"))],
                        in: nil, then: nil),
                    W.Clause(
                        on: "giveBack", parameters: [W.Parameter(name: "book", type: .string, speaks: nil)], when: nil,
                        actions: [.remove(.name("book"), from: "lent")], in: nil, then: nil),
                    W.Clause(on: "howMany", parameters: nil, when: nil, actions: [.reply(.name("loans"))], in: nil, then: nil),
                ]),
            sameAs: nil, start: nil, protocols: nil)
        return """
            An object keeps running on its own: its fields are what it remembers, and each clause says how it answers a message. The first clause that matches a message handles it, running its actions in order; a clause with `when` matches only while its conditions hold. A value names a parameter or a field, or `self`; or it's a number, text, true or false, or a list. In text, a name in braces, such as {book}, is filled in. To make another object that behaves the same, give `sameAs`, with `start` values of its own. To change an object, define it again with its handle. For example, a loan desk:

            \(example.generatedContent.jsonString)
            """
    }

    /// How a spec is written, read before objects_define, which it adds to the turn's tools.
    func readTheGuide() -> String {
        readGuide = true
        return Self.guide
    }

    /// Makes an object, from its spec or as the same as another, or, for the handle of one made
    /// here, changes its spec or protocols. Returns its handle.
    func define(_ input: ObjectToolsDefineInput) async throws -> DiscoveryJSON {
        let protocols = input.protocols ?? []
        if let existing = try await madeObject(named: input.name) {
            guard Self.given(input.sameAs) == nil, input.start == nil else {
                throw ObjectToolError.failed(
                    "`\(existing.handle)` exists, so this changes it: `sameAs` and `start` are only for a new object. Give `spec`, `protocols`, or both.")
            }
            let changes = [protocols.isEmpty ? nil : Change.protocols(protocols), input.spec.map(Change.spec)].compactMap { $0 }
            guard !changes.isEmpty else {
                throw ObjectToolError.failed(
                    "`\(existing.handle)` exists, so this changes it: give `spec`, its new spec, `protocols`, or both.")
            }
            let identity = try await existing.object.identity
            for change in changes {
                try await making { try await $0.update(identity, change: change) }
            }
            actorSystem.log.info("Changed object", metadata: ["handle": .string(existing.handle)])
            return .string(existing.handle)
        }

        let name = input.name
        let made: Spec
        switch (input.spec, Self.given(input.sameAs)) {
        case (let spec?, nil):
            made = .written(spec, protocols: protocols)
        case (nil, let other?):
            made = .sameAs(try await dynamicObject(other))
        case (.some, .some):
            throw ObjectToolError.failed(
                "Give either `spec`, to describe a new object, or `sameAs`, the handle of an object it behaves like, not both.")
        case (nil, nil):
            throw ObjectToolError.failed(
                "Give `spec`, the new object's spec, or `sameAs`, the handle of an object it behaves like.\n\nobjects_guide shows how a spec is written, with an example.")
        }
        let identity = try await making { try await $0.create(name: name, spec: made, start: try Behavior.Field.values(input.start ?? [])) }
        let object = try await DynamicObject.resolve(on: actorSystem, identity: identity)
        actorSystem.log.info("Created object", metadata: ["name": .string(name)])
        return .string(handle(for: try DiscoverableObject.resolve(id: object.id, using: actorSystem), titled: name))
    }

    /// The object made here that `name` is the handle of, written as its handle or as its name.
    /// A handle of an object made elsewhere can't be defined.
    private func madeObject(named name: String) async throws -> (handle: String, object: DynamicObject)? {
        for handle in Set([name, ObjectNames.handle(for: name)]) {
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
        return "removed"
    }

    /// Runs `body` on the directory where objects are made, with its errors as the model reads them.
    private func making<Result: Sendable>(_ body: (DynamicObjects) async throws -> Result) async throws -> Result {
        let directory = try await DynamicObjects.resolve(on: actorSystem, scope: .shared)
        do {
            return try await body(directory)
        } catch let error as BehaviorError {
            throw ObjectToolError.failed(error.description + "\n\nobjects_guide shows how a spec is written, with an example.")
        } catch let error as DynamicObjectsError {
            throw ObjectToolError.failed(error.description)
        } catch let error as DynamicObjectError {
            throw ObjectToolError.failed(error.description)
        }
    }

    /// The object behind `handle`, if it was made with create.
    private func dynamicObject(_ handle: String) async throws -> DynamicObject {
        let object = try await object(handle)
        let made = try DynamicObject.resolve(id: object.id, using: actorSystem)
        do {
            _ = try await made.identity
        } catch {
            throw ObjectToolError.failed("`\(handle)` wasn't made with objects_define, so it can't be changed or shared this way.")
        }
        return made
    }

    // MARK: Actions as tools

    /// A typed tool for each action of every object the model can reach now: the roots, and the
    /// objects it met this turn, such as one it just made. Read again before every model round.
    func actionTools() async -> [ObjectActionTool] {
        for entry in (try? await entries()) ?? [] { _ = handle(for: entry.object, titled: entry.title) }
        var tools: [ObjectActionTool] = []
        for (handle, object) in objects.sorted(by: { $0.key < $1.key }) {
            // One that can't describe itself now, such as a removed object, offers nothing.
            guard let description = try? await object.describe() else { continue }
            for (name, action) in description.actions.sorted(by: { $0.key < $1.key }) {
                do {
                    tools.append(
                        try ObjectActionTool(
                            session: self, handle: handle, title: description.title, action: name,
                            summary: action.description, input: action.input))
                } catch {
                    actorSystem.log.warning(
                        "Object action has no usable schema",
                        metadata: ["handle": .string(handle), "action": .string(name), "error": .string("\(error)")])
                }
            }
        }
        return tools
    }

    /// Reference lines for a turn: each root's handle, title, and description, so the
    /// model knows what the `objects` tool reaches without calling it.
    static func turnContext(
        actorSystem: ClusterSystem,
        objectCatalog: ObjectCatalog? = nil,
        conversationID: ConversationID,
        limit: Int = 20
    ) async -> [String] {
        let session = ObjectSession(
            actorSystem: actorSystem,
            objectCatalog: objectCatalog,
            scopes: conversationID.participantUserID.map(ObjectScope.visible(to:)) ?? [.shared]
        )
        guard case .array(let entries)? = try? await session.list(), !entries.isEmpty else { return [] }
        let lines = entries.prefix(limit).map { entry in
            let handle = entry["handle"].flatMap { if case .string(let text) = $0 { text } else { nil } } ?? ""
            let title = entry["title"].flatMap { if case .string(let text) = $0 { text } else { nil } } ?? ""
            let description =
                entry["description"].flatMap { if case .string(let text) = $0 { ": \(text)" } else { nil } } ?? ""
            let actions =
                entry["actions"].flatMap { value -> [String]? in
                    guard case .array(let values) = value else { return nil }
                    return values.compactMap { if case .string(let text) = $0 { text } else { nil } }
                } ?? []
            let events = entry["events"].flatMap { value -> [String]? in
                guard case .array(let values) = value else { return nil }
                return values.compactMap { if case .string(let text) = $0 { text } else { nil } }
            } ?? []
            let affordances =
                (actions.isEmpty ? "" : "; actions: \(actions.joined(separator: ", "))")
                + (events.isEmpty ? "" : "; events: \(events.joined(separator: ", "))")
            return "- `\(handle)`, \(title)\(description)\(affordances)"
        }
        let more = entries.count > limit ? ["…and \(entries.count - limit) more; use objects_find."] : []
        return ["Objects here, by handle. Each action of an object is its own tool, named handle_action, such as shop_startShift:"]
            + lines + more
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
        if let handle = handles[object.id] { return .string(handle) }
        return .string(handle(for: object, titled: try await object.describe().title))
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
                return ["type": "string", "description": "An object handle, such as reminder-list."]
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
        case .unknownHandle(let handle):
            "There's no object `\(handle)`; objects_find finds objects by what they're for"
        case .unknownAction(let action, let handle, let available) where available.isEmpty:
            "`\(handle)` has no action `\(action)`, and no actions at all yet"
        case .unknownAction(let action, let handle, let available):
            "`\(handle)` has no action `\(action)`; its actions are \(available.joined(separator: ", "))"
        case .unreachable(let handle, let reason):
            "the object behind \(handle) can't be reached (\(reason)); use list and walk back to it"
        case .expectedHandle:
            "expected an object handle, such as reminder-list"
        case .unreadable(let explanation):
            explanation
        case .invalidArgument(let action, let argument, let reason, let usage):
            "\(action) couldn't use `\(argument)`: \(reason)" + (usage.map { "\n\nHow \(action) works: \($0)" } ?? "")
        case .missingArguments(let action, let missing, let unexpected):
            "\(action) needs \(missing.joined(separator: ", "))"
                + (unexpected.isEmpty ? "" : ", not \(unexpected.joined(separator: ", "))")
                + "; pass them in arguments, such as \(missing[0]): …"
        case .failed(let reason):
            reason
        }
    }
}

// MARK: - Effects

/// How a spec is written: read when the model is about to make an object, so every request doesn't
/// carry it, the way an agent skill loads its instructions only when it's used.
public struct ObjectsGuideEffect: ScopedEffect, Sendable {
    public let name = "objects.guide"
    let session: ObjectSession
    public static func run(in token: borrowing EffectToken<Self>) async throws -> String {
        let session = token.withConfiguration { $0.session }
        return await session.readTheGuide()
    }
}

public struct ListObjectsEffect: ScopedEffect, Sendable {
    public let name = "objects.list"
    let session: ObjectSession
    public static func run(in token: borrowing EffectToken<Self>) async throws -> String {
        let session = token.withConfiguration { $0.session }
        return try ObjectSession.text(try await session.list())
    }
}

public struct DefineObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.define"
    let session: ObjectSession
    let input: ObjectToolsDefineInput
    public static func run(in token: borrowing EffectToken<Self>) async throws -> String {
        let (session, input) = token.withConfiguration { ($0.session, $0.input) }
        return try ObjectSession.text(try await session.define(input))
    }
}

public struct RemoveObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.remove"
    let session: ObjectSession
    let handle: String
    public static func run(in token: borrowing EffectToken<Self>) async throws -> String {
        let (session, handle) = token.withConfiguration { ($0.session, $0.handle) }
        return try ObjectSession.text(try await session.remove(handle))
    }
}

public struct FindObjectsEffect: ScopedEffect, Sendable {
    public let name = "objects.find"
    let session: ObjectSession
    let query: String
    public static func run(in token: borrowing EffectToken<Self>) async throws -> String {
        let (session, query) = token.withConfiguration { ($0.session, $0.query) }
        return try ObjectSession.text(try await session.find(query))
    }
}

public struct DescribeObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.describe"
    let session: ObjectSession
    let handle: String
    public static func run(in token: borrowing EffectToken<Self>) async throws -> String {
        let (session, handle) = token.withConfiguration { ($0.session, $0.handle) }
        return try await session.summary(handle)
    }
}

public struct InvokeObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.invoke"
    let session: ObjectSession
    let handle: String
    let action: String
    let arguments: String?
    public static func run(in token: borrowing EffectToken<Self>) async throws -> String {
        let (session, handle, action, arguments) = token.withConfiguration {
            ($0.session, $0.handle, $0.action, $0.arguments)
        }
        return try ObjectSession.text(try await session.invoke(handle, action: action, arguments: arguments))
    }
}

public struct ReadObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.read"
    let session: ObjectSession
    let handle: String
    let property: String
    public static func run(in token: borrowing EffectToken<Self>) async throws -> String {
        let (session, handle, property) = token.withConfiguration { ($0.session, $0.handle, $0.property) }
        return try ObjectSession.text(try await session.read(handle, property: property))
    }
}

// MARK: - Tool

@Tool("objects")
public struct ObjectTools: Sendable {
    let session: ObjectSession

    public init(session: ObjectSession) {
        self.session = session
    }

    @Command(
        "find",
        description:
            "Find the objects that match what you need, such as \"reminders\" or \"battery\", with a handle for each. Includes the Mac's own apps, like Reminders."
    )
    public func find(_ input: ObjectToolsFindInput) throws -> FindObjectsEffect {
        FindObjectsEffect(session: session, query: input.query)
    }

    @Command(
        "describe",
        description:
            "Describe an object: what it's for, the messages it takes, as the tools that send them, and its values now."
    )
    public func describe(_ input: ObjectToolsDescribeInput) throws -> DescribeObjectEffect {
        DescribeObjectEffect(session: session, handle: input.handle)
    }

    @Command("read", description: "Read one property of an object.")
    public func read(_ input: ObjectToolsReadInput) throws -> ReadObjectEffect {
        ReadObjectEffect(session: session, handle: input.handle, property: input.property)
    }

    @Command(
        "list",
        description: "List every object you can use, with a handle for each, including the ones made with create."
    )
    public func list(_ input: ObjectToolsListInput) throws -> ListObjectsEffect {
        ListObjectsEffect(session: session)
    }

    @Command(
        "define",
        description:
            "Make an object that keeps running on its own and remembers its values, from its `spec`, or as the same as an object it behaves like, with `sameAs`. Given the handle of an object made here, it changes that object instead."
    )
    public func define(_ input: ObjectToolsDefineInput) throws -> DefineObjectEffect {
        DefineObjectEffect(session: session, input: input)
    }

    @Command("remove", description: "Remove an object made with objects_define, for good.")
    public func remove(_ input: ObjectToolsRemoveInput) throws -> RemoveObjectEffect {
        RemoveObjectEffect(session: session, handle: input.object)
    }

    @Command("guide", description: "How to make or change an object, with an example. Reading it adds objects_define.")
    public func guide(_ input: ObjectToolsListInput) throws -> ObjectsGuideEffect {
        ObjectsGuideEffect(session: session)
    }

    public func render(_ output: String) -> ToolOutput { .text(output) }
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

    init(
        session: ObjectSession, handle: String, title: String, action: String, summary: String?,
        input: DiscoveryJSON?
    ) throws {
        self.session = session
        self.handle = handle
        self.title = title
        self.action = action
        self.summary = summary
        self.input = input
        let schema = Self.handles(in: input ?? ["type": "object", "properties": [:]])
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

    public func runOutput(input: GeneratedContent, token: borrowing EffectToken<InvokeObjectEffect>) async throws
        -> ToolOutput
    {
        .text(try await InvokeObjectEffect.run(in: token))
    }

    /// The schema as the model writes it: a reference to an object is its handle, a string, and an
    /// optional value is the value, since leaving it out of `required` already makes it optional.
    static func handles(in schema: DiscoveryJSON) -> DiscoveryJSON {
        switch schema {
        case .object(let members) where members["x-actor-reference"] == .bool(true):
            return ["type": "string", "description": "An object's handle, such as shop."]
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

/// The actions of the objects a model can reach, as tools, read again every round: an object it
/// makes or is handed during a turn brings its tools with it.
extension ObjectTools {
    static let defineName = "objects_define"

    /// The tools every request carries: all but objects_define, whose spec schema is most of
    /// their size. ``ObjectDefiningTools`` adds it once the guide's been read.
    public var everyTurn: [any HailCore.Tool] {
        tools.filter { $0.name != Self.defineName }
    }
}

/// objects_define, from the round after the guide's read, the way an agent skill loads only when
/// it's used: requests that don't make or change objects don't carry its schema.
public struct ObjectDefiningTools: ToolSource {
    let session: ObjectSession

    public init(session: ObjectSession) {
        self.session = session
    }

    public func tools() async -> [any HailCore.Tool] {
        guard await session.readGuide else { return [] }
        return ObjectTools(session: session).tools.filter { $0.name == ObjectTools.defineName }
    }
}

public struct ObjectActionTools: ToolSource {
    let session: ObjectSession

    public init(session: ObjectSession) {
        self.session = session
    }

    public func tools() async -> [any HailCore.Tool] {
        await session.actionTools()
    }
}

@Generable
public struct ObjectToolsListInput: Sendable {}

@Generable
public struct ObjectToolsDefineInput: Sendable {
    @Guide(description: "A new object's name, such as Ann, or the handle of an object made here, to change it.")
    public let name: String
    @Guide(description: "Its fields, and how it answers each message.")
    public let spec: Behavior.Written?
    @Guide(description: "For a new object: the handle of an object it behaves like, instead of a spec of its own.")
    public let sameAs: String?
    @Guide(description: "For a new object: values it starts with instead of its spec's.")
    public let start: [Behavior.Written.Field]?
    @Guide(description: "Protocols its spec speaks or types parameters with, new or changed.")
    public let protocols: [MessageProtocol.Written]?
}

@Generable
public struct ObjectToolsRemoveInput: Sendable {
    @Guide(description: "The object's handle.")
    public let object: String
}

@Generable
public struct ObjectToolsFindInput: Sendable {
    @Guide(description: "Words describing what you need, such as reminders or battery.")
    public let query: String
}

@Generable
public struct ObjectToolsDescribeInput: Sendable {
    @Guide(description: "The object's handle, such as mac or reminder-list.")
    public let handle: String
}

@Generable
public struct ObjectToolsReadInput: Sendable {
    @Guide(description: "The object's handle, such as mac or reminder-list.")
    public let handle: String
    @Guide(description: "The property's name, as listed by describe.")
    public let property: String
}
