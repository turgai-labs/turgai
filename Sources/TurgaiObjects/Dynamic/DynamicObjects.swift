import DiscoverableActors
import Distributed
import DistributedCluster
import EventSourcing
import TurgaiCalls
import TurgaiDomain
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A space's types and the objects made there by name, the way an Erlang node holds its modules
/// and a supervisor its top processes. There's one for each space, reached by the space's id: only
/// what's in the space reaches it, and nothing in it reaches another space's. It makes those
/// objects, gives a type's new code to them, and starts them again after a restart: each restores
/// itself from its own journal. An object code makes is its maker's, which holds it: a type's new
/// code reaches it through its maker, as down a tree, and nothing here knows it.
///
/// It's where a type is checked before it runs: its Swift reads against the types it uses, and
/// its objects start with their checks holding. An object also checks every message when it
/// arrives: that it's of the type the call was made through, and that its arguments are of their
/// types.
@EventSourced
@VirtualActor
public distributed actor DynamicObjects {
    public typealias ActorSystem = ClusterSystem
    public typealias Event = DynamicObjectsEvent
    public typealias State = DynamicObjectsState
    public typealias Dependency = SpaceID

    public var state = DynamicObjectsState()
    /// The space whose they are: given, never kept in its state.
    private let home: SpaceID
    /// References to its objects, resolved once each.
    private var resolved: [ObjectIdentity: DynamicObject] = [:]
    /// Whoever follows that its objects changed: each one's backlog, and its pull while it waits.
    private var pulls = Pulls<ObjectsChanged>()
    /// Each type's code as the checker read it, read again only when the type's code is another.
    private var checked: [BehaviorID: CheckedScript] = [:]

    public init(actorSystem: ClusterSystem, dependency space: SpaceID) async throws {
        self.actorSystem = actorSystem
        self.home = space
        try await actorSystem.journal.register(actor: self, with: Self.persistenceID(for: space))
    }

    /// The types and objects of `space`, made by name there.
    package static func of(_ space: SpaceID, on system: ClusterSystem) async throws -> DynamicObjects {
        try await system.virtualActors.getActor(identifiedBy: actorID(for: space), dependency: space)
    }

    static func actorID(for space: SpaceID) -> VirtualActorID {
        VirtualActorID(rawValue: "objects:\(space.rawValue.uuidString)")
    }

    private static let persistencePrefix = "turgai-objects-"

    public static func persistenceID(for space: SpaceID) -> String {
        persistencePrefix + space.rawValue.uuidString
    }

    /// The space whose registry's journal is `persistenceID`: none for another's journal.
    public static func space(persistedAs persistenceID: String) -> SpaceID? {
        guard persistenceID.hasPrefix(persistencePrefix) else { return nil }
        return UUID(uuidString: String(persistenceID.dropFirst(persistencePrefix.count))).map(SpaceID.init(rawValue:))
    }

    /// The chain the current call came through: every call is on someone's behalf.
    private func caller() throws -> CallChain {
        guard let chain = CallChain.current else {
            throw CallOnBehalfOfNoOne(actor: .virtual(Self.actorID(for: home)))
        }
        return chain
    }

    // MARK: Objects

    /// Creates an object named `name`, running a new type, a named type, or the type of an object
    /// here, shared from then on.
    /// - Parameters:
    ///   - name: What it's called: its id is the name's handle.
    ///   - description: What it was made for, as it's listed.
    ///   - spec: Where its type comes from.
    ///   - start: Values it holds instead of its type's starting ones, where given.
    public distributed func create(
        name: String, description: String? = nil, spec: Spec, start: [String: JSONValue] = [:]
    ) async throws
        -> ObjectIdentity
    {
        guard try object(named: name) == nil, state.type(named: name) == nil else {
            throw DynamicObjectsError.nameTaken(name)
        }
        // Its id is its name, as tools and code write it: stored, unique here, never another's.
        let identity = ObjectIdentity(rawValue: ObjectNames.handle(for: name))
        let id: BehaviorID
        switch spec {
        case .new(let source):
            try await check(source, as: identity)
            id = .new()
            try await emit(event: .typeWritten(id, source))
        case .sameAs(let object):
            // Only an object of this space: another space's isn't reached from here.
            if DynamicObject.space(of: object.id) != home, let other = DynamicObject.identity(of: object.id) {
                throw DynamicObjectsError.unknownObject(other)
            }
            let shared = try await object.identity
            guard let entry = state.entries.first(where: { $0.identity == shared }) else {
                throw DynamicObjectsError.unknownObject(shared)
            }
            id = entry.type
        case .type(let name):
            guard let shared = state.type(named: name) else { throw DynamicObjectsError.unknownType(name) }
            id = shared
        }
        guard let code = state.types[id] else { throw DynamicObjectsError.unknownType(id.rawValue) }
        // One that's there already, made by name or named by code, is changed, not made again.
        let existing = try await DynamicObject.identified(by: identity, in: home, on: actorSystem)
        do {
            let code = try await existing.source
            throw DynamicObjectsError.exists(identity.rawValue, type: code.type)
        } catch is NotAllowed {
            // It's there, but not the caller's to see: another's, or what another object holds.
            throw DynamicObjectsError.nameTaken(name)
        } catch is DynamicObjectError {
            // Not made yet, or removed, whose name is free.
        }
        guard !state.identities.contains(identity),
            try await ObjectNames.object(named: identity.rawValue, in: home, using: actorSystem) == nil
        else { throw DynamicObjectsError.nameTaken(name) }
        let made = try await DynamicObject.identified(by: identity, in: home, on: actorSystem)
        try await made.adopt(id, code: code)
        try await made.describe(name: name, description: description)
        if !start.isEmpty { try await made.set(values: start) }
        let access = try await made.access
        let maker = try await made.maker
        let place = try await made.madeIn
        try await emit(
            event: .added(identity, type: id, description: description, access: access, maker: maker, in: place))
        return identity
    }

    /// The types here no object runs yet, each one's spec by the type its code declares: what an
    /// object made with `Type()` will be.
    public distributed func unmadeTypes() throws -> [String: ObjectDescription] {
        let running = Set(state.entries.map(\.type))
        var specs: [String: ObjectDescription] = [:]
        for (_, type) in state.typeNames where !running.contains(type) {
            guard let source = state.types[type] else { continue }
            specs[source.type] = try checked(type, source).spec(description: nil)
        }
        return specs
    }

    /// The type whose actor is `type`, with its code as it is now: what an object made with
    /// `Type()` runs.
    public distributed func type(declaring type: ObjectTypeName) throws -> ObjectType {
        guard let id = state.type(declaring: type), let code = state.types[id] else {
            throw DynamicObjectsError.unknownType(type.rawValue)
        }
        return ObjectType(id: id, code: code)
    }

    // MARK: Built-in objects

    // MARK: Websites

    /// The websites made here, by name.
    public distributed var sites: [SiteName] { state.sites.sorted() }

    /// Its space's website named `name`, made the first time, which holds the name for the space:
    /// refused while another space holds the name.
    package distributed func site(named name: SiteName) async throws -> Website {
        let website = try await Website.named(name, in: home, on: actorSystem)
        if !state.sites.contains(name) {
            try await website.claim()
            try await emit(event: .siteMade(name))
        }
        return website
    }

    /// The website named `name` taken out of its space, as whoever may configure the space asks:
    /// its name free for any space from then on.
    public distributed func removeSite(_ name: SiteName) async throws {
        try configuring()
        guard state.sites.contains(name) else { return }
        try await Website.named(name, in: home, on: actorSystem).release()
        try await emit(event: .siteRemoved(name))
    }

    /// Refused unless whoever the call is on behalf of may configure its space.
    private func configuring() throws {
        let chain = try caller()
        guard chain.scope.space == home, chain.scope.permissions.configureSpace else { throw NotAllowed(.write) }
    }

    /// `code`, type `id`'s, as the checker reads it: read again only when it's other code than
    /// last time.
    private func checked(_ id: BehaviorID, _ code: Script) throws(CodeProblem) -> CheckedScript {
        if let read = checked[id], read.script == code { return read }
        let read = try CheckedScript(code)
        checked[id] = read
        return read
    }

    // MARK: Listing

    /// The objects made here by name that the call may read, as they're listed and found: each as
    /// its type and what it was made for say, without asking the objects.
    public distributed func held() async throws -> [ObjectEntry] {
        let reader = try caller()
        var held: [ObjectEntry] = []
        for entry in state.entries where entry.access.allows(reader, .read) {
            guard let code = state.types[entry.type] else { continue }
            let spec = try checked(entry.type, code).spec(description: entry.description)
            let object = try await object(entry.identity)
            held.append(
                ObjectEntry(
                    id: .virtual(DynamicObject.actorID(for: entry.identity, in: home)),
                    object: try DiscoverableObject.resolve(id: object.id, using: actorSystem), type: spec.type,
                    description: spec.description,
                    actions: spec.actions.map { ObjectCatalog.signature($0.key, input: $0.value.input) }.sorted(),
                    events: spec.events.keys.sorted()))
        }
        return held
    }

    /// The object `identity` changed who may read and write it: its listing follows, read from the
    /// object itself, which is what's true.
    distributed func accessChanged(_ identity: ObjectIdentity) async throws {
        guard state.identities.contains(identity) else { return }
        try await emit(event: .accessChanged(identity, try await object(identity).access))
    }

    /// The object made here under `name`, by its name or its handle, among those the call may read:
    /// its id is its name's handle.
    public distributed func object(named name: String) throws -> ObjectIdentity? {
        let reader = try caller()
        let handle = ObjectNames.handle(for: name)
        return state.entries.first { $0.identity.rawValue == handle && $0.access.allows(reader, .read) }?.identity
    }

    /// The object made here as `identity`.
    public distributed func held(_ identity: ObjectIdentity) async throws -> DynamicObject {
        try await object(identity)
    }

    /// Which of the objects made here the actor `id` is, if it's one of them.
    public distributed func identity(of id: ClusterSystem.ActorID) -> ObjectIdentity? {
        guard DynamicObject.space(of: id) == home else { return nil }
        return DynamicObject.identity(of: id).flatMap { state.identities.contains($0) ? $0 : nil }
    }

    /// The other objects made here running the same type as the object `identity`, by name: those
    /// the call may read.
    public distributed func sharing(_ identity: ObjectIdentity) async throws -> [String] {
        guard let entry = state.entries.first(where: { $0.identity == identity }) else {
            throw DynamicObjectsError.unknownObject(identity)
        }
        let reader = try caller()
        var names: [String] = []
        for other in state.entries
        where other.type == entry.type && other.identity != identity && other.access.allows(reader, .read) {
            if let name = try await object(other.identity).name { names.append(name) }
        }
        return names
    }

    /// Changes an object's type, which changes every object sharing it: an object made here by
    /// name, or one code named by its id.
    public distributed func update(_ identity: ObjectIdentity, source: Script) async throws {
        if let entry = state.entries.first(where: { $0.identity == identity }) {
            try await rewrite(entry.type, as: source)
            return
        }
        let named = try await DynamicObject.identified(by: identity, in: home, on: actorSystem)
        guard let type = try? await named.type else { throw DynamicObjectsError.unknownObject(identity) }
        try await rewrite(type, as: source)
        // It may be held by nothing made here by name, so it's told itself too.
        _ = try await named.typeChanged(type, code: source, reached: [])
    }

    /// The object with `identity`, made here by name or named by code with its id, if there's one.
    public distributed func existing(_ identity: ObjectIdentity) async throws -> DynamicObject? {
        let object = try await DynamicObject.identified(by: identity, in: home, on: actorSystem)
        return (try? await object.source) == nil ? nil : object
    }

    /// Defines a type: one with a name and no object, which objects can share. Defined again, it
    /// changes, and so does every object sharing it.
    public distributed func defineType(_ name: String, source: Script) async throws {
        if let id = state.type(named: name) {
            try await rewrite(id, as: source)
            return
        }
        guard try object(named: name) == nil else { throw DynamicObjectsError.nameTaken(name) }
        // No object is of it yet: its code is checked as each object adopts it.
        try await check(source, as: nil)
        let id = BehaviorID.new()
        try await emit(event: .typeWritten(id, source))
        try await emit(event: .typeNamed(name, id))
    }

    /// Gives the type `id` a new version, checked as a new one is: each object made here that the
    /// call may write is given it, runs it if it's of the type, and passes it on to the objects it
    /// holds, as down a tree.
    private func rewrite(_ id: BehaviorID, as source: Script) async throws {
        guard state.types[id] != nil else { throw DynamicObjectsError.unknownType(id.rawValue) }
        let writer = try caller()
        try await check(source, as: state.entries.first { $0.type == id }?.identity)
        try await emit(event: .typeWritten(id, source))
        var reached: Set<ObjectIdentity> = []
        for entry in state.entries where entry.access.allows(writer, .write) {
            reached = try await object(entry.identity).typeChanged(id, code: source, reached: reached)
        }
    }

    /// Removes one of these objects for good.
    public distributed func remove(_ identity: ObjectIdentity) async throws {
        guard state.identities.contains(identity) else { throw DynamicObjectsError.unknownObject(identity) }
        try await object(identity).remove()
        try await emit(event: .removed(identity))
    }

    /// The object held here as `identity`: a reference, resolved once.
    private func object(_ identity: ObjectIdentity) async throws -> DynamicObject {
        if let object = resolved[identity] { return object }
        guard state.entries.contains(where: { $0.identity == identity }) else {
            throw DynamicObjectsError.unknownObject(identity)
        }
        let object = try await DynamicObject.identified(by: identity, in: home, on: actorSystem)
        resolved[identity] = object
        return object
    }

    /// Every object held here, by identity, oldest first.
    public distributed var identities: [ObjectIdentity] { state.identities }

    /// It runs while someone follows its changes: its objects run themselves.
    public func shouldDeactivate() async -> Bool { pulls.isEmpty }

    // MARK: Following its changes

    /// That its objects changed, from now on, as they're made, removed or shared: for
    /// whoever shows them to list them again.
    public nonisolated func subscription() async throws -> Subscription<ObjectsChanged> {
        let subscriber = UUID()
        try await subscribe(subscriber)
        return Subscription(subscriber, pull: { try await self.next(for: $0) }, leave: { try await self.leave($0) })
    }

    distributed func subscribe(_ subscriber: UUID) {
        pulls.subscribe(subscriber)
    }

    distributed func next(for subscriber: UUID) async -> ObjectsChanged? {
        switch pulls.take(subscriber) {
        case .element(let change): return change
        case .ended: return nil
        case .empty: return await withCheckedContinuation { pulls.park(subscriber, $0) }
        }
    }

    distributed func leave(_ subscriber: UUID) {
        pulls.leave(subscriber)
    }

    public func handleEvent(_ event: DynamicObjectsEvent) {
        state.apply(event)
        // Whoever follows is told, as each change happens: replayed, there's no one to tell yet.
        pulls.tell(ObjectsChanged())
    }

    // MARK: Checks

    /// What's wrong with a type's own code before it runs: its Swift reads, the object `identity`
    /// starts with its checks holding, and what it reads of itself it declares. Other objects
    /// aren't read: each checks the messages it's sent, when they arrive.
    private func check(_ source: Script, as identity: ObjectIdentity?) async throws {
        if let identity { _ = try await ScriptInstance.starts(source, as: identity) }
        let problems = source.selfProblems
        if !problems.isEmpty { throw CodeProblem(problems.map(\.description).joined(separator: "\n")) }
    }
}

/// A type: which one, and its code as it is now.
public struct ObjectType: Codable, Sendable {
    public let id: BehaviorID
    public let code: Script
}

/// Where a new object's type comes from.
public enum Spec: Codable, Sendable, Equatable {
    /// A new type, from its source.
    case new(Script)
    /// The type another object runs, shared from then on.
    case sameAs(DynamicObject)
    /// A named type, shared from then on.
    case type(String)
}

/// What happened to an owner's types and objects, as journaled.
public enum DynamicObjectsEvent: Codable, Sendable {
    /// A type, new or changed.
    case typeWritten(BehaviorID, Script)
    /// A type named, with no object of its own.
    case typeNamed(String, BehaviorID)
    /// An object made by name, of a type, by `maker`: listed and found by the name it holds, to
    /// whoever may read it.
    case added(
        ObjectIdentity, type: BehaviorID, description: String?, access: Access, maker: CallScope, in: ConversationID?)
    /// Who may read and write an object changed, as the object says.
    case accessChanged(ObjectIdentity, Access)
    case removed(ObjectIdentity)
    /// A website made, its name its space's.
    case siteMade(SiteName)
    /// A website taken out, its name given up.
    case siteRemoved(SiteName)
}

public struct DynamicObjectsState: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let identity: ObjectIdentity
        public let type: BehaviorID
        /// What it was made for.
        public let description: String?
        /// Who may read and write it, as it last said: who it's listed to.
        public var access: Access
        /// Whoever made it, on whose behalf it's started.
        public let maker: CallScope
        /// The conversation it was made in, where it's started.
        public let place: ConversationID?
    }

    /// Each type as it is now.
    public var types: [BehaviorID: Script] = [:]
    /// The named types, with no object of their own.
    public var typeNames: [String: BehaviorID] = [:]
    /// The objects made by name, oldest first: what's listed and found here. An
    /// object that code made with `Type()` isn't one of them: it's reached through what holds it.
    public var entries: [Entry] = []
    /// The websites made here, by name.
    public var sites: Set<SiteName> = []

    public init() {}

    public var identities: [ObjectIdentity] { entries.map(\.identity) }

    /// The type whose actor is `type`: an object's here first, then a named one.
    func type(declaring type: ObjectTypeName) -> BehaviorID? {
        entries.lazy.map(\.type).first { types[$0]?.type == type.rawValue }
            ?? typeNames.values.first { types[$0]?.type == type.rawValue }
    }

    /// The type called `name`, by its name or its handle.
    func type(named name: String) -> BehaviorID? {
        typeNames.first { Self.key($0.key) == Self.key(name) || ObjectNames.handle(for: $0.key) == name }?.value
    }

    private static func key(_ name: String) -> String {
        name.trimmed().lowercased()
    }

    mutating func apply(_ event: DynamicObjectsEvent) {
        switch event {
        case .typeWritten(let id, let code):
            types[id] = code
        case .typeNamed(let name, let id):
            typeNames[name] = id
        case .added(let identity, let type, let description, let access, let maker, let place):
            entries.append(
                Entry(
                    identity: identity, type: type, description: description, access: access, maker: maker,
                    place: place))
        case .accessChanged(let identity, let access):
            if let index = entries.firstIndex(where: { $0.identity == identity }) { entries[index].access = access }
        case .removed(let identity):
            entries.removeAll { $0.identity == identity }
        case .siteMade(let name):
            sites.insert(name)
        case .siteRemoved(let name):
            sites.remove(name)
        }
    }
}

public enum DynamicObjectsError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case unknownObject(ObjectIdentity)
    case nameTaken(String)
    /// An object with this id is there already, of this type.
    case exists(String, type: String)
    case unknownType(String)

    public var description: String {
        switch self {
        case .unknownObject(let identity):
            "There's no object \(identity) here."
        case .exists(let id, let type):
            "`\(id)` already exists: it's a `\(type)`. Change it with edit_object."
        case .nameTaken(let name):
            "An object or type named \(name) already exists. Change it with edit_object, or choose another name."
        case .unknownType(let name):
            "There's no object or type \(name) here."
        }
    }
}

/// That a space's objects changed: someone showing them lists them again.
public struct ObjectsChanged: Codable, Sendable, Equatable {
    public init() {}
}
