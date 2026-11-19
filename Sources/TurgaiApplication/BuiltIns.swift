import DiscoverableActors
import DistributedCluster
import TurgaiDomain
import TurgaiObjects

/// A built-in object a space can install: its kind, and how its objects in a space are reached.
public struct BuiltIn: Sendable {
    public let kind: BuiltInKind
    /// Its objects in a space, started there: one for most, one per site for websites.
    let objects: @Sendable (SpaceID, DynamicObjects, ClusterSystem) async throws -> [DiscoverableObject]

    /// Every built-in there is, in the order they're offered. Weather is left out for now, so an
    /// object wrapping a weather API can be written without the built-in answering instead.
    public static let all: [BuiltIn] = [
        BuiltIn(kind: Scheduler.kind) { space, _, system in
            [try DiscoverableObject.resolve(id: try await Scheduler.of(space, on: system).id, using: system)]
        },
        BuiltIn(kind: Timers.kind) { space, _, system in
            [try DiscoverableObject.resolve(id: try await Timers.of(space, on: system).id, using: system)]
        },
        BuiltIn(kind: Website.kind) { space, objects, system in
            var sites: [DiscoverableObject] = []
            for name in try await objects.sites {
                let site = try await Website.named(name, in: space, on: system)
                sites.append(try DiscoverableObject.resolve(id: site.id, using: system))
            }
            return sites
        },
    ]

    /// The built-in objects installed in `space`, each started and checked in there, where the
    /// space's code finds it by name, as the catalog lists them: those the call's chain may read.
    public static func entries(installedIn space: SpaceID, _ objects: DynamicObjects, on system: ClusterSystem)
        async throws -> [ObjectEntry]
    {
        let installed = Set(try await objects.installed)
        var entries: [ObjectEntry] = []
        for builtIn in all where installed.contains(builtIn.kind) {
            for object in try await builtIn.objects(space, objects, system) {
                await system.receptionist.checkIn(object, with: .virtualObjects(in: space))
                guard let virtual = object.id.virtualActorID, let description = try? await object.describe() else {
                    continue
                }
                entries.append(
                    ObjectEntry(
                        id: .virtual(virtual), object: object, type: description.type,
                        description: description.description,
                        actions: description.actions.map { ObjectCatalog.signature($0.key, input: $0.value.input) }
                            .sorted(),
                        events: description.events.keys.sorted()))
            }
        }
        return entries
    }
}

extension BuiltInKind {
    /// What a new space starts with: every built-in object there is.
    public static let installedInNewSpaces: [BuiltInKind] = BuiltIn.all.map(\.kind)
}
