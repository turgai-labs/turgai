import ComposableArchitecture
import Foundation
import TurgaiModels

/// One object in the cluster, as the objects window shows it.
package struct ObjectRow: Equatable, Identifiable, Sendable {
    package let id: String
    package let title: String
    /// Its identity, when it's an object made here, which can be shared.
    package let made: MadeObjectID?
    package let summary: String?
    package let actions: [String]
    /// What it announces, such as `RefundRequested`.
    package let events: [String]
    /// The node the object lives on, such as `127.0.0.1:52034`.
    package let node: String
}

/// A space's objects the signed-in account may read, as the server lists them on its behalf.
@DependencyClient
package struct ObjectsClient: Sendable {
    /// Shares an object made in the space with everyone in it, as far as asked, or takes that back.
    package var share: @Sendable (SpaceID, MadeObjectID, ObjectSharing) async throws -> Void
    /// One of the space's objects' card, by its handle as listed: what it is, its YAML and its Swift.
    package var card: @Sendable (SpaceID, String) async throws -> ObjectCard
}

extension ObjectsClient: DependencyKey {
    package static let testValue = ObjectsClient()

    package static let liveValue = ObjectsClient(
        share: { space, made, sharing in
            guard let session = SessionStore.liveValue.load() else { return }
            var request = session.request("api/v1/spaces/\(space.rawValue)/objects/\(made.rawValue)/share")
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(ObjectSharingRequest(everyone: sharing))
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw ObjectSharingRefused() }
        },
        card: { space, handle in
            guard let session = SessionStore.liveValue.load() else { throw ObjectCardMissing() }
            var request = session.request("api/v1/spaces/\(space.rawValue)/objects")
            request.url = request.url?.appending(component: handle).appending(path: "card")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ObjectCardMissing() }
            return try JSONDecoder().decode(ObjectCard.self, from: data)
        })
}

/// An object's card that couldn't be had: no one signed in, or no object like it they may read.
package struct ObjectCardMissing: Error {}

extension ObjectRow {
    fileprivate init(_ listing: ObjectListing) {
        self.init(
            id: listing.id, title: listing.title, made: listing.made, summary: listing.summary,
            actions: listing.actions, events: listing.events, node: listing.node)
    }
}

extension DependencyValues {
    package var objects: ObjectsClient {
        get { self[ObjectsClient.self] }
        set { self[ObjectsClient.self] = newValue }
    }
}

@Reducer
package struct ObjectsFeature {
    package init() {}

    @ObservableState
    package struct State: Equatable {
        package enum Listing: Equatable {
            /// Not listed yet.
            case waiting
            case live(IdentifiedArrayOf<ObjectRow>)
        }

        /// The space shown, whose objects are listed: none until the sidebar shows one.
        package var space: SpaceID?
        package var listing = Listing.waiting
        /// Why sharing an object was refused, while it's shown.
        package var refusal: String?

        package var isRefused: Bool { refusal != nil }

        /// Where `row`'s card is: the window that shows it, for the space shown.
        package func card(of row: ObjectRow) -> ObjectCardAddress? {
            space.map { ObjectCardAddress(space: $0, handle: row.title) }
        }
    }

    package enum Action {
        /// The sidebar shows another space: its objects are followed instead; none while it shows
        /// none.
        case spaceChanged(SpaceID?)
        case changed([ObjectRow])
        /// Share an object made here with everyone, as far as asked, or take that back.
        case share(MadeObjectID, ObjectSharing)
        case shareRefused
        /// The refusal's alert: `false` once it's closed.
        case refusalPresented(Bool)
    }

    @Dependency(\.objects) package var objects
    @Dependency(\.chat) package var chat

    fileprivate enum CancelID { case live }

    package var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
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
    /// `space`'s objects followed: as the server tells them now, and again each time they change,
    /// until another space is shown.
    private func follow(_ space: SpaceID?) -> Effect<Action> {
        guard let space else { return .cancel(id: CancelID.live) }
        return .run { send in
            await chat.following(.objects(space: space)) { heard in
                for await event in heard {
                    if case .objects(space, let listed) = event.payload {
                        await send(.changed(listed.map(ObjectRow.init)))
                    }
                }
            }
        }
        .cancellable(id: CancelID.live, cancelInFlight: true)
    }
}

/// Sharing an object wasn't done: the server refused it, or couldn't be reached.
private struct ObjectSharingRefused: Error {}
