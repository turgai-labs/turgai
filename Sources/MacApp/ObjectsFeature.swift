import ComposableArchitecture
import Foundation
import TurgaiModels
import TurgaiObjects
import TurgaiServer

/// One object in the cluster, as the objects window shows it.
struct ObjectRow: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    /// Its identity, when it's an object made here, which can be shared.
    let made: MadeObjectID?
    let summary: String?
    let actions: [String]
    /// What it announces, such as `RefundRequested`.
    let events: [String]
    /// The node the object lives on, such as `127.0.0.1:52034`.
    let node: String
}

/// The objects the signed-in account may read, following the runtime's object catalog.
@DependencyClient
struct ObjectsClient: Sendable {
    /// The current objects, then the whole list again whenever one joins or leaves.
    var live: @Sendable () -> AsyncStream<[ObjectRow]> = { .finished }
    /// Shares an object made here with everyone, as far as asked, or takes that back.
    var share: @Sendable (MadeObjectID, ObjectSharing) async throws -> Void
}

extension AsyncStream {
    fileprivate static var finished: AsyncStream<Element> { AsyncStream { $0.finish() } }
}

extension ObjectsClient: TestDependencyKey {
    static let testValue = ObjectsClient()

    /// No runtime, so no objects.
    static let unavailable = ObjectsClient(live: { .finished }, share: { _, _ in })

    static func live(_ source: TurgaiObjectCatalogSource) -> ObjectsClient {
        ObjectsClient(
            live: {
                AsyncStream { continuation in
                    let task = Task {
                        let catalog = await source.catalog()
                        guard let changes = await catalog.whenLocal({ $0.changes() }) else {
                            return continuation.finish()
                        }
                        for await _ in changes {
                            continuation.yield(await listed())
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            share: { made, sharing in
                guard let session = SessionStore.liveValue.load() else { return }
                var request = URLRequest(
                    url: LocalServer.baseURL.appending(path: "api/v1/objects/\(made.rawValue)/share"))
                request.httpMethod = "POST"
                request.setValue("\(LocalServer.sessionCookieName)=\(session.token)", forHTTPHeaderField: "Cookie")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(ObjectSharingRequest(everyone: sharing))
                let (_, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw ObjectSharingRefused() }
            })
    }
}

extension ObjectsClient {
    /// The objects the signed-in account may read, as the server lists them on its behalf in its
    /// chat: none when no one is signed in.
    fileprivate static func listed() async -> [ObjectRow] {
        guard let session = SessionStore.liveValue.load() else { return [] }
        var request = URLRequest(url: LocalServer.baseURL.appending(path: "api/v1/objects"))
        request.setValue("\(LocalServer.sessionCookieName)=\(session.token)", forHTTPHeaderField: "Cookie")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
            let listings = try? JSONDecoder().decode([ObjectListing].self, from: data)
        else { return [] }
        return listings.map(ObjectRow.init)
    }
}

extension ObjectRow {
    fileprivate init(_ listing: ObjectListing) {
        self.init(
            id: listing.id, title: listing.title, made: listing.made, summary: listing.summary,
            actions: listing.actions, events: listing.events, node: listing.node)
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
        /// Why sharing an object was refused, while it's shown.
        var refusal: String?
    }

    enum Action {
        /// The window appeared: follow the catalog while it's open.
        case appeared
        case changed([ObjectRow])
        /// Share an object made here with everyone, as far as asked, or take that back.
        case share(MadeObjectID, ObjectSharing)
        case shareRefused
        case refusalDismissed
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

            case .share(let made, let sharing):
                return .run { send in
                    do {
                        try await objects.share(made, sharing)
                    } catch {
                        await send(.shareRefused)
                    }
                }

            case .shareRefused:
                state.refusal = "Only someone who may change it can share it."
                return .none

            case .refusalDismissed:
                state.refusal = nil
                return .none
            }
        }
    }
}

/// Sharing an object wasn't done: the server refused it, or couldn't be reached.
private struct ObjectSharingRefused: Error {}
