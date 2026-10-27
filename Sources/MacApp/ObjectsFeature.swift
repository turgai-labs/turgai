import ComposableArchitecture
import Foundation
import TurgaiObjects
import TurgaiServer

/// One object in the cluster, as the objects window shows it.
struct ObjectRow: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let summary: String?
    let actions: [String]
    /// What it announces, such as `RefundRequested`.
    let events: [String]
    /// The node the object lives on, such as `127.0.0.1:52034`.
    let node: String
}

/// The machine's objects in the cluster, following the runtime's object catalog.
@DependencyClient
struct ObjectsClient: Sendable {
    /// The current objects, then the whole list again whenever one joins or leaves.
    var live: @Sendable () -> AsyncStream<[ObjectRow]> = { .finished }
}

extension AsyncStream {
    fileprivate static var finished: AsyncStream<Element> { AsyncStream { $0.finish() } }
}

extension ObjectsClient: TestDependencyKey {
    static let testValue = ObjectsClient()

    /// No runtime, so no objects.
    static let unavailable = ObjectsClient(live: { .finished })

    static func live(_ source: TurgaiObjectCatalogSource) -> ObjectsClient {
        ObjectsClient(live: {
            AsyncStream { continuation in
                let task = Task {
                    let catalog = await source.catalog()
                    guard let changes = await catalog.whenLocal({ $0.changes() }) else {
                        return continuation.finish()
                    }
                    for await _ in changes {
                        let entries = (try? await catalog.entries()) ?? []
                        continuation.yield(entries.map(ObjectRow.init))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        })
    }
}

extension ObjectRow {
    fileprivate init(_ entry: ObjectEntry) {
        let endpoint = entry.object.id.node.endpoint
        self.init(
            id: entry.object.id.description,
            title: entry.id.description,
            summary: entry.description,
            actions: entry.actions,
            events: entry.events,
            node: "\(endpoint.host):\(endpoint.port)"
        )
    }
}

extension DependencyValues {
    var objects: ObjectsClient {
        get { self[ObjectsClient.self] }
        set { self[ObjectsClient.self] = newValue }
    }
}

@Reducer
struct ObjectsFeature {
    @ObservableState
    struct State: Equatable {
        enum Listing: Equatable {
            /// The runtime's catalog hasn't answered yet.
            case waiting
            case live(IdentifiedArrayOf<ObjectRow>)
        }

        var listing = Listing.waiting
    }

    enum Action {
        /// The window appeared: follow the catalog while it's open.
        case appeared
        case changed([ObjectRow])
    }

    @Dependency(\.objects) var objects

    private enum CancelID { case live }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .appeared:
                return .run { send in
                    for await rows in objects.live() {
                        await send(.changed(rows))
                    }
                }
                .cancellable(id: CancelID.live, cancelInFlight: true)

            case .changed(let rows):
                state.listing = .live(IdentifiedArray(uniqueElements: rows))
                return .none
            }
        }
    }
}
