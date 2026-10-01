import DiscoverableActors
import DistributedCluster
import Foundation

/// Search Apple Music and control playback on this Mac.
@Discoverable
public distributed actor Music {
    public typealias ActorSystem = ClusterSystem

    private let client: MusicClient

    public init(actorSystem: ActorSystem, client: MusicClient, scope: ObjectScope = .shared) async throws {
        self.actorSystem = actorSystem
        self.client = client
        let object = try DiscoverableObject.resolve(id: self.id, using: actorSystem)
        await actorSystem.receptionist.checkIn(object, with: scope.receptionistKey)
    }

    /// Search the Apple Music catalog for songs.
    @DiscoverableAction(safe: true, idempotent: true)
    public distributed func search(_ query: String) async throws -> [MusicSong] {
        try await client.search(query)
    }

    /// Play the best matching song or artist from Apple Music.
    public distributed func play(_ query: String) async throws {
        try await client.play(query)
    }

    /// The current track and whether Music is playing it.
    @DiscoverableAction(safe: true, idempotent: true)
    public distributed func nowPlaying() async throws -> MusicNowPlaying? {
        try await client.nowPlaying()
    }

    public distributed func pause() async { await client.pause() }

    public distributed func next() async throws { try await client.next() }

    public distributed func previous() async throws { try await client.previous() }
}

public struct MusicClient: Sendable {
    public var search: @Sendable (String) async throws -> [MusicSong]
    public var play: @Sendable (String) async throws -> Void
    public var nowPlaying: @Sendable () async throws -> MusicNowPlaying?
    public var pause: @Sendable () async -> Void
    public var next: @Sendable () async throws -> Void
    public var previous: @Sendable () async throws -> Void

    public init(
        search: @escaping @Sendable (String) async throws -> [MusicSong],
        play: @escaping @Sendable (String) async throws -> Void,
        nowPlaying: @escaping @Sendable () async throws -> MusicNowPlaying?,
        pause: @escaping @Sendable () async -> Void,
        next: @escaping @Sendable () async throws -> Void,
        previous: @escaping @Sendable () async throws -> Void
    ) {
        self.search = search
        self.play = play
        self.nowPlaying = nowPlaying
        self.pause = pause
        self.next = next
        self.previous = previous
    }
}

@Describable
public struct MusicNowPlaying: Codable, Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String?
    public var isPlaying: Bool

    public init(title: String, artist: String, album: String? = nil, isPlaying: Bool) {
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
    }
}

@Describable
public struct MusicSong: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: TimeInterval?

    public init(id: String, title: String, artist: String, album: String? = nil, duration: TimeInterval? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

public enum MusicError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case accessDenied
    case noMatch(String)
    /// Apple Music can't be reached from this build of Turgai.
    case catalogUnavailable
    /// Any other MusicKit failure, as text: MusicKit's own errors can't cross nodes.
    case failed(String)

    public var description: String {
        switch self {
        case .accessDenied:
            "Turgai isn't allowed to use Apple Music. Allow Music access in System Settings › Privacy & Security › Media & Apple Music."
        case .noMatch(let query): "Apple Music found no playable song for ‘\(query)’"
        case .catalogUnavailable:
            "Apple Music's catalog isn't available to this build of Turgai: its App ID needs the MusicKit service. Tell the user; retrying won't help."
        case .failed(let reason): "Apple Music failed: \(reason)"
        }
    }
}
