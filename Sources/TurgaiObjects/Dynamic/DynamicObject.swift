import DiscoverableActors
import Distributed
import DistributedCluster
import EventSourcing
import Foundation
import VirtualActors

/// An object that runs Swift a model wrote, its ``Script``, the way an Erlang process runs a
/// module: a name, the kind it runs, and its own fields. Its code runs as a live instance of its
/// actor, on this actor: it handles one message at a time, and messages interleave only where one
/// waits on another object, as Swift actors do. To other objects and to models, it's an object
/// like any other: each message its kind takes is one of its actions.
///
/// It's a virtual actor keyed by its ``ObjectIdentity``: whoever has the identity can always
/// reach it, and it starts on demand, on any node. What happens to it is journaled, so it comes
/// back after a restart with the same fields. ``DynamicObjects`` creates, upgrades and removes
/// them.
@EventSourced
@VirtualActor
public distributed actor DynamicObject: DiscoverableActor {
    public typealias ActorSystem = ClusterSystem
    public typealias Dependency = ObjectIdentity
    public typealias Event = DynamicObjectEvent
    public typealias State = DynamicObjectState

    public var state = DynamicObjectState.unmade
    private let ownIdentity: ObjectIdentity
    /// Its code: stopped, or running as an instance started from what's journaled. It stops when
    /// its kind changes or a message fails, as an Erlang process restarts from its last state.
    private var process = Process.stopped(generation: 0)
    /// Its subscribers, to the events the code it runs announces: replaced with each new code, so
    /// subscribers find theirs ended, and subscribe again.
    private var hub = _DiscoveryEventHub(events: [])
    /// The objects it follows, by the `@Subscribed` field holding each.
    private var followers: [String: Follower] = [:]

    /// An object followed: the one the field held, and the task delivering its events.
    private struct Follower: Sendable {
        let source: ObjectReference
        let task: Task<Void, Never>
    }

    /// An object's code, as it runs on this actor. Each start is a generation: a task belongs to
    /// the instance that started it, and is gone with it.
    private enum Process {
        case stopped(generation: Int)
        case running(ScriptInstance, generation: Int, tasks: [Int: Task<Void, Never>])

        var generation: Int {
            switch self {
            case .stopped(let generation), .running(_, let generation, _): generation
            }
        }
    }

    /// What it follows ends with it. (Its code's tasks hold it while they run, so none outlive it.)
    deinit {
        for follower in followers.values { follower.task.cancel() }
    }

    public init(actorSystem: ClusterSystem, dependency identity: ObjectIdentity) async throws {
        self.actorSystem = actorSystem
        self.ownIdentity = identity
        try await actorSystem.journal.register(actor: self, with: Self.persistenceID(for: identity))
        if case .live(let object) = state {
            try await checkIn(object.scope)
            try rehub()
            refollow()
        }
    }

    /// The object with `identity`, started if it isn't running.
    public static func resolve(on system: ClusterSystem, identity: ObjectIdentity) async throws -> DynamicObject {
        try await system.virtualActors.getActor(identifiedBy: actorID(for: identity), dependency: identity)
    }

    static func actorID(for identity: ObjectIdentity) -> VirtualActorID {
        VirtualActorID(rawValue: "dynamic-object:\(identity.rawValue)")
    }

    static func persistenceID(for identity: ObjectIdentity) -> String {
        "turgai-object-\(identity.rawValue)"
    }

    /// Which object this is: its own, kept across restarts, unlike its actor ID.
    public distributed var identity: ObjectIdentity { ownIdentity }

    public func handleEvent(_ event: DynamicObjectEvent) {
        state = state.applying(event)
    }

    // MARK: Lifecycle

    /// Makes this object `name`, running `kind`, holding `start`. An object is created once.
    distributed func create(
        name: String, description: String?, kind: Script, id: BehaviorID, start: [String: JSONValue], scope: ObjectScope
    ) async throws {
        let birth = Birth(name: name, description: description, kind: kind, id: id, scope: scope, start: start, at: Date())
        try await emit(event: try state.creating(birth))
        try await checkIn(scope)
        try rehub()
        refollow()
    }

    /// Runs a new version of the kind it shares, from its next message on, once it isn't handling
    /// one: the way a new module reaches an Erlang process. Data new to it starts as `starts` has
    /// it; what it holds stays its own.
    distributed func adopt(_ kind: Script, starts: [String: JSONValue]) async throws {
        try await emit(event: try state.live.adopting(kind, starts: starts))
        stop()
        try rehub()
        refollow()
    }

    /// Sets values of its own data, for it alone: objects sharing its kind keep theirs.
    public distributed func set(values: [String: JSONValue]) async throws {
        try await emit(event: try state.live.setting(values))
        stop()
        refollow()
    }

    /// Starts it if it isn't running: being called is what starts a virtual actor, and starting
    /// checks it in, so it's findable.
    distributed func start() {}

    /// It runs while it's living, so it stays findable.
    public func shouldDeactivate() async -> Bool {
        if case .live = state { false } else { true }
    }

    /// Ends the object for good: it answers nothing from now on, and the next idle sweep stops
    /// it, which takes it out of the catalog.
    distributed func remove() async throws {
        try await emit(event: try state.removing())
        stop()
        try rehub()
        refollow()
    }

    /// Checks in under its stable reference, the one ``resolve(on:identity:)`` returns, which
    /// keeps reaching it after it restarts.
    private func checkIn(_ scope: ObjectScope) async throws {
        let reference = try await reference()
        let object = try DiscoverableObject.resolve(id: reference.id, using: actorSystem)
        await actorSystem.receptionist.checkIn(object, with: scope.receptionistKey)
        await actorSystem.receptionist.checkIn(reference, with: scope.madeObjectsKey)
    }

    /// The reference it checks in under: the one to know it by.
    public distributed var stableReference: DynamicObject {
        get async throws { try await reference() }
    }

    /// Its own reference, which keeps reaching it after it restarts: what it checks in under, and
    /// passes on as `self`. Resolving its identity gives the same reference each time.
    private func reference() async throws -> DynamicObject {
        try await Self.resolve(on: actorSystem, identity: ownIdentity)
    }

    // MARK: DiscoverableActor
    //
    // Every requirement is implemented `async`: a sync implementation can be bypassed by the
    // library's async `invoke` overloads (https://github.com/swiftlang/swift/issues/92795).

    /// Its kind, as it's kept, for changing it.
    public distributed var source: Script {
        get throws { try state.live.kind }
    }

    /// Whether its code is working, and why not when it isn't.
    public distributed var health: Health {
        get throws { try state.live.health }
    }

    /// What happened to it lately, newest first.
    public distributed var recent: [Happening] {
        get throws { try state.live.recent }
    }

    public distributed func describe() async throws -> ObjectDescription {
        let object = try state.live
        return try object.kind.spec(title: object.name, description: object.description, holding: object.fields)
    }

    static func schema(of value: JSONValue) -> [String: JSONValue] {
        if ObjectReference(value) != nil { return ["x-actor-reference": true] }
        switch value {
        case .array: return ["type": "array"]
        case .string: return ["type": "string"]
        case .bool: return ["type": "boolean"]
        case .integer, .unsignedInteger: return ["type": "integer"]
        case .number: return ["type": "number"]
        case .object: return ["type": "object"]
        case .null: return [:]
        }
    }

    public distributed func read(property name: String) async throws -> JSONValue {
        guard let value = try state.live.fields[name] else {
            throw DiscoveryError.unknownProperty(name)
        }
        return value
    }

    public distributed func _subscribe(_ subscriber: UUID, to event: String) async throws {
        try hub.subscribe(subscriber, to: event)
    }

    public distributed func _nextEvent(for subscriber: UUID) async throws -> _EventDelivery {
        await hub.next(for: subscriber)
    }

    public distributed func _unsubscribe(_ subscriber: UUID) async throws {
        hub.unsubscribe(subscriber)
    }

    /// A hub for the events its code announces now, after its code changed: none for an object
    /// that isn't living.
    private func rehub() throws {
        let events: Set<String> = if case .live(let object) = state { try object.announces() } else { [] }
        hub = _DiscoveryEventHub(events: events)
    }

    // MARK: Messages

    /// Handles a message the way its kind says: its method runs on its instance, what it holds
    /// that changed is journaled, and its reply comes back.
    @discardableResult
    public distributed func invoke(_ action: String, arguments: JSONValue) async throws -> JSONValue {
        try await respond(action, arguments: arguments).reply
    }

    /// Handles a message as ``invoke(_:arguments:)`` does, with what its code printed.
    public distributed func respond(_ action: String, arguments: JSONValue) async throws -> ObjectReply {
        try await respond(action, arguments: arguments, chain: .start)
    }

    /// Handles a message another object's code sent, in the chain of calls it came through. A
    /// message that fails is journaled with why, and stops its code, to start again from what's
    /// journaled.
    public distributed func respond(_ action: String, arguments: JSONValue, chain: CallChain) async throws -> ObjectReply {
        try await handling(action, arguments: arguments, origin: .message(Delivery(message: action, arguments: arguments, at: Date())), chain: chain)
    }

    /// Handles `action` with `arguments`, run by `origin`: a message, or an event of an object it
    /// follows. What it changed is journaled, then what it announced, which its subscribers get.
    private func handling(_ action: String, arguments: JSONValue, origin: Origin, chain: CallChain) async throws -> ObjectReply {
        try state.live.taking(action)
        let instance: ScriptInstance
        let reply: ObjectReply
        let after: [String: JSONValue]
        do {
            instance = try await running()
            reply = try await CallChain.$current.withValue(chain) { try await instance.handle(action, arguments: arguments) }
            after = try await instance.fields()
        } catch {
            stop()
            try await emit(event: .failed(origin, problem: String(describing: error)))
            throw error
        }
        if let event = try state.live.handling(origin, holding: after) { try await emit(event: event) }
        try await announce(reply.announced)
        refollow()
        return ObjectReply(reply: try Self.replacingSelf(in: reply.reply, with: try await me()), printed: reply.printed, announced: reply.announced)
    }

    /// Journals each event it announced, then hands it to its subscribers.
    private func announce(_ announcements: [Announcement]) async throws {
        for announcement in announcements {
            try await emit(event: .announced(announcement))
            hub.announce(announcement.values, named: announcement.event)
        }
    }

    // MARK: Its code

    /// Its instance, started from what's journaled if it isn't running. Calling another object
    /// from its code is calling that object, whose reply the call returns.
    private func running() async throws -> ScriptInstance {
        if case .running(let instance, _, _) = process { return instance }
        let object = try state.live
        let me = try await me()
        let scopes = Self.scopes(around: object.scope)
        let system = actorSystem
        let generation = process.generation + 1
        let started = try await ScriptInstance.start(
            object.kind, holding: object.fields,
            reaches: { recipient, request in
                let callee = try await Self.recipient(recipient, me: me, scopes: scopes, home: object.scope, using: system)
                switch (request, callee) {
                case (.call(let message, let arguments), .made(let callee)):
                    // A call continues the chain of the message it's made in.
                    let chain = try CallChain.current.continuing(from: object.name)
                    return try await callee.respond(message, arguments: try Self.replacingSelf(in: arguments, with: me), chain: chain).reply
                case (.call(let message, let arguments), .other(let callee)):
                    return try await callee.invoke(message, arguments: try Self.replacingSelf(in: arguments, with: me))
                // What another kind of object publishes; an object made here only answers messages.
                case (.read(let name), .other(let callee)):
                    return try await callee.read(property: name)
                case (.read(let name), .made):
                    throw DynamicObjectError.notPublished(name)
                }
            },
            schedules: { [self] id in Task { await self.whenLocal { $0.startTask(id, of: generation) } } },
            cancels: { [self] id in Task { await self.whenLocal { $0.cancelTask(id, of: generation) } } })
        // Another message may have started it while this one waited.
        if case .running(let instance, _, _) = process { return instance }
        process = .running(started, generation: generation, tasks: [:])
        return started
    }

    /// Stops its code: the next message starts it again from what's journaled, and the tasks it
    /// started are gone with it.
    private func stop() {
        if case .running(_, _, let tasks) = process { tasks.values.forEach { $0.cancel() } }
        process = .stopped(generation: process.generation)
    }

    /// Starts the task its code started as `id`, on this actor, as a Swift task inherits the actor
    /// it's made on. What it changes is journaled; when it fails, that's journaled, and its code
    /// stops.
    private func startTask(_ id: Int, of generation: Int) {
        guard case .running(let instance, generation, var tasks) = process else { return }
        tasks[id] = Task {
            let origin = Origin.task(at: Date())
            do {
                // A task's starter doesn't wait on it: its calls start a chain of their own.
                let announced = try await CallChain.$current.withValue(.start) { try await instance.runTask(id) }
                let after = try await instance.fields()
                taskEnded(id, of: generation)
                if let event = try state.live.handling(origin, holding: after) { try await emit(event: event) }
                try await announce(announced)
                refollow()
            } catch {
                taskEnded(id, of: generation)
                guard case .running(_, generation, _) = process else { return }
                stop()
                try? await emit(event: .failed(origin, problem: String(describing: error)))
            }
        }
        process = .running(instance, generation: generation, tasks: tasks)
    }

    private func cancelTask(_ id: Int, of generation: Int) {
        guard case .running(_, generation, let tasks) = process else { return }
        tasks[id]?.cancel()
    }

    private func taskEnded(_ id: Int, of generation: Int) {
        guard case .running(let instance, generation, var tasks) = process else { return }
        tasks[id] = nil
        process = .running(instance, generation: generation, tasks: tasks)
    }

    // MARK: Following

    /// Follows the objects its `@Subscribed` fields hold now: a field holding another object than
    /// before follows that one instead, and one that's gone, or a removed object, follows nothing.
    private func refollow() {
        guard case .live(let object) = state, let shape = try? ObjectShape(object.kind) else {
            for follower in followers.values { follower.task.cancel() }
            followers = [:]
            return
        }
        var wanted: [String: ObjectReference] = [:]
        for field in shape.subscriptions {
            if let held = object.fields[field].flatMap(ObjectReference.init) { wanted[field] = held }
        }
        for (field, follower) in followers where wanted[field] != follower.source {
            follower.task.cancel()
            followers[field] = nil
        }
        let handlers = Set(shape.messages.map(\.name))
        for (field, source) in wanted where followers[field] == nil {
            // It follows for as long as the object lives and its node runs: the task holds it only
            // while following, so the object can go, and the task with it.
            followers[field] = Follower(source: source, task: Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, !self.actorSystem.isTerminated else { return }
                    guard await self.whenLocal({ await $0.follow(field, holding: source, handlers: handlers) }) == true else { return }
                    try? await Task.sleep(for: .seconds(1))
                }
            })
        }
    }

    /// Delivers the events of the object `field` holds that the code has a method for, named like
    /// each, until they end: whether it should follow again, which a source that's gone, or not
    /// there yet, should be.
    private func follow(_ field: String, holding reference: ObjectReference, handlers: Set<String>) async -> Bool {
        do {
            let object = try state.live
            let source = try await Self.discoverable(
                reference, me: try await me(), scopes: Self.scopes(around: object.scope), home: object.scope, using: actorSystem)
            let events = try await source.describe().events.keys.filter { handlers.contains(Self.handler(for: $0)) }
            guard !events.isEmpty else { return false }
            let pulls = events.map { event in Task { await pull(event, from: source, into: field) } }
            await withTaskCancellationHandler {
                for pull in pulls { await pull.value }
            } onCancel: {
                for pull in pulls { pull.cancel() }
            }
        } catch {
            actorSystem.log.warning("A dynamic object can't follow an object", metadata: ["object": "\(ownIdentity)", "field": "\(field)", "error": "\(error)"])
        }
        return true
    }

    /// Subscribes to `event` of `source`, and delivers each one until it ends.
    private func pull(_ event: String, from source: DiscoverableObject, into field: String) async {
        let subscriber = UUID()
        do {
            try await source._subscribe(subscriber, to: event)
            while !Task.isCancelled {
                switch try await source._nextEvent(for: subscriber) {
                case .event(let values): await deliver(event, values: values, from: field)
                case .idle: continue
                case .ended: return
                }
            }
            try await source._unsubscribe(subscriber)
        } catch {
            actorSystem.log.warning("A dynamic object's subscription ended", metadata: ["object": "\(ownIdentity)", "event": "\(event)", "error": "\(error)"])
        }
    }

    /// An event of an object it follows, handled by its method named like it, as any message is:
    /// journaled, with what failed if it did.
    private func deliver(_ event: String, values: JSONValue, from field: String) async {
        let handler = Self.handler(for: event)
        let origin = Origin.event(Delivery(message: handler, arguments: values, at: Date()), from: field)
        do {
            _ = try await handling(handler, arguments: values, origin: origin, chain: .start)
        } catch {
            // Journaled as it failed; the next event is delivered all the same.
        }
    }

    /// The function that handles `event`: on and its name, `buttonPressed`'s and `ButtonPressed`'s
    /// `onButtonPressed`.
    public static func handler(for event: String) -> String {
        "on" + event.prefix(1).uppercased() + event.dropFirst()
    }

    /// Itself, as it's passed on: its stable reference.
    private func me() async throws -> ActorReference {
        try ActorReference(try await reference())
    }

    // MARK: Calling other objects

    /// An object a call goes to: one made here, which takes the chain of calls along, or another
    /// kind of object, which doesn't.
    private enum Callee {
        case made(DynamicObject)
        case other(DiscoverableObject)
    }

    /// Who a call goes to: a living actor, an object by its name, a virtual one by its id and
    /// type, or itself.
    private static func recipient(
        _ recipient: ObjectReference, me: ActorReference, scopes: [ObjectScope], home: ObjectScope, using system: ClusterSystem
    ) async throws -> Callee {
        switch recipient {
        case .actor(let reference):
            return await callee(try reference.resolve(using: system), scopes: scopes, using: system)
        case .itself:
            return await callee(try me.resolve(using: system), scopes: scopes, using: system)
        case .named(let name):
            guard let found = await ObjectNames.object(named: name, in: scopes, using: system) else {
                throw DynamicObjectError.noObjectNamed(name)
            }
            return await callee(found.object, scopes: scopes, using: system)
        case .virtual(let id, let type):
            // The object with that id, which may be one the machine has, or else one activated in
            // this object's scope as its type.
            if let found = await ObjectNames.object(named: id, in: scopes, using: system) {
                return await callee(found.object, scopes: scopes, using: system)
            }
            let identity = try await DynamicObjects.resolve(on: system, scope: home).object(id: id, type: type)
            return .made(try await DynamicObject.resolve(on: system, identity: identity))
        }
    }

    /// The object a reference is to, as any object is reached: to describe, and to subscribe to.
    private static func discoverable(
        _ reference: ObjectReference, me: ActorReference, scopes: [ObjectScope], home: ObjectScope, using system: ClusterSystem
    ) async throws -> DiscoverableObject {
        switch try await recipient(reference, me: me, scopes: scopes, home: home, using: system) {
        case .made(let object): try DiscoverableObject.resolve(id: object.id, using: system)
        case .other(let object): object
        }
    }

    /// `object` as a callee: one made here, when it's checked in as what it is.
    private static func callee(_ object: DiscoverableObject, scopes: [ObjectScope], using system: ClusterSystem) async -> Callee {
        for scope in scopes {
            for made in await system.receptionist.lookup(scope.madeObjectsKey) where made.id == object.id {
                return .made(made)
            }
        }
        return .other(object)
    }

    /// The scopes an object of `scope` can name objects in: its own, and the machine's.
    static func scopes(around scope: ObjectScope) -> [ObjectScope] {
        switch scope {
        case .shared: [.shared]
        case .owned(let user): ObjectScope.visible(to: user)
        }
    }

    /// Itself, passed on in a value, is this object's own reference, to pass on as a reply-to.
    private static func replacingSelf(in value: JSONValue, with me: ActorReference) throws -> JSONValue {
        if ObjectReference(value) == .itself { return try ObjectReference.actor(me).json }
        switch value {
        case .object(let members): return .object(try members.mapValues { try replacingSelf(in: $0, with: me) })
        case .array(let items): return .array(try items.map { try replacingSelf(in: $0, with: me) })
        default: return value
        }
    }
}

/// A message's reply, and what the object's code printed handling it.
public struct ObjectReply: Codable, Sendable, Equatable {
    public let reply: JSONValue
    public let printed: [String]
    /// The events it announced handling it.
    public let announced: [Announcement]
}

/// Which behavior an object runs, shared with every object running the same one.
public struct BehaviorID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func new() -> BehaviorID {
        BehaviorID(rawValue: UUID().uuidString.lowercased())
    }
}

/// A dynamic object's own identity, given when it's created and kept across restarts.
public struct ObjectIdentity: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A new, unique identity.
    public static func new() -> ObjectIdentity {
        ObjectIdentity(rawValue: UUID().uuidString.lowercased())
    }

    public var description: String { rawValue }
}

/// A dynamic object in a signature, such as an object to change, is a reference to it.
extension DynamicObject: Describable {
    public static var jsonSchema: JSONValue {
        _DiscoverySupport.actorReferenceSchema
    }
}

/// An identity in a signature is its string.
extension ObjectIdentity: Describable {
    public static var jsonSchema: JSONValue {
        ["type": "string", "description": "An object's identity."]
    }
}
