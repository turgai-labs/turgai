import ComposableArchitecture
import Foundation
import TurgaiModels

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

/// A space's objects the signed-in account may read, as the server lists them on its behalf.
@DependencyClient
struct ObjectsClient: Sendable {
    /// The space's objects as they are now: none when no one is signed in.
    var list: @Sendable (SpaceID) async -> [ObjectRow] = { _ in [] }
    /// Shares an object made in the space with everyone in it, as far as asked, or takes that back.
    var share: @Sendable (SpaceID, MadeObjectID, ObjectSharing) async throws -> Void
}

extension ObjectsClient: DependencyKey {
    static let testValue = ObjectsClient()

    static let liveValue = ObjectsClient(
        list: { await listed(in: $0) },
        share: { space, made, sharing in
            guard let session = SessionStore.liveValue.load() else { return }
            var request = URLRequest(
                url: LocalServer.baseURL.appending(
                    path: "api/v1/spaces/\(space.rawValue)/objects/\(made.rawValue)/share"))
            request.httpMethod = "POST"
            request.setValue("\(LocalServer.sessionCookieName)=\(session.token)", forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(ObjectSharingRequest(everyone: sharing))
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw ObjectSharingRefused() }
        })
}

extension ObjectsClient {
    /// `space`'s objects the signed-in account may read, as the server lists them on its behalf:
    /// none when no one is signed in.
    fileprivate static func listed(in space: SpaceID) async -> [ObjectRow] {
        guard let session = SessionStore.liveValue.load() else { return [] }
        var request = URLRequest(
            url: LocalServer.baseURL.appending(path: "api/v1/spaces/\(space.rawValue)/objects"))
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
            /// Not listed yet.
            case waiting
            case live(IdentifiedArrayOf<ObjectRow>)
        }

        /// The space shown, whose objects are listed: none until the sidebar shows one.
        var space: SpaceID?
        var listing = Listing.waiting
        /// Why sharing an object was refused, while it's shown.
        var refusal: String?

        var isRefused: Bool { refusal != nil }
    }

    enum Action {
        /// The window appeared: follow the shown space's objects while it's open.
        case appeared
        /// The sidebar shows another space: its objects are followed instead.
        case spaceChanged(SpaceID)
        case changed([ObjectRow])
        /// Share an object made here with everyone, as far as asked, or take that back.
        case share(MadeObjectID, ObjectSharing)
        case shareRefused
        /// The refusal's alert: `false` once it's closed.
        case refusalPresented(Bool)
    }

    @Dependency(\.objects) var objects
    @Dependency(\.chat) var chat

    fileprivate enum CancelID { case live }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .appeared:
                return follow(state.space)

            case .spaceChanged(let space):
                guard state.space != space else { return .none }
                state.space = space
                state.listing = .waiting
                return follow(space)

            case .changed(let rows):
                state.listing = .live(IdentifiedArray(uniqueElements: rows))
                return .none

            case .share(let made, let sharing):
                guard let space = state.space else { return .none }
                return .run { send in
                    do {
                        try await objects.share(space, made, sharing)
                    } catch {
                        await send(.shareRefused)
                    }
                }

            case .shareRefused:
                state.refusal = "Only someone who may change it can share it."
                return .none

            case .refusalPresented(let presented):
                if !presented { state.refusal = nil }
                return .none
            }
        }
    }
}

extension ObjectsFeature {
    /// `space`'s objects followed: listed now, and again each time objects change, until another
    /// space is shown.
    private func follow(_ space: SpaceID?) -> Effect<Action> {
        guard let space else { return .none }
        return .run { send in
            // Listened to before it's joined, and joined before it's listed, so no change in
            // between goes unheard.
            let heard = await chat.events()
            try? await chat.perform(.join(.objects(space: space)))
            await send(.changed(await objects.list(space)))
            for await event in heard {
                if case .objectsChanged = event.payload { await send(.changed(await objects.list(space))) }
            }
            try? await chat.perform(.leave(.objects(space: space)))
        }
        .cancellable(id: CancelID.live, cancelInFlight: true)
    }
}

/// Sharing an object wasn't done: the server refused it, or couldn't be reached.
private struct ObjectSharingRefused: Error {}
