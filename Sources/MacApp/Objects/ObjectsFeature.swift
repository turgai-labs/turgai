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
    /// One of the space's objects' card, by its handle as listed: what it is, its YAML and its Swift.
    var card: @Sendable (SpaceID, String) async throws -> ObjectCard
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
        },
        card: { space, handle in
            guard let session = SessionStore.liveValue.load() else { throw ObjectCardMissing() }
            var request = URLRequest(
                url: LocalServer.baseURL.appending(path: "api/v1/spaces/\(space.rawValue)/objects")
                    .appending(component: handle).appending(path: "card"))
            request.setValue("\(LocalServer.sessionCookieName)=\(session.token)", forHTTPHeaderField: "Cookie")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ObjectCardMissing() }
            return try JSONDecoder().decode(ObjectCard.self, from: data)
        })
}

/// An object's card that couldn't be had: no one signed in, or no object like it they may read.
struct ObjectCardMissing: Error {}

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
        /// The card shown for one of its objects, while it's open.
        var card: Card?

        var isRefused: Bool { refusal != nil }
        var isShowingCard: Bool { card != nil }
    }

    /// One object's card: what it is, its YAML and its Swift, once it's had.
    struct Card: Equatable {
        enum Content: Equatable {
            case loading
            case shown([CardBlock])
            case missing
        }

        let title: String
        var content = Content.loading
    }

    /// A part of a card, in the order it says them: a heading, some text, or a block of code.
    enum CardBlock: Equatable {
        case heading(String)
        case text(String)
        case code(language: String, String)
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
        /// Show an object's card: what it is, its YAML and its Swift.
        case cardTapped(ObjectRow)
        case cardLoaded(ObjectCard)
        case cardMissing
        /// The card's sheet: `false` once it's closed.
        case cardPresented(Bool)
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

            case .cardTapped(let row):
                guard let space = state.space else { return .none }
                state.card = Card(title: row.title)
                return .run { send in
                    do {
                        await send(.cardLoaded(try await objects.card(space, row.title)))
                    } catch {
                        await send(.cardMissing)
                    }
                }

            case .cardLoaded(let card):
                state.card?.content = .shown(Self.blocks(of: card.markdown))
                return .none

            case .cardMissing:
                state.card?.content = .missing
                return .none

            case .cardPresented(let presented):
                if !presented { state.card = nil }
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

extension ObjectsFeature {
    /// A card's Markdown as its parts: `#` headings, fenced blocks of code with their language, and
    /// the text between them, a paragraph at a time.
    static func blocks(of markdown: String) -> [CardBlock] {
        var blocks: [CardBlock] = []
        var code: (language: String, lines: [String])?
        var text: [String] = []
        func endText() {
            let paragraph = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty { blocks.append(.text(paragraph)) }
            text = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let open = code {
                if line.hasPrefix("```") {
                    blocks.append(.code(language: open.language, open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code?.lines.append(line)
                }
            } else if line.hasPrefix("```") {
                endText()
                code = (String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
            } else if line.hasPrefix("# ") {
                endText()
                blocks.append(.heading(String(line.dropFirst(2))))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                endText()
            } else {
                text.append(line)
            }
        }
        endText()
        if let open = code { blocks.append(.code(language: open.language, open.lines.joined(separator: "\n"))) }
        return blocks
    }
}
