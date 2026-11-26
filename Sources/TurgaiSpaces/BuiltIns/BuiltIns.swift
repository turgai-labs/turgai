import DiscoverableActors
import DistributedCluster
import TurgaiDomain
import TurgaiObjects

/// A built-in object every space has: how its objects in a space are reached.
public struct BuiltIn: Sendable {
    /// Its objects in a space, started there.
    let objects: @Sendable (SpaceID, DynamicObjects, ClusterSystem) async throws -> [DiscoverableObject]

    /// Every built-in there is, in the order they're offered. Weather is left out for now, so an
    /// object wrapping a weather API can be written without the built-in answering instead.
    public static let all: [BuiltIn] = [
        BuiltIn { space, _, system in
            [try DiscoverableObject.resolve(id: try await Scheduler.of(space, on: system).id, using: system)]
        },
        BuiltIn { space, _, system in
            [try DiscoverableObject.resolve(id: try await Timers.of(space, on: system).id, using: system)]
        },
    ]

    /// The built-in objects of `space`, as the catalog lists them: those the call's chain may read.
    public static func entries(in space: SpaceID, _ objects: DynamicObjects, on system: ClusterSystem)
        async throws -> [ObjectEntry]
    {
        var entries: [ObjectEntry] = []
        for builtIn in all {
            for object in try await builtIn.objects(space, objects, system) {
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
